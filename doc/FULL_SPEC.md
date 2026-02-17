# 3-Graph Generation Spec

## Purpose
This spec defines how to generate the 3 core figures for the paper from per-second running data.

## Input Data Schema (Unified Long Format)
One row per second.

| Column | Type | Required | Notes |
|---|---|---|---|
| `run_id` | string | Yes | Unique run/activity id |
| `ts` | datetime (ISO-8601) | Yes | Per-second timestamp |
| `start_time` | datetime (ISO-8601) | Yes | Run start timestamp (used for day/window grouping) |
| `hr` | float | Yes | Heart rate (bpm) |
| `pace_sec_per_km` | float | Yes | Pace in sec/km (derive from speed if needed) |
| `cadence` | float | Yes | Cadence in spm (steps/min) |
| `grade` | float | Optional | Grade in percent |

### Source Mapping (Strava)
- `time` stream -> `ts = start_time + time(seconds)`
- `heartrate` stream -> `hr`
- `velocity_smooth` stream -> `pace_sec_per_km = 1000 / velocity_smooth`
- `cadence` stream -> `cadence = raw_cadence * 2` (Strava per-leg to spm)
- `grade_smooth` stream -> `grade = grade_smooth * 100`

## Global Parameters
- `max_hr` (default: 200)
- `rest_hr` (default: 54)
- HR band lower bounds (default %): `59, 74, 84, 88, 95`
- rolling window days (default: `30`)
- compare cadence thresholds (default: `125, 140, 150`)
- threshold sweep range: `120..170`, step `5`

## Derived Signals
### HR intensity
Primary (HRR):

`intensity = (hr - rest_hr) / (max_hr - rest_hr)`

Fallback if invalid denominator:

`intensity = hr / max_hr`

Clamp to `[0.0, 1.5]`.

### HR bands
Given lower bounds `(z1,z2,z3,z4,z5)` in proportions:
- `Z1: [z1, z2)`
- `Z2: [z2, z3)`
- `Z3: [z3, z4)`
- `Z4: [z4, z5)`
- `Z5: [z5, +inf)`

### Running stride filter
A sample is stride-filtered-in if:

`cadence >= threshold_spm`

## Baseline Definition
For a given day `D`, HR band `B`, and cadence threshold rule:
1. Take samples whose `start_time` day is within `[D-window_days+1, D]`.
2. Keep only samples in HR band `B`.
3. If stride filtering is enabled, keep only `cadence >= threshold`.
4. Baseline value for day `D` = mean of `pace_sec_per_km` over kept samples.
5. Require minimum `20` samples; otherwise skip that day.

This produces a rolling baseline series per condition.

---

## Graph 1: Contamination SD Comparison
### Goal
Quantify contamination effect (with-walk vs stride-filtered) by HR band.

### Conditions per HR band
- `With-walk`: no cadence filtering
- `Filtered @ compare thresholds`: one condition per compare threshold (default 125/140/150)

### Statistic shown
For each condition, compute SD of rolling baseline series:

`SD = sqrt(variance(rolling_baseline_values))`

Display unit as `min/km`:

`sd_min_per_km = sd_sec_per_km / 60`

### Bars
For each band (`Z1..Z5`), show 4 bars:
1. with-walk SD
2. filtered SD @ threshold A
3. filtered SD @ threshold B
4. filtered SD @ threshold C

### Robustness table (below chart)
Using the main stride threshold (`Stride Threshold` input):
- with-walk SD
- filtered SD
- SD reduction %
- log(SD ratio)
- Bootstrap 95% CI for reduction %

Formulas:
- `reduction_pct = (sd_with_walk - sd_filtered) / sd_with_walk * 100`
- `log_sd_ratio = ln(sd_filtered / sd_with_walk)`

Bootstrap CI (N=1000, fixed seed acceptable):
- Resample rolling-baseline values with replacement for both conditions.
- Recompute reduction % per resample.
- CI = 2.5th and 97.5th percentiles.

---

## Graph 2: Stride Threshold Sensitivity
### Goal
Show threshold sensitivity and retention tradeoff.

### Sweep
For thresholds `120, 125, ... 170` in target HR band (default `Z2`):
1. Build stride-filtered rolling baseline series.
2. Compute `SD(threshold)`.
3. Compute retained sample % in target band:

`retained_pct = kept_samples / total_samples_in_target_band * 100`

### Chart lines
- Line 1 (blue): normalized SD index

`sd_index = (sd - min_sd) / (max_sd - min_sd) * 100`

- Line 2 (orange): retained sample %

### Fixed-threshold compare card (A/B/C)
For each compare threshold show:
- SD (`min/km`)
- normalized SD index
- retained sample %
- log(SD ratio) (vs with-walk in target band)
- Bootstrap 95% CI for SD reduction %

---

## Graph 3: Dual-Window All-Zone Comparison
### Goal
Compare current vs previous 30-day efficiency baseline for all HR bands.

### Windows
Let `last_day` be latest sample day.
- Current window: `[last_day-29, last_day]`
- Previous window: `[last_day-59, last_day-30]`

### Per-band baseline
For each band (`Z1..Z5`):
1. Keep stride-filtered samples using main `Stride Threshold`.
2. Compute mean `pace_sec_per_km` in current window.
3. Compute mean `pace_sec_per_km` in previous window.

### Delta
`efficiency_delta_pct = (previous - current) / previous * 100`

Positive means faster pace at same HR (improved efficiency).

### Output
- Grouped bars per band: previous vs current (`mm:ss /km` axis labels).
- All-zone table:
  - band
  - previous 30d (`mm:ss /km`)
  - current 30d (`mm:ss /km`)
  - delta %

---

## Output Formatting
- Pace display: `mm:ss /km`
- SD display: `min/km` (decimal)
- CI display: `[low%, high%]`
- If insufficient data, output `NA`.

## Data Quality Rules
- Drop rows with invalid/missing required fields.
- Require positive pace and cadence for running computations.
- Require at least 20 samples for each rolling-day estimate.
- For effect sizes and bootstrap: if sample counts are too small (<3), return `NA`.

## Reproducibility Notes
- Keep bootstrap seed fixed (e.g., `42`) for deterministic CI during development.
- Record all runtime parameters in output metadata:
  - max/rest HR
  - zone thresholds
  - window days
  - compare thresholds
  - sweep range

## Recommended Figure Order
1. Contamination SD Comparison
2. Stride Threshold Sensitivity
3. Dual-Window All-Zone Comparison

This ordering supports the argument flow:
- contamination exists -> threshold choice robustness -> trend interpretability.
