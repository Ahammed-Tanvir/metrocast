# DMAPRIME-QR_E: weekly Flu MetroCast generation workflow (R)

This repository produces the weekly Flu MetroCast forecast for the `DMAPRIME-QR_E` model. The pipeline trains three quantile models and combines them by median: GBQR, quantile random forest, and linear quantile regression. For South Carolina, North Carolina, and Georgia, it then applies a Prisma Health + MUSC correction to improve the forecast when the local health-system signal is fresh and complete.

The procedure below reflects how the code is actually executed in this project.

## 1. Configure the run

Edit `config.R` once for your local environment:

```r
CONFIG <- list(
  hub = "flu-metrocast",
  data = "data",
  prisma = "/path/to/Prisma_Health_Weekly_Influenza_State_dx_...csv",
  musc = "/path/to/MUSC_Weekly_Influenza_State_dx_cond_lab_Incident.csv",
  team = "DMAPRIME",
  model = "QR_E",
  threads = 4L
)
```

Key points from the code:

- `hub` is the local clone of `reichlab/flu-metrocast`.
- `data` is the working data directory used for NSSP downloads and generated artifacts.
- `prisma` and `musc` point to the weekly state-level health-system files used for the correction layer.
- `team` and `model` define the output file naming convention.

The command-line options in `run_weekly.R` can override these values at runtime, for example:

```bash
Rscript run_weekly.R --update --threads 6
```

## 2. Run the weekly workflow

The project is designed to be run from the repository root. The standard weekly execution path is:

```bash
Rscript run_weekly.R --update
```

This launches the full workflow defined in `run_weekly.R`:

1. It ensures the local `data/` directory exists.
2. If `--update` is set, it checks out or updates the hub repository and downloads the latest NSSP parquet data from the CDC-hosted file.
3. It reads the hub's `hub-config/tasks.json` to identify the active round based on the reference Saturday.
4. It loads the latest hub data and auxiliary NSSP series needed for model training.
5. It builds the training panel and fits:
   - GBQR
   - QRF
   - Linear quantile regression
6. It predicts the next submission period and combines the three models by the median.
7. For SC, NC, and GA, it applies the Prisma + MUSC correction from `correction.R` when the signal is deemed usable.
8. It converts the quantiles to submission samples and writes the parquet output.
9. It validates the file against the hub requirements.
10. It generates plots and diagnostics in `data/plots/` and `data/diagnostics/`.

You can also run the project from RStudio by sourcing `run_from_R.R`.

## 3. How the reference date is selected

The pipeline selects the reference date as the upcoming Saturday by default:

```r
ref <- if (!is.null(opt("reference-date"))) as.IDate(opt("reference-date")) else today + ((7L - wday(today)) %% 7L)
```

This means the run targets the next valid Saturday submission date unless you override it explicitly with `--reference-date`.

## 4. Data and model preparation

The workflow loads hub data and other relevant time series before fitting. The main steps are:

- `load_locations(hub)` loads hub locations.
- `load_latest(hub)` reads the latest available forecast data in the hub repository.
- `load_aux(nssp, locs)` loads the auxiliary NSSP series.
- `transform_stats()` and `make_meta()` prepare the model features.
- `fit_gbqr()`, `fit_qrf()`, and `fit_lqr()` fit the component models.

The model then predicts the target horizon, merges the quantile outputs, and prepares the final submission object.

## 5. Correction step for SC, NC, and GA

The correction layer is defined in `correction.R`. It is only used when `--no-correction` is not set and the location is in the correction states.

Before applying the correction, the code checks whether:

- the Prisma Health file is present,
- the MUSC file is present,
- the latest NSSP week appears in both files,
- the most recent week has enough data to be considered complete,
- the signal is not stale or too incomplete to use.

If any check fails, the correction is skipped and the system falls back to the median-only forecast. The code is intentionally conservative: the fallback is safer than forcing a bad correction.

## 6. Validation and output files

After forecasting, the script writes a parquet submission file to the hub output directory:

```text
flu-metrocast/model-output/DMAPRIME-QR/<reference-date>-DMAPRIME-QR_E.parquet
```

It then runs `validate.R` checks, and if everything passes it prints:

```text
validation: all <n> checks passed
```

The script also writes:

- `data/plots/<reference-date>-DMAPRIME-QR_E.pdf`
- `data/plots/<reference-date>-DMAPRIME-QR_E.html`
- `data/diagnostics/<reference-date>-DMAPRIME-QR_E_quantiles.csv`
- `data/diagnostics/<reference-date>-DMAPRIME-QR_E_internal.rds`

## 7. Submission procedure

The code ends with a clear submission instruction:

1. Inspect the generated forecast plots.
2. Confirm validation has passed.
3. Commit the parquet file to your fork of `reichlab/flu-metrocast`.
4. Open a pull request to the model-output directory for the appropriate team-model.

If you run from RStudio using `run_from_R.R`, the script will also open the newest HTML plot automatically when the run is complete.

## 8. Files in this repository

- `run_weekly.R` — main execution script for the full pipeline
- `run_from_R.R` — convenience runner for RStudio / plain R
- `config.R` — local configuration values
- `metrocast_lib.R` — helper functions, feature prep, model fitting, and output generation
- `correction.R` — Prisma + MUSC correction logic
- `validate.R` — hub validation checks
- `plot_forecast.R` — PDF and HTML plotting
- `model-metadata/DMAPRIME-QR_E.yml` — metadata for the hub submission
- `tests/` — validation and safety checks

## 9. Operating rhythm

The repository is built around a recurring weekly cadence. The workflow assumes the hub has updated its data on Wednesday, and the run is done after the latest information is available. The script warns if the hub data appear stale relative to the expected deadline.

This is not a generic package and not just a setup guide. It is the actual operating procedure for producing and validating the weekly forecast submission.
