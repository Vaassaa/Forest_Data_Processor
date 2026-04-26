# modules/monitoring.R
# Generates monitoring.dat — soil temperature and moisture forcing for DRUtES.
# One file per tree × location combination, 10-min timestep.
#
# Variable mapping (from makeMonitorData.py):
#   topsoil T1  → T_n8cm      subsoil T2  → T_n15cm
#   subsoil T1  → T_n23cm     topsoil moisture → theta_n8cm
#   subsoil moisture → theta_n23cm

write_monitoring_dat <- function(top_raw, sub_raw,
                                  date_from, date_to, date_to_end,
                                  campaign_dir) {
  combos <- unique(rbind(
    top_raw[, .(tree, location)],
    sub_raw[, .(tree, location)]
  ))

  for (ci in seq_len(nrow(combos))) {
    tr  <- combos$tree[ci]
    loc <- combos$location[ci]

    avg_layer <- function(raw) {
      d <- raw[tree == tr & location == loc &
               DTM >= date_from & DTM <= date_to_end]
      if (!nrow(d)) return(NULL)
      d <- d[!duplicated(d, by = c("DTM", "ID"))]
      out <- d[, lapply(.SD, mean, na.rm = TRUE),
               by = "DTM", .SDcols = c("T1", "T2", "T3", "moisture")]
      setorder(out, DTM)
      out
    }

    td <- avg_layer(top_raw)
    sd <- avg_layer(sub_raw)

    if (is.null(td) || is.null(sd)) {
      cat(sprintf("  [monitoring.dat] %s/loc%d — missing %s data, skipping.\n",
                  tr, loc, if (is.null(td)) "topsoil" else "subsoil"))
      next
    }

    grid <- seq(date_from, date_to, by = "10 min")
    secs <- as.numeric(difftime(grid, date_from, units = "secs"))

    mon <- data.table(
      `sim_time[s]` = secs,
      T_n8cm        = interp10(td$DTM, td$T1,       grid),
      T_n15cm       = interp10(sd$DTM, sd$T2,       grid),
      T_n23cm       = interp10(sd$DTM, sd$T1,       grid),
      theta_n8cm    = interp10(td$DTM, td$moisture, grid),
      theta_n23cm   = interp10(sd$DTM, sd$moisture, grid)
    )

    fname <- file.path(campaign_dir, sprintf("%s_loc%d_monitoring.dat", tr, loc))
    con   <- file(fname, open = "w", encoding = "UTF-8")
    writeLines(c(
      paste("# campaign:",
            format(date_from, "%Y-%m-%d %H:%M:%S+00:00"),
            format(date_to,   "%Y-%m-%d %H:%M:%S+00:00")),
      "# time[s] T_n8cm[°C] T_n15cm[°C] T_n23cm[°C] theta_n8cm[-] theta_n23cm[-]"
    ), con)
    write.table(mon, con, sep = " ", row.names = FALSE, col.names = FALSE, quote = FALSE)
    close(con)
    cat(sprintf("  DAT  : %d timesteps (10 min)  →  %s\n", nrow(mon), fname))
  }
}
