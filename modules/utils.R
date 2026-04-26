# modules/utils.R
# Shared helpers, interactive input, and variable catalogue.
# Sourced at the top of prepare_forest_simulation_data.R.

STDIN <- file("stdin", open = "r")
ask   <- function(prompt) { cat(prompt); trimws(readLines(STDIN, n = 1)) }

parse_date <- function(s) {
  d <- as.POSIXct(paste(s, "00:00:00"), format = "%d.%m.%Y %H:%M:%S", tz = "UTC")
  if (is.na(d)) stop("Cannot parse '", s, "' — use DD.MM.YYYY.")
  d
}

interp10 <- function(times, vals, grid) {
  ok <- !is.na(vals) & !duplicated(times)
  if (sum(ok) < 2) return(rep(NA_real_, length(grid)))
  approx(as.numeric(times[ok]), vals[ok], as.numeric(grid), rule = 2)$y
}

hr <- function(char = "─", width = 72) cat("\n", strrep(char, width), "\n", sep = "")

# ── Variable catalogue ────────────────────────────────────────────────────────

VAR_COLS <- c("T1", "T2", "T3", "moisture", "Wmm")
VAR_DESC <- c(
  "T1       — air/litter temperature at −80 mm            [°C]",
  "T2       — surface temperature at 0 mm                 [°C]",
  "T3       — soil temperature at +150 mm                 [°C]",
  "moisture — volumetric water content                    [m³/m³]",
  "Wmm      — water equivalent depth                      [mm]"
)
VAR_UNIT <- c("°C", "°C", "°C", "m³/m³", "mm")

var_ylabel <- function(v, layer) {
  if (v == "moisture") return(sprintf("Vol. water content [m³/m³]  (%s)", layer))
  if (v == "Wmm")      return(sprintf("Water depth [mm]  (%s)", layer))
  depth <- c(
    topsoil.T1 = "-8 cm (air/litter)",
    topsoil.T2 = "0 cm (surface)",
    topsoil.T3 = "+15 cm (soil)",
    subsoil.T1 = "-23 cm",
    subsoil.T2 = "-15 cm",
    subsoil.T3 = "-30 cm"
  )[paste(layer, v, sep = ".")]
  sprintf("Temperature at %s  [°C]", if (is.na(depth)) v else depth)
}
