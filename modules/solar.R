# modules/solar.R
# NOAA solar position algorithm (R port of solar.py) and GPS/bbox parser.
# Sourced by prepare_forest_simulation_data.R.

solar_noon_hr <- function(lon, doy, tz) {
  gamma  <- 2 * pi / 365 * doy
  eqtime <- 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
                      - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
  (720 - 4 * lon - eqtime) / 60 + tz
}

# dtm_utc : POSIXct vector (UTC)  →  W m-2 vector
calc_solar_rad <- function(dtm_utc, cloud_frac = 0.8, lon, lat, tz = 1L) {
  c_f  <- pmax(pmin(as.numeric(cloud_frac), 1), 0)
  rlat <- lat * pi / 180
  doy  <- as.integer(format(dtm_utc, "%j"))
  t_hr <- as.integer(format(dtm_utc, "%H")) +
          as.integer(format(dtm_utc, "%M")) / 60 + tz
  noon  <- solar_noon_hr(lon, doy, tz)
  delta <- 0.409 * sin(2 * pi * doy / 365 - 1.39)
  sin_e <- pmax(sin(rlat) * sin(delta) +
                  cos(rlat) * cos(delta) * cos(2 * pi * (t_hr - noon) / 24), 0)
  Tt <- pmax(pmin((2.33 - c_f) / 3.33, 1), 0)
  pmax(1360 * Tt * sin_e, 0)
}

# Parses data/amalie_gps_cords.txt → list(lat, lon, bbox_N, bbox_W, bbox_E, bbox_S)
parse_gps <- function(gps_file = "data/amalie_gps_cords.txt") {
  raw <- trimws(readLines(gps_file, warn = FALSE))

  site_line <- raw[grepl("[0-9]N", raw) & grepl("[0-9]E", raw)][1]
  parts <- strsplit(site_line, ",")[[1]]
  lat   <- as.numeric(sub("N", "", trimws(parts[1])))
  lon   <- as.numeric(sub("E", "", trimws(parts[2])))

  num_lines <- raw[!grepl("[A-DF-Za-df-z#]", raw) & nchar(raw) > 0]
  bbox_vals <- lapply(num_lines, function(l) {
    v <- suppressWarnings(as.numeric(strsplit(trimws(l), "\\s+")[[1]]))
    v[!is.na(v)]
  })
  bbox_line <- bbox_vals[sapply(bbox_vals, length) == 4][[1]]   # order: N W E S
  list(lat = lat, lon = lon,
       bbox_N = bbox_line[1], bbox_W = bbox_line[2],
       bbox_E = bbox_line[3], bbox_S = bbox_line[4])
}
