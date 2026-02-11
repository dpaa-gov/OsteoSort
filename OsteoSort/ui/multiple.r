multiple_osteometric_sorting <- tabPanel("Multiple",
    icon = icon("gears", lib = "font-awesome"),
    sidebarLayout(
        sidebarPanel(
            tags$div(class = "sidebar-section-label", "REFERENCE"),
            uiOutput("multiple_reference"),
            tags$div(class = "sidebar-section-label", "ANALYSIS"),
            uiOutput("multiple_analysis"),
            tags$div(class = "sidebar-section-label", "UPLOAD"),
            uiOutput("resettableInput"),
            conditionalPanel(
                condition = "input.multiple_analysis == 'pairmatch'",
                tags$div(class = "sidebar-section-label", "ELEMENT"),
                uiOutput("multiple_element_pair_match"),
                tags$div(class = "sidebar-section-label", "MEASUREMENTS"),
                uiOutput("multiple_measurement_antimere")
            ),
            conditionalPanel(
                condition = "input.multiple_analysis == 'articulation'",
                uiOutput("multiple_non_antimere_side"),
                uiOutput("multiple_element_non_antimere"),
                fluidRow(
                    column(
                        6,
                        uiOutput("multiple_measurements_non_antimere_a")
                    ),
                    column(
                        6,
                        uiOutput("multiple_measurements_non_antimere_b")
                    )
                )
            ),
            conditionalPanel(
                condition = "input.multiple_analysis == 'regression'",
                fluidRow(
                    column(
                        6,
                        uiOutput("multiple_association_side_a"),
                        uiOutput("multiple_elements_association_a"),
                        uiOutput("multiple_measurement_association_a")
                    ),
                    column(
                        6,
                        uiOutput("multiple_association_side_b"),
                        uiOutput("multiple_elements_association_b"),
                        uiOutput("multiple_measurement_association_b")
                    )
                )
            ),
            # Settings inline (moved from modal)
            tags$div(class = "sidebar-section-label", "SETTINGS"),
            conditionalPanel(
                condition = "input.multiple_analysis != 'regression'",
                uiOutput("multiple_absolute_value"),
                uiOutput("multiple_yeojohnson"),
                uiOutput("multiple_mean"),
                uiOutput("multiple_tails")
            ),
            sliderInput(
                inputId = "multiple_common_alpha_level", label = "Alpha level",
                min = 0.05, max = 0.5, value = 0.1, step = 0.05
            ),
            hr(),
            fluidRow(
                column(
                    6,
                    actionButton("pro", "Process ", icon = icon("gear"))
                ),
                column(
                    6,
                    actionButton("clearFile1", "Clear   ", icon = icon("rectangle-xmark"))
                )
            ),
            width = 3
        ),
        mainPanel(
            conditionalPanel(
                condition = "output.multiple_has_results",
                tags$div(
                    style = "border: 1px solid #ccc; padding: 15px; border-radius: 4px;",
                    tags$div(class = "main-section-label", "Summary"),
                    fluidRow(
                        column(4, tableOutput("multiple_contents")),
                        column(8, plotly::plotlyOutput("multiple_plot", height = "250px"))
                    )
                ),
                br(),
                tags$div(
                    style = "border: 1px solid #ccc; padding: 15px; border-radius: 4px;",
                    tags$div(class = "main-section-label", "Results"),
                    tabsetPanel(
                        id = "tabSelected",
                        tabPanel(
                            "Not excluded",
                            br(),
                            DT::dataTableOutput("table")
                        ),
                        tabPanel(
                            "Excluded",
                            br(),
                            DT::dataTableOutput("tablen")
                        ),
                        tabPanel(
                            "Rejected",
                            br(),
                            DT::dataTableOutput("tablenr")
                        )
                    )
                )
            ),
            width = 9
        )
    )
)
