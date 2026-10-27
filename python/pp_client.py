"""
pp_client.py - runs on ONE machine (not on users' PCs).

Reads production data from SAP over the REST service  /sap/zpp/analytics  (class ZCL_PP_REST),
keeps a local cache, runs production_analytics.py on it and writes the results back to
the SAP Z tables (ZPP_ORD, ZPP_COMP, ZPP_GRP, ZPP_DRV, ZPP_RUNLOG).
Users only open the SAP report ZPP_PRED_REP.

    py pp_client.py ping                  test the connection
    py pp_client.py full  [--from YYYYMMDD] [--to YYYYMMDD]    first load (default: last 730 days)
    py pp_client.py delta                 every 30 min: only orders with new postings/confirmations
    py pp_client.py nightly               once a night: delta + recalculate the last 45 days
                                          + group comparison + drivers
    options: --dry          do not send anything to SAP, write the JSON into the out folder
             --max-pages N  fetch only N pages of orders (testing)
             --recalc-days N  nightly window (default 45)

Settings: .env file next to this script (or environment variables)
    SAP_URL=https://host:port/sap/zpp/analytics      SAP_CLIENT=100
    SAP_USER=...   SAP_PASSWORD=...           SAP_VERIFY_SSL=1 (0 = do not check the certificate, tests only)
    SAP_CA_BUNDLE=         optional: path to the company root certificate (.pem) when SAP uses an internal CA
    SAP_ALLOW_HTTP=0       1 = allow plain http:// (DEV tests only; production must use https)
    PP_KEEP_OUT=0          1 = keep the result files (out folder) after the upload; default: delete them
    SAP_PLANTS=            optional, comma separated
    WORK_DIR=              default: folder "work" next to the script
Install once:  py -m pip install pandas numpy scikit-learn scipy matplotlib requests
"""

import csv
import io
import json
import logging
import os
import subprocess
import sys
import time
from datetime import datetime, timedelta
from logging.handlers import RotatingFileHandler

import pandas as pd
import requests

HERE = os.path.dirname(os.path.abspath(__file__))
ANALYTICS = os.path.join(HERE, "production_analytics.py")
PAGE = 300                 # orders per request
BATCH = 200                # orders per upload request
OVERLAP_MIN = 10           # delta window overlaps the last run by 10 minutes
KEEP_DAYS = 800            # older orders are dropped from the local cache

# column names of the analytics result files -> field names of the SAP Z tables
ORD_MAP = {"order": "aufnr", "status": "status", "plant": "werks", "material": "matnr",
           "material_desc": "maktx", "material_group": "matkl", "order_type": "auart",
           "work_center": "arbpl", "shift": "shift", "prod_supervisor": "fevor",
           "actual_finish": "finish_date", "target_qty": "target_qty", "delivered_qty": "deliv_qty",
           "unit": "meins", "own_issued_qty": "own_issued_qty", "planned_value": "plan_value",
           "actual_value": "act_value", "excess_value": "excess_value", "currency": "waers",
           "variance_pct": "variance_pct", "components": "comp_cnt", "flagged_components": "flag_cnt",
           "unplanned_components": "unplan_cnt", "scrap_qty": "scrap_qty", "scrap_unit": "scrap_unit",
           "scrap_rate": "scrap_rate", "scrap_flag": "scrap_flag", "explanation": "explanation"}
COMP_MAP = {"order": "aufnr", "item": "item", "flag": "flag", "plant": "werks", "material": "matnr",
            "material_group": "matkl", "work_center": "arbpl", "shift": "shift",
            "actual_finish": "finish_date", "component": "comp_matnr", "component_desc": "comp_desc",
            "component_group": "comp_matkl", "in_plan": "in_plan", "planned_qty": "plan_qty",
            "planned_for_actual": "plan_for_act", "actual_qty": "act_qty",
            "actual_without_reservation": "act_nores_qty", "unit": "meins", "variance_qty": "var_qty",
            "variance_pct": "variance_pct", "typical_variance_pct": "typ_var_pct", "z_score": "z_score",
            "excess_value": "excess_value", "currency": "waers", "explanation": "explanation"}
GRP_MAP = {"dimension": "dimension", "group": "grp", "group_desc": "group_desc", "orders": "order_cnt",
           "value_share": "value_share", "variance_pct": "variance_pct",
           "others_variance_pct": "oth_var_pct", "difference_pp": "diff_pp",
           "variance_significant": "var_signif", "excess_value": "excess_value", "scrap_rate": "scrap_rate",
           "others_scrap_rate": "oth_scrap_rate", "scrap_difference_pct": "scrap_diff_pct",
           "scrap_significant": "scrap_signif", "finding": "finding"}
DRV_MAP = {"target": "target", "rank": "rank", "driver": "driver", "meaning": "meaning",
           "importance_pct": "importance_pct", "model_r2": "model_r2"}
INT_FIELDS = {"comp_cnt", "flag_cnt", "unplan_cnt", "order_cnt", "rank"}
DATE_FIELDS = {"finish_date"}

log = logging.getLogger("pp_client")


# ---------------------------------------------------------------- settings
def load_env():
    path = os.path.join(HERE, ".env")
    if os.path.exists(path):
        with open(path, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


def cfg(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"Missing setting {name} (.env file next to pp_client.py)")
    return v


class Sap:
    def __init__(self):
        self.url = cfg("SAP_URL", required=True).rstrip("/")
        if self.url.lower().startswith("http://") and cfg("SAP_ALLOW_HTTP", "0") != "1":
            sys.exit("SAP_URL uses plain HTTP: the password would travel unencrypted. "
                     "Use https:// (production) or set SAP_ALLOW_HTTP=1 (DEV tests only).")
        self.s = requests.Session()
        self.s.auth = (cfg("SAP_USER", required=True), cfg("SAP_PASSWORD", required=True))
        ca = cfg("SAP_CA_BUNDLE", "")          # company root certificate file (PEM), if SAP uses an internal CA
        if ca:
            if not os.path.isfile(ca):
                sys.exit(f"SAP_CA_BUNDLE file not found: {ca}")
            self.s.verify = ca
        else:
            self.s.verify = cfg("SAP_VERIFY_SSL", "1") != "0"
        self.base = {}
        if cfg("SAP_CLIENT"):
            self.base["sap-client"] = cfg("SAP_CLIENT")

    def call(self, method, action, params=None, body=None, tries=3):
        p = dict(self.base, action=action, **(params or {}))
        for attempt in range(1, tries + 1):
            try:
                if method == "GET":
                    r = self.s.get(self.url, params=p, timeout=300)
                else:
                    r = self.s.post(self.url, params=p, data=json.dumps(body).encode("utf-8"),
                                    headers={"Content-Type": "application/json; charset=utf-8"}, timeout=600)
                if r.status_code == 200:
                    return r.json()
                if r.status_code in (401, 403):
                    sys.exit(f"SAP login refused ({r.status_code}): check user, password, authorizations")
                raise RuntimeError(f"HTTP {r.status_code}: {r.text[:300]}")
            except (requests.RequestException, RuntimeError) as e:
                log.warning("%s %s failed (try %d/%d): %s", method, action, attempt, tries, e)
                if attempt == tries:
                    raise
                time.sleep(5 * attempt)


# ---------------------------------------------------------------- cache
class Cache:
    """Local copy of the extract: orders, components, wrong movements (all as text)."""
    FILES = {"orders": "pp_orders_cache.csv", "components": "pp_components_cache.csv",
             "wrongmvt": "pp_wrongmvt_cache.csv"}

    def __init__(self, folder):
        self.folder = folder
        os.makedirs(folder, exist_ok=True)

    def path(self, kind):
        return os.path.join(self.folder, self.FILES[kind])

    def read(self, kind):
        p = self.path(kind)
        if not os.path.exists(p):
            return pd.DataFrame()
        return pd.read_csv(p, sep=";", dtype=str, keep_default_na=False, encoding="utf-8-sig")

    def update(self, kind, csv_text, order_ids):
        """Replace the rows of the given orders by the new rows."""
        old = self.read(kind)
        if not old.empty:
            old = old[~old["order"].isin(order_ids)]
        new = (pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str, keep_default_na=False)
               if csv_text else pd.DataFrame())
        df = pd.concat([old, new], ignore_index=True) if not (old.empty and new.empty) else pd.DataFrame()
        if not df.empty:
            df.to_csv(self.path(kind), sep=";", index=False, encoding="utf-8-sig", quoting=csv.QUOTE_MINIMAL)

    def prune(self, keep_days):
        o = self.read("orders")
        if o.empty:
            return
        limit = (datetime.now() - timedelta(days=keep_days)).strftime("%Y-%m-%d")
        old_ids = set(o.loc[(o["actual_finish"] != "") & (o["actual_finish"] < limit), "order"])
        if not old_ids:
            return
        for kind in self.FILES:
            df = self.read(kind)
            if not df.empty:
                df[~df["order"].isin(old_ids)].to_csv(self.path(kind), sep=";", index=False,
                                                      encoding="utf-8-sig")
        log.info("cache: %d orders older than %d days dropped", len(old_ids), keep_days)


# ---------------------------------------------------------------- SAP -> cache
def order_ids_of(csv_text):
    if not csv_text:
        return set()
    return set(pd.read_csv(io.StringIO(csv_text), sep=";", dtype=str, keep_default_na=False)["order"])


def fetch(sap, cache, since, date_from, date_to, plants, max_pages):
    """Fetch pages until SAP says there is no more; returns (set of order numbers, server time)."""
    changed, after, page, server_time = set(), "", 0, None
    while True:
        params = {"from": date_from, "to": date_to, "max": PAGE}
        if since:
            params["since"] = since
        if plants:
            params["plant"] = plants
        if after:
            params["after"] = after
        res = sap.call("GET", "delta", params)
        if server_time is None:
            server_time = res["server_time"]       # time before the first page: nothing is missed
        page += 1
        ids = order_ids_of(res.get("orders", ""))
        log.info("page %d: %d orders (after %s)", page, res["order_cnt"], after or "-")
        if ids:
            cache.update("orders", res["orders"], ids)
            cache.update("components", res.get("components", ""), ids)
            cache.update("wrongmvt", res.get("wrongmvt", ""), ids)
            changed |= ids
        if not res.get("more") or not res.get("last_order"):
            break
        after = res["last_order"]
        if max_pages and page >= max_pages:
            log.info("stopped after %d page(s) (--max-pages)", page)
            break
    return changed, server_time


# ---------------------------------------------------------------- analytics
def run_analytics(cache_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    env = dict(os.environ, PYTHONIOENCODING="utf-8")
    r = subprocess.run([sys.executable, ANALYTICS, cache_dir, out_dir], capture_output=True, text=True,
                       env=env, encoding="utf-8", errors="replace")
    log.info("analytics:\n%s", r.stdout.strip())
    if r.returncode != 0:
        raise RuntimeError("production_analytics.py failed:\n" + r.stdout[-1500:] + r.stderr[-1500:])


def clean_out(out_dir):
    """After a successful upload the result files are not needed any more: SAP holds the results.
    Set PP_KEEP_OUT=1 to keep them (for checking)."""
    if cfg("PP_KEEP_OUT", "0") == "1" or not os.path.isdir(out_dir):
        return
    n = 0
    for name in os.listdir(out_dir):
        fp = os.path.join(out_dir, name)
        if os.path.isfile(fp):
            try:
                os.remove(fp)
                n += 1
            except OSError as e:
                log.warning("could not delete %s: %s", fp, e)
    log.info("removed %d result file(s) from the out folder", n)


def read_result(out_dir, name):
    p = os.path.join(out_dir, name)
    if not os.path.exists(p):
        return pd.DataFrame()
    return pd.read_csv(p, sep=";", dtype=str, keep_default_na=False, encoding="utf-8-sig",
                       quoting=csv.QUOTE_NONE, escapechar="\\")


def to_rows(df, mapping):
    """DataFrame (text) -> list of dicts with SAP field names, every value a string."""
    rows = []
    cols = [c for c in mapping if c in df.columns]
    for rec in df[cols].to_dict("records"):
        row = {}
        for c in cols:
            v = (rec[c] or "").strip()
            f = mapping[c]
            if f in DATE_FIELDS:
                v = v.replace("-", "")[:8]
            elif f in INT_FIELDS and v:
                try:
                    v = str(int(round(float(v))))
                except ValueError:
                    v = "0"
            elif f == "in_plan":
                v = "X" if v.upper() in ("X", "TRUE", "1") else ""
            row[f] = v
        rows.append(row)
    return rows


# ---------------------------------------------------------------- cache results -> SAP
def upload(sap, out_dir, order_ids, with_groups, run_id, run_mode, dry):
    o = read_result(out_dir, "pp_res_orders.csv")
    k = read_result(out_dir, "pp_res_components.csv")
    if order_ids is not None:
        o = o[o["order"].isin(order_ids)]
        k = k[k["order"].isin(order_ids)]
    ids = list(o["order"])
    log.info("upload: %d orders, %d component lines%s", len(o), len(k), ", groups + drivers" if with_groups else "")
    n = 0
    for i in range(0, max(len(ids), 1), BATCH):
        part = ids[i:i + BATCH]
        if not part and ids:
            break
        body = {"run_id": f"{run_id}-{i // BATCH + 1}", "run_mode": run_mode,
                "orders": to_rows(o[o["order"].isin(part)], ORD_MAP),
                "components": to_rows(k[k["order"].isin(part)], COMP_MAP)}
        if not body["orders"]:
            break
        n += 1
        if dry:
            with open(os.path.join(out_dir, f"payload_{n}.json"), "w", encoding="utf-8") as f:
                json.dump(body, f, ensure_ascii=False, indent=1)
        else:
            ack = sap.call("POST", "results", body=body)
            log.info("SAP stored: %s", ack)
    if with_groups:
        g = read_result(out_dir, "pp_res_groups.csv")
        d = read_result(out_dir, "pp_res_drivers.csv")
        body = {"run_id": f"{run_id}-grp", "run_mode": run_mode,
                "groups": to_rows(g, GRP_MAP) if not g.empty else [],
                "drivers": to_rows(d, DRV_MAP) if not d.empty else []}
        if dry:
            with open(os.path.join(out_dir, "payload_groups.json"), "w", encoding="utf-8") as f:
                json.dump(body, f, ensure_ascii=False, indent=1)
        elif body["groups"] or body["drivers"]:
            log.info("SAP stored: %s", sap.call("POST", "results", body=body))


# ---------------------------------------------------------------- main
def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("ping", "full", "delta", "nightly"):
        sys.exit(__doc__)
    mode = args[0]

    def opt(name, default=None):
        return args[args.index(name) + 1] if name in args else default

    dry = "--dry" in args
    load_env()
    work = cfg("WORK_DIR", os.path.join(HERE, "work"))
    os.makedirs(os.path.join(work, "logs"), exist_ok=True)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s",
                        handlers=[RotatingFileHandler(os.path.join(work, "logs", "pp_client.log"),
                                                      maxBytes=2_000_000, backupCount=5, encoding="utf-8"),
                                  logging.StreamHandler()])
    sap = Sap()
    if mode == "ping":
        print(sap.call("GET", "ping"))
        return

    lock = os.path.join(work, "pp_client.lock")
    if os.path.exists(lock) and time.time() - os.path.getmtime(lock) < 2 * 3600:
        log.info("another run is active (lock file) - skipped")
        return
    open(lock, "w").write(str(os.getpid()))
    try:
        cache = Cache(os.path.join(work, "cache"))
        out_dir = os.path.join(work, "out")
        state_file = os.path.join(work, "state.json")
        state = json.load(open(state_file)) if os.path.exists(state_file) else {}
        plants = cfg("SAP_PLANTS", "")
        today = datetime.now().strftime("%Y%m%d")
        run_id = datetime.now().strftime("%Y%m%d_%H%M%S")
        max_pages = int(opt("--max-pages", 0))

        if mode == "full":
            date_from = opt("--from", (datetime.now() - timedelta(days=730)).strftime("%Y%m%d"))
            date_to = opt("--to", today)
            changed, server_time = fetch(sap, cache, None, date_from, date_to, plants, max_pages)
            affected = None                                  # everything
            groups = True
        else:
            if "last_server_time" not in state:
                sys.exit("No previous run: start with  pp_client.py full")
            since = (datetime.strptime(state["last_server_time"], "%Y%m%d%H%M%S")
                     - timedelta(minutes=OVERLAP_MIN)).strftime("%Y%m%d%H%M%S")
            date_from = (datetime.now() - timedelta(days=KEEP_DAYS)).strftime("%Y%m%d")
            changed, server_time = fetch(sap, cache, since, date_from, today, plants, max_pages)
            affected, groups = set(changed), False
            if mode == "nightly":
                days = int(opt("--recalc-days", 45))
                o = cache.read("orders")
                limit = (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d")
                affected |= set(o.loc[o["actual_finish"] >= limit, "order"])
                cache.prune(KEEP_DAYS)
                groups = True
            if not changed and mode == "delta":
                log.info("delta: nothing changed since %s", since)
                state["last_server_time"] = server_time
                json.dump(state, open(state_file, "w"))
                return

        run_analytics(cache.folder, out_dir)
        upload(sap, out_dir, affected, groups, run_id, mode, dry)
        if not dry:
            clean_out(out_dir)
            state["last_server_time"] = server_time
            state["last_" + mode] = run_id
            json.dump(state, open(state_file, "w"))
        log.info("%s finished", mode)
    finally:
        if os.path.exists(lock):
            os.remove(lock)


if __name__ == "__main__":
    main()
