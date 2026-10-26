# Tests of the Prisma + MUSC correction (uses the saved internals of a run)
#   Rscript tests/test_correction.R <internal.rds> <prisma.csv> <musc.csv> [<prisma_age_group.csv>]
source("metrocast_lib.R"); source("correction.R"); source("validate.R")
a <- commandArgs(trailingOnly = TRUE); x <- readRDS(a[1]); PR <- a[2]; MU <- a[3]
tasks <- x$tasks; Q0 <- x$Qz0; ref <- max(tasks$target_end_date) - 21L
se <- tasks$state %in% CORR_STATES & tasks$k <= CORR_MAX_K
res <- list(); add <- function(test, ok, detail = "") res[[length(res) + 1]] <<- data.table(test = test, result = if (isTRUE(ok)) "PASS" else "FAIL", detail = detail)
tmp <- tempfile(fileext = ".csv")
# 1 normal case
r <- apply_correction(Q0, tasks, ref, PR, MU)
add("applied with complete Prisma and MUSC files", r$applied, paste(r$msgs, collapse = " | "))
add("only SC/NC/GA forecasts (steps 1-4) change", all(r$Q[!se, ] == Q0[!se, ]) && any(r$Q[se, ] != Q0[se, ]),
    sprintf("%d of %d forecasts changed", sum(rowSums(r$Q != Q0) > 0), nrow(Q0)))
add("corrected quantiles stay ordered", all(apply(r$Q, 1, function(v) !is.unsorted(v))), "")
add("shift is the same for every quantile of a forecast (distribution moved, not reshaped)",
    max(abs(apply(r$Q[se, ] - Q0[se, ], 1, function(v) diff(range(v))))) < 1e-9, "")
# 2 missing file
r2 <- apply_correction(Q0, tasks, ref, PR, "/no/such/file.csv")
add("missing MUSC file -> no correction, plain median kept", !r2$applied && identical(r2$Q, Q0), paste(r2$msgs, collapse = " | "))
# 3 stale file (latest week removed)
p <- fread(PR); last <- max(as.IDate(p$Week)); fwrite(p[as.IDate(Week) < last], tmp)
r3 <- apply_correction(Q0, tasks, ref, tmp, MU)
add("stale Prisma file (latest week missing) -> no correction", !r3$applied && identical(r3$Q, Q0), paste(r3$msgs, collapse = " | "))
# 4 incomplete latest week
p2 <- copy(p)[as.IDate(Week) == last, Weekly_Tests := as.integer(Weekly_Tests * 0.3)]; fwrite(p2, tmp)
r4 <- apply_correction(Q0, tasks, ref, tmp, MU)
add("incomplete latest week (tests at 30% of the week before) -> no correction", !r4$applied, paste(r4$msgs, collapse = " | "))
# 5 wrong columns
fwrite(p[, .(Week, Weekly_Diagnoses)], tmp)
e <- tryCatch({ apply_correction(Q0, tasks, ref, tmp, MU); "no error" }, error = function(e) conditionMessage(e))
add("file without the needed columns -> clear error", grepl("missing columns", e), e)
# 6 age-group version of the Prisma file is summed over age groups
if (length(a) >= 4) {
  t1 <- read_health_system(PR); t2 <- read_health_system(a[4]); j <- merge(t1, t2, by = "date")
  add("age-group file sums to the totals file (tests, positives, diagnoses)",
      all(j$tests.x == j$tests.y & j$pos.x == j$pos.y & j$dx.x == j$dx.y), sprintf("%d weeks compared; %d differ", nrow(j), sum(j$tests.x != j$tests.y | j$pos.x != j$pos.y | j$dx.x != j$dx.y)))
}
# 7 a corrected submission passes validation
S <- pmin(quantiles_to_samples(r$Q, tasks$level, tasks$p95, tasks$mu), 100)
dir.create(file.path(tempdir(), "DMAPRIME-QR"), showWarnings = FALSE)
f <- file.path(tempdir(), "DMAPRIME-QR", sprintf("%s-DMAPRIME-QR.parquet", ref)); write_pq(make_submission(tasks, S, ref), f)
v <- validate_file(f, "/home/claude/flu-metrocast")
add("corrected submission passes all validation checks", all(v$result == "PASS"), sprintf("%d of %d", sum(v$result == "PASS"), nrow(v)))
out <- rbindlist(res); options(width = 220); print(out)
cat(sprintf("\n%d of %d correction tests passed\n", sum(out$result == "PASS"), nrow(out)))
