#!/usr/bin/env Rscript
# OsteoSort Local Development Server
# Runs the Shiny app without Docker
#
# Prerequisites:
#   - R with required packages (see README.md)
#   - Julia 1.11+ with OSJ package
#   - .env file in OsteoSort/ with DB credentials
#
# Usage:
#   Rscript start_dev.R
#   # or from RStudio: source("start_dev.R")

cat("Starting OsteoSort in development mode...\n")

# Install missing R packages
required_packages <- c(
    "shiny", "htmltools", "dplyr",
    "shinyalert", "DT", "DBI", "RPostgres", "dotenv", "plotly"
)
missing <- required_packages[!sapply(required_packages, requireNamespace, quietly = TRUE)]
if (length(missing) > 0) {
    cat("Installing missing packages:", paste(missing, collapse = ", "), "\n")
    install.packages(missing)
}

cat("App will be available at http://127.0.0.1:4001\n\n")

shiny::runApp(
    appDir = "OsteoSort",
    port = 4001,
    host = "127.0.0.1",
    launch.browser = TRUE
)
