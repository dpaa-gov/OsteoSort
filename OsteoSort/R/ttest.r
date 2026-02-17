ttest <- function(refa = NULL, refb = NULL, sorta = NULL, sortb = NULL, alphalevel = 0.1, absolute = TRUE, zmean = FALSE, tails = 2, yeojohnson = TRUE, reference = NULL) {
    start_time <- start_time()

    meta_cols <- c("accession", "side", "element")

    force(alphalevel)
    force(absolute)
    force(zmean)
    force(tails)
    force(yeojohnson)

    # Appends a variable with 0 to make sure the data structure stays the same in Julia
    refa <- cbind(refa, fa = 0)
    refb <- cbind(refb, fa = 0)
    sorta <- cbind(sorta, fa = 0)
    sortb <- cbind(sortb, fa = 0)

    if (all(is.na(sorta)) || is.null(sorta)) {
        return(NULL)
    }
    if (all(is.na(sortb)) || is.null(sortb)) {
        return(NULL)
    }
    if (all(is.na(refa)) || is.null(refa)) {
        return(NULL)
    }
    if (all(is.na(refb)) || is.null(refb)) {
        return(NULL)
    }

    # Get non-meta columns for Julia calls
    meas_cols <- !names(sorta) %in% meta_cols

    plot_data <- NULL

    # Call unified Julia TTEST with keyword arguments
    sort_mat <- as.matrix(sorta[, meas_cols])
    sort_mat_b <- as.matrix(sortb[, meas_cols])
    ref_mat <- as.matrix(refa[, meas_cols])
    ref_mat_b <- as.matrix(refb[, meas_cols])

    results <- julia_call("OSJ.TTEST", sort_mat, sort_mat_b, ref_mat, ref_mat_b, tails,
        absolute = absolute, yeojohnson = yeojohnson, zeromean = zmean
    )

    # Plot data for single comparisons
    if (nrow(as.matrix(sorta)) == 1 && nrow(as.matrix(sortb)) == 1) {
        plot_data <- julia_call("OSJ.TTEST_plot", sort_mat, sort_mat_b, ref_mat, ref_mat_b,
            absolute = absolute, yeojohnson = yeojohnson
        )
    }

    # Transform numerical T/F to measurement names
    if (nrow(results) > 1) {
        measurements <- data.frame(results[, c(8:ncol(results))])
    } else {
        measurements <- data.frame(t(results[c(8:length(results))]))
    }

    is_articulation <- sorta[results[, 1], "element"] != sortb[results[, 2], "element"]

    if (is_articulation[1]) {
        # Articulation: bones are different, so column names don't align positionally.
        # Just show all measurement names from both bones.
        meas_a <- colnames(sorta[, meas_cols])
        meas_a <- meas_a[meas_a != "fa"]
        meas_b <- colnames(sortb[, meas_cols])
        meas_b <- meas_b[meas_b != "fa"]
        measurements <- rep(paste(c(meas_a, meas_b), collapse = " "), nrow(results))
    } else {
        # Pair-matching: same bone both sides, names align with Julia flags.
        measurement_names <- colnames(sorta[, meas_cols])
        fa_idx <- which(measurement_names == "fa")
        if (length(fa_idx) > 0) {
            measurement_names <- measurement_names[-fa_idx]
            measurements <- measurements[, -fa_idx, drop = FALSE]
        }

        for (i in seq_len(ncol(measurements))) {
            measurements[measurements[, i] != 0, i] <- paste(measurement_names[i], " ", sep = "")
            measurements[measurements[, i] == 0, i] <- ""
        }

        measurements <- do.call(paste0, measurements[seq_len(ncol(measurements))])
    }

    # Format data.frame to return
    results_formatted <- data.frame(
        cbind(
            id_1 = sorta[results[, 1], "accession"],
            element_1 = sorta[results[, 1], "element"],
            side_1 = sorta[results[, 1], "side"],
            id_2 = sortb[results[, 2], "accession"],
            element_2 = sortb[results[, 2], "element"],
            side_2 = sortb[results[, 2], "side"],
            measurements = measurements,
            n = results[, 7],
            mean = round(results[, 5], digits = 4),
            sd = round(results[, 6], digits = 4),
            p = round(results[, 4], digits = 5)
        ),
        result = NA
    )
    rejected <- results_formatted[results_formatted$measurements == "", 1:6]
    results_formatted <- results_formatted[results_formatted$measurements != "", ]

    # Append exclusion results
    results_formatted[results_formatted$p > alphalevel, "result"] <- "Cannot Exclude"
    results_formatted[results_formatted$p <= alphalevel, "result"] <- "Excluded"

    t_time <- end_time(start_time)
    return(list(results_formatted, plot_data, t_time, rejected))
}
