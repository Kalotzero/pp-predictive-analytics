"""Diagnostic (read-only): where does a remaining distortion in the totals come from?

Copy this file next to production_analytics.py and run  py diag.py  (reads <script folder>/work/cache,
or the cache folder given as first argument). It prints planned/actual value by flag, the biggest lines
that are not UNIT CHECK, and the biggest UNPLANNED lines. It changes and writes nothing."""
import os, sys
# the data is in work/cache (override: py diag.py <cache folder>)
_here = os.path.dirname(os.path.abspath(__file__))
sys.argv = [sys.argv[0], sys.argv[1] if len(sys.argv) > 1 else os.path.join(_here, "work", "cache")]
import pandas as pd
import production_analytics as pa
pd.set_option("display.width", 250, "display.max_columns", 30, "display.max_colwidth", 28)

o, c = pa.load()
k = pa.consumption(o, c)
k["ratio"] = k["planned_for_actual"] / k["actual_qty"].where(k["actual_qty"] > 0)
tot = k["planned_value"].sum()
print(f"Planned value total {tot:,.0f}   actual {k['actual_value'].sum():,.0f}")

print("\n1) Planned value by flag (what is carrying the 1.5bn?)")
print(k.groupby(k["flag"].replace("", "(none)"))[["planned_value", "actual_value", "excess_value"]]
      .sum().round(0).sort_values("planned_value", ascending=False))

print("\n2) Lines without flag, by ratio planned/actual (planned value)")
n = k[(k["flag"] == "") & k["ratio"].notna()]
b = pd.cut(n["ratio"], [0, 0.02, 0.1, 0.5, 0.9, 1.1, 2, 10, 50, 1e12])
print(n.groupby(b, observed=True)[["planned_value", "actual_value"]].agg(["count", "sum"]).round(0))

print("\n3) Top 15 lines by planned value that are NOT UNIT CHECK and deviate >5x either way")
x = k[(k["flag"] != "UNIT CHECK") & ((k["ratio"] > 5) | (k["ratio"] < 0.2) | (k["flag"] == "NOT ISSUED"))]
cols = ["order", "material", "component", "flag", "planned_for_actual", "actual_qty", "unit", "price_per_unit", "currency", "planned_value"]
print(x.sort_values("planned_value", ascending=False)[cols].head(15).to_string(index=False))

print("\n4) Top 10 lines by actual value on UNPLANNED lines (no recipe)")
u = k[k["flag"] == "UNPLANNED"].sort_values("actual_value", ascending=False)
print(u[["order", "material", "component", "actual_qty", "unit", "price_per_unit", "currency", "actual_value"]].head(10).to_string(index=False))

# ---- focus on one currency (default: the most frequent; override with DIAG_CURRENCY)
import os
CUR = os.environ.get("DIAG_CURRENCY") or k["currency"].mode().iat[0]
R = k[k["currency"] == CUR]
print(f"\n5) {CUR}: planned/actual/excess by flag")
print(R.groupby(R["flag"].replace("", "(none)"))[["planned_value", "actual_value", "excess_value"]].sum().round(0))
print(f"\n6) {CUR}: top 20 lines by |excess_value|")
cols2 = ["order", "material", "component", "flag", "planned_for_actual", "actual_qty", "unit", "price_per_unit", "planned_value", "excess_value"]
print(R.reindex(R["excess_value"].abs().sort_values(ascending=False).index)[cols2].head(20).to_string(index=False))
print(f"\n7) {CUR}: planned value of the top 10 orders (share of {CUR} total)")
t = R.groupby("order")[["planned_value", "excess_value"]].sum().sort_values("excess_value").head(10)
t["share_of_excess"] = t["excess_value"] / R["excess_value"].sum()
print(t.round(3))
