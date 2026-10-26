# =============================================================================
# Pooled Prisma Health + MUSC correction for South Carolina, North Carolina and Georgia.
#
# The two systems' weekly counts are summed into one South Carolina signal. For each of the three
# states, a median quantile regression learns how the ensemble's error (truth minus forecast median,
# on the transformed scale) depends on the signal's recent growth:
#     err ~ (2-week change in log positivity + 1-week change in log diagnoses
#            + 2-week change in log positive tests) * steps_ahead
# trained on past forecast errors (correction_training_errors.csv, 2023-24 to 2025-26, only those
# already resolved by the forecast date). The whole forecast distribution is shifted by the
# predicted error. Applied for steps ahead 1-4 only.
#
# Safety: if either file is missing, lacks the latest NSSP week, or the latest week looks incomplete
# (tests below 50% of the previous week), no correction is applied and the plain median is used.
# =============================================================================
CORR_STATES <- c("South Carolina", "North Carolina", "Georgia")
CORR_MAX_K <- 4L
MIN_TEST_RATIO <- 0.5

read_health_system <- function(path) {
  if (is.null(path) || !nzchar(path) || !file.exists(path)) return(NULL)
  d <- fread(path)
  need <- c("Week", "Weekly_Diagnoses", "Weekly_Tests", "Weekly_Positive_Tests")
  miss <- setdiff(need, names(d))
  if (length(miss)) stop(sprintf("%s is missing columns: %s", basename(path), paste(miss, collapse = ", ")))
  if ("State" %in% names(d)) d <- d[State %in% c("SC", "South Carolina")]
  d[, date := as.IDate(Week)]
  # an age-group file is summed over age groups
  d[, .(tests = sum(Weekly_Tests), pos = sum(Weekly_Positive_Tests), dx = sum(Weekly_Diagnoses)), by = date][order(date)]
}

check_health_system <- function(d, name, need_week) {
  if (is.null(d)) return(list(ok = FALSE, msg = sprintf("%s: file not found", name)))
  last <- max(d$date)
  if (last < need_week) return(list(ok = FALSE, msg = sprintf("%s: latest week %s, but the latest NSSP week is %s", name, last, need_week)))
  cur <- d[date == need_week, tests]; prev <- d[date == need_week - 7L, tests]
  if (length(cur) && length(prev) && prev > 0 && cur < MIN_TEST_RATIO * prev)
    return(list(ok = FALSE, msg = sprintf("%s: week %s looks incomplete (%d tests vs %d the week before)", name, need_week, cur, prev)))
  list(ok = TRUE, msg = sprintf("%s: complete through %s", name, last))
}

pooled_features <- function(P, M) {
  lg <- function(x) log(pmax(x, 0) + 1)
  S <- merge(P, M, by = "date")[, .(date, tests = tests.x + tests.y, pos = pos.x + pos.y, dx = dx.x + dx.y)]
  setorder(S, date)
  S[, posit := pos / pmax(tests, 1)]
  S[, `:=`(s_posit_g2 = log(posit + 0.005) - shift(log(posit + 0.005), 2L),
           s_dx_g1 = lg(dx) - shift(lg(dx)),
           s_pos_g2 = lg(pos) - shift(lg(pos), 2L))]
  S[, .(date, s_posit_g2, s_dx_g1, s_pos_g2)]
}

# Qz: delta quantiles (rows = tasks, 11 levels); tasks: location, state, k, date (last observed week)
apply_correction <- function(Qz, tasks, ref, prisma_path, musc_path, train_path = "correction_training_errors.csv") {
  status <- list(applied = FALSE, msgs = character(), info = data.table())
  need_week <- max(tasks[state %in% CORR_STATES, date])
  P <- read_health_system(prisma_path); M <- read_health_system(musc_path)
  cp <- check_health_system(P, "Prisma", need_week); cm <- check_health_system(M, "MUSC", need_week)
  status$msgs <- c(cp$msg, cm$msg)
  if (!cp$ok || !cm$ok || !file.exists(train_path)) {
    if (!file.exists(train_path)) status$msgs <- c(status$msgs, sprintf("training file %s not found", train_path))
    status$msgs <- c(status$msgs, "no correction applied: SC/NC/GA use the plain median")
    return(c(list(Q = Qz), status))
  }
  feats <- pooled_features(P, M)
  tr <- fread(train_path)[, `:=`(target_end_date = as.IDate(target_end_date), origin = as.IDate(origin))]
  tr <- merge(tr[target_end_date <= ref - 7L], feats, by.x = "origin", by.y = "date")
  tr <- tr[complete.cases(tr[, .(err, s_posit_g2, s_dx_g1, s_pos_g2)])]
  out <- Qz; info <- list()
  for (st in CORR_STATES) {
    trs <- tr[state == st]; idx <- which(tasks$state == st & tasks$k <= CORR_MAX_K)
    if (!length(idx) || nrow(trs) < 150) next
    fit <- quantreg::rq(err ~ (s_posit_g2 + s_dx_g1 + s_pos_g2) * k, tau = 0.5, data = trs)
    nd <- feats[tasks[idx, .(date, k)], on = "date"]
    shift <- as.vector(predict(fit, newdata = nd)); shift[!is.finite(shift)] <- 0
    out[idx, ] <- Qz[idx, ] + shift
    info[[st]] <- data.table(state = st, training_errors = nrow(trs), forecasts_corrected = length(idx),
                             mean_shift = round(mean(shift), 4), min_shift = round(min(shift), 4), max_shift = round(max(shift), 4))
  }
  status$applied <- length(info) > 0
  status$info <- rbindlist(info)
  c(list(Q = sort_rows(out)), status)
}
