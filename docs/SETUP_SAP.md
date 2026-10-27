# SAP side

## 1. Objects (create in DEV, transport to QAS and PRD)

Create in this order: tables -> classes -> report -> ICF node.

| Object | Type | Source |
|---|---|---|
| ZPP_ORD, ZPP_COMP, ZPP_GRP, ZPP_DRV, ZPP_RUNLOG | transparent tables | `abap/tables/*.tabl.abap` (ADT: New > Dictionary > Database Table, paste, activate) |
| ZCL_PP_EXTRACT | global class | `abap/classes/ZCL_PP_EXTRACT.clas.abap` |
| ZCL_PP_REST | global class (HTTP handler) | `abap/classes/ZCL_PP_REST.clas.abap` |
| ZPP_PRED_REP | report (user output) | `abap/reports/ZPP_PRED_REP.abap` |
| ZPP_BOM_QTY_CHECK | report (read-only BOM check) | `abap/reports/ZPP_BOM_QTY_CHECK.abap` |
| /sap/zpp/analytics | ICF service node | SICF, see below |

Optional: a transaction code for `ZPP_PRED_REP` (SE93).

## 2. ICF node

1. Transaction SICF, hierarchy type SERVICE, execute.
2. Right-click `default_host > sap` > New Sub-Element: `zpp`, then under it `pp`.
3. Tab "Handler List": `ZCL_PP_REST`. Leave "Logon Data" empty (the caller logs on with user and password).
4. Activate the service. In production set "SSL required" on the node.
5. Test in a browser: `https://<host>:<https-port>/sap/zpp/analytics?action=ping&sap-client=<client>` returns
   `{"ok":true,"server_time":...,"client":...,"system":...}`.

Parent node `zpp` is only a folder: a "404 No Extension Found" means you tested the parent, not `pp`, or the handler is not active.

## 3. Technical user and role

A dialog-type or system user used only by the Python server. The role needs:

- `S_ICF` for the service `/sap/zpp/analytics`,
- `S_TABU_NAM` with activity 02 and 03 on the five `ZPP_*` tables (the handler checks 03 for reading,
  02 for writing results),
- read access to the tables the extract reads: AFKO, AFPO, AUFK, AFRU, RESB, MATDOC, MARA, MAKT, MBEW, CRHD, T001K, T001.

Test the role with `python pp_client.py ping` and a `--dry` run.

## 4. HTTPS

Make sure the HTTPS port is active (SMICM > Services) and the server certificate is valid (STRUST).
If the certificate comes from an internal CA, give the root certificate to the client with `SAP_CA_BUNDLE`.

## 5. User report

`ZPP_PRED_REP` has four views: orders, components, groups, drivers.
Double-click an Explanation cell to read the full text. Order number -> CO03, material -> MM03.
The list shows at most ~128 characters of a cell in the grid; the popup shows everything.

## 6. BOM check (optional)

`ZPP_BOM_QTY_CHECK` lists active production BOM items whose quantity is more than FACTOR times the BOM
base quantity (same unit), more than FACTOR times the median of the same component in the plant, or above an
absolute limit. It only reads data. Use it to fix the BOM errors that the analysis flags as `UNIT CHECK`.
