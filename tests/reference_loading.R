# Run from the repository root: Rscript tests/reference_loading.R
source("OsteoSort/R/reference_data.r")

groups <- data.frame(
    group_label = c("A white male", "B black female", "Empty white male", NA),
    collection = c("A", "B", "Empty", "Missing"),
    ancestry = c("white", "black", "white", NA), sex = c("male", "female", "male", "male")
)
measurements <- data.frame(ards = c("Fem_01", "Fem_02", "Tib_01"),
    bone = c("femur", "femur", "tibia"), full_name = c("Length", "Width", "Length"))
queries <- list()
query <- function(conn, statement, params = NULL) {
    queries[[length(queries) + 1L]] <<- list(sql = statement, params = params)
    if (grepl("SELECT DISTINCT", statement, fixed = TRUE)) return(groups)
    if (grepl("FROM osteometry.measurements", statement, fixed = TRUE)) {
        stopifnot(grepl("osteosort_method = TRUE", statement, fixed = TRUE))
        return(measurements)
    }
    stopifnot(grepl("c.osteosort_method = TRUE", statement, fixed = TRUE),
              grepl("i.osteosort_method = TRUE", statement, fixed = TRUE))
    if (identical(params, list("femur"))) {
        return(data.frame(collection = c("A", "A", "B", "Excluded"), ancestry = c("white", "white", "black", "white"),
            sex = c("male", "male", "female", "male"), accession = c("1", "2", "3", "4"),
            side = c("left", "right", "left", "left"), element = "femur",
            fem_01 = c(45, 48, 42, 50), fem_02 = c(NA, 8, 7, 9)))
    }
    if (identical(params, list("tibia"))) {
        return(data.frame(collection = "A", ancestry = "white", sex = "male", accession = "1", side = "left",
            element = "tibia", tib_01 = 36))
    }
    stop("Unexpected query")
}

result <- load_reference_data(DBI::ANSI(), query)
stopifnot(length(queries) == 4L)
stopifnot(identical(result$reference_groups$group_label, c("A white male", "B black female", "Empty white male")))
stopifnot(identical(result$osteosort_bones, c("femur", "tibia")))
a <- result$reference_list[["A white male"]]
stopifnot(identical(names(a), c("accession", "side", "element", "fem_01", "fem_02", "tib_01")))
stopifnot(nrow(a) == 3L, identical(a$element, c("femur", "femur", "tibia")))
stopifnot(identical(a$accession, c("1", "2", "1")), identical(a$side, c("left", "right", "left")))
stopifnot(identical(a$fem_01, c(45, 48, NA)), identical(a$tib_01, c(NA, NA, 36)))
stopifnot(nrow(result$reference_list[["B black female"]]) == 1L)
stopifnot(identical(result$reference_list[["Empty white male"]], data.frame()))
stopifnot(identical(result$measurement_tooltips[["fem_02"]], "Width"))

# No eligible groups means no bone queries.
groups <- groups[FALSE, , drop = FALSE]
queries <- list()
empty <- load_reference_data(DBI::ANSI(), query)
stopifnot(length(queries) == 2L, length(empty$reference_list) == 0L)

# An unavailable bone must not erase data from other bones.
groups <- data.frame(group_label = "A white male", collection = "A", ancestry = "white", sex = "male")
partial <- suppressMessages(load_reference_data(DBI::ANSI(), function(conn, statement, params = NULL) {
    if (identical(params, list("femur"))) stop("Bone table unavailable")
    query(conn, statement, params)
}))
stopifnot(nrow(partial$reference_list[["A white male"]]) == 1L,
          partial$reference_list[["A white male"]]$element == "tibia")
cat("Reference loading checks passed.\n")
