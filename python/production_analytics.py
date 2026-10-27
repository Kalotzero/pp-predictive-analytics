"""
Production analytics on the ZPP_PRED_EXTRACT files (SAP).

Reads from one folder:  pp_orders_*.csv, pp_components_*.csv
Writes into the same folder (fixed names, overwritten each run) the result
files that SAP report ZPP_PRED_ALV shows in an ALV:
    pp_res_orders.csv       one row per production order, status + explanation
    pp_res_components.csv   one row per component: planned vs actual, flag
    pp_res_groups.csv       comparison of groups (product group, line, shift ...)
    pp_res_drivers.csv      what drives over-consumption / scrap (ML model)

Analyses
  1. Raw-material over/under-consumption: planned (order BOM, scaled to the
     delivered quantity) vs actual issued (material documents 261-262) per
     component; unusual lines flagged with a robust z-score compared with the
     same component's normal behaviour. Materials issued without being in the
     order BOM are flagged UNPLANNED (e.g. a substitute material).
  2. Scrap / by-products (movement 531): scrap per order, rate vs input and
     vs output, unusual orders flagged.
  3. Group comparison: e.g. "material group A uses +3.1 points more raw
     material than the other groups" with a significance test.
  4. Drivers: gradient-boosting model that explains which factors (line,
     shift, product, batch size, weekday, month ...) push variance and scrap.

Install once:  py -m pip install pandas numpy scikit-learn scipy requests
Run:           py production_analytics.py .
"""

import sys
import glob
import os

import numpy as np
import pandas as pd
from scipy.stats import mannwhitneyu
from sklearn.ensemble import HistGradientBoostingRegressor
from sklearn.inspection import permutation_importance

# ---------------------------------------------------------------- settings
DATA_DIR = sys.argv[1] if len(sys.argv) > 1 else "."
OUTPUT_DIR = sys.argv[2] if len(sys.argv) > 2 else DATA_DIR

NET_OWN_ISSUE = True      # reduce the delivered qty by the product itself issued to its own order
VAR_LIMIT = 0.05          # +-5 % vs recipe counts as a deviation
Z_LIMIT = 3.0             # robust z-score above 3 = unusual for this component
MIN_PLANNED_VALUE = 1.0   # ignore component lines worth less than 1 currency unit planned
UNIT_CHECK_FACTOR = 50.0  # planned and actual differ by more than this factor (either way) = UNIT CHECK:
                          # most likely a wrong BOM quantity or unit; kept visible, but left out of the
                          # value totals, the baselines and the group comparison
SUBST_TOLERANCE = 0.10    # NOT ISSUED + UNPLANNED of the same order, same unit, quantities within 10 % = substitution
RED_EXCESS_VALUE = 200.0  # order is RED when excess raw material value is above this (in the order currency)
# optional per-currency limits, e.g. {"EUR": 200.0, "USD": 220.0}; currencies not listed use RED_EXCESS_VALUE
RED_EXCESS_BY_CURRENCY = {}
SCRAP_PCTL = 0.90         # order scrap above the 90th percentile of its product = flagged
MIN_GROUP_ORDERS = 20     # groups with fewer orders are not compared
SHIFTS = [(6, 14, "Morning 06-14"), (14, 22, "Afternoon 14-22"), (22, 30, "Night 22-06")]

ID_COLS = {c: str for c in ["order", "item", "plant", "material", "material_group", "component",
                            "component_group", "movement_type", "order_type", "work_center",
                            "mrp_controller", "prod_supervisor", "storage_loc"]}


# ---------------------------------------------------------------- load
def read_all(pattern):
    files = sorted(glob.glob(os.path.join(DATA_DIR, pattern)))
    if not files:
        return pd.DataFrame()
    parts = []
    for f in files:                      # file names carry the run time -> sorted = oldest first
        part = pd.read_csv(f, sep=";", encoding="utf-8-sig", dtype=ID_COLS, low_memory=False)
        part["_run"] = os.path.basename(f)
        parts.append(part)
    df = pd.concat(parts, ignore_index=True)
    # empty key fields must be "" and not NaN: old pandas versions (1.x) silently drop rows with NaN group keys
    # in groupby(...).transform(function) and then fail with "Length mismatch"
    for col in ID_COLS:
        if col in df.columns:
            df[col] = df[col].fillna("")
    print(f"{pattern:24s} {len(files)} file(s), {len(df):,} rows")
    return df


def shift_of(ts):
    if pd.isna(ts):
        return "(no confirmation)"
    h = ts.hour if ts.hour >= 6 else ts.hour + 24
    for a, b, name in SHIFTS:
        if a <= h < b:
            return name
    return "(unknown)"


def load():
    o = read_all("pp_orders_*.csv")
    c = read_all("pp_components_*.csv")
    if o.empty or c.empty:
        sys.exit("pp_orders_*.csv and pp_components_*.csv are needed in " + DATA_DIR)
    # the same order can be in several extract runs: keep only its newest data
    o = o.drop_duplicates("order", keep="last")
    c["_run_ord"] = c.groupby("order")["_run"].transform("max")
    c = c[c["_run"] == c["_run_ord"]]
    c = c.drop_duplicates(["order", "component", "movement_type"], keep="last")
    o = o.drop(columns=["_run"])
    c = c.drop(columns=["_run", "_run_ord"])
    o["actual_finish"] = pd.to_datetime(o["actual_finish"])
    o["conf_start"] = pd.to_datetime(o["conf_start"], errors="coerce")
    o["shift"] = o["conf_start"].map(shift_of)
    o["weekday"] = o["actual_finish"].dt.day_name()
    o["month"] = o["actual_finish"].dt.month
    o["work_center"] = o["work_center"].fillna("(none)")
    o["prod_supervisor"] = o["prod_supervisor"].fillna("(none)")
    o["batch_ratio"] = (o["delivered_qty"] / o["target_qty"]).replace([np.inf, -np.inf], np.nan)
    o = o[o["delivered_qty"] > 0]
    for col in ["planned_qty", "actual_qty", "actual_without_reservation", "price_per_unit"]:
        if col not in c:
            c[col] = 0.0
        c[col] = pd.to_numeric(c[col], errors="coerce").fillna(0.0)
    c = c[c["order"].isin(o["order"])]

    # The order's own product issued to the order itself (261 of the output material, not in the
    # BOM) is a WRONG MOVEMENT (receipt correction / rework posted as consumption): it is flagged,
    # kept out of the raw-material values, and the delivered quantity is reduced by it.
    chk = c.merge(o[["order", "material"]], on="order", how="left")
    own_mask = ((chk["movement_type"] == "261") & (chk["component"] == chk["material"])
                & (chk["planned_qty"] == 0)).to_numpy()
    c["own_product"] = own_mask
    own = c[own_mask].groupby("order")["actual_qty"].sum()
    o = o.copy()
    o["own_issued_qty"] = o["order"].map(own).fillna(0.0)
    o["delivered_gross"] = o["delivered_qty"]
    if NET_OWN_ISSUE:
        o["delivered_qty"] = o["delivered_qty"] - o["own_issued_qty"]
    o = o[o["delivered_qty"] > 0]
    c = c[c["order"].isin(o["order"])]

    # document, user and date of those postings (file pp_wrongmvt_*.csv from the extract)
    o["wrong_mvt_info"] = ""
    w = read_all("pp_wrongmvt_*.csv")
    if not w.empty:
        w = w.drop(columns=["_run"]).drop_duplicates(["doc", "year", "item"], keep="last")
        w["order"] = w["order"].astype(str)
        w = w[w["order"].isin(o[o["own_issued_qty"] > 0]["order"])]
        w["posting_date"] = pd.to_datetime(w["posting_date"], errors="coerce").dt.strftime("%d.%m.%Y")
        w["txt"] = ("doc " + w["doc"].astype(str) + " by " + w["user"].astype(str) + " on "
                    + w["posting_date"].astype(str) + " (" + w["movement_type"].astype(str) + ")")
        info = w.groupby("order")["txt"].apply(lambda s_: "; ".join(s_.head(3)))
        o["wrong_mvt_info"] = o["order"].map(info).fillna("")
    return o, c


# ---------------------------------------------------------------- 1. consumption
def robust_z(s):
    med = s.median()
    mad = (s - med).abs().median() * 1.4826
    if not mad or np.isnan(mad):
        mad = max(s.std(), 1e-9) if s.std() and not np.isnan(s.std()) else 1e-9
    return (s - med) / mad


def consumption(o, c):
    oo = o[["order", "material", "material_desc", "material_group", "work_center", "shift",
            "actual_finish", "target_qty", "delivered_qty", "wrong_mvt_info", "unit"]].rename(columns={"unit": "order_unit"})
    k = c[c["movement_type"] == "261"].merge(oo, on="order", how="inner")
    k[["material", "component"]] = k[["material", "component"]].fillna("")
    scale = (k["delivered_qty"] / k["target_qty"]).where(k["target_qty"] > 0, 1.0)
    k["planned_for_actual"] = np.where(k["fixed_qty"].fillna("") == "X", k["planned_qty"],
                                       k["planned_qty"] * scale)
    # keep planned lines and materials issued although not in the order BOM
    k = k[(k["planned_for_actual"] > 0) | (k["actual_qty"] != 0)].copy()
    planned = k["planned_for_actual"] > 0
    k["variance_qty"] = k["actual_qty"] - k["planned_for_actual"]
    k["variance_pct"] = (k["variance_qty"] / k["planned_for_actual"]).where(planned)
    k["excess_value"] = k["variance_qty"] * k["price_per_unit"]
    k["planned_value"] = k["planned_for_actual"] * k["price_per_unit"]
    k["actual_value"] = k["actual_qty"] * k["price_per_unit"]
    # wrong movements (own product issued to its own order) are not raw-material consumption
    k.loc[k["own_product"], ["excess_value", "planned_value", "actual_value"]] = 0.0

    # implausible recipe quantity: planned vs actual differ by more than UNIT_CHECK_FACTOR (either way).
    # Only lines that matter in value (>= MIN_PLANNED_VALUE on either side) are considered.
    big = np.maximum(k["planned_value"], k["actual_value"]) >= MIN_PLANNED_VALUE
    ratio_hi = (k["planned_for_actual"] > k["actual_qty"] * UNIT_CHECK_FACTOR) & (k["actual_qty"] > 0)
    ratio_lo = (k["actual_qty"] > k["planned_for_actual"] * UNIT_CHECK_FACTOR) & planned
    # not-issued lines (nothing to compare with): judge the recipe quantity against
    #  A) the same product/component in other orders (planned qty per unit of target qty)
    #  B) the order's own output (same unit: a component cannot weigh more than UNIT_CHECK_FACTOR x the product)
    per_out = (k["planned_qty"] / k["target_qty"]).where((k["target_qty"] > 0) & (k["planned_qty"] > 0))
    med = per_out.groupby([k["material"], k["component"]]).transform("median")
    cnt = per_out.groupby([k["material"], k["component"]]).transform("count")
    rule_a = (per_out > med * UNIT_CHECK_FACTOR) & (cnt >= 5) & (med > 0)
    rule_b = (k["unit"] == k["order_unit"]) & (k["planned_for_actual"] > k["delivered_qty"] * UNIT_CHECK_FACTOR)
    k["unit_check"] = (ratio_hi | ratio_lo | rule_a | rule_b) & big & ~k["own_product"]
    # a wrong BOM base quantity inflates ALL lines of the order, not only the one that trips a rule:
    # in an order with a clear unit error, the other lines nothing was issued for are suspect too
    bad_orders = set(k.loc[k["unit_check"], "order"])
    k["unit_check"] = k["unit_check"] | (k["order"].isin(bad_orders) & planned & (k["actual_qty"] == 0)
                                         & big & ~k["own_product"])
    # their values would distort every total: kept out (the quantities stay visible)
    k.loc[k["unit_check"], ["excess_value", "planned_value", "actual_value"]] = 0.0

    # typical behaviour of the same component in the same product (planned lines only,
    # without the implausible ones)
    base = planned & ~k["unit_check"]
    grp = k[base].groupby(["material", "component"])["variance_pct"]
    k.loc[base, "typical_variance_pct"] = grp.transform("median")
    k.loc[base, "z_score"] = grp.transform(lambda s: robust_z(s) if len(s) >= 5 else s * 0)
    k["z_score"] = k["z_score"].clip(-99, 99)

    def flag(r):
        if r["own_product"]:
            return "WRONG MVT"
        if r["planned_for_actual"] <= 0:
            return "UNPLANNED"
        if r["unit_check"]:
            return "UNIT CHECK"
        if r["actual_qty"] == 0:
            return "NOT ISSUED"
        if r["planned_value"] < MIN_PLANNED_VALUE:
            return ""
        if r["variance_pct"] > VAR_LIMIT and r["z_score"] > Z_LIMIT:
            return "OVER"
        if r["variance_pct"] < -VAR_LIMIT and r["z_score"] < -Z_LIMIT:
            return "UNDER"
        return ""
    k["flag"] = k.apply(flag, axis=1)

    # substitution: a planned component not issued, and an unplanned one issued instead in the same
    # quantity (same order, same unit): not a consumption deviation, values netted out
    k["subst_for"] = ""
    both = set(k.loc[k["flag"] == "NOT ISSUED", "order"]) & set(k.loc[k["flag"] == "UNPLANNED", "order"])
    for od in both:
        ni = k[(k["order"] == od) & (k["flag"] == "NOT ISSUED")]
        up = k[(k["order"] == od) & (k["flag"] == "UNPLANNED")]
        used = set()
        for i, n in ni.iterrows():
            for j, u in up.iterrows():
                if j in used or u["unit"] != n["unit"] or n["planned_for_actual"] <= 0:
                    continue
                if abs(u["actual_qty"] - n["planned_for_actual"]) / n["planned_for_actual"] <= SUBST_TOLERANCE:
                    used.add(j)
                    k.loc[[i, j], ["excess_value", "planned_value", "actual_value"]] = 0.0
                    k.loc[i, "subst_for"] = "substituted by " + str(u["component"])
                    k.loc[j, "subst_for"] = "substitute for " + str(n["component"])
                    break

    def name(r):
        d = r["component_desc"] if isinstance(r["component_desc"], str) and r["component_desc"] else ""
        return f"{r['component']} {d}".strip()

    # unplanned / not issued materials per order, to explain substitutions
    # (plain dicts: DataFrame.apply / groupby.apply on empty frames behave differently in old pandas)
    unpl, notiss = {}, {}
    for r_ in k[k["flag"] == "UNPLANNED"].to_dict("records"):
        unpl.setdefault(r_["order"], []).append(f"{name(r_)} ({r_['actual_qty']:,.3f} {r_['unit']})")
    for r_ in k[k["flag"] == "NOT ISSUED"].to_dict("records"):
        notiss.setdefault(r_["order"], []).append(name(r_))
    unpl = {o_: ", ".join(v) for o_, v in unpl.items()}
    notiss = {o_: ", ".join(v) for o_, v in notiss.items()}

    def explain(r):
        if r["flag"] == "WRONG MVT":
            t = (f"{name(r)}: the product itself was issued (261) to its own order, {r['actual_qty']:,.3f} {r['unit']} "
                 f"- wrong movement? check and reverse/correct")
            if r["wrong_mvt_info"]:
                t += f" [{r['wrong_mvt_info']}]"
            return t
        if r["flag"] == "UNPLANNED":
            t = f"{name(r)}: issued {r['actual_qty']:,.3f} {r['unit']} but not in the order BOM"
            if r["subst_for"]:
                return f"{name(r)}: issued {r['actual_qty']:,.3f} {r['unit']} - {r['subst_for']} (same quantity, values netted)"
            if r["order"] in notiss:
                t += f" - possibly instead of {notiss[r['order']]}"
            return t
        if r["flag"] == "NOT ISSUED":
            if r["subst_for"]:
                return f"{name(r)}: {r['subst_for']} (same quantity, values netted)"
            t = f"{name(r)}: planned {r['planned_for_actual']:,.3f} {r['unit']} but nothing issued"
            if r["order"] in unpl:
                t += f" - order used instead: {unpl[r['order']]}"
            return t
        if r["flag"] == "UNIT CHECK":
            if r["actual_qty"] <= 0:
                how = "nothing issued, planned quantity implausible for this product"
            else:
                ratio = r["planned_for_actual"] / r["actual_qty"]
                how = f"planned is {ratio:,.0f}x the issued quantity" if ratio >= 1 else \
                      f"issued is {1 / ratio:,.0f}x the planned quantity"
            return (f"{name(r)}: planned {r['planned_for_actual']:,.3f} {r['unit']}, issued {r['actual_qty']:,.3f} "
                    f"{r['unit']} ({how}) - check the BOM quantity / unit; left out of the totals")
        if r["flag"] in ("OVER", "UNDER"):
            return (f"{name(r)}: {r['variance_pct']:+.1%} vs recipe ({r['variance_qty']:+,.1f} {r['unit']}, "
                    f"{r['excess_value']:+,.0f} {r['currency']}); usually {r['typical_variance_pct']:+.1%}")
        return ""
    k["explanation"] = k.apply(explain, axis=1)
    return k


# ---------------------------------------------------------------- 2. scrap
def scrap(o, c):
    s = c[c["movement_type"] == "531"]
    if s.empty:
        return pd.DataFrame(columns=["order", "scrap_qty", "scrap_unit", "scrap_planned",
                                     "scrap_rate_input", "scrap_rate_output"])
    agg = s.groupby("order").agg(scrap_qty=("actual_qty", "sum"), scrap_planned=("planned_qty", "sum"),
                                 scrap_unit=("unit", "first"))
    # input consumed in the same unit as the scrap (e.g. m3 blocks -> m3 scrap)
    inp = c[(c["movement_type"] == "261") & ~c["own_product"]].merge(agg[["scrap_unit"]], left_on="order", right_index=True)
    inp = inp[inp["unit"] == inp["scrap_unit"]].groupby("order")["actual_qty"].sum()
    agg["scrap_rate_input"] = (agg["scrap_qty"] / inp.reindex(agg.index)).replace([np.inf], np.nan)
    agg = agg.join(o.set_index("order")[["delivered_qty"]])
    agg["scrap_rate_output"] = agg["scrap_qty"] / agg["delivered_qty"]
    return agg.drop(columns="delivered_qty").reset_index()


# ---------------------------------------------------------------- order level
def order_level(o, k, sc):
    g = k.groupby("order").agg(planned_value=("planned_value", "sum"), actual_value=("actual_value", "sum"),
                               excess_value=("excess_value", "sum"), currency=("currency", "first"),
                               components=("component", "count"),
                               flagged_components=("flag", lambda f: f.isin(["OVER", "UNDER", "NOT ISSUED", "WRONG MVT", "UNIT CHECK"]).sum()),
                               unplanned_components=("flag", lambda f: (f == "UNPLANNED").sum()))
    g["variance_pct"] = (g["actual_value"] - g["planned_value"]) / g["planned_value"].where(g["planned_value"] > 0)
    top_d, uc_d = {}, {}
    cand = k[~k["flag"].isin(["", "WRONG MVT", "UNIT CHECK"])].assign(absval=lambda d: d["excess_value"].abs())
    for od, sub in cand.sort_values("absval", ascending=False).groupby("order"):
        top_d[od] = " | ".join(sub["explanation"].head(2))
    for od, sub in k[k["flag"] == "UNIT CHECK"].groupby("order"):
        uc_d[od] = f"UNIT CHECK on {len(sub)} line(s): " + sub["explanation"].iloc[0]
    r = o.set_index("order").join(g)
    r["explanation"] = pd.Series(top_d, dtype="object").reindex(r.index)
    r["unit_txt"] = pd.Series(uc_d, dtype="object").reindex(r.index)
    r = r.join(sc.set_index("order") if not sc.empty else None) if not sc.empty else r
    for col in ["scrap_qty", "scrap_rate_input", "scrap_rate_output", "scrap_planned"]:
        if col not in r:
            r[col] = np.nan
    if "scrap_unit" not in r:
        r["scrap_unit"] = ""

    # scrap flag: rate above the 90th percentile of the same product
    rate = r["scrap_rate_input"].fillna(r["scrap_rate_output"])
    r["material"] = r["material"].fillna("")
    p90 = rate.groupby(r["material"]).transform(lambda s: s.quantile(SCRAP_PCTL) if s.notna().sum() >= 5 else np.nan)
    r["scrap_rate"] = rate
    r["scrap_flag"] = np.where((rate > p90) & rate.notna(), "HIGH SCRAP", "")

    def red_limit(cur):
        return RED_EXCESS_BY_CURRENCY.get(cur, RED_EXCESS_VALUE)

    def status(x):
        if (x["excess_value"] or 0) > red_limit(x["currency"]) or x["scrap_flag"] or (x["own_issued_qty"] or 0) > 0:
            return "RED"
        if (x["flagged_components"] or 0) > 0 or (x["unplanned_components"] or 0) > 0 \
                or (x["own_issued_qty"] or 0) > 0 or abs(x["variance_pct"] or 0) > VAR_LIMIT:
            return "YELLOW"
        return "GREEN"
    r = r.fillna({"flagged_components": 0, "unplanned_components": 0, "excess_value": 0.0, "variance_pct": 0.0})
    r["status"] = r.apply(status, axis=1)
    sc_txt = np.where(r["scrap_flag"] != "",
                      "Scrap " + r["scrap_qty"].round(2).astype(str) + " " + r["scrap_unit"].astype(str)
                      + " (" + (r["scrap_rate"] * 100).round(1).astype(str) + "%, usually <= "
                      + (p90 * 100).round(1).astype(str) + "%)", "")
    own_txt = np.where(r["own_issued_qty"] > 0,
                       "WRONG MOVEMENT: product itself issued (261) to its own order, "
                       + r["own_issued_qty"].round(1).astype(str) + " " + r["unit"].astype(str)
                       + np.where(r["wrong_mvt_info"] != "", " [" + r["wrong_mvt_info"] + "]", "")
                       + (" - delivered qty shown is net of it" if NET_OWN_ISSUE else ""),
                       "")
    r["explanation"] = [" | ".join([t for t in (a, u, b, c) if isinstance(t, str) and t])
                        for a, u, b, c in zip(own_txt, r["unit_txt"], r["explanation"], sc_txt)]
    # RED only because of the value: say so, and where to look (a RED order must never have an empty explanation)
    lim = r["currency"].map(red_limit)
    by_value = (r["status"] == "RED") & (r["explanation"] == "") & (r["excess_value"] > lim)
    r.loc[by_value, "explanation"] = ("Excess raw material " + r["excess_value"].round(0).map("{:,.0f}".format)
                                      + " " + r["currency"].astype(str) + " (" + (r["variance_pct"] * 100).round(1).astype(str)
                                      + "% vs recipe, limit " + lim.map("{:,.0f}".format)
                                      + "): spread over several components, none unusual on its own - see the components view of this order")
    r = r.drop(columns="unit_txt")
    return r.reset_index()


# ---------------------------------------------------------------- 3. groups
DIMENSIONS = {"material_group": "Product group", "material": "Product", "work_center": "Work center / line",
              "shift": "Shift", "prod_supervisor": "Production supervisor", "order_type": "Order type",
              "weekday": "Weekday"}


def compare_groups(r):
    rows = []
    # orders without a usable recipe (planned value zero or tiny against what was issued) say nothing
    # about consumption behaviour: they stay in the order list but are not part of the comparison
    r = r[(r["planned_value"] > 0) & (r["actual_value"] <= r["planned_value"] * UNIT_CHECK_FACTOR)]
    for dim, label in DIMENSIONS.items():
        if dim not in r:
            continue
        for grp, sub in r.groupby(dim):
            cur = sub["currency"].mode().iloc[0] if "currency" in sub and sub["currency"].notna().any() else None
            if cur is not None:                      # values of different currencies are never added up
                sub = sub[sub["currency"] == cur]
            others = r[(r[dim] != grp) & ((r["currency"] == cur) if cur is not None else True)]
            if len(sub) < MIN_GROUP_ORDERS or len(others) < MIN_GROUP_ORDERS:
                continue
            row = {"dimension": label, "group": str(grp),
                   "group_desc": sub["material_desc"].iloc[0] if dim == "material" else "",
                   "orders": len(sub), "value_share": sub["planned_value"].sum() / max(r.loc[r["currency"] == cur, "planned_value"].sum() if cur is not None else r["planned_value"].sum(), 1e-9)}
            # raw material: value-weighted variance
            v_g = (sub["actual_value"].sum() - sub["planned_value"].sum()) / max(sub["planned_value"].sum(), 1e-9)
            v_o = (others["actual_value"].sum() - others["planned_value"].sum()) / max(others["planned_value"].sum(), 1e-9)
            p_v = mannwhitneyu(sub["variance_pct"].dropna(), others["variance_pct"].dropna()).pvalue \
                if sub["variance_pct"].notna().sum() > 5 and others["variance_pct"].notna().sum() > 5 else 1.0
            row.update(variance_pct=v_g, others_variance_pct=v_o, difference_pp=(v_g - v_o) * 100,
                       excess_value=sub["excess_value"].sum(), variance_significant="YES" if p_v < 0.05 else "no")
            # scrap
            sg, so = sub["scrap_rate"].dropna(), others["scrap_rate"].dropna()
            if len(sg) >= 5 and len(so) >= 5:
                p_s = mannwhitneyu(sg, so).pvalue
                row.update(scrap_rate=sg.mean(), others_scrap_rate=so.mean(),
                           scrap_difference_pct=(sg.mean() / so.mean() - 1) if so.mean() else np.nan,
                           scrap_significant="YES" if p_s < 0.05 else "no")
            rows.append(row)
    g = pd.DataFrame(rows)
    if g.empty:
        return g

    def finding(x):
        parts = []
        name = f"{x['dimension']} {x['group']}" + (f" ({x['group_desc']})" if x.get("group_desc") else "")
        if x["variance_significant"] == "YES" and abs(x["difference_pp"]) >= 0.5:
            parts.append(f"{name} uses {abs(x['difference_pp']):.1f} points {'more' if x['difference_pp'] > 0 else 'less'} "
                         f"raw material vs recipe than the others ({x['variance_pct']:+.1%} vs {x['others_variance_pct']:+.1%})")
        if x.get("scrap_significant") == "YES" and pd.notna(x.get("scrap_difference_pct")) \
                and abs(x["scrap_difference_pct"]) >= 0.10:
            parts.append(f"{name} has {abs(x['scrap_difference_pct']):.0%} {'more' if x['scrap_difference_pct'] > 0 else 'less'} "
                         f"scrap than the others ({x['scrap_rate']:.1%} vs {x['others_scrap_rate']:.1%})")
        return " | ".join(parts)
    g["finding"] = g.apply(finding, axis=1)
    for col in ["scrap_rate", "others_scrap_rate", "scrap_difference_pct", "scrap_significant"]:
        if col not in g:
            g[col] = np.nan
    g["sort"] = g["difference_pp"].abs() * (g["finding"] != "")
    return g.sort_values(["sort", "excess_value"], ascending=False).drop(columns="sort")


# ---------------------------------------------------------------- 4. drivers
DRIVER_TEXT = {"material_group": "Product group", "material": "Product", "work_center": "Work center / line",
               "shift": "Shift", "prod_supervisor": "Production supervisor", "order_type": "Order type",
               "weekday": "Weekday", "month": "Month (season)", "batch_ratio": "Delivered vs target quantity",
               "log_target": "Order size", "setup_time": "Setup time", "confirmations": "Number of confirmations"}


def drivers(r):
    out = []
    feats = ["material_group", "material", "work_center", "shift", "prod_supervisor", "order_type",
             "weekday", "month", "batch_ratio", "log_target", "setup_time", "confirmations"]
    d = r.copy()
    d["log_target"] = np.log1p(d["target_qty"].clip(lower=0))
    feats = [f for f in feats if f in d]
    cat = [f for f in feats if not pd.api.types.is_numeric_dtype(d[f])]
    X = d[feats].copy()
    for f in cat:   # keep frequent values, the rest = OTHER; then integer codes (works with every scikit-learn version)
        v = X[f].fillna("OTHER").astype(str)
        top = v.value_counts().index[:50]
        X[f] = pd.Categorical(v.where(v.isin(top), "OTHER")).codes.astype("int32")
    is_cat = np.array([f in cat for f in feats])
    for target, label in [("variance_pct", "Raw material variance"), ("scrap_rate", "Scrap rate")]:
        y = d[target]
        m = y.notna() & np.isfinite(y)
        if m.sum() < 200:
            continue
        y = y[m].clip(y[m].quantile(0.01), y[m].quantile(0.99))
        model = HistGradientBoostingRegressor(max_iter=200, learning_rate=0.05, categorical_features=is_cat,
                                              random_state=42)
        model.fit(X[m], y)
        imp = permutation_importance(model, X[m], y, n_repeats=3, random_state=42)
        s = pd.Series(np.clip(imp.importances_mean, 0, None), index=feats)
        if s.sum() <= 0:
            continue
        s = (100 * s / s.sum()).sort_values(ascending=False)
        for rank, (f, v) in enumerate(s.items(), 1):
            if v >= 1:
                out.append({"target": label, "rank": rank, "driver": f, "meaning": DRIVER_TEXT.get(f, f),
                            "importance_pct": v, "model_r2": model.score(X[m], y)})
    return pd.DataFrame(out)


# ---------------------------------------------------------------- output
def clean_text(df):
    """No ';' or line breaks inside fields, so the SAP side can split on ';'."""
    for col in df.columns:
        if not pd.api.types.is_numeric_dtype(df[col]) and not pd.api.types.is_datetime64_any_dtype(df[col]):
            df[col] = (df[col].astype(object).where(df[col].notna(), "").astype(str)
                       .str.replace(";", ",").str.replace("\n", " ").replace({"nan": "", "None": ""}))
    return df


def write(df, cols, name):
    df = df.reindex(columns=cols).copy()
    for col in df.columns:
        if pd.api.types.is_datetime64_any_dtype(df[col]):
            df[col] = df[col].dt.strftime("%Y-%m-%d")
        elif pd.api.types.is_float_dtype(df[col]):
            df[col] = df[col].replace([np.inf, -np.inf], np.nan).round(5)
    df = clean_text(df)
    path = os.path.join(OUTPUT_DIR, name)
    df.to_csv(path, sep=";", index=False, encoding="utf-8-sig", quoting=3, escapechar="\\",
              float_format="%.5f")
    print(f"  {name:24s} {len(df):,} rows")
    return path


ORDER_COLS = ["order", "status", "plant", "material", "material_desc", "material_group", "order_type",
              "work_center", "shift", "prod_supervisor", "actual_finish", "target_qty", "delivered_qty", "unit", "own_issued_qty",
              "planned_value", "actual_value", "excess_value", "currency", "variance_pct", "components",
              "flagged_components", "unplanned_components", "scrap_qty", "scrap_unit", "scrap_rate", "scrap_flag", "explanation"]
COMP_COLS = ["order", "item", "flag", "plant", "material", "material_group", "work_center", "shift",
             "actual_finish", "component", "component_desc", "component_group", "in_plan", "planned_qty",
             "planned_for_actual", "actual_qty", "actual_without_reservation", "unit", "variance_qty", "variance_pct",
             "typical_variance_pct", "z_score", "excess_value", "currency", "explanation"]
GROUP_COLS = ["dimension", "group", "group_desc", "orders", "value_share", "variance_pct",
              "others_variance_pct", "difference_pp", "variance_significant", "excess_value", "scrap_rate",
              "others_scrap_rate", "scrap_difference_pct", "scrap_significant", "finding"]
DRIVER_COLS = ["target", "rank", "driver", "meaning", "importance_pct", "model_r2"]


def main():
    o, c = load()
    print(f"Orders: {len(o):,}  finished {o['actual_finish'].min().date()} - {o['actual_finish'].max().date()}")
    k = consumption(o, c)
    sc = scrap(o, c)
    r = order_level(o, k, sc)
    g = compare_groups(r)
    d = drivers(r)
    k = k.merge(r[["order", "status"]], on="order", how="left")

    print("\nResult files for ZPP_PRED_ALV:")
    write(r, ORDER_COLS, "pp_res_orders.csv")
    write(k, COMP_COLS, "pp_res_components.csv")
    write(g, GROUP_COLS, "pp_res_groups.csv")
    write(d, DRIVER_COLS, "pp_res_drivers.csv")

    print("\nSummary")
    print(f"  Orders RED / YELLOW / GREEN : {(r.status == 'RED').sum():,} / {(r.status == 'YELLOW').sum():,} / "
          f"{(r.status == 'GREEN').sum():,}")
    for cur, d in r.groupby("currency"):
        print(f"  [{cur}] planned value {d['planned_value'].sum():,.0f}   actual {d['actual_value'].sum():,.0f}   "
              f"excess {d['excess_value'].sum():,.0f} ({d['excess_value'].sum() / max(d['planned_value'].sum(), 1):+.2%})")
    print(f"  Component lines flagged     : {(k['flag'] != '').sum():,} of {len(k):,}")
    print(f"  Orders with high scrap      : {(r['scrap_flag'] != '').sum():,}")
    uc = k[k["flag"] == "UNIT CHECK"]
    print(f"  UNIT CHECK lines (left out) : {len(uc):,} in {uc['order'].nunique():,} orders")
    if not g.empty:
        print("\nTop findings:")
        for t in g[g["finding"] != ""]["finding"].head(8):
            print("  - " + t)


if __name__ == "__main__":
    main()
