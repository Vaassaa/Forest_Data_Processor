# modules/rain.R
# Downloads precipitation data from Grafana/InfluxDB (Scintillometer) and
# writes rain.in for DRUtES.
#
# Credentials: ~/.grafanarc  (fields: url, user, password, datasource_id, database)
# Source metric: nb_data_v3 / Pulses / 5  [mm per native interval]
# Output unit:   rain rate [m/s]  — resampled to 10-min grid

write_rain_in <- function(date_from, date_to, date_to_end, campaign_dir, file_pfx) {
  suppressPackageStartupMessages({
    library(httr)
    library(jsonlite)
    library(ggplot2)
  })

  # ── Read credentials from ~/.grafanarc ───────────────────────────────────────
  gfrc <- path.expand("~/.grafanarc")
  if (!file.exists(gfrc))
    stop("~/.grafanarc not found. See README.md for setup instructions.")
  rc_gf      <- readLines(gfrc, warn = FALSE)
  parse_gfrc <- function(field) {
    ln <- rc_gf[startsWith(rc_gf, field)]
    if (!length(ln)) stop("'", field, "' not found in ~/.grafanarc")
    trimws(sub(paste0(field, ":"), "", ln[1]))
  }
  gf_url  <- parse_gfrc("url")
  gf_user <- parse_gfrc("user")
  gf_pass <- parse_gfrc("password")
  gf_dsid <- parse_gfrc("datasource_id")
  gf_db   <- parse_gfrc("database")
  cat(sprintf("  Grafana: %s  (user: %s)\n", gf_url, gf_user))

  # ── Query ────────────────────────────────────────────────────────────────────
  q_str <- sprintf(
    paste0('SELECT "Pulses" / 5 AS "rain" FROM "nb_data_v3"',
           ' WHERE ("name" = \'Scintilometr\')',
           ' AND time >= \'%s\' AND time <= \'%s\'',
           ' GROUP BY "name"'),
    format(date_from,   "%Y-%m-%dT%H:%M:%SZ"),
    format(date_to_end, "%Y-%m-%dT%H:%M:%SZ")
  )

  cat("  Querying Grafana (InfluxDB)...\n")
  resp <- GET(
    sprintf("%s/api/datasources/proxy/%s/query", gf_url, gf_dsid),
    authenticate(gf_user, gf_pass, type = "basic"),
    query = list(db = gf_db, epoch = "s", q = q_str)
  )
  if (status_code(resp) != 200L)
    stop("Grafana query failed (HTTP ", status_code(resp), "): ",
         content(resp, "text", encoding = "UTF-8"))

  series <- content(resp, "parsed")$results[[1]]$series[[1]]
  if (is.null(series))
    stop("No rain data returned for the selected period. Check Grafana time range.")

  # ── Parse response ───────────────────────────────────────────────────────────
  vals <- do.call(rbind, lapply(series$values, function(x) {
    c(as.numeric(x[[1]]),
      if (is.null(x[[2]])) NA_real_ else as.numeric(x[[2]]))
  }))
  rain_dt <- data.table(
    ts_unix = vals[, 1],
    mm      = pmax(ifelse(is.na(vals[, 2]), 0, vals[, 2]), 0)
  )
  setorder(rain_dt, ts_unix)
  cat(sprintf("  Received %d measurements  (%s -> %s)\n",
              nrow(rain_dt),
              format(as.POSIXct(rain_dt$ts_unix[1],             origin = "1970-01-01", tz = "UTC"), "%d.%m.%Y %H:%M"),
              format(as.POSIXct(rain_dt$ts_unix[nrow(rain_dt)], origin = "1970-01-01", tz = "UTC"), "%d.%m.%Y %H:%M")))

  # ── Native timestep & rate conversion ────────────────────────────────────────
  dt_s <- if (nrow(rain_dt) > 1) median(diff(rain_dt$ts_unix)) else 600
  cat(sprintf("  Native timestep: %d s (%.0f min)\n", as.integer(round(dt_s)), dt_s / 60))

  # rain [mm] / dt [s] / 1000 [mm per m]  =  rate [m/s]
  rain_dt[, rate_ms := mm * 1e-3 / dt_s]

  # ── Snap timestamps to native grid (removes ~3 s sensor clock offset) ────────
  t0_unix <- as.numeric(date_from)
  rain_dt[, sim_s := round((ts_unix - t0_unix) / dt_s) * dt_s]

  # Fill gaps in native grid with zero before interpolation
  native_max  <- max(rain_dt$sim_s)
  native_grid <- data.table(sim_s = seq(0, native_max, by = as.integer(round(dt_s))))
  rain_dt     <- merge(native_grid, rain_dt[, .(sim_s, rate_ms)], by = "sim_s", all.x = TRUE)
  rain_dt[is.na(rate_ms), rate_ms := 0]

  # ── Resample to 10-min grid (matches ebalance.in / monitoring.dat) ────────────
  target_grid <- seq(date_from, date_to, by = "10 min")
  target_s    <- as.numeric(difftime(target_grid, date_from, units = "secs"))

  rate_interp <- pmax(approx(rain_dt$sim_s, rain_dt$rate_ms,
                             xout = target_s, method = "linear", rule = 2)$y, 0)

  rain_out <- data.table(
    sim_s   = target_s,
    rate_ms = rate_interp,
    mm      = rate_interp * 600 * 1000   # mm per 10-min interval, for plotting
  )

  # ── Write rain.in ─────────────────────────────────────────────────────────────
  rain_file <- file.path(campaign_dir, sprintf("%s_rain.in", file_pfx))
  con <- file(rain_file, open = "w", encoding = "UTF-8")
  writeLines(c(
    sprintf("##EVENT %s - %s",
            format(date_from, "%Y-%m-%d %H:%M"),
            format(date_to,   "%Y-%m-%d %H:%M")),
    "#time\train[m/s](scintilometr)"
  ), con)
  write.table(rain_out[, .(sim_s, rate_ms)],
              con, sep = "\t", row.names = FALSE, col.names = FALSE, quote = FALSE)
  close(con)
  cat(sprintf("  RAIN : %d timesteps (10 min)  ->  %s\n", nrow(rain_out), rain_file))

  # ── Plot ─────────────────────────────────────────────────────────────────────
  dir.create(file.path(campaign_dir, "figs"), recursive = TRUE, showWarnings = FALSE)
  p_rain <- ggplot(data.table(time = target_grid, mm = rain_out$mm),
                   aes(x = time, y = mm)) +
    geom_col(fill = "#2166ac", width = 600 * 0.9) +
    labs(title = sprintf("Precipitation (Scintillometer)  |  %s -> %s",
                         format(date_from, "%d.%m.%Y"), format(date_to, "%d.%m.%Y")),
         x = NULL, y = "Precipitation [mm / 10 min]") +
    theme_bw(base_size = 11) +
    theme(plot.title       = element_text(size = 9, face = "bold"),
          axis.text.x      = element_text(angle = 30, hjust = 1),
          panel.grid.minor = element_blank()) +
    scale_x_datetime(date_labels = "%d.%m.%Y", date_breaks = "1 week")

  rain_png <- file.path(campaign_dir, "figs", "rain.png")
  ggsave(rain_png, p_rain, width = 12, height = 4, dpi = 150)
  cat(sprintf("  Plot : %s\n", rain_png))
}
