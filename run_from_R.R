# =============================================================================
# Run the weekly MetroCast pipeline from R or RStudio.
#
#   In RStudio: open this file and click "Source" (top right of the editor).
#   In plain R: source("~/Documents/DMAPRIME-QR_pipeline/run_from_R.R")   (use your folder)
#
# It runs run_weekly.R, prints its messages here, and opens the forecast plots when it is done.
# =============================================================================
UPDATE_DATA    <- TRUE    # pull the hub and download the latest NSSP file first
REFERENCE_DATE <- NULL    # NULL = the coming Saturday; or a Saturday such as "2026-10-24"
USE_CORRECTION <- TRUE    # Prisma + MUSC correction for SC, NC and GA

# -----------------------------------------------------------------------------
here <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)), error = function(e) getwd())
if (!file.exists(file.path(here, "run_weekly.R")))
  stop("Can't find run_weekly.R. Use Session > Set Working Directory > Choose Directory and pick the DMAPRIME-QR_pipeline folder, then run again.")
old <- setwd(here); on.exit(setwd(old), add = TRUE)

args <- "run_weekly.R"
if (UPDATE_DATA) args <- c(args, "--update")
if (!is.null(REFERENCE_DATE)) args <- c(args, "--reference-date", REFERENCE_DATE)
if (!USE_CORRECTION) args <- c(args, "--no-correction")

message("Running the pipeline in ", here, " (about 5-15 minutes) ...")
status <- system2(file.path(R.home("bin"), "Rscript"), args)
if (status != 0) stop("The pipeline stopped with an error. Read the messages above. Do not submit.")

plots <- list.files("data/plots", pattern = "\\.html$", full.names = TRUE)
if (length(plots)) {
  newest <- plots[which.max(file.mtime(plots))]
  message("Opening the forecast plots: ", newest)
  browseURL(normalizePath(newest))
}
subs <- list.files(list.files("flu-metrocast/model-output", pattern = "^DMAPRIME", full.names = TRUE), pattern = "\\.parquet$", full.names = TRUE)
if (length(subs)) message("Submission file: ", normalizePath(subs[which.max(file.mtime(subs))]))
