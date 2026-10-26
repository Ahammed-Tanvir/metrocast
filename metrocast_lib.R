# =============================================================================
# Flu MetroCast: shared functions (data, features, models, scoring)
# Packages: data.table, jsonlite, lightgbm, ranger, quantreg, arrow (or nanoparquet)
# Threads: options(metrocast.threads = n) before fitting (default 1)
# =============================================================================
suppressPackageStartupMessages({
  library(data.table)
  library(jsonlite)
})

`%||%` <- function(a, b) if (is.null(a)) b else a
TARGET <- "Flu ED visits pct"
QL     <- c(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.975, 0.99)  # levels each model fits
QL9    <- c(0.025, 0.05, 0.1, 0.25, 0.5, 0.75, 0.9, 0.95, 0.975)               # levels used for WIS
QCOLS  <- paste0("q", seq_along(QL))
NS     <- 100                                    # samples per location (hub requirement)
U      <- (seq_len(NS) - 0.5) / NS               # quantile level of each sample (shared across horizons)
MAX_K  <- 5                                      # steps from last observed week (horizon 0-3 + 1 week lag slack)
DROP_SEASONS <- c(2008L, 2009L, 2020L, 2021L)    # H1N1 pandemic and COVID-disrupted seasons

# ---------------------------------------------------------------- I/O helpers
read_pq <- function(path) {
  if (requireNamespace("arrow", quietly = TRUE)) return(as.data.table(arrow::read_parquet(path)))
  as.data.table(nanoparquet::read_parquet(path))
}
write_pq <- function(df, path) {
  if (requireNamespace("arrow", quietly = TRUE)) return(arrow::write_parquet(df, path))
  nanoparquet::write_parquet(as.data.frame(df), path)
}

# ---------------------------------------------------------------- data
load_locations <- function(hub) {
  l <- fread(file.path(hub, "auxiliary-data", "locations.csv"),
             colClasses = list(character = "original_location_code"))
  l[, population := as.numeric(gsub(",", "", population))]
  l[, is_state := as.integer(original_location_code == "All")]
  l[]
}

load_latest <- function(hub) {
  d <- fread(file.path(hub, "target-data", "latest-data.csv"))
  d[target == TARGET, .(location, date = as.IDate(target_end_date), y = as.numeric(observation))]
}

load_vintages <- function(hub) {
  d <- fread(file.path(hub, "target-data", "time-series.csv"))
  d[target == TARGET, .(as_of = as.IDate(as_of), location, date = as.IDate(target_end_date),
                        y = as.numeric(observation))]
}

# Data as available on `asof`: per location the newest vintage released by then; older weeks
# (before that vintage's coverage) from latest-data; no vintage -> latest-data cut 4 days before.
snapshot <- function(asof, latest, vint) {
  asof <- as.IDate(asof)
  v <- vint[as_of <= asof]
  if (nrow(v) == 0) return(latest[date <= asof - 4L][order(location, date)])
  v[, use := max(as_of), by = location]
  v <- v[as_of == use, .(location, date, y)]
  vmin <- v[, .(vmin = min(date)), by = location]
  old <- merge(latest, vmin, by = "location", all.x = TRUE)
  old <- old[(is.na(vmin) & date <= asof - 4L) | (!is.na(vmin) & date < vmin), .(location, date, y)]
  rbind(old, v)[order(location, date)]
}

# Flu % ED visits for every other NSSP HSA and state (not already a hub location)
load_aux <- function(nssp_path, locs) {
  d <- read_pq(nssp_path)
  d <- d[trend_source %in% c("HSA", "State"),
         .(date = as.IDate(week_end), geography, hsa = as.character(hsa_nci_id), trend_source,
           y = as.numeric(percent_visits_influenza))]
  d[, location := ifelse(trend_source == "State", paste0("state:", geography), paste0("hsa:", hsa))]
  d <- unique(d, by = c("location", "date"))
  hub_keys <- c(paste0("hsa:", locs[location_type == "hsa_nci_id" & is_state == 0, original_location_code]),
                paste0("state:", locs[is_state == 1, state]))
  d <- d[!location %in% hub_keys & !is.na(y)]
  d[, .(location, date, y, is_state = as.integer(trend_source == "State"), state = geography)]
}

# ---------------------------------------------------------------- calendar
season_of   <- function(d) { d <- as.IDate(d); ifelse(month(d) >= 8L, year(d), year(d) - 1L) }
season_week <- function(d) {
  d <- as.IDate(d)
  as.integer(d - as.IDate(sprintf("%d-08-01", season_of(d)))) %/% 7L + 1L
}
weeks_from_xmas <- function(d) {
  d <- as.IDate(d)
  x <- as.IDate(sprintf("%d-12-25", season_of(d)))
  xs <- x + (7L - wday(x))                     # Saturday ending Christmas week
  as.integer(d - xs) %/% 7L
}

# ---------------------------------------------------------------- transform (Flusion)
# z = y^(1/4), scaled by the location's 95th percentile and centred on its mean.
transform_stats <- function(df, cutoff) {
  d <- df[date < as.IDate(cutoff) & !is.na(y)]
  d[, z := pmax(y, 0)^0.25]
  s <- d[, .(p95 = max(quantile(z, 0.95), 0.3)), by = location]
  d <- merge(d, s, by = "location")
  merge(s, d[, .(mu = mean(z / p95)), by = location], by = "location")
}
to_z   <- function(y, p95, mu) pmax(y, 0)^0.25 / p95 - mu
from_z <- function(z, p95, mu) pmax((z + mu) * p95, 0)^4

noise_proxy <- function(df, stats, cutoff) {      # typical weekly change: stand-in for population
  d <- merge(df[date < as.IDate(cutoff)], stats, by = "location")
  setorder(d, location, date)
  d[, z := to_z(y, p95, mu)]
  d[, dz := z - shift(z), by = location]
  d[, .(noise = median(abs(dz), na.rm = TRUE)), by = location]
}

# ---------------------------------------------------------------- features
TAYLOR <- list(c(2, 4), c(2, 6), c(1, 3), c(1, 5))   # (degree, window)
taylor_proj <- function(deg, w) {
  u <- seq(-(w - 1), 0)
  X <- sapply(0:deg, function(c) u^c / factorial(c))
  solve(crossprod(X), t(X))                         # (deg+1) x w
}

build_panel <- function(df, stats, meta) {
  d <- df[location %in% stats$location, .(location, date, y)]
  d <- unique(d, by = c("location", "date"), fromLast = TRUE)
  grid <- d[, .(date = as.IDate(seq(as.Date(min(date)), as.Date(max(date)), by = 7))), by = location]
  d <- merge(grid, d, by = c("location", "date"), all.x = TRUE)
  d <- merge(d, stats, by = "location")
  setorder(d, location, date)
  d[, z := to_z(y, p95, mu)]
  d[, level := z]
  base <- "level"
  for (tp in TAYLOR) {
    deg <- tp[1]; w <- tp[2]; P <- taylor_proj(deg, w)
    for (c in 0:deg) {
      nm <- sprintf("tp_d%d_w%d_c%d", deg, w, c)
      d[, (nm) := Reduce(`+`, lapply(seq_len(w), function(j) P[c + 1, j] * shift(z, w - j))), by = location]
      base <- c(base, nm)
    }
  }
  d[, rm_w2 := frollmean(z, 2), by = location]
  d[, rm_w4 := frollmean(z, 4), by = location]
  base <- c(base, "rm_w2", "rm_w4")
  for (L in 1:2) for (b in base) d[, (paste0(b, "_lag", L)) := shift(get(b), L), by = location]
  d[, `:=`(season = season_of(date), season_week = season_week(date), wk_xmas = weeks_from_xmas(date))]
  merge(d, meta, by = "location", all.x = TRUE)
}

# Contemporaneous level/slope of the location's state (released at the same time as the HSA data)
add_state_context <- function(panel) {
  st <- panel[is_state == 1, .(state, date, st_level = level, st_slope3 = tp_d1_w3_c1, st_slope4 = tp_d2_w4_c1)]
  st <- unique(st, by = c("state", "date"))
  merge(panel, st, by = c("state", "date"), all.x = TRUE)
}

feature_cols <- function(panel) {
  base <- grep("^(level|tp_|rm_)", names(panel), value = TRUE)
  c(base, "season_week", "wk_xmas", "log_pop", "noise", "is_state", "src_nc", "src_nyc", "k",
    "st_level", "st_slope3", "st_slope4")
}
# compact set for the linear quantile model
LQR_COLS <- c("level", "tp_d2_w4_c1", "tp_d2_w4_c2", "tp_d2_w6_c1", "tp_d2_w6_c2",   # <= 6 lag combos (no collinearity)
              "st_slope3", "noise", "sin1", "cos1")

add_fourier <- function(d) {   # season timing of the TARGET week
  a <- 2 * pi * (d$season_week + d$k) / 52
  d[, `:=`(sin1 = sin(a), cos1 = cos(a))]
}

make_training_rows <- function(panel, max_date, ks = 1:MAX_K, sw = c(6L, 46L)) {
  p <- panel[date <= max_date & season_week >= sw[1] & season_week <= sw[2] & !season %in% DROP_SEASONS &
               !is.na(level) & !is.na(tp_d2_w6_c0)]
  zl <- panel[, .(location, tdate = date, z_target = z)]
  r <- rbindlist(lapply(ks, function(k) { x <- copy(p); x[, `:=`(k = k, tdate = date + 7L * k)]; x }))
  r <- r[tdate <= max_date]
  r <- merge(r, zl, by = c("location", "tdate"))[!is.na(z_target)]
  r[, delta := z_target - level]
  add_fourier(r)
  r[]
}

# ---------------------------------------------------------------- models (all predict delta quantiles)
fit_gbqr <- function(tr, cols, nrounds = 250, seed = 1) {
  ds <- lightgbm::lgb.Dataset(as.matrix(tr[, ..cols]), label = tr$delta, free_raw_data = FALSE)
  lapply(QL, function(q) lightgbm::lgb.train(
    params = list(objective = "quantile", alpha = q, learning_rate = 0.05, num_leaves = 31,
                  min_data_in_leaf = 40, bagging_fraction = 0.7, bagging_freq = 1,
                  feature_fraction = 0.8, verbose = -1, num_threads = getOption("metrocast.threads", 1L), seed = seed),
    data = ds, nrounds = nrounds))
}
pred_gbqr <- function(models, X) matrix(sapply(models, function(m) predict(m, X)), nrow = nrow(X))

impute <- function(X, fill = -99) { X[is.na(X)] <- fill; X }

fit_qrf <- function(tr, cols, n_max = 150000, seed = 1) {
  set.seed(seed)
  tr <- if (nrow(tr) > n_max) tr[sample(.N, n_max)] else tr
  X <- impute(as.data.frame(tr[, ..cols]))
  ranger::ranger(x = X, y = tr$delta, num.trees = 300, min.node.size = 20, mtry = 12,
                 sample.fraction = 0.5, quantreg = TRUE, num.threads = getOption("metrocast.threads", 1L), seed = seed)
}
pred_qrf <- function(m, X) {
  set.seed(7)
  predict(m, data = impute(as.data.frame(X)), type = "quantiles", quantiles = QL)$predictions
}

# linear quantile regression per step k (quantile regression averaging family, GEFCom2014)
fit_lqr <- function(tr, n_max = 60000, seed = 1) {
  set.seed(seed)
  lapply(seq_len(MAX_K), function(kk) {
    d <- tr[k == kk]
    if (nrow(d) > n_max) d <- d[sample(.N, n_max)]
    X <- cbind(1, impute(as.matrix(d[, ..LQR_COLS]), 0))
    sapply(QL, function(q) quantreg::rq.fit(X, d$delta, tau = q, method = "fn")$coefficients)
  })
}
pred_lqr <- function(models, X, k) {
  Xm <- cbind(1, impute(as.matrix(X[, ..LQR_COLS]), 0))
  out <- matrix(NA_real_, nrow(Xm), length(QL))
  for (kk in unique(k)) { i <- which(k == kk); out[i, ] <- Xm[i, , drop = FALSE] %*% models[[kk]] }
  out
}

# flat baseline: empirical quantiles of past k-step changes (pooled over locations)
fit_base <- function(tr) {
  t(sapply(seq_len(MAX_K), function(kk) {
    dl <- tr[k == kk, delta]
    quantile(c(dl, -dl), QL, names = FALSE)              # symmetrised, median 0 = persistence
  }))
}
pred_base <- function(B, k) B[k, , drop = FALSE]

sort_rows <- function(Q) t(apply(Q, 1, sort))
med3 <- function(a, b, c) pmax(pmin(a, b), pmin(pmax(a, b), c))   # element-wise median of three

# ---------------------------------------------------------------- post-processing
# widen spread around the median by factor c (transformed scale)
widen_q <- function(Q, c) { med <- Q[, 6]; med + c * (Q - med) }

# delta quantiles -> trajectories on the original scale (same U for every horizon of a location)
quantiles_to_samples <- function(Q, level, p95, mu) {
  S <- t(apply(Q, 1, function(q) approx(QL, q, xout = U, rule = 2)$y))
  from_z(level + S, p95, mu)
}

# ---------------------------------------------------------------- scoring
wis_from_q <- function(Qy, y) {    # Qy: n x 9 quantiles (QL9) on original scale
  Qy <- sort_rows(Qy)
  yy <- matrix(y, nrow(Qy), ncol(Qy))
  L <- matrix(QL9, nrow(Qy), ncol(Qy), byrow = TRUE)
  2 * rowMeans(ifelse(yy >= Qy, L * (yy - Qy), (1 - L) * (Qy - yy)))
}

# ---------------------------------------------------------------- pipeline helpers (backtest + weekly)
make_meta <- function(locs, hub_names, hub_df, aux_df, st_hub, st_aux, cutoff) {
  m <- locs[match(hub_names, location)]
  mh <- data.table(location = hub_names, log_pop = log10(m$population),
                   is_state = fifelse(is.na(m$is_state), 0L, m$is_state),
                   src_nc = as.integer(m$location_type %in% "nc_flu_region_id"),
                   src_nyc = as.integer(hub_names == "nyc"), state = m$state)
  mh <- merge(mh, noise_proxy(hub_df, st_hub, cutoff), by = "location", all.x = TRUE)
  ma <- unique(aux_df[, .(location, is_state, state)], by = "location")
  ma[, `:=`(log_pop = NA_real_, src_nc = 0L, src_nyc = 0L)]
  ma <- merge(ma, noise_proxy(aux_df, st_aux, cutoff), by = "location", all.x = TRUE)
  list(hub = mh, aux = ma)
}

make_tasks <- function(hub_panel, ref_date) {
  last <- hub_panel[!is.na(level) & !is.na(tp_d2_w6_c0)][, .SD[which.max(date)], by = location]
  tasks <- rbindlist(lapply(0:3, function(h) copy(last)[, `:=`(horizon = h, target_end_date = ref_date + 7L * h)]))
  tasks[, k := as.integer(target_end_date - date) %/% 7L]
  tasks[k > MAX_K, k := MAX_K]          # stale series: reuse the longest step model
  tasks <- tasks[k >= 1L]
  add_fourier(tasks)
  setorder(tasks, location, horizon)
  tasks[]
}

fit_all <- function(tr, cols, which = c("gbqr", "qrf", "lqr", "base")) {
  f <- list()
  if ("gbqr" %in% which) f$gbqr <- fit_gbqr(tr, cols)
  if ("qrf"  %in% which) f$qrf  <- fit_qrf(tr, cols)
  if ("lqr"  %in% which) f$lqr  <- fit_lqr(tr)
  if ("base" %in% which) f$base <- fit_base(tr)
  f
}

predict_all <- function(fits, tasks, cols) {
  P <- list()
  if (!is.null(fits$gbqr)) P$gbqr <- sort_rows(pred_gbqr(fits$gbqr, as.matrix(tasks[, ..cols])))
  if (!is.null(fits$qrf))  P$qrf  <- sort_rows(pred_qrf(fits$qrf, tasks[, ..cols]))
  if (!is.null(fits$lqr))  P$lqr  <- sort_rows(pred_lqr(fits$lqr, tasks, tasks$k))
  if (!is.null(fits$base)) P$base <- pred_base(fits$base, tasks$k)
  P
}

# ---------------------------------------------------------------- submission file (hub README, 2026-27)
# Columns: reference_date, target, target_end_date, location, output_type, output_type_id, value
# (no horizon column). output_type_id = "S1".."S100". Within a location, each id is one trajectory
# across the four weeks. Ids are shared across locations as the README asks; to avoid claiming
# perfect correlation between locations, each location's trajectories are put in a fixed random order
# (independent across locations), which leaves every location's forecast unchanged.
make_submission <- function(tasks, S, ref) {
  ord <- tasks[, .(location, horizon, target_end_date)]
  perm <- lapply(split(seq_len(nrow(ord)), ord$location), function(i) {
    set.seed(sum(utf8ToInt(ord$location[i[1]])) + as.integer(ref)); sample.int(NS)
  })
  rows <- rbindlist(lapply(names(perm), function(loc) {
    i <- which(ord$location == loc); p <- perm[[loc]]
    data.table(location = loc, target_end_date = rep(ord$target_end_date[i], each = NS),
               output_type_id = rep(paste0("S", p), times = length(i)),
               value = as.vector(t(S[i, , drop = FALSE])))
  }))
  rows[, `:=`(reference_date = as.Date(ref), target = TARGET, output_type = "sample", target_end_date = as.Date(target_end_date))]
  setcolorder(rows, c("reference_date", "target", "target_end_date", "location", "output_type", "output_type_id", "value"))
  rows[]
}
