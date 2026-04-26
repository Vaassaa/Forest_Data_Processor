#!/usr/bin/env Rscript
# Main entry point — interactive wizard that prepares DRUtES simulation inputs.
# Run from the Forest_Data_Processor/ directory:
#   Rscript prepare_forest_simulation_data.R

.libPaths(c("~/R/libs", .libPaths()))
suppressPackageStartupMessages({
  library(data.table)
  library(ggplot2)
})

source("modules/utils.R")
source("modules/solar.R")
source("modules/monitoring.R")
source("modules/ebalance.R")
source("modules/rain.R")

# ══════════════════════════════════════════════════════════════════════════════
# Load sensor data
# ══════════════════════════════════════════════════════════════════════════════

cat("Loading data...\n")
dl      <- readRDS("data/TMS_standard_long.rds")
top_raw <- dl$topsoil_data
sub_raw <- dl$subsoil_data
sns     <- dl$sensors_description

meta_cols <- c("serial_number", "sensor_name", "tree", "type", "location")
top_raw <- merge(top_raw, sns[, ..meta_cols], by.x = "ID", by.y = "serial_number", all.x = TRUE)
sub_raw <- merge(sub_raw, sns[, ..meta_cols], by.x = "ID", by.y = "serial_number", all.x = TRUE)
all_raw <- rbind(top_raw, sub_raw)

dr <- range(all_raw$DTM, na.rm = TRUE)
cat(sprintf("  %d records  |  %s -> %s\n",
            nrow(all_raw), format(dr[1], "%d.%m.%Y"), format(dr[2], "%d.%m.%Y")))

# ══════════════════════════════════════════════════════════════════════════════
# Interactive selection
# ══════════════════════════════════════════════════════════════════════════════

hr()
cat("DATE RANGE  (format: DD.MM.YYYY)\n")
date_from   <- parse_date(ask("  Start : "))
date_to     <- parse_date(ask("  End   : "))
if (date_to <= date_from) stop("End date must be after start date.")
date_to_end <- date_to + 86399   # include the whole end day

campaign_dir <- file.path("out", sprintf("Campaign_%s_%s",
                                          format(date_from, "%-d-%-m-%Y"),
                                          format(date_to,   "%-d-%-m-%Y")))
dir.create(file.path(campaign_dir, "figs"), recursive = TRUE, showWarnings = FALSE)
cat(sprintf("  Output dir: %s\n", campaign_dir))

hr()
avail_trees <- sort(unique(sns$tree))
cat("TREE SPECIES   (smrk = spruce  |  buk = beech  |  modrin = larch)\n")
cat(sprintf("  Available : %s\n", paste(avail_trees, collapse = ", ")))
tree_in   <- ask("  Select    : [comma-separated or 'all'] ")
sel_trees <- if (tree_in == "all") avail_trees else
  intersect(trimws(strsplit(tree_in, ",")[[1]]), avail_trees)
if (!length(sel_trees)) stop("No valid tree species selected.")

hr()
avail_locs <- sort(unique(sns$location))
cat(sprintf("LOCATION\n  Available : %s\n", paste(avail_locs, collapse = ", ")))
loc_in   <- ask("  Select    : [comma-separated or 'all'] ")
sel_locs <- if (loc_in == "all") avail_locs else
  as.integer(trimws(strsplit(loc_in, ",")[[1]]))
if (any(is.na(sel_locs))) stop("Locations must be integers.")

tree_pfx <- if (length(sel_trees) == 1) sel_trees else "multi"
loc_pfx  <- if (length(sel_locs)  == 1) sprintf("loc%d", sel_locs) else "locs"
file_pfx <- paste(tree_pfx, loc_pfx, sep = "_")

hr()
cat("SOIL LAYER   (topsoil | subsoil | all)\n")
sel_types <- switch(trimws(ask("  Select    : ")),
  "all"     = c("topsoil", "subsoil"),
  "topsoil" = "topsoil",
  "subsoil" = "subsoil",
  stop("Choose topsoil, subsoil, or all.")
)

hr()
cat("SENSORS\n")
matching_sns <- sns[tree %in% sel_trees & location %in% sel_locs & type %in% sel_types]
setorder(matching_sns, tree, location, type)
cat(sprintf("  %-4s  %-12s  %-9s  %-5s  %-9s  %s\n",
            "#", "Serial", "Tree", "Loc", "Layer", "Sensor name"))
cat("  ", strrep("-", 58), "\n", sep = "")
for (i in seq_len(nrow(matching_sns))) {
  r <- matching_sns[i]
  cat(sprintf("  %-4d  %-12d  %-9s  %-5d  %-9s  %s\n",
              i, r$serial_number, r$tree, r$location, r$type, r$sensor_name))
}
sensor_in   <- ask("\n  'avg' for average of all, or sensor #s [e.g. 1,3,5] : ")
use_avg     <- trimws(sensor_in) == "avg"
sel_serials <- NULL
if (!use_avg) {
  idx <- as.integer(trimws(strsplit(sensor_in, ",")[[1]]))
  if (any(is.na(idx) | idx < 1 | idx > nrow(matching_sns))) stop("Invalid sensor numbers.")
  sel_serials <- matching_sns$serial_number[idx]
  cat(sprintf("  -> Keeping serials: %s\n", paste(sel_serials, collapse = ", ")))
}

hr()
cat("VARIABLES FOR CSV EXPORT\n")
for (i in seq_along(VAR_COLS)) cat(sprintf("  %d. %s\n", i, VAR_DESC[i]))
var_in <- ask("\n  Select    : [comma-separated, numbers or names, or 'all'] ")
if (trimws(var_in) == "all") {
  sel_vars <- VAR_COLS
} else {
  tokens   <- trimws(strsplit(var_in, ",")[[1]])
  by_num   <- suppressWarnings(as.integer(tokens))
  sel_vars <- intersect(ifelse(!is.na(by_num), VAR_COLS[by_num], tokens), VAR_COLS)
}
if (!length(sel_vars)) stop("No valid variables selected.")
cat(sprintf("  -> Exporting: %s\n", paste(sel_vars, collapse = ", ")))

hr()
cat("OUTPUT OPTIONS\n")
csv_default   <- sprintf("%s_export.csv", file_pfx)
csv_file      <- ask(sprintf("  CSV filename       [default: %s] : ", csv_default))
if (!nchar(csv_file)) csv_file <- csv_default
csv_file      <- file.path(campaign_dir, csv_file)
do_monitoring <- tolower(ask("  Generate monitoring.dat?                    [y/n] : ")) %in% c("y", "yes")
do_plots      <- tolower(ask("  Generate sensor plots in figs/?             [y/n] : ")) %in% c("y", "yes")
do_ebalance   <- tolower(ask("  Generate ebalance.in?  (ERA5 download)      [y/n] : ")) %in% c("y", "yes")
do_rain       <- tolower(ask("  Generate rain.in?      (Grafana download)   [y/n] : ")) %in% c("y", "yes")

# ══════════════════════════════════════════════════════════════════════════════
# Filter & average sensor data
# ══════════════════════════════════════════════════════════════════════════════

cat("\nProcessing...\n")
result <- all_raw[DTM >= date_from & DTM <= date_to_end &
                  tree %in% sel_trees & location %in% sel_locs & type %in% sel_types]
if (!use_avg) result <- result[ID %in% sel_serials]
if (!nrow(result)) stop("No data matched the filters.")

if (use_avg) {
  avg_horizon <- function(dt) {
    if (!nrow(dt)) return(NULL)
    dt[, lapply(.SD, mean, na.rm = TRUE),
       by = .(DTM, tree, location, type), .SDcols = sel_vars]
  }
  # Average each horizon independently — T1/T2/T3 map to different depths in
  # topsoil vs subsoil and must never be pooled across layers.
  result <- rbind(avg_horizon(result[type == "topsoil"]),
                  avg_horizon(result[type == "subsoil"]), fill = TRUE)
  setorder(result, DTM, tree, location, type)
} else {
  keep   <- c("DTM", "ID", "sensor_name", "tree", "location", "type", sel_vars)
  result <- result[, ..keep]
  setorder(result, DTM, tree, location, type, ID)
}

# ══════════════════════════════════════════════════════════════════════════════
# CSV export
# ══════════════════════════════════════════════════════════════════════════════

fwrite(result, csv_file, sep = ",", dateTimeAs = "write.csv")
cat(sprintf("  CSV  : %d rows x %d cols  ->  %s\n", nrow(result), ncol(result), csv_file))

# ══════════════════════════════════════════════════════════════════════════════
# monitoring.dat
# ══════════════════════════════════════════════════════════════════════════════

if (do_monitoring)
  write_monitoring_dat(top_raw, sub_raw, date_from, date_to, date_to_end, campaign_dir)

# ══════════════════════════════════════════════════════════════════════════════
# Sensor plots  (one PNG per variable x tree x location x soil layer)
# ══════════════════════════════════════════════════════════════════════════════

if (do_plots) {
  n_plots <- 0
  for (tr in unique(result$tree)) {
    for (loc in unique(result[tree == tr, location])) {
      for (lyr in unique(result[tree == tr & location == loc, type])) {
        sub_dt <- result[tree == tr & location == loc & type == lyr]
        if (!nrow(sub_dt)) next
        for (v in sel_vars) {
          if (!v %in% names(sub_dt) || all(is.na(sub_dt[[v]]))) next
          fname <- file.path(campaign_dir, "figs",
                             sprintf("%s_loc%d_%s_%s.png", tr, loc, lyr, v))
          p <- ggplot(sub_dt, aes(x = DTM, y = .data[[v]])) +
            labs(title = sprintf("%s  |  loc %d  |  %s  |  %s",
                                 tr, loc, lyr, VAR_DESC[match(v, VAR_COLS)]),
                 x = NULL, y = var_ylabel(v, lyr)) +
            theme_bw(base_size = 11) +
            theme(plot.title       = element_text(size = 9, face = "bold"),
                  axis.text.x      = element_text(angle = 30, hjust = 1),
                  panel.grid.minor = element_blank()) +
            scale_x_datetime(date_labels = "%d.%m.%Y", date_breaks = "1 week")
          if (!use_avg && "sensor_name" %in% names(sub_dt)) {
            p <- p + geom_line(aes(color = sensor_name, group = sensor_name),
                               linewidth = 0.5, alpha = 0.85) +
              scale_color_brewer(palette = "Set1", name = "Sensor") +
              theme(legend.position = "right")
          } else {
            p <- p + geom_line(color = "#2166ac", linewidth = 0.6)
          }
          ggsave(fname, p, width = 12, height = 4, dpi = 150)
          n_plots <- n_plots + 1
          cat(sprintf("  Plot : %s\n", fname))
        }
      }
    }
  }
  cat(sprintf("  %d figure(s) saved to %s/figs/\n", n_plots, campaign_dir))
}

# ══════════════════════════════════════════════════════════════════════════════
# ebalance.in
# ══════════════════════════════════════════════════════════════════════════════

if (do_ebalance) {
  combos <- unique(result[, .(tree, location)])
  if (nrow(combos) > 1) {
    hr()
    cat("EBALANCE — select tree/location for T_15cm (topsoil T3)\n")
    for (i in seq_len(nrow(combos)))
      cat(sprintf("  %d.  %s / loc%d\n", i, combos$tree[i], combos$location[i]))
    sel     <- as.integer(ask("  Select [number]: "))
    eb_tree <- combos$tree[sel]
    eb_loc  <- combos$location[sel]
  } else {
    eb_tree <- combos$tree[1]
    eb_loc  <- combos$location[1]
  }
  write_ebalance_in(top_raw, date_from, date_to, date_to_end,
                    campaign_dir, file_pfx, eb_tree, eb_loc)
}

# ══════════════════════════════════════════════════════════════════════════════
# rain.in
# ══════════════════════════════════════════════════════════════════════════════

if (do_rain)
  write_rain_in(date_from, date_to, date_to_end, campaign_dir, file_pfx)

cat("\nDone.\n")
