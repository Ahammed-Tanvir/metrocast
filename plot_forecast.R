# =============================================================================
# Forecast plots in the style of the MetroCast dashboard: observed data (black), forecast median
# (orange) with 50% and 95% intervals, vertical line at the forecast due date.
#   plot_submission(file, hub, out_prefix)  ->  <out_prefix>.pdf (one page per location)
#                                               <out_prefix>.html (viewer with a location menu)
#   as a script: Rscript plot_forecast.R <file.parquet> <hub_dir> <out_prefix>
# =============================================================================
if (!exists("TARGET")) source("metrocast_lib.R")
suppressPackageStartupMessages(library(ggplot2))

forecast_plot <- function(obs, q, title, due, model_id, base_size = 13) {
  cols <- setNames(c("#222222", "#EE8A3C"), c("Observed", model_id))
  ggplot() +
    geom_ribbon(data = q, aes(as.Date(target_end_date), ymin = q025, ymax = q975), fill = "#F7C9A4", alpha = 0.75) +
    geom_ribbon(data = q, aes(as.Date(target_end_date), ymin = q25, ymax = q75), fill = "#F2A66B", alpha = 0.55) +
    geom_vline(xintercept = as.Date(due), colour = "grey55", linewidth = 0.6) +
    geom_line(data = obs, aes(as.Date(date), y, colour = "Observed"), linewidth = 1.1) +
    geom_point(data = obs, aes(as.Date(date), y, colour = "Observed"), size = 1.8) +
    geom_line(data = q, aes(as.Date(target_end_date), q50, colour = model_id), linewidth = 1.1) +
    geom_point(data = q, aes(as.Date(target_end_date), q50, colour = model_id), size = 2.4) +
    scale_colour_manual(values = cols, breaks = names(cols)) +
    scale_x_date(date_breaks = "2 weeks", date_labels = "%b %d") +
    scale_y_continuous(limits = c(0, NA), expand = expansion(mult = c(0, 0.05))) +
    labs(title = title, subtitle = "Median, 50% and 95% prediction intervals; vertical line = forecast due date",
         x = NULL, y = "% of ED visits due to influenza", colour = NULL) +
    theme_minimal(base_size = base_size) +
    theme(legend.position = c(0.02, 0.98), legend.justification = c(0, 1), legend.background = element_rect(fill = "white", colour = NA),
          panel.grid.minor = element_blank(), axis.line = element_line(colour = "grey40"))
}

plot_submission <- function(f, hub, out_prefix, weeks_back = 12) {
  d <- read_pq(f)[, target_end_date := as.IDate(target_end_date)]
  model_id <- sub("^\\d{4}-\\d{2}-\\d{2}-(.*)\\.parquet$", "\\1", basename(f))
  ref <- as.IDate(unique(d$reference_date)[1]); due <- ref - 3L
  obs <- load_latest(hub)[date < ref & date >= ref - 7L * (weeks_back + 1L)]
  q <- d[, .(q025 = quantile(value, .025), q25 = quantile(value, .25), q50 = median(value),
             q75 = quantile(value, .75), q975 = quantile(value, .975)), by = .(location, target_end_date)]
  locs <- load_locations(hub)
  nm <- setNames(locs$location_name, locs$location)
  ord <- locs[location %in% unique(q$location)][order(state, -is_state, location_name), location]
  dir.create(dirname(out_prefix), showWarnings = FALSE, recursive = TRUE)
  pdf(paste0(out_prefix, ".pdf"), width = 11, height = 5.2)
  for (l in ord) print(forecast_plot(obs[location == l], q[location == l], nm[[l]], due, model_id))
  invisible(dev.off())
  # HTML viewer: one embedded PNG per location, chosen from a menu
  tmp <- tempfile(fileext = ".png"); imgs <- character(length(ord))
  for (i in seq_along(ord)) {
    png(tmp, width = 1100, height = 520, res = 110); print(forecast_plot(obs[location == ord[i]], q[location == ord[i]], nm[[ord[i]]], due, model_id)); dev.off()
    imgs[i] <- jsonlite::base64_enc(readBin(tmp, "raw", file.info(tmp)$size))
  }
  opts <- paste0(sprintf('<option value="%d">%s</option>', seq_along(ord) - 1L, htmltools_escape(unname(nm[ord]))), collapse = "\n")
  figs <- paste0(sprintf('<img id="f%d" src="data:image/png;base64,%s" style="display:%s">', seq_along(ord) - 1L, imgs,
                         ifelse(seq_along(ord) == 1, "block", "none")), collapse = "\n")
  html <- sprintf('<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>%s forecasts, reference date %s</title>
<style>body{font-family:-apple-system,Segoe UI,Helvetica,Arial,sans-serif;margin:24px;color:#222}
.bar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:12px} select,button{font-size:15px;padding:6px 10px}
img{max-width:100%%;height:auto;border:1px solid #eee}</style></head><body>
<h2 style="margin:0 0 6px">%s &mdash; reference date %s</h2>
<p style="margin:0 0 14px;color:#555">%d locations. Use the menu or the arrow keys.</p>
<div class="bar"><button onclick="step(-1)">&larr; Previous</button><select id="loc" onchange="show(this.value)">%s</select>
<button onclick="step(1)">Next &rarr;</button></div>%s
<script>var n=%d,cur=0;function show(i){i=+i;document.getElementById("f"+cur).style.display="none";
document.getElementById("f"+i).style.display="block";cur=i;document.getElementById("loc").value=i;}
function step(s){show((cur+s+n)%%n);}document.addEventListener("keydown",function(e){if(e.key=="ArrowRight")step(1);if(e.key=="ArrowLeft")step(-1);});</script>
</body></html>', model_id, ref, model_id, ref, length(ord), opts, figs, length(ord))
  writeLines(html, paste0(out_prefix, ".html"))
  q
}
htmltools_escape <- function(x) { x <- gsub("&", "&amp;", x, fixed = TRUE); x <- gsub("<", "&lt;", x, fixed = TRUE); gsub(">", "&gt;", x, fixed = TRUE) }

if (sys.nframe() == 0) {
  a <- commandArgs(trailingOnly = TRUE)
  invisible(plot_submission(a[1], a[2], a[3])); cat("wrote", paste0(a[3], c(".pdf", ".html")), "\n")
}
