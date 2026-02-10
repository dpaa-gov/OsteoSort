source("./ui/single.r", local = TRUE)
source("./ui/multiple.r", local = TRUE)
source("./ui/files.r", local = TRUE)

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
        tags$script(HTML(paste("var header = $('.navbar > .container-fluid');header.append('<div style=\"float:left\"><img src=\"osteosort.png\" alt=\"alt\" style=\"float:right; width:200px;padding-top:0px;\"></div><div style=\"float:right; padding-top:15px\">",
            "<font color=\"#d4a843\"><strong>Version: ", "1.5.0", "</strong></font>", "</div>');console.log(header)",
            sep = ""
        ))),
        single_osteometric_sorting,
        multiple_osteometric_sorting,
        files
    )
)
