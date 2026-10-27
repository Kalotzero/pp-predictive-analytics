# PP predictive analytics for SAP production orders

Finds production orders whose raw-material consumption differs from the recipe (BOM) or whose scrap is high,
explains why in plain text, compares product groups / lines / shifts / supervisors, and ranks the factors
behind the deviations. Results are shown to users in a normal SAP report. No external service, no AI/API key,
no data leaves your network.

```
 SAP (ICF REST service /sap/zpp/analytics)         one server (Python)                    SAP
 ZCL_PP_REST + ZCL_PP_EXTRACT  --->   pp_client.py                    --->  Z tables ZPP_ORD / COMP /
 orders, BOM components (RESB),             local cache (CSV, rebuildable)         GRP / DRV / RUNLOG
 material documents (MATDOC 261/262),       production_analytics.py                       |
 confirmations, scrap (531)                 (pandas, scipy, scikit-learn)                 v
                                                                               report ZPP_PRED_REP
```

Users only open the SAP report. Nobody else needs Python. The Python part runs on **one** machine (Windows or Linux).

## What you get

| Area | Content |
|---|---|
| Per component | planned (scaled to the delivered quantity) vs actual issued, flag `OVER`, `UNDER`, `NOT ISSUED`, `UNPLANNED`, `WRONG MVT`, `UNIT CHECK` |
| Per order | status RED / YELLOW / GREEN, excess value, scrap rate, plain-text explanation |
| Groups | product group, product, work center, shift, supervisor, order type, weekday compared with all others (Mann-Whitney test, per currency) |
| Drivers | gradient-boosting model + permutation importance: which factors explain the variance and the scrap |
| Data quality | `UNIT CHECK` finds BOMs with wrong base quantity or unit (quantities off by more than 50x) and keeps them out of the totals |
| BOM check | read-only SAP report `ZPP_BOM_QTY_CHECK` lists BOM items with implausible quantities at the source |

Rules are described in [docs/ANALYSIS_RULES.md](docs/ANALYSIS_RULES.md).

## Repository layout

```
abap/tables/       ZPP_ORD, ZPP_COMP, ZPP_GRP, ZPP_DRV, ZPP_RUNLOG   (result tables)
abap/classes/      ZCL_PP_EXTRACT (data), ZCL_PP_REST (HTTP handler incl. authorization check)
abap/reports/      ZPP_PRED_REP (user report), ZPP_BOM_QTY_CHECK (BOM quantity check)
python/            pp_client.py, production_analytics.py, requirements.txt, .env.example, scheduler examples
python/tools/      diag.py (read-only diagnostic)
docs/              setup and operation guides
```

The `ZPP_` / `ZCL_PP_` prefix is only a naming convention. To use your own Z namespace, search and replace it in
the ABAP files and in the ICF node name (`/sap/zpp/analytics`). The Python scripts only need the URL; they use the
table *field* names (`ORD_MAP`, `COMP_MAP`, ... in `pp_client.py`), which stay the same.

## Quick start

1. **SAP:** create the objects and the ICF node, see [docs/SETUP_SAP.md](docs/SETUP_SAP.md).
2. **Server:** install Python and the packages, create the `.env`, see [docs/SETUP_SERVER.md](docs/SETUP_SERVER.md).
3. **First load:** `python pp_client.py ping`, then `python pp_client.py full --dry`, then `python pp_client.py full`.
4. **Schedule:** `delta` every 30 minutes, `nightly` at 02:00 (examples in `python/`).

## Modes of `pp_client.py`

| Command | When | What it does |
|---|---|---|
| `ping` | any time | tests URL, login and certificate |
| `full [--from YYYYMMDD] [--to YYYYMMDD]` | once, and after rule changes | loads the last 730 days (default), calculates everything, uploads all results |
| `delta` | every 30 minutes | fetches orders with new postings/confirmations only, recalculates and uploads them |
| `nightly` | once per night | delta + recalculation of the last 45 days + group comparison + drivers |

Options: `--dry` (send nothing to SAP, write the JSON into `work/out`), `--max-pages N`, `--recalc-days N`.
Two runs never overlap: a lock file makes a second start exit.

## Configuration (`.env` or environment variables)

See [python/.env.example](python/.env.example). Environment variables win over the `.env` file.
Thresholds (tolerance, z-score, unit-check factor, RED limit per currency) are constants at the top of
`production_analytics.py`.

## Security notes

- Use HTTPS in production (the client refuses plain `http://` unless `SAP_ALLOW_HTTP=1`) and keep `SAP_VERIFY_SSL=1`.
- Use a technical user with a minimal role (see docs/SETUP_SAP.md). The handler also checks `S_TABU_NAM`
  (03 for reading, 02 for writing results).
- The `.env` holds the password in clear text: restrict the file to the service account and never commit it
  (`.gitignore` excludes it).
- The local cache (`work/cache`) contains business data (orders, quantities, values). Keep it on a protected
  local disk; it can be deleted and rebuilt with `full`.
- The program contacts only the SAP URL from the `.env`. Internet access is needed once for `pip install`.

## Tested with

Python 3.8-3.13 syntax; analysis run end-to-end with pandas 1.4, 1.5 and 3.0 and scikit-learn 1.1, 1.3 and current,
against a mock service. Always test with your own data first (`full --dry`).

## License

Add the license of your choice before publishing.
