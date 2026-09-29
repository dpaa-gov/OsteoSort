# Load current ARDS reference data for this session.
if (file.exists(".env")) {
    dotenv::load_dot_env(".env")
} else {
    message("No .env file found; using system environment variables.")
}

reference_snapshot <- (function() {
    db_host <- Sys.getenv("DB_HOST", unset = "host.docker.internal")
    db_port <- Sys.getenv("DB_PORT", unset = "5432")
    db_name <- Sys.getenv("DB_NAME", unset = "")
    db_user <- Sys.getenv("DB_USER", unset = "")
    db_pass <- Sys.getenv("DB_PASS", unset = "")

    if (db_port == "" || is.na(suppressWarnings(as.integer(db_port)))) {
        db_port <- "5432"
    }

    if (db_name == "" || db_user == "" || db_pass == "") {
        stop("Missing required database environment variables: DB_NAME, DB_USER, and/or DB_PASS")
    }

    pg_conn <- tryCatch(
        dbConnect(
            RPostgres::Postgres(),
            host = db_host,
            port = as.integer(db_port),
            dbname = db_name,
            user = db_user,
            password = db_pass
        ),
        error = function(e) {
            stop("Failed to connect to ARDS database: ", e$message)
        }
    )

    on.exit(DBI::dbDisconnect(pg_conn), add = TRUE)
    load_reference_data(pg_conn)
})()

reference_groups <- reference_snapshot$reference_groups
osteosort_measurements <- reference_snapshot$osteosort_measurements
osteosort_bones <- reference_snapshot$osteosort_bones
measurement_tooltips <- reference_snapshot$measurement_tooltips

# Set up reactive values
reference_name_list <- reactiveValues(reference_name_list = reference_groups$group_label)
reference_list <- reactiveValues(reference_list = reference_snapshot$reference_list)
articulation_config <- reactiveValues(df = read.csv(file = "./extdata/config/articulation_config", header = TRUE, sep = ","))
regression_bones <- reactiveValues(bones = read.csv(file = "./extdata/config/regression_config", header = TRUE)$Bone)
rm(reference_snapshot)
