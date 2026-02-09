single_osteometric_sorting <- tabPanel("Single", icon = icon("gear", lib = "font-awesome"),
	sidebarLayout(
		sidebarPanel(
			tags$style(type='text/css', ".selectize-input { font-size: 14px; line-height: 14px;} .selectize-dropdown { font-size: 14px; line-height: 14px; }"),
			tags$style(".irs-bar, .irs-bar-edge, .irs-single, irs.grid-pol {background: #126a8f; border-color: #126a8f;}"),
			tags$style(".well {background-color: #f6f6f6;}"),
			tags$style(type = "text/css", "#proc { width:100%; font-size:85%; background-color:#126a8f }"),
			tags$style(type = "text/css", "#template { color:#FFFFFF }"),
			tags$style(type = "text/css", "#example { color:#FFFFFF }"),
			uiOutput("single_reference"),
			uiOutput("single_analysis"),
			conditionalPanel(condition = "input.single_analysis == 'pairmatch'",
				uiOutput("single_element_pair_match"),
				fluidRow(
					column(6,
						h4("Left"),
						uiOutput("list_numeric_inputs_single_left")
					),
					column(6,
						h4("Right"),
						uiOutput("list_numeric_inputs_single_right")
					)
				)
			),
			conditionalPanel(condition = "input.single_analysis == 'regression'",
				fluidRow(
					column(6,
						selectInput("single_association_side_a", "Side", c(Left = "Left", Right = "Right")),
						uiOutput("single_elements_association_a"),
						uiOutput("list_numeric_inputs_single_A")
					),
					column(6,
						selectInput("single_association_side_b", "Side", c(Left = "Left", Right = "Right")),
						uiOutput("single_elements_association_b"),
						uiOutput("list_numeric_inputs_single_B")
					)
				)
			),
			conditionalPanel(condition = "input.single_analysis == 'articulation'",
				fluidRow(
					column(12,
						selectInput("single_osr_side", "Side", c(Left = "Left", Right = "Right"))
					),
					column(12,
						uiOutput("single_element_osr")
					),
					column(6,
						uiOutput("single_measurement_osr_a")
					),
					column(6,
						uiOutput("single_measurement_osr_b")
					)
				)
			),
			fluidRow(
				column(6,
					textInput(inputId = "ID1", label = "1st ID #", value = "X1")
				),
				column(6,
					textInput(inputId = "ID2", label = "2nd ID #", value = "Y1")
				)
			),
			hr(),
			h4("Settings"),
			conditionalPanel(condition = "input.single_analysis != 'regression'",
				checkboxInput("single_absolute_value", "Absolute D-value |a-b|", value = FALSE),
				checkboxInput("single_yeojohnson", "YeoJohnson transformation", value = FALSE),
				checkboxInput("single_mean", "Zero mean", value = FALSE),
				radioButtons("single_tails", "Tails", choices = c(1, 2), selected = 2, inline = TRUE)
			),
			sliderInput("common_alpha_level", "Alpha level", min = 0.1, max = 1, value = 0.1, step = 0.1),
			actionButton("proc", "Process", icon = icon("gear")),
			width = 3
		),
		mainPanel(
			plotly::plotlyOutput("single_plot"),
			br(),
			DT::dataTableOutput("table2"),
			width = 9
		)
	)
)
