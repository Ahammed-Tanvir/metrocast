# The validator must catch broken files. Each corrupted copy of a valid file must FAIL.
#   Rscript tests/test_validator.R <valid.parquet> <hub_dir>
source("metrocast_lib.R"); source("validate.R")
a <- commandArgs(trailingOnly = TRUE); good <- read_pq(a[1]); hub <- a[2]
ref <- as.character(unique(good$reference_date)); fn <- basename(a[1])
dirp <- file.path(tempdir(), "DMAPRIME-QR"); dir.create(dirp, showWarnings = FALSE)
try_case <- function(name, d, file = fn, folder = dirp) {
  f <- file.path(folder, file); write_pq(d, f); v <- validate_file(f, hub); unlink(f)
  data.table(case = name, caught = any(v$result == "FAIL"), failed_checks = paste(v[result == "FAIL", check], collapse = "; "))
}
g <- copy(good)
cases <- rbindlist(list(
  try_case("valid file (should pass)", g),
  try_case("extra horizon column", copy(g)[, horizon := as.integer((target_end_date - reference_date) / 7)]),
  try_case("numeric sample ids 1-100", copy(g)[, output_type_id := sub("^S", "", output_type_id)]),
  try_case("a duplicated row", rbind(g, g[1])),
  try_case("a negative value", copy(g)[1, value := -0.1]),
  try_case("horizon 3 missing for one location", g[!(location == location[1] & target_end_date == max(target_end_date))]),
  try_case("99 samples for one location-week", g[!(location == location[1] & output_type_id == "S100" & target_end_date == min(target_end_date))]),
  try_case("unknown location", copy(g)[location == location[1], location := "atlantis"]),
  try_case("file name date differs from reference_date", g, file = sub("^\\d{4}-\\d{2}-\\d{2}", "2026-10-31", fn)),
  try_case("file in a folder with another model name", g, folder = { p <- file.path(tempdir(), "DMAPRIME-Other"); dir.create(p, showWarnings = FALSE); p })))
cases[, result := fifelse(case == "valid file (should pass)", fifelse(!caught, "PASS", "FAIL"), fifelse(caught, "PASS", "FAIL"))]
options(width = 220); print(cases[, .(case, result, failed_checks)])
cat(sprintf("\n%d of %d validator tests passed\n", sum(cases$result == "PASS"), nrow(cases)))
