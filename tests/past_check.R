# Score a dry run for a past date against what happened: submitted (with correction) vs median only
#   Rscript tests/past_check.R <internal.rds> <hub_dir>
source("metrocast_lib.R"); source("correction.R")
a <- commandArgs(trailingOnly = TRUE); x <- readRDS(a[1]); t <- copy(x$tasks)
t[load_latest(a[2]), on = .(location, target_end_date = date), truth := i.y]; ok <- !is.na(t$truth)
w <- function(M) wis_from_q(from_z(t$level[ok] + sort_rows(M[ok, ])[, 2:10], t$p95[ok], t$mu[ok]), t$truth[ok])
Y <- from_z(t$level[ok] + sort_rows(x$Qz[ok, ])[, 2:10], t$p95[ok], t$mu[ok])
r <- data.table(t[ok, .(location, state, horizon)], wis_median = w(x$Qz0), wis_submitted = w(x$Qz),
                cov95 = t$truth[ok] >= Y[, 1] & t$truth[ok] <= Y[, 9], cov50 = t$truth[ok] >= Y[, 4] & t$truth[ok] <= Y[, 6])
r[, flat := wis_from_q(from_z(t$level[ok] + matrix(0, sum(ok), 9), t$p95[ok], t$mu[ok]), t$truth[ok])]   # persistence point forecast as a rough reference
cat(sprintf("reference date %s: %d forecasts scored (%d locations)\n", max(t$target_end_date) - 21L, nrow(r), uniqueN(r$location)))
print(r[, .(n = .N, wis_median_only = round(mean(wis_median), 3), wis_submitted = round(mean(wis_submitted), 3),
            ratio = round(mean(wis_submitted) / mean(wis_median), 3), cov50 = round(mean(cov50), 2), cov95 = round(mean(cov95), 2)),
        by = .(group = fifelse(state %in% CORR_STATES, "SC/NC/GA (corrected)", "other states"))])
print(r[, .(wis_submitted = round(mean(wis_submitted), 3), cov95 = round(mean(cov95), 2)), by = horizon][order(horizon)])
