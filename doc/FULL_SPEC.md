# FULL_SPEC.md

# Cadence-Gated Rolling Baselines for Wearable Running Data
Technical Specification (Stage 1 N-of-1 Configuration)

## 1. Purpose

This document specifies the computational workflow used for cadence-gated rolling-baseline estimation in wearable running data under mixed-regime conditions.

The purpose of this specification is reproducibility. It documents the implementation logic, parameterization, data structures, and evaluation outputs used in the Stage 1 N-of-1 methods study associated with this repository.

This specification does **not** constitute:
- population-level validation,
- a universal cadence-threshold claim,
- a formal physiological performance metric,
- or a deployment guarantee across runners, devices, or training styles.

The current implementation is designed to support a regime-aware longitudinal monitoring pipeline in which:
1. cadence is used as a practical locomotion-state label,
2. heart rate is used as the intensity-conditioning axis,
3. rolling baselines are computed within HR-conditioned bands,
4. and mixed-regime variance contamination is reduced before temporal comparison.

---

## 2. Scope

This repository implements a **Stage 1 proof-of-concept** pipeline for a single-runner longitudinal dataset obtained through authorized Strava API access.

The workflow is intended to support:
- contamination analysis,
- cadence-threshold sensitivity analysis,
- HR-conditioned rolling-baseline estimation,
- dual-window temporal differentiation,
- cadence–HR temporal separation checks,
- and permutation-based sanity checks.

The workflow is **not** intended to:
- infer athletic improvement directly,
- estimate physiological ground truth,
- replace formal laboratory validation,
- or establish universal settings across runners.

---

## 3. Conceptual Framing

### 3.1 Core problem

Wearable running sessions often contain mixed locomotion regimes within the same analysis window, including:
- continuous running,
- planned run–walk intervals,
- recovery breaks,
- and short non-running interruptions.

If such samples are aggregated without conditioning, rolling summaries can become unstable and less interpretable for longitudinal athlete monitoring.

### 3.2 Design choice

The implementation addresses this problem by separating likely running from likely walking at the sample level using cadence, then computing baseline summaries within HR-conditioned intensity bands.

Cadence is treated as a **kinematic regime-labeling signal**, not as a performance target.

Heart rate remains the **conditioning axis** for internal load.

### 3.3 Interpretation policy

Variance reduction is interpreted as **stabilization** of the rolling baseline under regime heterogeneity.

It is **not** interpreted as:
- improved fidelity to an unobserved “true” physiological value,
- improved sensor validity,
- or proof of better athletic performance.

---

## 4. Inputs

### 4.1 Required stream-level inputs

Each activity is represented as a second-level time series when available. Core inputs are:

- `timestamp`
- `heartrate` or equivalent HR stream, in bpm
- `velocity` or pace-derived speed, in m/s
- `cadence` from Strava or equivalent source
- `grade` (optional), in percent

### 4.2 Metadata / configuration inputs

The workflow also requires user- or study-level configuration values:

- `HRmax`
- `HRrest`
- HR zone cut points
- cadence threshold
- rolling-window length
- trimming settings
- optional comparison thresholds for robustness reporting

### 4.3 Data source assumption

The current Stage 1 implementation assumes data are retrieved through Strava API authorization rather than ad hoc CSV upload. If other sources are used, field names and cadence normalization rules must be mapped into the same canonical schema before analysis.

---

## 5. Canonical Variables

The following canonical variables are used throughout the pipeline.

### 5.1 Raw variables

- `HR(t)` : heart rate at time `t` in bpm
- `v(t)` : velocity at time `t` in m/s
- `cad_raw(t)` : cadence from source
- `g(t)` : grade at time `t` in %

### 5.2 Derived variables

- `pace_sec_per_km(t) = 1000 / v(t)` for `v(t) > 0`
- `cad_spm(t)` : cadence in steps per minute
- `I(t)` : intensity scalar derived from heart rate
- `band(t)` : HR-conditioned band label
- `R(t)` : running-regime indicator

### 5.3 Display variables

Optional display-oriented fields may be generated, e.g.:

- `pace_mmss_per_km`
- `gap_mmss_per_km`
- formatted dual-window outputs
- summary tables for reporting

Display fields are not used for computation.

---

## 6. Preprocessing

### 6.1 Warm-up / cool-down trimming

In the current implementation, no default warm-up / cool-down trimming is applied.

All valid retained samples are kept unless an explicit trimming rule is added in configuration or preprocessing.

### 6.2 Time-domain alignment

For activity-to-activity diagnostics that require pointwise comparison, aligned segments are created by truncating each activity to the minimum retained length across the compared set.

This implementation does **not** perform time warping or interpolation-based realignment.

This choice prioritizes comparability and avoids alignment artefacts, while potentially underrepresenting later-session drift.

### 6.3 Invalid pace handling

Samples with non-positive velocity are excluded from pace-based computation.

### 6.4 Missing grade handling

Grade may be retained as an auxiliary field for diagnostics or reporting.

In the current implementation, baseline computation uses raw pace (`pace_sec_per_km`) regardless of grade availability.

---

## 7. Cadence Normalization and Regime Labeling

### 7.1 Strava cadence normalization

Strava cadence is commonly exposed per leg (strides per minute). For implementation consistency, cadence is converted to steps per minute as:

`cad_spm = 2 * cad_strava`

If cadence is already provided in steps per minute, no doubling is applied.

### 7.2 Running-regime indicator

A sample-level running-regime indicator is defined as:

`R(t) = 1 if cad_spm(t) >= tau_cad, else 0`

where:
- `tau_cad` is the cadence threshold in steps per minute.

### 7.3 Default threshold

The default threshold is:

- `tau_cad = 140 spm`

### 7.4 Threshold robustness window

In the associated Stage 1 paper, the range **140–150 spm** is treated as an **operational robustness window** for the present dataset because it balances variance reduction, retained data, and stability.

This range is **not** claimed to be universal across runners.

### 7.5 Known limitations of cadence gating

Cadence gating is a practical proxy classifier and can produce false negatives or subject-specific differences in cases such as:

- uphill running,
- fatigued running,
- slow jogging,
- atypical stride mechanics,
- different devices or cadence estimation methods.

For this reason, threshold behavior should be interpreted as **subject- and configuration-sensitive**.

---

## 8. Intensity Conditioning

### 8.1 HRR-based intensity scalar

The primary implementation uses heart-rate reserve (HRR):

`I(t) = (HR(t) - HRrest) / (HRmax - HRrest)`

with values interpreted on `[0, 1]` where possible.

### 8.2 Stage 1 configuration

The current Stage 1 N-of-1 configuration uses:

- `HRmax = 200`
- `HRrest = 54`

These values are configuration settings for the current subject and are not claimed to be general defaults.

### 8.3 HRR band cut points

The current implementation uses the following cut points:

- 59%
- 74%
- 84%
- 88%
- 95%

These define five zones (`Z1`–`Z5`) on the HRR scale.

### 8.4 Boundary handling

Each sample is assigned to the first band whose interval contains the computed intensity value.

Values outside the configured range are clipped to the nearest boundary band:
- underflow -> lowest band,
- overflow -> highest band.

### 8.5 Alternative stratification

For comparative analysis, a `%HRmax` partition may also be reported.

This alternative is included for interpretability and robustness comparison, not as the primary conditioning scheme.

---

## 9. Pace Representation

### 9.1 Primary pace variable

The rolling baseline is computed using pace-like variables defined at the sample level.

Current implementation:
- `pace_sec_per_km(t)` is used as the primary computational variable.

### 9.2 Interpretation rule

The baseline represents a **band-conditioned running baseline** under comparable internal-load strata.

It should not be interpreted as:
- a universal efficiency score,
- a physiological capacity estimate,
- or a standalone outcome measure.

---

## 10. Rolling Baseline Estimator

### 10.1 Window definition

For each anchor day `d` and band `b`, the pipeline constructs a trailing rolling window of length `W` days.

Default:
- `W = 30 days`

### 10.2 Sample set

Let `S(d, b)` denote the set of retained samples that satisfy all of the following:
- sample time falls within the trailing window for day `d`,
- sample belongs to HR band `b`,
- sample is labeled as running-regime (`R(t) = 1`),
- pace-like value is valid.

### 10.3 Baseline summary

Within each `S(d, b)`, the baseline is summarized using:

- mean pace (`pace_sec_per_km`)
- sample standard deviation

Conceptually:

- `mu(d, b) = mean(E(t)) for t in S(d, b)`
- `sigma(d, b) = sd(E(t)) for t in S(d, b)`

where `E(t)` is the selected pace-like variable.

### 10.4 Unconditioned comparator

For contamination analysis, an unconditioned comparator is computed under otherwise identical settings but with walking samples included.

This serves as the regime-mixed baseline.

---

## 11. Dual-Window Temporal Differentiation

### 11.1 Default definition

The primary dual-window comparison uses two consecutive, non-overlapping 30-day windows:

- previous 30-day window,
- current 30-day window.

For each HR band, the baseline difference is computed as:

`Delta(b) = mu_current(b) - mu_previous(b)`

This 30-day previous-versus-current comparison is the main dual-window analysis reported in the manuscript.

### 11.2 Illustrative window-length comparison

In addition to the default 30-day setting, the Stage 1 manuscript reports an illustrative
**14-day versus 30-day** window-length comparison as a robustness check.

In that comparison, the 14-day setting yields higher temporal sensitivity and higher baseline variance, whereas the 30-day setting yields smoother estimator behavior; both settings show directionally consistent variance stabilization under cadence conditioning.

The 14-day setting should therefore be interpreted as a **supplementary window-length robustness comparison**, not as the primary default analysis window.

### 11.3 Intended use

Dual-window comparison is used as a **qualitative stability probe** and **signal-preservation check**.

It is not intended as:
- inferential change detection,
- evidence of physiological improvement,
- or a formal longitudinal outcome estimate.

### 11.4 Data sufficiency

For transparency, retained-second counts are tracked for each band and each window.

Very sparse bands may be:
- flagged,
- de-emphasized,
- or set to `NA` in output tables, depending on reporting rules.

---

## 12. Evaluation Outputs

### 12.1 Contamination analysis

Compares:
- regime-mixed baseline (with walking samples),
- cadence-filtered baseline.

Primary outputs:
- SD by HR band,
- reduction percentage,
- log(SD ratio),
- descriptive bootstrap bounds where applicable.

### 12.2 Threshold sensitivity sweep

Evaluates cadence thresholds across a broad range.

Primary outputs:
- baseline SD,
- normalized SD index,
- retained sample percentage,
- threshold-specific stabilization summaries.

### 12.3 Intensity-stratification comparison

Compares:
- global aggregation,
- HRR-based stratification,
- `%HRmax`-based stratification.

This evaluates whether cadence gating adds stabilization beyond HR-based partitioning alone.

### 12.4 HR-only versus cadence-gated comparison

Compares:
- unconditioned baseline,
- HR-only banding,
- HR-banding plus cadence gating.

This isolates the incremental contribution of cadence gating.

### 12.5 Cadence–HR temporal separation check

Examines whether cadence gating acts as a circular partition of the HR signal by aligning cadence transition events and evaluating HR response lag.

The expected interpretation is temporal separation, not instantaneous HR partitioning.

### 12.6 Permutation-based sanity check

Uses label or gating perturbation as a structural sanity check.

If the observed stabilization disappears under permutation, this supports the interpretation that the stabilization is linked to real cadence-defined regime structure rather than arbitrary sample removal.

---

## 13. Bootstrap Policy

### 13.1 Role of bootstrap

Bootstrap reporting is used as a **descriptive robustness device** rather than as strict inferential confirmation.

### 13.2 Rolling-baseline outputs

For rolling-baseline summaries, bootstrap may be applied over daily baseline values rather than raw second-level samples.

### 13.3 Dependency caveat

Because rolling windows overlap, daily baseline series are serially dependent.

Accordingly, bootstrap intervals should be interpreted as:
- descriptive robustness bounds,
- not formal i.i.d. confidence intervals.

### 13.4 Dual-window outputs

For dual-window summaries, any percentile ranges are likewise descriptive and should not be interpreted as formal hypothesis-test outputs.

---

## 14. Output Tables and Figures

The implementation may generate the following output families:

- contamination summary by HR band,
- threshold sensitivity plots,
- HRR / `%HRmax` comparison tables,
- dual-window baseline comparison tables,
- window-length robustness tables (e.g. 14-day vs 30-day),
- event-aligned cadence–HR plots,
- incremental stabilization comparison tables,
- permutation sanity-check summaries.

Exact formatting can vary across paper, notebook, or app-facing output layers, but the computational logic should remain consistent with this specification.

---

## 15. Out-of-Scope Items

The following are explicitly out of scope for the present Stage 1 manuscript-level workflow:

- universal threshold optimization across runners,
- device-level validation against chest-strap references,
- population-level inference,
- causal performance claims,
- formal change-detection inference,
- multi-runner external validation,
- complete sensor-error modeling,
- and downstream application-facing composite execution scores.

A downstream per-session score may exist in broader product or app design, but it is **not** the methodological contribution documented here.

---

## 16. Current Stage 1 Parameter Snapshot

Current manuscript-aligned settings:

- cadence threshold default: `140 spm`
- operational robustness window (current dataset): `140–150 spm`
- primary rolling baseline / dual-window setting: `30 days`
- illustrative window-length robustness comparison: `14 vs 30 days`
- HRmax: `200`
- HRrest: `54`
- HRR cut points: `59 / 74 / 84 / 88 / 95`

These settings are provided for reproducibility of the current Stage 1 analysis and should not be interpreted as universally optimal.

---

## 17. Reproducibility Notes

This repository is intended to provide:
- code,
- implementation documentation,
- parameter definitions,
- and workflow transparency
for the computational pipeline described in the associated manuscript.

Where the paper presents the methodological framing and empirical results, this specification serves as the technical implementation companion.

If any discrepancy arises between older repository notes and the manuscript-aligned wording in this file, the manuscript-aligned wording should be treated as authoritative for the Stage 1 research version.

---


## 18. Citation / Manuscript Relationship

If this repository is cited in a manuscript, it should be described as providing:
- implementation details,
- schema definitions,
- and reproducibility support
for the cadence-gated rolling-baseline workflow.

It should **not** be cited as evidence of multi-runner validation or as a replacement for empirical evaluation.

---
