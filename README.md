# DMAPRIME-QR_E

This repository contains the weekly Flu MetroCast forecast pipeline for the `DMAPRIME-QR_E` model. The forecast is built from three quantile learners trained on hub target data and auxiliary NSSP series: gradient-boosted quantile regression (GBQR), quantile random forest (QRF), and linear quantile regression (LQR). At each location and forecast horizon, the submitted predictive distribution is the element-wise median of the three model quantiles, with no interval widening.

For South Carolina, North Carolina, and Georgia, the median forecast may be adjusted with a pooled Prisma Health + MUSC correction when the health-system signal is sufficiently current and complete. If the correction data fail the freshness or completeness checks, the pipeline falls back to the median-only forecast rather than forcing a potentially unreliable adjustment.

## Methodology

The forecast pipeline follows a multi-stage modeling approach built around the code in `metrocast_lib.R` and `run_weekly.R`.

- Data assembly:
  - The hub target series is loaded from `target-data/latest-data.csv` and filtered to `Flu ED visits pct`.
  - Auxiliary NSSP data are loaded from the CDC all-HSA parquet file and restricted to non-hub HSA and state series.
  - Locations, state metadata, and population information are merged from the hub `locations.csv` table.

- Transformation and feature construction:
  - The target series is transformed on a fourth-root scale, `z = y^(1/4)`, then normalized by a location-specific 95th percentile and centered by the location mean.
  - The transformed level is used to generate Taylor-series projections over recent history, rolling means, and seasonal covariates.
  - Features include historical level and slope terms, rolling windows, seasonal timing (`season_week`, `wk_xmas`), population (`log_pop`), a location-level noise proxy, and contemporaneous state context (`st_level`, `st_slope3`, `st_slope4`).
  - Training rows are created for k-step-ahead changes by aligning future target values with lagged feature windows across horizons 1 through 5.

- Model specification:
  - GBQR: LightGBM quantile regression trained on the full feature set with quantile loss over the model quantile grid `QL = (0.01, 0.025, ..., 0.99)`.
  - QRF: ranger quantile forest trained on the same feature set, using quantile regression trees with a limited node size and random subsampling.
  - LQR: step-specific linear quantile regression for each forecasting lag, using a compact feature set designed to reduce collinearity while preserving seasonal and slope structure.

- Forecast construction:
  - Each component model predicts quantile changes on the transformed scale.
  - Predictions from the three models are sorted within each row and combined by the element-wise median.
  - The resulting delta quantiles are converted back to the original scale using the location-specific `p95` and `mu` calibration.
  - Quantile forecasts are then converted into 100 sample trajectories per location and written in the hub submission format.

## Repository structure

- `run_weekly.R` — main forecasting script
- `run_from_R.R` — convenience runner for R / RStudio
- `config.R` — local configuration values
- `metrocast_lib.R` — transformation utilities, feature generation, model fitting, and forecast post-processing
- `correction.R` — Prisma + MUSC correction logic
- `validate.R` — validation checks against hub requirements
- `plot_forecast.R` — plotting and diagnostics
- `model-metadata/DMAPRIME-QR_E.yml` — hub metadata
- `tests/` — correction and validation tests

## Output and validation

The main forecast is written in the standard hub format as a parquet file:

```text
flu-metrocast/model-output/DMAPRIME-QR/<reference-date>-DMAPRIME-QR_E.parquet
```

The pipeline also writes diagnostics and plots to the local `data/` directory, including quantile summaries, internal forecast objects, and PDF/HTML plots. Validation checks are run after forecast generation and the run stops if any required check fails.

## Correction logic

The correction layer targets SC, NC, and GA only. It compares the latest Prisma Health and MUSC surveillance data against the expected coverage and completeness pattern before applying the pooled correction. The logic is intentionally conservative: if either signal is missing, stale, or incomplete relative to the prior week, the correction is skipped and the model uses the median-only forecast.

This safeguard prevents the adjustment from being applied under weak signal conditions and is designed to preserve forecast quality rather than force an intervention when evidence is insufficient.

## Notes

- The project is designed around the weekly FluSight update cycle.
- The workflow warns if hub data appear stale relative to the expected due date.
- The repository is operational forecast code used to generate the weekly DMAPRIME-QR_E submission, not a generic R package.
