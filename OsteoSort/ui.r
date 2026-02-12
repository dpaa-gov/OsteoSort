source("./ui/single.r", local = TRUE)
source("./ui/multiple.r", local = TRUE)
source("./ui/files.r", local = TRUE)

# Read version from file
app_version <- trimws(readLines("VERSION", n = 1))

shinyUI(
    navbarPage(
        theme = "css/flatly-bootstrap.css", windowTitle = "OsteoSort",
        header = tags$head(
            tags$link(rel = "stylesheet", type = "text/css", href = "css/osteosort.css"),
            tags$script(HTML("
                Shiny.addCustomMessageHandler('updateProgress', function(data) {
                    var bar = document.getElementById(data.id + '-progress-bar');
                    var txt = document.getElementById(data.id + '-progress-text');
                    if (bar) bar.style.width = data.pct + '%';
                    if (txt) txt.textContent = data.text;
                });
            "))
        ),
        title = tags$img(src = "osteosort.png", class = "navbar-logo"),
        tags$script(HTML(paste0(
            "var header = $('.navbar > .container-fluid');",
            "header.append('<span class=\"version-badge\">v ", app_version, "</span>');"
        ))),
        single_osteometric_sorting,
        multiple_osteometric_sorting,
        files
    )
)
