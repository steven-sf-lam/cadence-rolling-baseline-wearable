# Cadence-Conditioned Rolling Baseline Estimation

This repository provides anonymized 1 Hz wearable running data 
supporting the methodological study:

Cadence-Conditioned Rolling Baseline Estimation for Wearable Running Data:
Variance Stabilization, Threshold Robustness, and Intensity-Stratified Temporal Differentiation

---

## Overview

This repository contains:

- Anonymized raw wearable time-series data (1 Hz resolution)
- Data schema specification
- Documentation describing the estimation procedure
- Figures corresponding to the manuscript

The repository is intended to support reproducibility of the statistical framework described in the paper.

No personally identifiable information is included.

---

## Research Scope

This project investigates variance stabilization in rolling baseline estimation under regime-mixed wearable data.

Specifically, it examines:

- Cadence-conditioned filtering
- Rolling 30-day baseline estimation
- Dual-window temporal differentiation
- Threshold robustness and sensitivity analysis

This work does NOT claim:

- Training optimization
- Performance prediction
- Physiological causation
- Clinical interpretation

All results are statistical in nature.

---

## Data Description

Sampling resolution: 1 Hz

Variables include:

- Heart rate (bpm)
- Pace (sec per km)
- Cadence (steps per minute)
- Relative time index
- Intensity band labels

Removed for anonymization:

- GPS coordinates
- Absolute timestamps
- Route information
- Activity identifiers

---

## Reproducibility

The estimation procedure is fully described in the manuscript and accompanying documentation.

Researchers may re-implement the statistical pipeline in any programming language.

No executable source code is required to reproduce the analysis.

---

## Citation

If you use this dataset or methodology, please cite the associated manuscript.

See CITATION.cff for structured citation metadata.

---

## License

Data and documentation are released under the terms specified in the LICENSE file.
