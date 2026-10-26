# =============================================================================
# Checks a MetroCast submission against hub-config/tasks.json and model-output/README.md.
# Complements (does not replace) hubValidations::validate_submission().
#   as a script:   Rscript validate.R <file.parquet> <hub_dir>
#   as a function: validate_file(path, hub)  -> table of PASS/FAIL checks
# =============================================================================
if (!exists("TARGET")) source("metrocast_lib.R")

validate_file <- function(f, hub) {
  res <- list()
  chk <- function(name, ok, detail = "") res[[length(res) + 1]] <<- data.table(check = name, result = if (isTRUE(ok)) "PASS" else "FAIL", detail = detail)
  d <- tryCatch(read_pq(f), error = function(e) NULL)
  chk("file is a readable parquet file", !is.null(d), basename(f))
  if (is.null(d)) return(rbindlist(res))
  cfg <- fromJSON(file.path(hub, "hub-config", "tasks.json"), simplifyVector = FALSE)
  vals <- function(x) unlist(c(x$required, x$optional))
  ref <- as.character(unique(d$reference_date))
  mt <- NULL
  for (r in cfg$rounds) for (m in r$model_tasks) if (TARGET %in% vals(m$task_ids$target) && ref[1] %in% vals(m$task_ids$reference_date)) mt <- m
  fn <- basename(f); folder <- basename(dirname(f))
  chk("file name YYYY-MM-DD-team-model.parquet", grepl("^\\d{4}-\\d{2}-\\d{2}-[A-Za-z0-9_+]+-[A-Za-z0-9_+]+\\.parquet$", fn), fn)
  chk("file name date = reference_date", substr(fn, 1, 10) == ref[1], ref[1])
  chk("folder name = team-model of the file", folder == sub("^\\d{4}-\\d{2}-\\d{2}-(.*)\\.parquet$", "\\1", fn), folder)
  chk("one reference date, a Saturday, accepted by a round in tasks.json",
      length(ref) == 1 && weekdays(as.Date(ref[1])) == "Saturday" && !is.null(mt), paste(ref, collapse = ","))
  want <- c("reference_date", "target", "target_end_date", "location", "output_type", "output_type_id", "value")
  chk("exactly the 7 README columns (no horizon, no extras)", setequal(names(d), want), paste(names(d), collapse = ", "))
  chk("column types: dates, character id, numeric value",
      inherits(d$reference_date, "Date") && inherits(d$target_end_date, "Date") && is.character(d$output_type_id) && is.numeric(d$value),
      paste(sapply(d, function(x) class(x)[1]), collapse = ", "))
  locs <- fread(file.path(hub, "auxiliary-data", "locations.csv"))$location
  chk("locations exist in auxiliary-data/locations.csv", all(d$location %in% locs), sprintf("%d locations", uniqueN(d$location)))
  if (!is.null(mt)) {
    chk("target values allowed", all(d$target %in% vals(mt$task_ids$target)), paste(unique(d$target), collapse = ","))
    chk("locations allowed in this round", all(d$location %in% vals(mt$task_ids$location)), "")
    chk("target_end_date values allowed in this round", all(as.character(d$target_end_date) %in% vals(mt$task_ids$target_end_date)), "")
    sp <- mt$output_type$sample$output_type_id_params
    if (is.null(sp)) chk("round accepts sample output", FALSE, "this round's tasks.json has no sample output type")
    else chk(sprintf("sample id length <= %d", sp$max_length), max(nchar(d$output_type_id)) <= sp$max_length, sprintf("max %d", max(nchar(d$output_type_id))))
  }
  hz <- d[, .(h = sort(unique(as.integer(target_end_date - reference_date) / 7))), by = location][, .(ok = identical(h, c(0, 1, 2, 3))), by = location]
  chk("every location has horizons 0, 1, 2, 3 (target_end_date = reference_date + 0/7/14/21)", all(hz$ok), sprintf("%d of %d locations", sum(hz$ok), nrow(hz)))
  chk("output_type = sample", all(d$output_type == "sample"), "")
  n_per <- d[, .(n = uniqueN(output_type_id)), by = .(location, target_end_date)]
  chk("100 samples per location and week", all(n_per$n == 100), sprintf("min %d, max %d", min(n_per$n), max(n_per$n)))
  chk("sample ids S1-S100 in every location (README)", all(d[, setequal(unique(output_type_id), paste0("S", 1:100)), by = location]$V1), "")
  traj <- d[, .(n_weeks = uniqueN(target_end_date), n_rows = .N), by = .(location, output_type_id)]
  chk("each sample id is one trajectory across the 4 weeks", all(traj$n_weeks == 4 & traj$n_rows == 4), "")
  chk("values non-negative, finite, at most 100", all(is.finite(d$value)) && min(d$value) >= 0 && max(d$value) <= 100,
      sprintf("range %.3f to %.3f", min(d$value), max(d$value)))
  chk("no duplicate rows", !anyDuplicated(d[, .(location, target, target_end_date, output_type_id)]), "")
  rbindlist(res)
}

if (sys.nframe() == 0) {
  a <- commandArgs(trailingOnly = TRUE)
  out <- validate_file(a[1], a[2]); options(width = 200); print(out)
  cat(sprintf("\n%d of %d checks passed\n", sum(out$result == "PASS"), nrow(out)))
  if (any(out$result == "FAIL")) quit(status = 1)
}
