single_osteometric_sorting <- tabPanel("Single",
    icon = icon("gear", lib = "font-awesome"),
    sidebarLayout(
        sidebarPanel(
            tags$div(class = "sidebar-section-label", "REFERENCE"),
            uiOutput("single_reference"),
            tags$div(class = "sidebar-section-label", "ANALYSIS"),
            uiOutput("single_analysis"),
            conditionalPanel(
                condition = "input.single_analysis == 'pairmatch'",
                tags$div(class = "sidebar-section-label", "ELEMENT"),
                uiOutput("single_element_pair_match"),
                fluidRow(
                    column(
                        6,
                        h5(HTML("&larr; LEFT"), class = "side-label"),
                        uiOutput("list_numeric_inputs_single_left")
                    ),
                    column(
                        6,
                        h5(HTML("&rarr; RIGHT"), class = "side-label"),
                        uiOutput("list_numeric_inputs_single_right")
                    )
                )
            ),
            conditionalPanel(
                condition = "input.single_analysis == 'regression'",
                fluidRow(
                    column(
                        6,
                        selectInput("single_association_side_a", "Side", c(Left = "Left", Right = "Right")),
                        uiOutput("single_elements_association_a"),
                        uiOutput("list_numeric_inputs_single_A")
                    ),
                    column(
                        6,
                        selectInput("single_association_side_b", "Side", c(Left = "Left", Right = "Right")),
                        uiOutput("single_elements_association_b"),
                        uiOutput("list_numeric_inputs_single_B")
                    )
                )
            ),
            conditionalPanel(
                condition = "input.single_analysis == 'articulation'",
                fluidRow(
                    column(
                        12,
                        selectInput("single_osr_side", "Side", c(Left = "Left", Right = "Right"))
                    ),
                    column(
                        12,
                        uiOutput("single_element_osr")
                    ),
                    column(
                        6,
                        uiOutput("single_measurement_osr_a")
                    ),
                    column(
                        6,
                        uiOutput("single_measurement_osr_b")
                    )
                )
            ),
            hr(),
            tags$div(class = "sidebar-section-label", "SETTINGS"),
            conditionalPanel(
                condition = "input.single_analysis != 'regression'",
                checkboxInput("single_absolute_value", "Absolute D-value |a-b|", value = FALSE),
                checkboxInput("single_yeojohnson", "YeoJohnson transformation", value = FALSE),
                checkboxInput("single_mean", "Zero mean", value = FALSE),
                radioButtons("single_tails", "Tails", choices = c(1, 2), selected = 2, inline = TRUE)
            ),
            sliderInput("common_alpha_level", "Alpha level", min = 0.05, max = 0.5, value = 0.1, step = 0.05),
            hr(),
            actionButton("proc", "Process", icon = icon("gear")),
            width = 3
        ),
        mainPanel(
            conditionalPanel(
                condition = "output.single_has_results",
                tags$div(
                    style = "border: 1px solid #ccc; padding: 15px; border-radius: 4px;",
                    tags$div(class = "main-section-label", "Plot"),
                    plotly::plotlyOutput("single_plot", width = "100%", height = "500px")
                ),
                br(),
                tags$div(
                    style = "border: 1px solid #ccc; padding: 15px; border-radius: 4px;",
                    tags$div(class = "main-section-label", "Results"),
                    tableOutput("table2")
                )
            ),
            width = 9
        )
    )
)
