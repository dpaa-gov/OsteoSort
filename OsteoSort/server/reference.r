# Connect to ARDS PostgreSQL and load reference data
dotenv::load_dot_env() # load database information
pg_conn <- dbConnect(
    RPostgres::Postgres(),
    host = Sys.getenv("DB_HOST"),
    port = as.integer(Sys.getenv("DB_PORT")),
    dbname = Sys.getenv("DB_NAME"),
    user = Sys.getenv("DB_USER"),
    password = Sys.getenv("DB_PASS")
)

# Get distinct reference groups (collection + ancestry + sex)
res <- dbSendQuery(
    conn = pg_conn,
    statement = " SELECT DISTINCT collection || ' ' || ancestry || ' ' || sex AS group_label,
        collection, ancestry, sex
        FROM osteometry.individuals
        WHERE osteosort_method = TRUE
        ORDER BY collection, ancestry, sex"
)
reference_groups <- unique(na.omit(dbFetch(res)))

# Get all bones that have osteosort-enabled measurements
res <- dbSendQuery(
    conn = pg_conn,
    statement = "SELECT DISTINCT bone FROM osteometry.measurements
        WHERE osteosort_method = TRUE
        ORDER BY bone"
)
osteosort_bones <- dbFetch(res)

# Get all osteosort-enabled measurements
res <- dbSendQuery(
    conn = pg_conn,
    statement = "SELECT ards, bone FROM osteometry.measurements
        WHERE osteosort_method = TRUE
        ORDER BY bone, ards"
)
osteosort_measurements <- dbFetch(res)

# Set up reactive values
reference_name_list <- reactiveValues(reference_name_list = reference_groups$group_label)
reference_list <- reactiveValues(reference_list = list())
articulation_config <- reactiveValues(df = read.csv(file = "./extdata/config/articulation_config", header = TRUE, sep = ",", stringsAsFactors = FALSE))
regression_bones <- reactiveValues(bones = read.csv(file = "./extdata/config/regression_config", header = TRUE, stringsAsFactors = FALSE)$Bone)

# Load reference data for each group at startup
observeEvent(TRUE, {
    for (i in 1:nrow(reference_groups)) {
        group <- reference_groups[i, ]
        label <- group$group_label

        # For each bone, query measurements for this group
        all_bone_data <- data.frame()
        for (bone in osteosort_bones$bone) {
            # Get measurement columns for this bone
            bone_meas <- osteosort_measurements[osteosort_measurements$bone == bone, "ards"]
            if (length(bone_meas) == 0) next

            # Build table name: "cervical 1" -> "osteometry.cervical_1"
            table_name <- paste0("osteometry.", gsub(" ", "_", tolower(bone)))

            # Build SELECT query with dynamic columns
            meas_cols <- paste(paste0("b.", bone_meas), collapse = ", ")
            query <- paste0(
                "SELECT i.accession, b.side, '", bone, "' AS element, ", meas_cols,
                " FROM ", table_name, " b",
                " INNER JOIN osteometry.individuals i ON b.accession = i.accession",
                " WHERE i.osteosort_method = TRUE",
                " AND i.collection = $1 AND i.ancestry = $2 AND i.sex = $3"
            )

            tryCatch(
                {
                    bone_data <- dbGetQuery(pg_conn, query, params = list(group$collection, group$ancestry, group$sex))
                    if (nrow(bone_data) > 0) {
                        all_bone_data <- dplyr::bind_rows(all_bone_data, bone_data)
                    }
                },
                error = function(e) {
                    message(paste("Warning: Could not load", bone, "for group", label, "-", e$message))
                }
            )
        }

        reference_list$reference_list[[label]] <- all_bone_data
    }
})
