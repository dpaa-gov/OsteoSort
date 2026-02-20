# OSJ Shared Library Interface
#
# Loads libosj.so and provides R wrapper functions for all OSJ functions.
# Replaces JuliaCall with direct .C() calls to the compiled shared library.

# ── Library loading ──────────────────────────────────────────
osj_load <- function() {
    # Determine library path
    # Docker: /home/shiny/dist/libosj/lib/libosj.so
    # Dev:    ../dist/libosj/lib/libosj.so (relative to OsteoSort/)
    lib_candidates <- c(
        "/home/shiny/dist/libosj/lib/libosj.so", # Docker
        file.path("..", "dist", "libosj", "lib", "libosj.so") # Dev
    )

    lib_path <- NULL
    for (p in lib_candidates) {
        if (file.exists(p)) {
            lib_path <- normalizePath(p)
            break
        }
    }
    if (is.null(lib_path)) {
        stop("libosj.so not found. Build it with:\n  julia --project=OSJ build/create_library.jl")
    }

    lib_dir <- dirname(lib_path)
    julia_lib_dir <- file.path(lib_dir, "julia")

    # Set LD_LIBRARY_PATH so Julia runtime libs can be found
    Sys.setenv(LD_LIBRARY_PATH = paste(lib_dir, julia_lib_dir,
        Sys.getenv("LD_LIBRARY_PATH"),
        sep = ":"
    ))

    # Load the shared library
    dyn.load(lib_path)

    # Load the C shim for init_julia ABI bridging
    shim_candidates <- c(
        "/home/shiny/dist/r_osj_shim.so", # Docker
        file.path("..", "build", "r_osj_shim.so") # Dev
    )
    shim_path <- NULL
    for (p in shim_candidates) {
        if (file.exists(p)) {
            shim_path <- normalizePath(p)
            break
        }
    }
    if (is.null(shim_path)) {
        stop("r_osj_shim.so not found. Build it with:\n  gcc -shared -fPIC -o build/r_osj_shim.so build/r_osj_shim.c -L dist/libosj/lib -losj")
    }
    dyn.load(shim_path)

    # Initialize Julia runtime
    .C("r_init_julia", as.integer(0))

    invisible(TRUE)
}

# ── TTEST wrapper ────────────────────────────────────────────
osj_ttest <- function(m1, m2, rl, rr, tails,
                      absolute = FALSE, yeojohnson = FALSE, zeromean = FALSE) {
    m1 <- as.matrix(m1)
    m2 <- as.matrix(m2)
    rl <- as.matrix(rl)
    rr <- as.matrix(rr)

    expected_rows <- as.integer(nrow(m1) * nrow(m2))
    max_cols <- as.integer(ncol(m1) + 7L)
    out <- double(expected_rows * max_cols)
    out_ncols <- integer(1)
    out_nrows <- integer(1)

    result <- .C("osj_ttest",
        m1_ptr        = as.double(m1),
        m1_rows       = as.integer(nrow(m1)),
        m1_cols       = as.integer(ncol(m1)),
        m2_ptr        = as.double(m2),
        m2_rows       = as.integer(nrow(m2)),
        m2_cols       = as.integer(ncol(m2)),
        rl_ptr        = as.double(rl),
        rl_rows       = as.integer(nrow(rl)),
        rl_cols       = as.integer(ncol(rl)),
        rr_ptr        = as.double(rr),
        rr_rows       = as.integer(nrow(rr)),
        rr_cols       = as.integer(ncol(rr)),
        tails         = as.double(tails),
        absolute      = as.integer(absolute),
        yeojohnson    = as.integer(yeojohnson),
        zeromean      = as.integer(zeromean),
        out_ptr       = out,
        out_max_rows  = expected_rows,
        out_ncols_ptr = out_ncols,
        out_nrows_ptr = out_nrows
    )

    nr <- result$out_nrows_ptr
    nc <- result$out_ncols_ptr
    if (nr < 0) stop("osj_ttest: Julia function returned error")

    out_mat <- matrix(result$out_ptr, nrow = expected_rows, ncol = max_cols)
    return(out_mat[1:nr, 1:nc, drop = FALSE])
}

# ── TTEST_plot wrapper ───────────────────────────────────────
osj_ttest_plot <- function(sl, sr, rl, rr,
                           absolute = FALSE, yeojohnson = FALSE) {
    sl <- as.matrix(sl)
    sr <- as.matrix(sr)
    rl <- as.matrix(rl)
    rr <- as.matrix(rr)

    max_out <- as.integer(nrow(rl) + 100L) # ref diffs + sort diff + margin
    out <- double(max_out)
    out_nrows <- integer(1)

    result <- .C("osj_ttest_plot",
        sl_ptr     = as.double(sl),
        sl_rows    = as.integer(nrow(sl)),
        sl_cols    = as.integer(ncol(sl)),
        sr_ptr     = as.double(sr),
        sr_rows    = as.integer(nrow(sr)),
        sr_cols    = as.integer(ncol(sr)),
        rl_ptr     = as.double(rl),
        rl_rows    = as.integer(nrow(rl)),
        rl_cols    = as.integer(ncol(rl)),
        rr_ptr     = as.double(rr),
        rr_rows    = as.integer(nrow(rr)),
        rr_cols    = as.integer(ncol(rr)),
        absolute   = as.integer(absolute),
        yeojohnson = as.integer(yeojohnson),
        out_ptr    = out,
        out_max    = max_out,
        out_nrows  = out_nrows
    )

    nr <- result$out_nrows
    if (nr < 0) stop("osj_ttest_plot: Julia function returned error")

    return(matrix(result$out_ptr[1:nr], ncol = 1))
}

# ── REGSL wrapper ────────────────────────────────────────────
osj_regsl <- function(m1, m2, rl, rr) {
    m1 <- as.matrix(m1)
    m2 <- as.matrix(m2)
    rl <- as.matrix(rl)
    rr <- as.matrix(rr)

    expected_rows <- as.integer(nrow(m1) * nrow(m2))
    max_cols <- as.integer(ncol(m1) + ncol(m2) + 5L)
    out <- double(expected_rows * max_cols)
    out_ncols <- integer(1)
    out_nrows <- integer(1)

    result <- .C("osj_regsl",
        m1_ptr        = as.double(m1),
        m1_rows       = as.integer(nrow(m1)),
        m1_cols       = as.integer(ncol(m1)),
        m2_ptr        = as.double(m2),
        m2_rows       = as.integer(nrow(m2)),
        m2_cols       = as.integer(ncol(m2)),
        rl_ptr        = as.double(rl),
        rl_rows       = as.integer(nrow(rl)),
        rl_cols       = as.integer(ncol(rl)),
        rr_ptr        = as.double(rr),
        rr_rows       = as.integer(nrow(rr)),
        rr_cols       = as.integer(ncol(rr)),
        out_ptr       = out,
        out_max_rows  = expected_rows,
        out_ncols_ptr = out_ncols,
        out_nrows_ptr = out_nrows
    )

    nr <- result$out_nrows_ptr
    nc <- result$out_ncols_ptr
    if (nr < 0) stop("osj_regsl: Julia function returned error")

    out_mat <- matrix(result$out_ptr, nrow = expected_rows, ncol = max_cols)
    return(out_mat[1:nr, 1:nc, drop = FALSE])
}

# ── REGSL_plot wrapper ───────────────────────────────────────
osj_regsl_plot <- function(sl, sr, rl, rr) {
    sl <- as.matrix(sl)
    sr <- as.matrix(sr)
    rl <- as.matrix(rl)
    rr <- as.matrix(rr)

    max_out <- as.integer(2L * nrow(rl) + 100L)
    out <- double(max_out)
    out_n_ref <- integer(1)
    out_total <- integer(1)

    result <- .C("osj_regsl_plot",
        sl_ptr    = as.double(sl),
        sl_rows   = as.integer(nrow(sl)),
        sl_cols   = as.integer(ncol(sl)),
        sr_ptr    = as.double(sr),
        sr_rows   = as.integer(nrow(sr)),
        sr_cols   = as.integer(ncol(sr)),
        rl_ptr    = as.double(rl),
        rl_rows   = as.integer(nrow(rl)),
        rl_cols   = as.integer(ncol(rl)),
        rr_ptr    = as.double(rr),
        rr_rows   = as.integer(nrow(rr)),
        rr_cols   = as.integer(ncol(rr)),
        out_ptr   = out,
        out_max   = max_out,
        out_n_ref = out_n_ref,
        out_total = out_total
    )

    n_ref <- result$out_n_ref
    total <- result$out_total
    if (total < 0) stop("osj_regsl_plot: Julia function returned error")

    vals <- result$out_ptr[1:total]
    refd_1 <- vals[1:n_ref]
    refd_2 <- vals[(n_ref + 1):(2 * n_ref)]
    dsum_1 <- vals[2 * n_ref + 1]
    dsum_2 <- vals[2 * n_ref + 2]

    return(list(refd_1, refd_2, dsum_1, dsum_2))
}
