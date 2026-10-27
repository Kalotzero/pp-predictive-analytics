# Analysis rules (production_analytics.py)

All thresholds are constants at the top of `production_analytics.py`.

## Component lines
Planned quantity (reservation RESB, scaled by delivered / target quantity unless fixed) is compared with the
actual issued quantity (material documents 261 minus 262).

| Flag | Meaning |
|---|---|
| `OVER` / `UNDER` | variance more than 5 % **and** robust z-score above 3 against the normal behaviour of the same component in the same product |
| `NOT ISSUED` | planned, nothing issued |
| `UNPLANNED` | issued, but not in the order BOM (often a substitute material) |
| `WRONG MVT` | the product itself was issued (261) to its own order; excluded from raw-material values, delivered quantity is reduced by it |
| `UNIT CHECK` | planned and actual differ by more than 50x (either way), or the planned quantity is more than 50x the median of the same component in other orders, or more than 50x the order output in the same unit. Almost always a wrong BOM base quantity or unit. If one line of an order is clearly implausible, the other planned lines with nothing issued are suspect too |

`UNIT CHECK` lines stay visible but are left out of value totals, baselines and group comparison.
A `NOT ISSUED` line and an `UNPLANNED` line of the same order, same unit and quantities within 10 % count as a
substitution; their values are netted to zero.

## Orders
- **RED**: excess raw-material value above the limit of the order currency (`RED_EXCESS_BY_CURRENCY`, optional; default `RED_EXCESS_VALUE` = 200 for
  other currencies), or high scrap (rate above the 90th percentile of the same product), or own product issued.
- **YELLOW**: at least one flagged or unplanned line, or the order variance is above 5 %.
- **GREEN**: everything else.
- A RED order without a component-level reason gets an explanation text that says so.

Adjust `RED_EXCESS_BY_CURRENCY` to the currencies and amounts that matter to you.

## Groups
Product group, product, work center, shift, supervisor, order type and weekday are compared with all others using a
value-weighted variance and a Mann-Whitney test. Values of different currencies are never added together: each group is
compared with orders of its own main currency. Orders without a usable recipe are excluded from the comparison.
A finding is reported when the difference is significant and at least 0.5 percentage points.

## Drivers
HistGradientBoostingRegressor on order features (product group, product, work center, shift, supervisor, order type,
weekday, month, delivered/target ratio, order size, setup time, confirmations) for the raw-material variance and the
scrap rate; permutation importance gives the ranking. Text columns are encoded as integer codes, so every scikit-learn
version works. At least 200 orders with a value are needed per target.

## Typical data findings
Most large "deviations" in a first run are master-data errors (BOM base quantity or unit). Use `UNIT CHECK` and the
BOM check report to find them, and fix them in the BOM, not in the code.
