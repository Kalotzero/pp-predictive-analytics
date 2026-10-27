# Python server

One machine runs everything (Windows or Linux). It needs network access to the SAP HTTPS port and about 1 GB of free disk.

## 1. Install

```
python -m pip install -r python/requirements.txt        # pandas numpy scikit-learn scipy requests
```

On Linux with an "externally managed environment" message use a virtual environment:

```
python3 -m venv venv
venv/bin/pip install -r python/requirements.txt
```

and start the jobs with `venv/bin/python`. Python 3.8 or newer works; a current Python is recommended.
Matplotlib is not needed.

## 2. Files

Put these files into one folder (the folder name is free, the file names are not: `pp_client.py` starts
`production_analytics.py` from its own folder):

```
pp_client.py
production_analytics.py
.env                      (created from python/.env.example)
```

## 3. `.env`

```
SAP_URL=https://<host>:<https-port>/sap/zpp/analytics
SAP_CLIENT=<client>
SAP_USER=<technical user>
SAP_PASSWORD=<password>
SAP_VERIFY_SSL=1
```

The file name is exactly `.env` (no `.txt`). Restrict it to the service account.
Optional: `WORK_DIR` (default `work` next to the script), `SAP_PLANTS`, `SAP_CA_BUNDLE`, `PP_KEEP_OUT`.

## 4. First run

```
python pp_client.py ping                       # {'ok': True, 'server_time': ..., 'client': ..., 'system': ...}
python pp_client.py full --from <YYYYMMDD> --max-pages 1 --dry
python pp_client.py full                       # first real load, can take 20-40 minutes
```

Watch progress in `work/logs/pp_client.log`. Do not pipe the output into a command that waits for the end.
If a run is interrupted, start it again; the local cache is kept.

## 5. Schedule

- every 30 minutes: `python pp_client.py delta`
- every night at 02:00: `python pp_client.py nightly`

Examples: `python/schedule_windows.ps1` (Task Scheduler) and `python/schedule_linux_cron.txt` (cron).
Set the working directory ("Start in") to the folder with the scripts. Jobs must not overlap; the lock file prevents it.

## 6. What is stored on the server

| Path | Content |
|---|---|
| `work/cache/*.csv` | local copy of the extract (orders, components, wrong movements), last 800 days, pruned nightly |
| `work/out/` | result files of one run; deleted after a successful upload (`PP_KEEP_OUT=0`) |
| `work/logs/pp_client.log` | log, rotates at 2 MB, 5 old files |
| `work/state.json` | time of the last run; without it `delta` stops and asks for `full` |
| `work/pp_client.lock` | exists only while a run is active (expires after 2 hours) |

The cache can be deleted at any time; run `full` to rebuild it. Treat it like any business data.
