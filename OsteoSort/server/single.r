# --- Helper functions ---

# Capitalize first letter for display labels (e.g., "fem_04" -> "Fem_04")
cap_first <- function(x) paste0(toupper(substr(x, 1, 1)), substr(x, 2, nchar(x)))

# Create a label with tooltip from DB full_name
meas_label <- function(code) {
    tooltip <- measurement_tooltips[tolower(code)]
    if (is.na(tooltip)) {
        return(cap_first(code))
    }
    tags$span(`data-tooltip` = tooltip, style = "cursor: help;", cap_first(code))
}

# Get available (non-all-NA) measurement columns for an element in reference data
get_available_measurements <- function(ref, element) {
    meta_cols <- c("accession", "side", "element")
    subset <- ref[tolower(ref$element) == tolower(element), ]
    meas <- subset[, !names(subset) %in% meta_cols, drop = FALSE]
    names(which(colSums(is.na(meas)) < nrow(meas)))
}

# Show a standard analysis error dialog
show_analysis_error <- function() {
    removeModal()
    shinyalert(
        title = "ERROR!",
        text = "There was an error with the input and/or reference data",
        type = "error", closeOnClickOutside = TRUE,
        showConfirmButton = TRUE, confirmButtonText = "Dismiss"
    )
}

# --- Reactive state (only what truly needs to persist across observers) ---

combined_ref <- reactiveValues(df = data.frame())
elements <- reactiveValues(elements = c())
art_elements <- reactiveValues(df = c())
art_measurements_a <- reactiveValues(df = c())
art_measurements_b <- reactiveValues(df = c())
single_ML <- reactiveValues(vals = c())
single_MLA <- reactiveValues(vals = c())
single_MLB <- reactiveValues(vals = c())

# --- Reference selection (server-rendered for multi-select) ---

output$single_reference <- renderUI({
    defaults <- c("DPAA White Male", "CMNH White Male", "SI-TERRY White Male", "UT White Male")
    all_refs <- reference_name_list$reference_name_list
    available_defaults <- all_refs[tolower(all_refs) %in% tolower(defaults)]
    selectizeInput(
        inputId = "single_reference",
        label = NULL,
        choices = reference_name_list$reference_name_list,
        selected = available_defaults,
        multiple = TRUE,
        options = list(placeholder = "Select reference group(s)...")
    )
})

# --- Analysis type (server-rendered) ---

output$single_analysis <- renderUI({
    selectInput(
        inputId = "single_analysis",
        label = NULL,
        choices = c("pairmatch" = "pairmatch", "articulation" = "articulation", "regression" = "regression"),
        selected = "pairmatch"
    )
})

# --- When reference groups change, combine and update all downstream UI ---

observeEvent(input$single_reference, {
    req(length(input$single_reference) > 0)

    # Merge all selected reference groups
    ref_data <- dplyr::bind_rows(
        lapply(input$single_reference, function(g) reference_list$reference_list[[g]])
    )
    combined_ref$df <- ref_data
    elements$elements <- unique(ref_data$element)

    # --- Articulation: determine valid element pairs from config ---
    art <- articulation_config$df
    # Lowercase config measurement names to match DB column names (PostgreSQL returns lowercase)
    art$Measurementa <- tolower(art$Measurementa)
    art$Measurementb <- tolower(art$Measurementb)
    ref_cols <- colnames(ref_data)
    art_elements$df <- NULL
    art_measurements_a$df <- NULL
    art_measurements_b$df <- NULL

    valid <- art$Measurementa %in% ref_cols & art$Measurementb %in% ref_cols
    valid_art <- art[valid, ]

    if (nrow(valid_art) > 0) {
        for (i in seq_len(nrow(valid_art))) {
            ma <- valid_art$Measurementa[i]
            mb <- valid_art$Measurementb[i]
            art_measurements_a$df <- c(art_measurements_a$df, ma)
            art_measurements_b$df <- c(art_measurements_b$df, mb)

            # Determine which elements these measurements belong to
            elem_a <- na.omit(unique(ref_data$element[!is.na(ref_data[[ma]])]))[1]
            elem_b <- na.omit(unique(ref_data$element[!is.na(ref_data[[mb]])]))[1]
            if (!is.na(elem_a) && !is.na(elem_b)) {
                label <- paste(elem_a, elem_b, sep = "-")
                # Deduplicate labels using while loop
                n <- 0
                if (!is.null(art_elements$df)) {
                    while (label %in% art_elements$df) {
                        n <- n + 1
                        label <- paste(elem_a, elem_b, n + 1, sep = "-")
                    }
                }
                art_elements$df <- c(art_elements$df, label)
            }
        }
    }

    # --- UI outputs for element selection ---

    output$single_element_osr <- renderUI({
        selectInput(inputId = "single_element_osr", label = "Elements", choices = art_elements$df)
    })

    output$single_element_pair_match <- renderUI({
        selectInput(inputId = "single_elements_pairmatch", label = NULL, choices = elements$elements)
    })

    # --- Regression: filter elements to regression-valid bones ---
    reg_valid <- elements$elements[tolower(elements$elements) %in% tolower(regression_bones$bones)]

    output$single_elements_association_a <- renderUI({
        selectInput(inputId = "single_elements_association_a", label = "Independent", choices = reg_valid)
    })

    # --- Dynamic measurement input fields ---

    output$list_numeric_inputs_single_left <- renderUI({
        lapply(single_ML$vals, function(i) {
            numericInput(paste0(i, "_left"), label = meas_label(i), value = "", min = 0, max = 999, step = 0.01)
        })
    })

    output$list_numeric_inputs_single_right <- renderUI({
        lapply(single_ML$vals, function(i) {
            numericInput(paste0(i, "_right"), label = meas_label(i), value = "", min = 0, max = 999, step = 0.01)
        })
    })

    output$list_numeric_inputs_single_A <- renderUI({
        lapply(single_MLA$vals, function(i) {
            numericInput(paste0(i, "_A"), label = meas_label(i), value = "", min = 0, max = 999, step = 0.01)
        })
    })

    output$list_numeric_inputs_single_B <- renderUI({
        lapply(single_MLB$vals, function(i) {
            numericInput(paste0(i, "_B"), label = meas_label(i), value = "", min = 0, max = 999, step = 0.01)
        })
    })

    output$single_measurement_osr_a <- renderUI({
        lapply(art_measurements_a$df[which(art_elements$df == input$single_element_osr)], function(i) {
            numericInput(paste0(i, "_art_a"), label = meas_label(i), value = "", min = 0, max = 999, step = 0.01)
        })
    })

    output$single_measurement_osr_b <- renderUI({
        lapply(art_measurements_b$df[which(art_elements$df == input$single_element_osr)], function(i) {
            numericInput(paste0(i, "_art_b"), label = meas_label(i), value = "", min = 0, max = 999, step = 0.01)
        })
    })

    # --- Update measurement lists when element selection changes ---

    observeEvent(input$single_elements_pairmatch, {
        single_ML$vals <- get_available_measurements(combined_ref$df, input$single_elements_pairmatch)
    })

    observeEvent(input$single_elements_association_a, {
        single_MLA$vals <- get_available_measurements(combined_ref$df, input$single_elements_association_a)
    })

    observeEvent(input$single_elements_association_b, {
        single_MLB$vals <- get_available_measurements(combined_ref$df, input$single_elements_association_b)
    })
})

# Dependent cannot be same bone as independent (moved outside to avoid observer stacking)
observeEvent(input$single_elements_association_a, {
    reg_valid <- elements$elements[tolower(elements$elements) %in% tolower(regression_bones$bones)]
    available <- reg_valid[reg_valid != input$single_elements_association_a]
    output$single_elements_association_b <- renderUI({
        selectInput(inputId = "single_elements_association_b", label = "Dependent", choices = available)
    })
})

# --- Analysis execution ---

run_pair_match <- function(ref, measurements, input) {
    input_left <- sapply(measurements, function(i) input[[paste0(i, "_left")]])
    input_right <- sapply(measurements, function(i) input[[paste0(i, "_right")]])

    input_left <- t(data.frame(input_left))
    colnames(input_left) <- measurements
    input_right <- t(data.frame(input_right))
    colnames(input_right) <- measurements

    # Check at least one pair is present
    has_pair <- FALSE
    for (x in seq_along(input_left)) {
        if (!is.na(input_left[x]) && !is.na(input_right[x])) {
            has_pair <- TRUE
            break
        }
    }
    if (!has_pair) {
        return(NULL)
    }

    sortleft <- data.frame(accession = "X", side = "left", element = tolower(input$single_elements_pairmatch), input_left)
    sortright <- data.frame(accession = "Y", side = "right", element = tolower(input$single_elements_pairmatch), input_right)

    pm.d1 <- pm.input(sort = rbind(sortleft, sortright), bone = input$single_elements_pairmatch, measurements = measurements, ref = ref)
    if (is.null(pm.d1)) {
        return(NULL)
    }

    d2 <- ttest(
        sorta = pm.d1[[3]], sortb = pm.d1[[4]],
        refa = pm.d1[[1]], refb = pm.d1[[2]],
        alphalevel = input$common_alpha_level,
        reference = paste(input$single_reference, collapse = ", "),
        absolute = input$single_absolute_value,
        zmean = input$single_mean,
        yeojohnson = input$single_yeojohnson,
        tails = as.numeric(input$single_tails)
    )
    return(d2)
}

run_articulation <- function(ref, art_elem, art_meas_a, art_meas_b, input) {
    temp1 <- which(art_elem == input$single_element_osr)
    tempa <- unique(art_meas_a[temp1])
    tempb <- unique(art_meas_b[temp1])

    input_a <- sapply(tempa, function(i) input[[paste0(i, "_art_a")]])
    input_b <- sapply(tempb, function(i) input[[paste0(i, "_art_b")]])

    input_a <- t(data.frame(input_a))
    colnames(input_a) <- tempa
    input_b <- t(data.frame(input_b))
    colnames(input_b) <- tempb

    if (is.na(input_a[1]) || is.na(input_b[1])) {
        return(NULL)
    }

    bone_parts <- strsplit(input$single_element_osr, split = "-")[[1]]
    sorta <- data.frame(accession = "X", side = tolower(input$single_osr_side), element = tolower(bone_parts[1]), input_a)
    sortb <- data.frame(accession = "Y", side = tolower(input$single_osr_side), element = tolower(bone_parts[2]), input_b)

    art.d1 <- art.input(
        side = tolower(input$single_osr_side), ref = ref,
        sorta = sorta, sortb = sortb,
        bonea = tolower(bone_parts[1]), boneb = tolower(bone_parts[2]),
        measurementsa = tempa, measurementsb = tempb
    )
    if (is.null(art.d1)) {
        return(NULL)
    }

    d2 <- ttest(
        sorta = art.d1[[3]], sortb = art.d1[[4]],
        refa = art.d1[[1]], refb = art.d1[[2]],
        alphalevel = input$common_alpha_level,
        reference = paste(input$single_reference, collapse = ", "),
        absolute = input$single_absolute_value,
        zmean = input$single_mean,
        yeojohnson = input$single_yeojohnson,
        tails = as.numeric(input$single_tails)
    )
    return(d2)
}

run_osr <- function(ref, meas_a, meas_b, input) {
    input_A <- sapply(meas_a, function(i) input[[paste0(i, "_A")]])
    input_B <- sapply(meas_b, function(i) input[[paste0(i, "_B")]])

    input_A <- t(data.frame(input_A))
    colnames(input_A) <- meas_a
    input_B <- t(data.frame(input_B))
    colnames(input_B) <- meas_b

    if (all(is.na(input_A)) || all(is.na(input_B))) {
        return(NULL)
    }

    sorta <- data.frame(accession = "X", side = tolower(input$single_association_side_a), element = tolower(input$single_elements_association_a), input_A)
    sortb <- data.frame(accession = "Y", side = tolower(input$single_association_side_b), element = tolower(input$single_elements_association_b), input_B)

    reg.d1 <- reg.input(
        sorta = sorta, sortb = sortb,
        sidea = tolower(input$single_association_side_a),
        sideb = tolower(input$single_association_side_b),
        bonea = tolower(input$single_elements_association_a),
        boneb = tolower(input$single_elements_association_b),
        measurementsa = meas_a, measurementsb = meas_b,
        ref = ref
    )
    if (is.null(reg.d1)) {
        return(NULL)
    }

    d2 <- reg.test(
        refa = reg.d1[[1]], refb = reg.d1[[2]],
        sorta = reg.d1[[3]], sortb = reg.d1[[4]],
        alphalevel = input$common_alpha_level,
        reference = paste(input$single_reference, collapse = ", ")
    )
    return(d2)
}

# --- Process button handler ---

# Reactive storage for results (used by CSV download)
analysis_results <- reactiveValues(df = NULL, plot_data = NULL, analysis_type = NULL)

# Flag to show/hide results panel
output$single_has_results <- reactive({
    !is.null(analysis_results$df)
})
outputOptions(output, "single_has_results", suspendWhenHidden = FALSE)

observeEvent(input$proc, {
    showModal(modalDialog(
        title = "Processing...",
        easyClose = FALSE,
        footer = NULL,
        tags$div(
            tags$div(
                class = "progress", style = "margin-bottom: 10px;",
                tags$div(
                    id = "single-progress-bar", class = "progress-bar progress-bar-striped active",
                    role = "progressbar", style = "width: 0%;",
                    `aria-valuenow` = "0", `aria-valuemin` = "0", `aria-valuemax` = "100"
                )
            ),
            tags$p(id = "single-progress-text", style = "text-align: center; margin: 0;", "Starting...")
        )
    ))
    tryCatch(
        {
            d2 <- NULL
            current_analysis <- input$single_analysis

            if (current_analysis == "articulation") {
                session$sendCustomMessage("updateProgress", list(id = "single", pct = 33, text = "Sorting data..."))
                d2 <- run_articulation(combined_ref$df, art_elements$df, art_measurements_a$df, art_measurements_b$df, input)
            } else if (current_analysis == "pairmatch") {
                session$sendCustomMessage("updateProgress", list(id = "single", pct = 33, text = "Sorting data..."))
                d2 <- run_pair_match(combined_ref$df, single_ML$vals, input)
            } else if (current_analysis == "regression") {
                session$sendCustomMessage("updateProgress", list(id = "single", pct = 33, text = "Sorting data..."))
                d2 <- run_osr(combined_ref$df, single_MLA$vals, single_MLB$vals, input)
            }

            if (is.null(d2)) {
                show_analysis_error()
                return(NULL)
            }

            session$sendCustomMessage("updateProgress", list(id = "single", pct = 66, text = "Running comparison..."))

            # New return format: list(results_formatted, plot_data, t_time, rejected)
            results_formatted <- d2[[1]]
            plot_data <- d2[[2]]

            # Store for CSV download
            analysis_results$df <- results_formatted
            analysis_results$plot_data <- plot_data
            analysis_results$analysis_type <- current_analysis

            # Render results table (strip _1/_2 suffixes for clean headers)
            # NOTE: Apply same names(df) <- sub("_[12]$", "", names(df)) pattern in multiple.r
            output$table2 <- renderTable(
                {
                    display_df <- results_formatted[, !names(results_formatted) %in% c("id_1", "id_2", "x_id", "y_id"), drop = FALSE]
                    names(display_df) <- sub("_[12]$", "", names(display_df)) # element_1 -> element
                    names(display_df) <- sub("^[xy]_", "", names(display_df)) # x_element -> element
                    display_df
                },
                striped = TRUE,
                bordered = TRUE,
                hover = TRUE,
                width = "100%"
            )

            # Render Plotly plot (only for single specimen comparisons)
            if (!is.null(plot_data)) {
                if (current_analysis == "regression") {
                    # Scatter plot with OLS prediction intervals
                    output$single_plot <- renderPlotly({
                        d <- data.frame(x = plot_data$ref_x, y = plot_data$ref_y)
                        OLS <- lm(y ~ x, data = d)
                        pm1 <- predict(OLS, interval = "prediction", level = 1 - plot_data$alphalevel)
                        d$fit <- pm1[, 1]
                        d$lwr <- pm1[, 2]
                        d$upr <- pm1[, 3]
                        d <- d[order(d$x), ]

                        plot_ly() %>%
                            add_markers(
                                data = d, x = ~x, y = ~y, marker = list(color = "grey", size = 6),
                                name = "Reference"
                            ) %>%
                            add_lines(
                                data = d, x = ~x, y = ~fit, line = list(color = "#d4a843", dash = "dash"),
                                name = "OLS"
                            ) %>%
                            add_lines(
                                data = d, x = ~x, y = ~lwr, line = list(color = "black", dash = "dash"),
                                name = "Lower PI"
                            ) %>%
                            add_lines(
                                data = d, x = ~x, y = ~upr, line = list(color = "black", dash = "dash"),
                                name = "Upper PI"
                            ) %>%
                            add_markers(
                                x = plot_data$specimen_x, y = plot_data$specimen_y,
                                marker = list(color = "#d4a843", size = 10),
                                name = "Specimen"
                            ) %>%
                            layout(
                                xaxis = list(title = cap_first(plot_data$x_label)),
                                yaxis = list(title = cap_first(plot_data$y_label)),
                                showlegend = FALSE,
                                plot_bgcolor = "#ffffff",
                                paper_bgcolor = "#ffffff"
                            )
                    })
                } else {
                    # Histogram with vertical specimen line (pairmatch / articulation)
                    output$single_plot <- renderPlotly({
                        ref_dist <- plot_data[1:(nrow(plot_data) - 1), ]
                        specimen_val <- plot_data[nrow(plot_data), ]

                        plot_ly() %>%
                            add_histogram(
                                x = ref_dist, marker = list(color = "#3d5a73", line = list(color = "grey", width = 1)),
                                name = "Reference"
                            ) %>%
                            layout(
                                shapes = list(list(
                                    type = "line", x0 = specimen_val, x1 = specimen_val,
                                    y0 = 0, y1 = 1, yref = "paper",
                                    line = list(color = "#d4a843", dash = "dash", width = 2)
                                )),
                                xaxis = list(title = ""),
                                yaxis = list(title = ""),
                                showlegend = FALSE,
                                plot_bgcolor = "#ffffff",
                                paper_bgcolor = "#ffffff"
                            )
                    })
                }
            }


            session$sendCustomMessage("updateProgress", list(id = "single", pct = 100, text = "Completed!"))
            Sys.sleep(0.3)
            removeModal()
        },
        error = function(e) {
            removeModal()
            show_analysis_error()
        }
    )
})
