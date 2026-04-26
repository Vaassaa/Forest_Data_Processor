#!/usr/bin/env Rscript
# Run this script once to install all R packages required by
# prepare_forest_simulation_data.R.
#
# Before running, install the NetCDF system library:
#   Arch Linux : sudo pacman -S netcdf
#   Ubuntu/Debian: sudo apt install libnetcdf-dev libhdf5-dev
#   Fedora/RHEL : sudo dnf install netcdf-devel hdf5-devel

lib <- "~/R/libs"
dir.create(lib, recursive = TRUE, showWarnings = FALSE)
.libPaths(c(lib, .libPaths()))

pkgs <- c(
  "data.table",   # fast data manipulation
  "ggplot2",      # time-series plots
  "httr",         # HTTP requests (ERA5 CDS API, Grafana API)
  "jsonlite",     # JSON serialisation for API request bodies
  "ncdf4"         # read ERA5 NetCDF files (requires system libnetcdf)
)

missing <- pkgs[!vapply(pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  cat(sprintf("Installing: %s\n", paste(missing, collapse = ", ")))
  install.packages(missing, lib = lib, repos = "https://cloud.r-project.org")
} else {
  cat("All packages already installed.\n")
}

cat("\nVersion summary:\n")
for (p in pkgs)
  cat(sprintf("  %-12s  %s\n", p, as.character(packageVersion(p))))
