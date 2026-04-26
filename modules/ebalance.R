# modules/ebalance.R
# Downloads ERA5 meteorological data (CDS API) and writes ebalance.in.
# Also writes ERA5 diagnostic plots to figs/.
#
# Credentials: ~/.cdsapirc   (fields: url, key)
# ERA5 variables: 10m wind (u+v), total cloud cover, 2m T + dewpoint → RH
# Solar radiation: NOAA algorithm via calc_solar_rad() from solar.R

write_ebalance_in <- function(top_raw, date_from, date_to, date_to_end,
                               campaign_dir, file_pfx, eb_tree, eb_loc) {
  suppressPackageStartupMessages({
    library(ncdf4)
    library(httr)
    library(jsonlite)
    library(ggplot2)
  })

  # ── GPS site & bounding box ──────────────────────────────────────────────────
  gps <- parse_gps()
  cat(sprintf("  Site: %.7f°N  %.7f°E\n", gps$lat, gps$lon))
  cat(sprintf("  ERA5 bbox: N=%.1f W=%.1f E=%.1f S=%.1f\n",
              gps$bbox_N, gps$bbox_W, gps$bbox_E, gps$bbox_S))

  # ── 10-min time grid ─────────────────────────────────────────────────────────
  grid <- seq(date_from, date_to, by = "10 min")
  secs <- as.numeric(difftime(grid, date_from, units = "secs"))

  # ── T_15cm from sensor data (topsoil T3, averaged across sensors) ────────────
  cat(sprintf("  T_15cm source: %s / loc%d / topsoil / T3\n", eb_tree, eb_loc))
  top_eb <- top_raw[tree == eb_tree & location == eb_loc &
                    DTM >= date_from & DTM <= date_to_end]
  if (!nrow(top_eb))
    stop("No topsoil data for ", eb_tree, " / loc", eb_loc)
  top_avg_eb <- top_eb[!duplicated(top_eb, by = c("DTM", "ID"))][
    , .(T3 = mean(T3, na.rm = TRUE)), by = "DTM"]
  setorder(top_avg_eb, DTM)
  T_15cm <- interp10(top_avg_eb$DTM, top_avg_eb$T3, grid)

  # ── Solar radiation ──────────────────────────────────────────────────────────
  cat("  Computing solar radiation...\n")
  S_t <- calc_solar_rad(grid, cloud_frac = 0.8,
                        lon = gps$lon, lat = gps$lat, tz = 1L)

  # ── ERA5 download ────────────────────────────────────────────────────────────
  nc_file <- file.path(campaign_dir, "era5_data.nc")

  if (file.exists(nc_file)) {
    cat(sprintf("  ERA5 NetCDF already exists, skipping download:\n    %s\n", nc_file))
  } else {
    hr()
    cat("ERA5 DOWNLOAD\n")
    cat("  Variables: 10m wind (u+v), total cloud cover,\n")
    cat("             2m temperature + dewpoint (-> relative humidity)\n")
    cat("  Dataset  : reanalysis-era5-single-levels\n\n")

    cdsrc <- path.expand("~/.cdsapirc")
    if (!file.exists(cdsrc))
      stop("~/.cdsapirc not found. See README.md for setup instructions.")
    rc_lines  <- readLines(cdsrc, warn = FALSE)
    parse_cds <- function(field) {
      ln <- rc_lines[startsWith(rc_lines, field)]
      if (!length(ln)) stop("'", field, "' not found in ~/.cdsapirc")
      trimws(sub(paste0(field, ":"), "", ln[1]))
    }
    cds_key <- parse_cds("key")
    cds_url <- parse_cds("url")
    cat(sprintf("  Credentials: ~/.cdsapirc  (key: %s...)\n", substr(cds_key, 1, 8)))

    all_days <- seq(as.Date(date_from), as.Date(date_to), by = "day")
    body <- list(
      inputs = list(
        product_type    = list("reanalysis"),
        variable        = list("10m_u_component_of_wind", "10m_v_component_of_wind",
                               "total_cloud_cover",
                               "2m_temperature", "2m_dewpoint_temperature"),
        year            = as.list(unique(format(all_days, "%Y"))),
        month           = as.list(unique(format(all_days, "%m"))),
        day             = as.list(unique(format(all_days, "%d"))),
        time            = as.list(sprintf("%02d:00", 0:23)),
        area            = list(gps$bbox_N, gps$bbox_W, gps$bbox_E, gps$bbox_S),
        data_format     = "netcdf",
        download_format = "unarchived"
      )
    )

    auth     <- add_headers(`PRIVATE-TOKEN` = cds_key, `Content-Type` = "application/json")
    exec_url <- paste0(cds_url, "/retrieve/v1/processes/reanalysis-era5-single-levels/execution")

    cat("  Submitting ERA5 request...\n")
    resp <- POST(exec_url, auth, body = toJSON(body, auto_unbox = TRUE), encode = "raw")

    if (!status_code(resp) %in% c(200L, 201L)) {
      err <- tryCatch(content(resp, "parsed")$detail, error = function(e) http_status(resp)$message)
      stop("CDS submission failed (HTTP ", status_code(resp), "): ", err)
    }

    job     <- content(resp, "parsed")
    job_id  <- job$jobID
    job_url <- paste0(cds_url, "/retrieve/v1/jobs/", job_id)
    cat(sprintf("  Job ID: %s\n", job_id))

    repeat {
      Sys.sleep(15)
      st <- content(GET(job_url, auth), "parsed")
      cat(sprintf("  Status: %s\n", st$status))
      if (st$status == "successful") break
      if (st$status %in% c("failed", "dismissed"))
        stop("ERA5 job failed. Check https://cds.climate.copernicus.eu/requests")
    }

    dl_url <- content(GET(paste0(job_url, "/results"), auth), "parsed")$asset$value$href
    cat("  Downloading NetCDF...\n")
    GET(dl_url, auth, write_disk(nc_file, overwrite = TRUE), progress(), timeout(600))
    cat(sprintf("  Saved: %s\n", nc_file))
  }

  # ── Read & process ERA5 NetCDF ───────────────────────────────────────────────
  cat("  Reading ERA5 NetCDF...\n")
  nc     <- nc_open(nc_file)
  lat_nc <- ncvar_get(nc, "latitude")
  lon_nc <- ncvar_get(nc, "longitude")
  i_lat  <- which.min(abs(lat_nc - gps$lat))
  i_lon  <- which.min(abs(lon_nc - gps$lon))
  cat(sprintf("  Nearest ERA5 cell: %.2f°N  %.2f°E\n", lat_nc[i_lat], lon_nc[i_lon]))

  era5_posix <- as.POSIXct("1970-01-01", tz = "UTC") + ncvar_get(nc, "valid_time")

  get_ts <- function(vname) {
    v <- ncvar_get(nc, vname)
    if (length(dim(v)) == 3) v[i_lon, i_lat, ] else as.vector(v)
  }
  u10 <- get_ts("u10")
  v10 <- get_ts("v10")
  tcc <- get_ts("tcc")
  t2m <- get_ts("t2m") - 273.15
  d2m <- get_ts("d2m") - 273.15
  nc_close(nc)

  wind_speed <- sqrt(u10^2 + v10^2)
  rh <- pmax(pmin(
    exp(17.625 * d2m / (243.04 + d2m)) / exp(17.625 * t2m / (243.04 + t2m)),
    1), 0)

  ws_10  <- interp10(era5_posix, wind_speed, grid)
  tcc_10 <- pmax(interp10(era5_posix, tcc, grid), 0)
  rh_10  <- pmax(pmin(interp10(era5_posix, rh, grid), 1), 0)

  # ── Write ebalance.in ────────────────────────────────────────────────────────
  eb_file <- file.path(campaign_dir, sprintf("%s_loc%d_ebalance.in", eb_tree, eb_loc))
  eb_data <- data.frame(
    time_s      = secs,
    S_t         = S_t,
    T_15cm      = T_15cm,
    wind_speed  = ws_10,
    cloud_cover = tcc_10,
    rh          = rh_10
  )

  con <- file(eb_file, open = "w", encoding = "UTF-8")
  writeLines(c(
    sprintf("#campaign %s %s",
            format(date_from, "%Y-%m-%d %H:%M"),
            format(date_to,   "%Y-%m-%d %H:%M")),
    "#time[s]\tS_t[W/m2]\tT_15cm[°C](amalie)\twind_speed[m/s](era5)\ttotal_cloud_cover[-](era5)\trelative_humidity[%/100](era5)"
  ), con)
  write.table(eb_data, con, sep = "\t", row.names = FALSE, col.names = FALSE,
              quote = FALSE, na = "NA")
  close(con)
  cat(sprintf("  EBAL : %d timesteps (10 min)  →  %s\n", nrow(eb_data), eb_file))

  # ── ERA5 plots ────────────────────────────────────────────────────────────────
  plot_vars <- list(
    list(col = "S_t",         label = "Solar radiation [W/m²]",          colour = "#e6550d"),
    list(col = "T_15cm",      label = "Soil temperature at +15 cm [°C]", colour = "#2166ac"),
    list(col = "wind_speed",  label = "Wind speed [m/s]",                colour = "#74c476"),
    list(col = "cloud_cover", label = "Total cloud cover [-]",           colour = "#756bb1"),
    list(col = "rh",          label = "Relative humidity [-]",           colour = "#2ca25f")
  )
  dir.create(file.path(campaign_dir, "figs"), recursive = TRUE, showWarnings = FALSE)
  for (vp in plot_vars) {
    fname <- file.path(campaign_dir, "figs", sprintf("era5_%s.png", vp$col))
    title <- sprintf("%s  |  %s -> %s", vp$label,
                     format(date_from, "%d.%m.%Y"), format(date_to, "%d.%m.%Y"))
    p <- ggplot(eb_data, aes(x = grid, y = .data[[vp$col]])) +
      geom_line(colour = vp$colour, linewidth = 0.6) +
      labs(title = title, x = NULL, y = vp$label) +
      theme_bw(base_size = 11) +
      theme(plot.title       = element_text(size = 9, face = "bold"),
            axis.text.x      = element_text(angle = 30, hjust = 1),
            panel.grid.minor = element_blank()) +
      scale_x_datetime(date_labels = "%d.%m.%Y", date_breaks = "1 week")
    ggsave(fname, p, width = 12, height = 4, dpi = 150)
    cat(sprintf("  Plot : %s\n", fname))
  }
}
