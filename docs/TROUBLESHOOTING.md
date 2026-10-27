# Troubleshooting

| Message / symptom | Cause and fix |
|---|---|
| `SAP login refused (401)` | wrong user or password, wrong client, or a placeholder still in `.env`. Settings in the shell (environment variables) override the `.env` |
| `403 not authorized (S_TABU_NAM ...)` | the technical user lacks activity 02/03 on the `ZPP_*` tables |
| `certificate has expired` / `SSLError` | renew the certificate in STRUST, or set `SAP_CA_BUNDLE` for an internal CA. `SAP_VERIFY_SSL=0` only for a test |
| `SAP_URL uses plain HTTP` | use `https://`; `SAP_ALLOW_HTTP=1` only for development |
| `404 No Extension Found` | test the node `pp`, not the parent `zpp`; check that the handler `ZCL_PP_REST` is active in SICF |
| `No previous run: start with full` | `work/state.json` is missing: run `full` once |
| `another run is active (lock file) - skipped` | a run is active; if none is, delete `work/pp_client.lock` (it also expires after 2 hours) |
| `can't open file ... production_analytics.py` | both scripts must be in the same folder under these names |
| `No module named ...` | install the packages for the Python that runs the job (`pip install -r requirements.txt`) |
| `Length mismatch: Expected axis has N elements` (old pandas 1.x) | fixed in this version: empty product/component values are normalised. Use the current `production_analytics.py` |
| `categorical_features ... from_dtype` (old scikit-learn) | fixed in this version |
| full load looks stuck | normal for 700-1000 pages; read `work/logs/pp_client.log` |
| explanation column cut in the grid | the ALV shows ~128 characters; double-click the cell for the full text |
| order is RED but nothing is flagged | excess value above the limit with no single unusual component: open the components view of the order, sort by excess value |
