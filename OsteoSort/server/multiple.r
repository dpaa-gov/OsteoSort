# --- Helper functions ---

# Clean column names for display (shared across all analysis types)
multiple_clean_display_cols <- function(df) {
    # Strip suffixes first
    names(df) <- sub("_[12]$", "", names(df))
    names(df) <- sub("^[xy]_", "", names(df))
    # Rename id columns to accession
    names(df)[names(df) == "id"] <- "accession"
    names(df)[names(df) == "sample"] <- "n"
    df
}

# Show a standard analysis error dialog
show_multiple_error <- function(msg = "There was an error with the input and/or reference data") {
    removeModal()
    shinyalert(
        title = "ERROR!", text = msg, type = "error",
        closeOnClickOutside = TRUE, showConfirmButton = TRUE, confirmButtonText = "Dismiss"
    )
}

# --- Reactive state ---

multiple_reference <- reactiveValues(multiple_reference = c("temp"))
multiple_reference_imported <- reactiveValues(multiple_reference_imported = data.frame())
multiple_elements <- reactiveValues(elements = c("temp"))
multiple_art_elements <- reactiveValues(df = c())
multiple_art_measurements_a <- reactiveValues(df = c())
multiple_art_measurements_b <- reactiveValues(df = c())
multiple_ML <- reactiveValues(multiple_ML = c("temp"))
multiple_MLB <- reactiveValues(multiple_ML = c("temp"))
multiple_MLA <- reactiveValues(multiple_ML = c("temp"))
uploaded_csv_cols <- reactiveValues(cols = c())
uploaded_csv_elements <- reactiveValues(elements = c())
uploaded_csv_sides <- reactiveValues(df = data.frame(element = character(), side = character()))

multiple_absolute_value <- reactiveValues(multiple_absolute_value = FALSE)
multiple_yeojohnson <- reactiveValues(multiple_yeojohnson = FALSE)
multiple_mean <- reactiveValues(multiple_mean = FALSE)
multiple_tails <- reactiveValues(multiple_tails = 2)
multiple_results_ready <- reactiveVal(FALSE)

# Flag to show/hide results panel
output$multiple_has_results <- reactive({
    multiple_results_ready()
})
outputOptions(output, "multiple_has_results", suspendWhenHidden = FALSE)

# --- UI renderers ---

output$resettableInput <- renderUI({
    input$clearFile1
    fileInput("file1", NULL, accept = c("text/csv", "text/comma-separated-values,text/plain", ".csv"))
})

observeEvent(input$clearFile1, {
    uploaded_csv_cols$cols <- c()
    uploaded_csv_elements$elements <- c()
    uploaded_csv_sides$df <- data.frame(element = character(), side = character())
    multiple_results_ready(FALSE)
    fileInput("file1", NULL, accept = c("text/csv", "text/comma-separated-values,text/plain", ".csv"))
})

# Store uploaded CSV column names, elements, and sides when file is selected
observeEvent(input$file1, {
    inFile <- input$file1
    if (!is.null(inFile) && file.size(inFile$datapath) > 1) {
        tempdata <- read.csv(inFile$datapath, header = TRUE, sep = ",", na.strings = c("", " ", "NA"), quote = "\"")
        uploaded_csv_cols$cols <- tolower(colnames(tempdata)[-(1:3)]) # skip accession, Side, Element
        # Only include rows with at least one non-NA measurement
        has_data <- apply(tempdata[, -(1:3), drop = FALSE], 1, function(row) any(!is.na(row)))
        valid_rows <- tempdata[has_data, ]
        uploaded_csv_elements$elements <- tolower(unique(valid_rows[[3]]))
        uploaded_csv_sides$df <- unique(data.frame(
            element = tolower(valid_rows[[3]]),
            side = valid_rows[[2]],
            stringsAsFactors = FALSE
        ))
    }
})

# Settings
output$multiple_absolute_value <- renderUI({
    checkboxInput("multiple_absolute_value", "Absolute D-value |a-b|", value = FALSE)
})
observeEvent(input$multiple_absolute_value, {
    multiple_absolute_value$multiple_absolute_value <- input$multiple_absolute_value
})

output$multiple_yeojohnson <- renderUI({
    checkboxInput("multiple_yeojohnson", "Yeojohnson transformation", value = FALSE)
})
observeEvent(input$multiple_yeojohnson, {
    multiple_yeojohnson$multiple_yeojohnson <- input$multiple_yeojohnson
})

output$multiple_mean <- renderUI({
    checkboxInput("multiple_mean", "Zero mean", value = FALSE)
})
observeEvent(input$multiple_mean, {
    multiple_mean$multiple_mean <- input$multiple_mean
})

output$multiple_tails <- renderUI({
    radioButtons("multiple_tails", "Tails", choices = list(1, 2), selected = 2, inline = TRUE)
})
observeEvent(input$multiple_tails, {
    multiple_tails$multiple_tails <- as.numeric(input$multiple_tails)
})

# Analysis type
output$multiple_analysis <- renderUI({
    selectInput("multiple_analysis", NULL, choices = c("pairmatch", "articulation", "regression"), selected = "pairmatch")
})

# Side selectors (filtered by uploaded CSV sides per element)
get_csv_sides <- function(element_name) {
    df <- uploaded_csv_sides$df
    if (nrow(df) == 0) {
        return(c(Left = "Left", Right = "Right"))
    }
    available <- unique(df$side[df$element == tolower(element_name)])
    if (length(available) == 0) available <- unique(df$side)
    setNames(available, available)
}
output$multiple_non_antimere_side <- renderUI({
    # Articulation has paired elements like "humerus-radius" — intersect sides from both
    pair <- input$multiple_element_non_antimere
    if (!is.null(pair) && grepl("-", pair)) {
        parts <- strsplit(pair, "-")[[1]]
        df <- uploaded_csv_sides$df
        if (nrow(df) > 0) {
            sides_a <- unique(df$side[df$element == tolower(parts[1])])
            sides_b <- unique(df$side[df$element == tolower(parts[2])])
            available <- intersect(sides_a, sides_b)
            if (length(available) > 0) {
                return(selectInput("multiple_non_antimere_side", "Side", choices = setNames(available, available)))
            }
        }
    }
    selectInput("multiple_non_antimere_side", "Side", choices = c(Left = "Left", Right = "Right"))
})
output$multiple_association_side_a <- renderUI({
    selectInput("multiple_association_side_a", "Side", choices = get_csv_sides(input$multiple_elements_association_a))
})
output$multiple_association_side_b <- renderUI({
    selectInput("multiple_association_side_b", "Side", choices = get_csv_sides(input$multiple_elements_association_b))
})

# Element selectors (filtered by uploaded CSV elements if available)
output$multiple_element_pair_match <- renderUI({
    choices <- multiple_elements$elements
    if (length(uploaded_csv_elements$elements) > 0) {
        choices <- choices[tolower(choices) %in% uploaded_csv_elements$elements]
    }
    selectInput("multiple_elements_pairmatch", NULL, choices = choices)
})

# Reference selector
observeEvent(input$multiple_reference, {
    multiple_reference$multiple_reference <- input$multiple_reference
})
output$multiple_reference <- renderUI({
    defaults <- c("DPAA White Male", "CMNH White Male", "SI-TERRY White Male", "UT White Male")
    all_refs <- reference_name_list$reference_name_list
    available_defaults <- all_refs[tolower(all_refs) %in% tolower(defaults)]
    selectizeInput(
        inputId = "multiple_reference",
        label = NULL,
        choices = all_refs,
        selected = available_defaults,
        multiple = TRUE,
        options = list(placeholder = "Select reference group(s)...")
    )
})

# --- Reference data cascade (elements, measurements) ---

observeEvent(input$multiple_reference, {
    req(length(input$multiple_reference) > 0)

    # Merge all selected reference groups
    ref_data <- dplyr::bind_rows(
        lapply(input$multiple_reference, function(g) reference_list$reference_list[[g]])
    )
    multiple_reference_imported$multiple_reference_imported <- ref_data
    multiple_reference$multiple_reference <- paste(input$multiple_reference, collapse = ", ")
    multiple_elements$elements <- tolower(unique(ref_data$element))

    # --- Articulation: determine valid element pairs from config ---
    art <- articulation_config$df
    art$Measurementa <- tolower(art$Measurementa)
    art$Measurementb <- tolower(art$Measurementb)
    ref_cols <- colnames(ref_data)
    multiple_art_elements$df <- NULL
    multiple_art_measurements_a$df <- NULL
    multiple_art_measurements_b$df <- NULL

    valid <- art$Measurementa %in% ref_cols & art$Measurementb %in% ref_cols
    valid_art <- art[valid, ]

    if (nrow(valid_art) > 0) {
        for (i in seq_len(nrow(valid_art))) {
            ma <- valid_art$Measurementa[i]
            mb <- valid_art$Measurementb[i]
            multiple_art_measurements_a$df <- c(multiple_art_measurements_a$df, ma)
            multiple_art_measurements_b$df <- c(multiple_art_measurements_b$df, mb)

            elem_a <- na.omit(unique(ref_data$element[!is.na(ref_data[[ma]])]))[1]
            elem_b <- na.omit(unique(ref_data$element[!is.na(ref_data[[mb]])]))[1]
            if (!is.na(elem_a) && !is.na(elem_b)) {
                label <- paste(elem_a, elem_b, sep = "-")
                n <- 0
                if (!is.null(multiple_art_elements$df)) {
                    while (label %in% multiple_art_elements$df) {
                        n <- n + 1
                        label <- paste(elem_a, elem_b, n + 1, sep = "-")
                    }
                }
                multiple_art_elements$df <- c(multiple_art_elements$df, label)
            }
        }
    }

    # --- UI outputs for element/measurement selection ---

    output$multiple_element_non_antimere <- renderUI({
        choices <- multiple_art_elements$df
        if (length(uploaded_csv_elements$elements) > 0 && length(choices) > 0) {
            # Filter to only pairs where both elements exist in CSV
            choices <- choices[sapply(choices, function(pair) {
                # Strip trailing "-N" dedup suffix if present
                parts <- strsplit(pair, "-")[[1]]
                if (length(parts) >= 2) {
                    elem_a <- tolower(parts[1])
                    elem_b <- tolower(parts[2])
                    elem_a %in% uploaded_csv_elements$elements & elem_b %in% uploaded_csv_elements$elements
                } else {
                    FALSE
                }
            })]
        }
        selectInput("multiple_element_non_antimere", "Elements", choices = choices)
    })

    output$multiple_measurements_non_antimere_a <- renderUI({
        idx <- which(multiple_art_elements$df == input$multiple_element_non_antimere)
        tempa <- unique(multiple_art_measurements_a$df[idx])
        selectizeInput("multiple_measurements_non_antimere_a", "", choices = tempa, multiple = TRUE, selected = tempa)
    })
    output$multiple_measurements_non_antimere_b <- renderUI({
        idx <- which(multiple_art_elements$df == input$multiple_element_non_antimere)
        tempb <- unique(multiple_art_measurements_b$df[idx])
        selectizeInput("multiple_measurements_non_antimere_b", "", choices = tempb, multiple = TRUE, selected = tempb)
    })

    output$multiple_measurement_antimere <- renderUI({
        selectizeInput("multiple_measurement_antimere", NULL, choices = multiple_ML$multiple_ML, multiple = TRUE, selected = multiple_ML$multiple_ML)
    })
})

# --- Regression element selectors (outside observer, reactive to both reference and CSV) ---

output$multiple_elements_association_a <- renderUI({
    reg_valid <- multiple_elements$elements[tolower(multiple_elements$elements) %in% tolower(regression_bones$bones)]
    if (length(uploaded_csv_elements$elements) > 0) {
        reg_valid <- reg_valid[tolower(reg_valid) %in% uploaded_csv_elements$elements]
    }
    selectInput("multiple_elements_association_a", "Independent", choices = reg_valid)
})

output$multiple_elements_association_b <- renderUI({
    reg_valid <- multiple_elements$elements[tolower(multiple_elements$elements) %in% tolower(regression_bones$bones)]
    if (length(uploaded_csv_elements$elements) > 0) {
        reg_valid <- reg_valid[tolower(reg_valid) %in% uploaded_csv_elements$elements]
    }
    available <- reg_valid[reg_valid != input$multiple_elements_association_a]
    selectInput("multiple_elements_association_b", "Dependent", choices = available)
})

output$multiple_measurement_association_a <- renderUI({
    selectizeInput("multiple_measurement_association_a", "", choices = multiple_MLA$multiple_ML, multiple = TRUE, selected = multiple_MLA$multiple_ML)
})
output$multiple_measurement_association_b <- renderUI({
    selectizeInput("multiple_measurement_association_b", "", choices = multiple_MLB$multiple_ML, multiple = TRUE, selected = multiple_MLB$multiple_ML)
})

# --- Update measurement lists when element selection changes ---

observeEvent(input$multiple_elements_pairmatch, {
    ref_meas <- get_available_measurements(multiple_reference_imported$multiple_reference_imported, input$multiple_elements_pairmatch)
    if (length(uploaded_csv_cols$cols) > 0) {
        ref_meas <- ref_meas[tolower(ref_meas) %in% uploaded_csv_cols$cols]
    }
    multiple_ML$multiple_ML <- ref_meas
})
observeEvent(input$multiple_elements_association_a, {
    ref_meas <- get_available_measurements(multiple_reference_imported$multiple_reference_imported, input$multiple_elements_association_a)
    if (length(uploaded_csv_cols$cols) > 0) {
        ref_meas <- ref_meas[tolower(ref_meas) %in% uploaded_csv_cols$cols]
    }
    multiple_MLA$multiple_ML <- ref_meas
})
observeEvent(input$multiple_elements_association_b, {
    ref_meas <- get_available_measurements(multiple_reference_imported$multiple_reference_imported, input$multiple_elements_association_b)
    if (length(uploaded_csv_cols$cols) > 0) {
        ref_meas <- ref_meas[tolower(ref_meas) %in% uploaded_csv_cols$cols]
    }
    multiple_MLB$multiple_ML <- ref_meas
})

# --- Analysis execution functions ---

read_upload_csv <- function(input) {
    inFile <- input$file1
    if (is.null(inFile) || !file.size(inFile$datapath) > 1) {
        return(NULL)
    }
    tempdata1 <- read.csv(inFile$datapath, header = TRUE, sep = ",", na.strings = c("", " ", "NA"), quote = "\"")
    # Lowercase all column names to match DB reference columns
    colnames(tempdata1) <- tolower(colnames(tempdata1))
    # Convert measurement columns to numeric (skip first 3: accession, side, element)
    tempdataa <- tempdata1[, 1:3]
    tempdatab <- lapply(tempdata1[, -(1:3)], function(x) as.numeric(as.character(x)))
    as.data.frame(c(tempdataa, tempdatab))
}

multiple_run_pair_match <- function(tempdata1, ref, measurements, alphalevel, settings) {
    pm.d1 <- pm.input(sort = tempdata1, bone = settings$bone, measurements = measurements, ref = ref)
    if (is.null(pm.d1)) {
        return(NULL)
    }
    ttest(
        sorta = pm.d1[[3]], sortb = pm.d1[[4]],
        refa = pm.d1[[1]], refb = pm.d1[[2]],
        alphalevel = alphalevel,
        reference = settings$reference,
        absolute = settings$absolute,
        zmean = settings$zmean,
        yeojohnson = settings$yeojohnson,
        tails = settings$tails
    )
}

multiple_run_articulation <- function(tempdata1, ref, art_elem, art_meas_a, art_meas_b, side, element, measa, measb, alphalevel, settings) {
    tempdata1$element <- tolower(tempdata1$element)
    bone_parts <- strsplit(element, split = "-")[[1]]
    sorta <- tempdata1[tempdata1$element == bone_parts[1], ]
    sortb <- tempdata1[tempdata1$element == bone_parts[2], ]

    art.d1 <- art.input(
        side = side, ref = ref,
        sorta = sorta, sortb = sortb,
        bonea = bone_parts[1], boneb = bone_parts[2],
        measurementsa = measa, measurementsb = measb
    )
    if (is.null(art.d1)) {
        return(NULL)
    }
    ttest(
        sorta = art.d1[[3]], sortb = art.d1[[4]],
        refa = art.d1[[1]], refb = art.d1[[2]],
        alphalevel = alphalevel,
        reference = settings$reference,
        absolute = settings$absolute,
        zmean = settings$zmean,
        yeojohnson = settings$yeojohnson,
        tails = settings$tails
    )
}

multiple_run_osr <- function(tempdata1, ref, sidea, sideb, bonea, boneb, measa, measb, alphalevel, settings) {
    tempdata1$element <- tolower(tempdata1$element)
    sorta <- tempdata1[tempdata1$element == bonea, ]
    sortb <- tempdata1[tempdata1$element == boneb, ]

    reg.d1 <- reg.input(
        sorta = sorta, sortb = sortb,
        sidea = sidea, sideb = sideb,
        bonea = bonea, boneb = boneb,
        measurementsa = measa, measurementsb = measb,
        ref = ref
    )
    if (is.null(reg.d1)) {
        return(NULL)
    }
    reg.test(
        refa = reg.d1[[1]], refb = reg.d1[[2]],
        sorta = reg.d1[[3]], sortb = reg.d1[[4]],
        alphalevel = alphalevel,
        reference = settings$reference
    )
}

# --- Process button handler ---

observeEvent(input$pro, {
    showModal(modalDialog(
        title = "Processing...",
        easyClose = FALSE,
        footer = NULL,
        tags$div(
            tags$div(
                class = "progress", style = "margin-bottom: 10px;",
                tags$div(
                    id = "multiple-progress-bar", class = "progress-bar progress-bar-striped active",
                    role = "progressbar", style = "width: 0%;",
                    `aria-valuenow` = "0", `aria-valuemin` = "0", `aria-valuemax` = "100"
                )
            ),
            tags$p(id = "multiple-progress-text", style = "text-align: center; margin: 0;", "Starting...")
        )
    ))
    tryCatch(
        {
            # Read CSV upload
            tempdata1 <- read_upload_csv(input)
            if (is.null(tempdata1)) {
                show_multiple_error()
                return(NULL)
            }

            # Common settings
            alphalevel <- input$multiple_common_alpha_level
            settings <- list(
                reference = multiple_reference$multiple_reference,
                absolute = multiple_absolute_value$multiple_absolute_value,
                zmean = multiple_mean$multiple_mean,
                yeojohnson = multiple_yeojohnson$multiple_yeojohnson,
                tails = multiple_tails$multiple_tails
            )
            ref <- multiple_reference_imported$multiple_reference_imported
            d2 <- NULL

            session$sendCustomMessage("updateProgress", list(id = "multiple", pct = 33, text = "Sorting data..."))

            if (input$multiple_analysis == "articulation") {
                if (is.null(input$multiple_measurements_non_antimere_a) || is.null(input$multiple_measurements_non_antimere_b)) {
                    show_multiple_error("The measurement data is missing")
                    return(NULL)
                }
                d2 <- multiple_run_articulation(
                    tempdata1, ref,
                    multiple_art_elements$df, multiple_art_measurements_a$df, multiple_art_measurements_b$df,
                    input$multiple_non_antimere_side, input$multiple_element_non_antimere,
                    input$multiple_measurements_non_antimere_a, input$multiple_measurements_non_antimere_b,
                    alphalevel, settings
                )
            } else if (input$multiple_analysis == "pairmatch") {
                if (is.null(input$multiple_measurement_antimere)) {
                    show_multiple_error("The measurement data is missing")
                    return(NULL)
                }
                settings$bone <- input$multiple_elements_pairmatch
                d2 <- multiple_run_pair_match(tempdata1, ref, input$multiple_measurement_antimere, alphalevel, settings)
            } else if (input$multiple_analysis == "regression") {
                if (is.null(input$multiple_measurement_association_a) || is.null(input$multiple_measurement_association_b)) {
                    show_multiple_error("The measurement data is missing")
                    return(NULL)
                }
                d2 <- multiple_run_osr(
                    tempdata1, ref,
                    input$multiple_association_side_a, input$multiple_association_side_b,
                    input$multiple_elements_association_a, input$multiple_elements_association_b,
                    input$multiple_measurement_association_a, input$multiple_measurement_association_b,
                    alphalevel, settings
                )
            }

            if (is.null(d2)) {
                show_multiple_error()
                return(NULL)
            }

            session$sendCustomMessage("updateProgress", list(id = "multiple", pct = 66, text = "Running comparisons..."))

            # ttest returns: list(results_formatted, plot_data, t_time, rejected)
            results_formatted <- d2[[1]]
            t_time <- d2[[3]]
            rejected <- d2[[4]]

            not_excluded <- results_formatted[results_formatted$result == "Cannot Exclude", ]
            excluded <- results_formatted[results_formatted$result == "Excluded", ]

            if (!all(is.na(not_excluded)) || !all(is.na(excluded))) {
                ll <- nrow(not_excluded) + nrow(excluded)
                nmatch <- nrow(not_excluded)
                samplesize <- length(unique(c(not_excluded[, 1], not_excluded[, 4], excluded[, 1], excluded[, 4])))
                exclusion_pct <- paste0(round((ll - nmatch) / ll, digits = 3) * 100, "%")
                summary_df <- data.frame(
                    Metric = c("Completed in", "Comparisons", "Specimens", "Potential matches", "Exclusions", "Rejected"),
                    Value = c(paste(t_time, "seconds"), ll, samplesize, nmatch, paste(ll - nmatch, paste0("(", exclusion_pct, ")")), nrow(rejected))
                )
                output$multiple_contents <- renderTable(
                    {
                        summary_df
                    },
                    colnames = FALSE,
                    striped = TRUE,
                    bordered = TRUE,
                    width = "100%"
                )

                # P-value histogram
                all_pvals <- as.numeric(results_formatted$p)
                all_results <- results_formatted$result
                output$multiple_plot <- plotly::renderPlotly({
                    df <- data.frame(p_value = all_pvals, result = all_results)
                    plotly::plot_ly(df,
                        x = ~p_value, color = ~result,
                        colors = c("Cannot Exclude" = "#3d5a73", "Excluded" = "#cc4444"),
                        type = "histogram", nbinsx = 30, opacity = 0.8
                    ) %>%
                        plotly::layout(
                            shapes = list(list(
                                type = "line", x0 = alphalevel, x1 = alphalevel,
                                y0 = 0, y1 = 1, yref = "paper",
                                line = list(color = "#d4a843", dash = "dash", width = 2)
                            )),
                            xaxis = list(title = "p-value", range = c(0, 1)),
                            yaxis = list(title = "Count"),
                            barmode = "stack",
                            legend = list(orientation = "h", x = 0.5, xanchor = "center", y = 1.1),
                            margin = list(t = 30, b = 40, l = 40, r = 10),
                            plot_bgcolor = "#ffffff",
                            paper_bgcolor = "#ffffff"
                        )
                })
            }

            # Render DT tables with CSV download buttons
            render_dt <- function(df, filename = "results") {
                DT::datatable(multiple_clean_display_cols(df),
                    selection = "none", rownames = FALSE,
                    extensions = "Buttons",
                    options = list(
                        dom = "Bfrtip",
                        buttons = list(list(extend = "csv", text = "Download", filename = filename)),
                        lengthMenu = c(10, 25, 50), pageLength = 10,
                        search = list(regex = TRUE, caseInsensitive = FALSE)
                    )
                )
            }

            output$table <- DT::renderDataTable(
                {
                    render_dt(not_excluded, "not_excluded")
                },
                server = FALSE
            )
            output$tablen <- DT::renderDataTable(
                {
                    render_dt(excluded, "excluded")
                },
                server = FALSE
            )
            output$tablenr <- DT::renderDataTable(
                {
                    render_dt(rejected, "rejected")
                },
                server = FALSE
            )

            multiple_results_ready(TRUE)
            session$sendCustomMessage("updateProgress", list(id = "multiple", pct = 100, text = "Completed!"))
            Sys.sleep(0.3)
            removeModal()
        },
        error = function(e) {
            removeModal()
            show_multiple_error(paste("An error occurred:", e$message))
        }
    )
})
