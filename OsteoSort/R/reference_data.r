# Read a fresh reference snapshot for each session, with one query per bone.
load_reference_data <- function(conn, read_query = DBI::dbGetQuery) {
    reference_groups <- unique(na.omit(read_query(conn, paste(
        "SELECT DISTINCT i.collection || ' ' || i.ancestry || ' ' || i.sex AS group_label,",
        "i.collection, i.ancestry, i.sex FROM osteometry.individuals i",
        "INNER JOIN osteometry.collections c ON i.collection = c.collection",
        "WHERE c.osteosort_method = TRUE AND i.osteosort_method = TRUE",
        "ORDER BY i.collection, i.ancestry, i.sex"
    ))))
    osteosort_measurements <- read_query(conn, paste(
        "SELECT ards, bone, full_name FROM osteometry.measurements",
        "WHERE osteosort_method = TRUE ORDER BY bone, ards"
    ))
    osteosort_bones <- unique(osteosort_measurements$bone)
    measurement_tooltips <- setNames(osteosort_measurements$full_name, tolower(osteosort_measurements$ards))

    group_rows <- lapply(seq_len(nrow(reference_groups)), function(i) list())
    for (bone in osteosort_bones) {
        if (nrow(reference_groups) == 0) break
        bone_meas <- osteosort_measurements[osteosort_measurements$bone == bone, "ards"]
        if (length(bone_meas) == 0) next
        # PostgreSQL folded the original unquoted measurement identifiers to lower case.
        table_name <- DBI::dbQuoteIdentifier(conn, DBI::Id(schema = "osteometry", table = gsub(" ", "_", tolower(bone))))
        meas_cols <- paste(paste0("b.", DBI::dbQuoteIdentifier(conn, tolower(bone_meas))), collapse = ", ")
        query <- paste0(
            "SELECT i.collection, i.ancestry, i.sex, i.accession, b.side, $1::text AS element, ", meas_cols,
            " FROM ", table_name, " b",
            " INNER JOIN osteometry.individuals i ON b.accession = i.accession",
            " INNER JOIN osteometry.collections c ON c.collection = i.collection",
            " WHERE i.osteosort_method = TRUE AND c.osteosort_method = TRUE"
        )
        bone_data <- tryCatch(
            read_query(conn, query, params = list(bone)),
            error = function(e) {
                message(paste("Warning: Could not load", bone, "reference data -", e$message))
                NULL
            }
        )
        if (is.null(bone_data) || nrow(bone_data) == 0) next
        data_columns <- c("accession", "side", "element", tolower(bone_meas))
        for (i in seq_len(nrow(reference_groups))) {
            group <- reference_groups[i, ]
            rows <- which(bone_data$collection == group$collection &
                          bone_data$ancestry == group$ancestry & bone_data$sex == group$sex)
            if (length(rows) == 0) next
            data <- bone_data[rows, data_columns, drop = FALSE]
            rownames(data) <- NULL
            group_rows[[i]][[bone]] <- data
        }
    }
    reference_list <- list()
    for (i in seq_len(nrow(reference_groups))) {
        # Keep the old per-group column layout, including empty groups.
        reference_list[[reference_groups$group_label[i]]] <- if (length(group_rows[[i]])) {
            dplyr::bind_rows(group_rows[[i]])
        } else data.frame()
    }
    list(reference_groups = reference_groups, osteosort_measurements = osteosort_measurements,
         osteosort_bones = osteosort_bones, measurement_tooltips = measurement_tooltips,
         reference_list = reference_list)
}
