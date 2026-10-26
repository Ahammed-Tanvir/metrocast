# DMAPRIME-QR_E: weekly Flu MetroCast pipeline (R)

**Model:** median of GBQR, QRF and linear quantile regression, with no interval widening, for all
locations. For **South Carolina, North Carolina and Georgia** the forecast is corrected with the
pooled **Prisma Health + MUSC** signal.

## One-time setup

```r
install.packages(c("data.table", "jsonlite", "lightgbm", "ranger", "quantreg", "arrow", "ggplot2"))
```

1. Put this folder anywhere, for example next to your hub clone.
2. Edit `config.R`: the Prisma and MUSC paths (already set to your Box folders), team, model and threads.
3. Fork `reichlab/flu-metrocast` on GitHub. Set `hub` in `config.R` to your fork's clone, or let
   `--update` clone the main repository the first time.
4. Add `model-metadata/DMAPRIME-QR_E.yml` to the hub's `model-metadata/` folder (edit the contributor email).
   `designated_model` is `false` because DMAPRIME-ObsHYB is your designated model; change it if this
   model should replace it.

## Every Wednesday (due 8 PM ET)

1. Wait for the hub's Wednesday data update, and make sure the Prisma and MUSC files in Box contain
   last week (the week ending last Saturday).
2. Run it, either way:
   - **RStudio:** open `run_from_R.R` and click **Source**. It runs everything and opens the plots.
   - **Terminal:** from this folder, `Rscript run_weekly.R --update`
3. Read the log:
   - `Prisma: complete through ...` and `MUSC: complete through ...` mean the correction was applied.
     Any other message means SC/NC/GA used the plain median, which is safe.
   - `validation: all 19 checks passed`. If any check fails, the script stops and nothing should be submitted.
4. Look at the forecasts:
   - `data/plots/<date>-DMAPRIME-QR_E.html`: one location at a time, with a menu and the arrow keys.
   - `data/plots/<date>-DMAPRIME-QR_E.pdf`: the same, one location per page.
5. Optionally run the hub's own validator:
   ```r
   hubValidations::validate_submission(hub_path = "flu-metrocast",
     file_path = "DMAPRIME-QR/2026-10-24-DMAPRIME-QR_E.parquet")
   ```
6. Commit `model-output/DMAPRIME-QR/<date>-DMAPRIME-QR_E.parquet` to your fork and open a pull request.

Runtime is about 14 minutes on 1 core; `threads` in `config.R` shortens it.

## Files

| file | purpose |
|---|---|
| `run_from_R.R` | one-click start from RStudio (calls run_weekly.R, opens the plots) |
| `run_weekly.R` | the pipeline: update, fit, median, correction, write, validate, plot |
| `config.R` | your paths, team, model, threads |
| `metrocast_lib.R` | data loading, features, models, sample/parquet writing |
| `correction.R` | Prisma + MUSC correction with freshness and completeness checks |
| `correction_training_errors.csv` | past forecast errors for SC/NC/GA (2023-24 to 2025-26) the correction learns from |
| `validate.R` | 19 checks against `tasks.json` and the hub README |
| `plot_forecast.R` | dashboard-style plots (PDF and HTML) |
| `tests/` | correction safety tests, validator tests, past-date accuracy check |
| `model-metadata/DMAPRIME-QR_E.yml` | metadata for the hub |

## Safety rules built in

- **Correction fallback.** It is skipped for all three states if either health-system file is missing,
  doesn't contain the latest NSSP week, or the latest week has under half the previous week's tests
  (probably incomplete).
- **Stale hub data.** The script warns if the hub data don't yet include last week; re-run after the update.
- **Age-group files.** An age-group version of a health-system file is summed over age groups automatically.
- **Format.** The file follows the hub README: seven columns, no `horizon`, and sample ids S1-S100 per
  location. Each id is one trajectory across the 4 weeks, in a fixed random order per location.
