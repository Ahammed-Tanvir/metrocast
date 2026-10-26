# =============================================================================
# Flu MetroCast weekly pipeline (DMAPRIME)
#
# Model: quantile-wise median of three global models (no interval widening)
#   GBQR (LightGBM quantile), QRF (ranger quantile forest), linear quantile regression
# trained jointly on every MetroCast location plus 300 other NSSP HSAs and all states.
# Then, for South Carolina, North Carolina and Georgia only, the pooled Prisma Health + MUSC
# correction (correction.R). Output: 100 trajectories per location, README format.
#
# Every Wednesday, after the hub's data update (submissions due 8 PM ET), from this folder:
#   Rscript run_weekly.R --update
# then open the PDF/HTML plots in data/plots/, and submit the parquet file (see README.md).
#
# Options (defaults in config.R):
#   --update                git pull the hub (clone on first use) and download the latest NSSP file
#   --reference-date D      Saturday YYYY-MM-DD (default: the coming Saturday)
#   --no-correction         skip the Prisma + MUSC correction
#   --dry-run               allow a date outside the hub's rounds (testing)
#   --out-dir DIR           default <hub>/model-output/<team>-<model>
#   --hub --data --prisma --musc --team --model --threads   override config.R
#   --no-plot
# =============================================================================
source("config.R")
source("metrocast_lib.R")
source("correction.R")
source("validate.R")
source("plot_forecast.R")

HUB_REPO <- "https://github.com/reichlab/flu-metrocast.git"
NSSP_URL <- "https://raw.githubusercontent.com/CDCgov/covid19-forecast-hub/main/auxiliary-data/nssp-raw-data/latest.parquet"
N_AUX <- 300L

opt <- function(name, default = NULL) {
  a <- commandArgs(trailingOnly = TRUE); i <- match(paste0("--", name), a)
  if (is.na(i)) default else if (i == length(a) || startsWith(a[i + 1], "--")) TRUE else a[i + 1]
}
cfg <- CONFIG
for (nm in c("hub", "data", "prisma", "musc", "team", "model", "threads")) if (!is.null(opt(nm))) cfg[[nm]] <- opt(nm)
dry <- isTRUE(opt("dry-run", FALSE)); do_update <- isTRUE(opt("update", FALSE))
do_plot <- !isTRUE(opt("no-plot", FALSE)); do_corr <- !isTRUE(opt("no-correction", FALSE))
options(metrocast.threads = as.integer(cfg$threads))
stopifnot(grepl("^[A-Za-z0-9_+]+$", cfg$team), grepl("^[A-Za-z0-9_+]+$", cfg$model))
today <- as.IDate(Sys.Date())
ref <- if (!is.null(opt("reference-date"))) as.IDate(opt("reference-date")) else today + ((7L - wday(today)) %% 7L)
stopifnot("reference date must be a Saturday" = weekdays(as.Date(ref)) == "Saturday")
t0 <- Sys.time()
step <- function(...) message(sprintf("[%4.1f min] ", as.numeric(difftime(Sys.time(), t0, units = "mins"))), ...)
hub <- cfg$hub; data_dir <- cfg$data

# ---- 1. data update
dir.create(data_dir, showWarnings = FALSE, recursive = TRUE)
nssp <- file.path(data_dir, "nssp_latest.parquet")
if (do_update) {
  if (!dir.exists(hub)) system2("git", c("clone", "--depth", "1", HUB_REPO, hub)) else system2("git", c("-C", hub, "pull", "--ff-only"))
  download.file(NSSP_URL, nssp, mode = "wb", quiet = TRUE)
  step("data updated (hub repository + NSSP all-HSA file)")
}
stopifnot("hub repository not found (run with --update)" = dir.exists(hub), "NSSP file not found (run with --update)" = file.exists(nssp))

# ---- 2. round configuration
tcfg <- fromJSON(file.path(hub, "hub-config", "tasks.json"), simplifyVector = FALSE)
vals <- function(x) unlist(c(x$required, x$optional))
rc <- NULL
for (r in tcfg$rounds) for (mt in r$model_tasks)
  if (TARGET %in% vals(mt$task_ids$target) && as.character(ref) %in% vals(mt$task_ids$reference_date)) rc <- mt
if (is.null(rc)) {
  if (!dry) stop("No round in tasks.json accepts reference_date ", ref, " (use --dry-run to test)")
  last <- tcfg$rounds[[length(tcfg$rounds)]]$model_tasks
  rc <- last[[which(sapply(last, function(mt) TARGET %in% vals(mt$task_ids$target)))[1]]]
  step("DRY RUN: reference date outside the hub's rounds")
}
round_locs <- vals(rc$task_ids$location)
step(sprintf("reference date %s (due %s); %d locations in the round", ref, ref - 3L, length(round_locs)))

# ---- 3. data available before the reference date
season_start <- as.IDate(sprintf("%d-08-01", season_of(ref)))
locs <- load_locations(hub)
latest <- load_latest(hub)[date < ref]
hub_names <- intersect(round_locs, unique(latest$location))
skipped <- setdiff(round_locs, hub_names)
if (length(skipped)) step("no target data yet (skipped): ", paste(skipped, collapse = ", "))
latest <- latest[location %in% hub_names]
if (max(latest$date) < ref - 7L)
  warning(sprintf("Hub data end %s, but data for the week ending %s should be out by the due date. Run again after the Wednesday update.",
                  max(latest$date), ref - 7L), call. = FALSE)
aux <- load_aux(nssp, locs)
set.seed(2024)
keep <- sample(unique(aux[is_state == 0, location]), min(N_AUX, uniqueN(aux[is_state == 0, location])))
aux <- aux[(is_state == 1 | location %in% keep) & date < season_start]
step(sprintf("hub data through %s (%d locations); %d other NSSP series", max(latest$date), length(hub_names), uniqueN(aux$location)))

# ---- 4. features, training rows, the three models
st_hub <- transform_stats(latest, season_start); st_aux <- transform_stats(aux, season_start)
meta <- make_meta(locs, hub_names, latest, aux, st_hub, st_aux, season_start)
hub_panel <- build_panel(latest, st_hub, meta$hub)
full <- add_state_context(rbind(hub_panel, build_panel(aux, st_aux, meta$aux), fill = TRUE))
cols <- feature_cols(full)
tr <- make_training_rows(full, max(latest$date))
step(sprintf("training rows: %s from %d series", format(nrow(tr), big.mark = ","), uniqueN(tr$location)))
fits <- list()
fits$gbqr <- fit_gbqr(tr, cols); step("GBQR fitted")
fits$qrf  <- fit_qrf(tr, cols);  step("QRF fitted")
fits$lqr  <- fit_lqr(tr);        step("linear QR fitted")

# ---- 5. forecasts: median of the three, then the Prisma + MUSC correction for SC, NC, GA
tasks <- make_tasks(add_state_context(hub_panel), ref)
stale <- unique(tasks[as.integer(ref - date) > 14L, location])
if (length(stale)) step("note: latest data more than 2 weeks old for: ", paste(stale, collapse = ", "))
P <- predict_all(fits, tasks, cols)
Qz0 <- sort_rows(med3(P$gbqr, P$qrf, P$lqr))
corr <- list(applied = FALSE, msgs = "correction switched off (--no-correction)", info = data.table())
Qz <- Qz0
if (do_corr) { corr <- apply_correction(Qz0, tasks, ref, cfg$prisma, cfg$musc, "correction_training_errors.csv"); Qz <- corr$Q }
for (m in corr$msgs) step(m)
if (corr$applied) { step("Prisma + MUSC correction applied:"); print(corr$info) }
S <- pmin(quantiles_to_samples(Qz, tasks$level, tasks$p95, tasks$mu), 100)
out <- make_submission(tasks, S, ref)

# ---- 6. write, validate, plot, diagnostics
tm <- paste0(cfg$team, "-", cfg$model)
out_dir <- opt("out-dir", file.path(hub, "model-output", tm))
dir.create(out_dir, showWarnings = FALSE, recursive = TRUE)
path <- file.path(out_dir, sprintf("%s-%s.parquet", ref, tm))
write_pq(out, path)
step(sprintf("wrote %s: %s rows, %d locations", path, format(nrow(out), big.mark = ","), uniqueN(out$location)))
v <- validate_file(path, hub)
options(width = 200); print(v[, .(check, result, detail)])
if (any(v$result == "FAIL")) {
  if (dry) step("dry run: failed round checks are expected for dates outside the 2026-27 round") else stop("validation failed: do not submit; fix first")
} else step(sprintf("validation: all %d checks passed", nrow(v)))
diag_dir <- file.path(data_dir, "diagnostics"); dir.create(diag_dir, showWarnings = FALSE, recursive = TRUE)
yq <- function(M) from_z(tasks$level + M[, c(2, 5, 6, 7, 10)], tasks$p95, tasks$mu)
dq <- cbind(tasks[, .(location, state, target_end_date, k)], setnames(as.data.table(yq(Qz0)), paste0("median_only_", c("q025", "q25", "q50", "q75", "q975"))),
            setnames(as.data.table(yq(Qz)), paste0("submitted_", c("q025", "q25", "q50", "q75", "q975"))))
fwrite(dq, file.path(diag_dir, sprintf("%s-%s_quantiles.csv", ref, tm)))
saveRDS(list(tasks = tasks, Qz0 = Qz0, Qz = Qz, corr = corr), file.path(diag_dir, sprintf("%s-%s_internal.rds", ref, tm)))
if (do_plot) {
  prefix <- file.path(data_dir, "plots", sprintf("%s-%s", ref, tm))
  invisible(plot_submission(path, hub, prefix))
  step(sprintf("plots: %s.pdf and %s.html", prefix, prefix))
}
if (dry) step("dry run complete: this file is for testing only, do not submit") else
  step(sprintf("done. Submit %s (pull request to reichlab/flu-metrocast, model-output/%s/).", basename(path), tm))
