# Set options for environment
options(scipen = 999) # no scientific notation
options(shiny.maxRequestSize = 40 * 1024^2) # 40MB file size limit

# load libraries
library(shiny)
library(htmltools)
library(dplyr)
library(shinyalert)
library(DT)

library(DBI)
library(RPostgres)
library(dotenv)
library(plotly)

# load analytical R code
source("./R/osj.r", local = TRUE)
osj_load() # Initialize Julia runtime before Shiny event loop
source("./R/art.input.r", local = TRUE)
source("./R/pm.input.r", local = TRUE)
source("./R/reg.input.r", local = TRUE)
source("./R/reg.test.r", local = TRUE)
source("./R/timer.r", local = TRUE)
source("./R/ttest.r", local = TRUE)

shinyServer(function(input, output, session) {
    source("./server/reference.r", local = TRUE)
    source("./server/single.r", local = TRUE)
    source("./server/multiple.r", local = TRUE)
    source("./server/files.r", local = TRUE)
})
