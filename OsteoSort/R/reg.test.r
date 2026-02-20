reg.test <- function(refa = NULL, refb = NULL, sorta = NULL, sortb = NULL, reference = NULL, type = "Logarithm Composite", alphalevel = 0.05) {
    start_time <- start_time()

    meta_cols <- c("accession", "side", "element")

    force(alphalevel)
    force(type)

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

    plot_data <- NULL

    # Use positional indexing for Julia calls since bone A and bone B have different columns
    results <- osj_regsl(as.matrix(sorta[, -c(1:3)]), as.matrix(sortb[, -c(1:3)]), as.matrix(refa[, -c(1:3)]), as.matrix(refb[, -c(1:3)]))
    if (nrow(as.matrix(sorta)) == 1 && nrow(as.matrix(sortb)) == 1) {
        plot_data <- osj_regsl_plot(as.matrix(sorta[, -c(1:3)]), as.matrix(sortb[, -c(1:3)]), as.matrix(refa[, -c(1:3)]), as.matrix(refb[, -c(1:3)]))
        # Attach labels and alpha for Plotly rendering
        plot_data <- list(
            ref_x = plot_data[[1]],
            ref_y = plot_data[[2]],
            specimen_x = plot_data[[3]],
            specimen_y = plot_data[[4]],
            x_label = sorta[1, "element"],
            y_label = sortb[1, "element"],
            alphalevel = alphalevel
        )
    }

    # Transform numerical T/F to measurement names
    if (nrow(results) > 1) {
        measurements <- data.frame(results[, c(6:ncol(results))])
    } else {
        measurements <- data.frame(t(results[c(6:length(results))]))
    }

    # Build full name list (including fa) to identify which columns to drop
    all_names <- c(colnames(sorta[, -c(1:3)]), colnames(sortb[, -c(1:3)]))
    fa_cols <- which(all_names == "fa")
    measurements <- measurements[, -fa_cols, drop = FALSE]
    measurement_names <- all_names[all_names != "fa"]

    for (i in seq_len(ncol(measurements))) {
        measurements[measurements[, i] == 1, i] <- paste(measurement_names[i], " ", sep = "")
        measurements[measurements[, i] == 0, i] <- ""
    }

    measurements <- do.call(paste0, measurements[seq_len(ncol(measurements))])

    # Format data.frame to return
    results_formatted <- data.frame(
        cbind(
            x_id = sorta[results[, 1], "accession"],
            x_element = sorta[results[, 1], "element"],
            x_side = sorta[results[, 1], "side"],
            y_id = sortb[results[, 2], "accession"],
            y_element = sortb[results[, 2], "element"],
            y_side = sortb[results[, 2], "side"],
            measurements = measurements,
            n = results[, 4],
            r2 = round(results[, 5], digits = 4),
            p = round(results[, 3], digits = 4)
        ),
        result = NA
    )
    names(results_formatted)[names(results_formatted) == "r2"] <- "R\u00b2"

    rejected <- results_formatted[results_formatted$measurements == "", 1:6]
    results_formatted <- results_formatted[results_formatted$measurements != "", ]

    results_formatted[results_formatted$p > alphalevel, "result"] <- "Cannot Exclude"
    results_formatted[results_formatted$p <= alphalevel, "result"] <- "Excluded"

    t_time <- end_time(start_time)
    return(list(results_formatted, plot_data, t_time, rejected))
}
