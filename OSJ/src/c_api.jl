# C-ABI wrappers for OSJ functions — R .C() compatible
# All scalar arguments are Ptr{} (R's .C() passes everything as pointers).
# This file is included inside the OSJ module — all OSJ functions are already in scope.

# ── Helper: wrap raw pointer into Julia Matrix (zero-copy, column-major) ──
function _wrap_matrix(ptr::Ptr{Float64}, rows::Cint, cols::Cint)
    return unsafe_wrap(Array, ptr, (Int(rows), Int(cols)))
end

# ── TTEST ──────────────────────────────────────────────────────
# R .C() convention: all args are pointers. Return value via out_nrows_ptr.
Base.@ccallable function osj_ttest(
    m1_ptr::Ptr{Float64}, m1_rows_p::Ptr{Cint}, m1_cols_p::Ptr{Cint},
    m2_ptr::Ptr{Float64}, m2_rows_p::Ptr{Cint}, m2_cols_p::Ptr{Cint},
    rl_ptr::Ptr{Float64}, rl_rows_p::Ptr{Cint}, rl_cols_p::Ptr{Cint},
    rr_ptr::Ptr{Float64}, rr_rows_p::Ptr{Cint}, rr_cols_p::Ptr{Cint},
    tails_p::Ptr{Float64},
    absolute_p::Ptr{Cint}, yeojohnson_p::Ptr{Cint}, zeromean_p::Ptr{Cint},
    out_ptr::Ptr{Float64}, out_max_rows_p::Ptr{Cint},
    out_ncols_ptr::Ptr{Cint}, out_nrows_ptr::Ptr{Cint}
)::Cvoid
    try
        m1_rows = unsafe_load(m1_rows_p); m1_cols = unsafe_load(m1_cols_p)
        m2_rows = unsafe_load(m2_rows_p); m2_cols = unsafe_load(m2_cols_p)
        rl_rows = unsafe_load(rl_rows_p); rl_cols = unsafe_load(rl_cols_p)
        rr_rows = unsafe_load(rr_rows_p); rr_cols = unsafe_load(rr_cols_p)
        tails = unsafe_load(tails_p)
        abs_flag = unsafe_load(absolute_p) != 0
        yj_flag  = unsafe_load(yeojohnson_p) != 0
        zm_flag  = unsafe_load(zeromean_p) != 0
        max_rows = unsafe_load(out_max_rows_p)

        m1 = _wrap_matrix(m1_ptr, m1_rows, m1_cols)
        m2 = _wrap_matrix(m2_ptr, m2_rows, m2_cols)
        RL = _wrap_matrix(rl_ptr, rl_rows, rl_cols)
        RR = _wrap_matrix(rr_ptr, rr_rows, rr_cols)

        result = TTEST(m1, m2, RL, RR, tails;
            absolute = abs_flag, yeojohnson = yj_flag, zeromean = zm_flag)

        nrows = size(result, 1)
        ncols = size(result, 2)

        unsafe_store!(out_ncols_ptr, Cint(ncols))
        unsafe_store!(out_nrows_ptr, Cint(nrows))

        out = unsafe_wrap(Array, out_ptr, (Int(max_rows), ncols))
        out[1:nrows, :] .= result
    catch e
        @error "osj_ttest error" exception=(e, catch_backtrace())
        unsafe_store!(out_nrows_ptr, Cint(-1))
    end
    return nothing
end

# ── TTEST_plot ─────────────────────────────────────────────────
Base.@ccallable function osj_ttest_plot(
    sl_ptr::Ptr{Float64}, sl_rows_p::Ptr{Cint}, sl_cols_p::Ptr{Cint},
    sr_ptr::Ptr{Float64}, sr_rows_p::Ptr{Cint}, sr_cols_p::Ptr{Cint},
    rl_ptr::Ptr{Float64}, rl_rows_p::Ptr{Cint}, rl_cols_p::Ptr{Cint},
    rr_ptr::Ptr{Float64}, rr_rows_p::Ptr{Cint}, rr_cols_p::Ptr{Cint},
    absolute_p::Ptr{Cint}, yeojohnson_p::Ptr{Cint},
    out_ptr::Ptr{Float64}, out_max_p::Ptr{Cint},
    out_nrows_ptr::Ptr{Cint}
)::Cvoid
    try
        sl_rows = unsafe_load(sl_rows_p); sl_cols = unsafe_load(sl_cols_p)
        sr_rows = unsafe_load(sr_rows_p); sr_cols = unsafe_load(sr_cols_p)
        rl_rows = unsafe_load(rl_rows_p); rl_cols = unsafe_load(rl_cols_p)
        rr_rows = unsafe_load(rr_rows_p); rr_cols = unsafe_load(rr_cols_p)
        out_max = unsafe_load(out_max_p)

        SL = _wrap_matrix(sl_ptr, sl_rows, sl_cols)
        SR = _wrap_matrix(sr_ptr, sr_rows, sr_cols)
        RL = _wrap_matrix(rl_ptr, rl_rows, rl_cols)
        RR = _wrap_matrix(rr_ptr, rr_rows, rr_cols)

        result = TTEST_plot(SL, SR, RL, RR;
            absolute = unsafe_load(absolute_p) != 0,
            yeojohnson = unsafe_load(yeojohnson_p) != 0)

        nrows = size(result, 1)
        unsafe_store!(out_nrows_ptr, Cint(nrows))

        out = unsafe_wrap(Array, out_ptr, (Int(out_max),))
        out[1:nrows] .= result[:]
    catch e
        @error "osj_ttest_plot error" exception=(e, catch_backtrace())
        unsafe_store!(out_nrows_ptr, Cint(-1))
    end
    return nothing
end

# ── REGSL ──────────────────────────────────────────────────────
Base.@ccallable function osj_regsl(
    m1_ptr::Ptr{Float64}, m1_rows_p::Ptr{Cint}, m1_cols_p::Ptr{Cint},
    m2_ptr::Ptr{Float64}, m2_rows_p::Ptr{Cint}, m2_cols_p::Ptr{Cint},
    rl_ptr::Ptr{Float64}, rl_rows_p::Ptr{Cint}, rl_cols_p::Ptr{Cint},
    rr_ptr::Ptr{Float64}, rr_rows_p::Ptr{Cint}, rr_cols_p::Ptr{Cint},
    out_ptr::Ptr{Float64}, out_max_rows_p::Ptr{Cint},
    out_ncols_ptr::Ptr{Cint}, out_nrows_ptr::Ptr{Cint}
)::Cvoid
    try
        m1_rows = unsafe_load(m1_rows_p); m1_cols = unsafe_load(m1_cols_p)
        m2_rows = unsafe_load(m2_rows_p); m2_cols = unsafe_load(m2_cols_p)
        rl_rows = unsafe_load(rl_rows_p); rl_cols = unsafe_load(rl_cols_p)
        rr_rows = unsafe_load(rr_rows_p); rr_cols = unsafe_load(rr_cols_p)
        max_rows = unsafe_load(out_max_rows_p)

        m1 = _wrap_matrix(m1_ptr, m1_rows, m1_cols)
        m2 = _wrap_matrix(m2_ptr, m2_rows, m2_cols)
        RL = _wrap_matrix(rl_ptr, rl_rows, rl_cols)
        RR = _wrap_matrix(rr_ptr, rr_rows, rr_cols)

        result = REGSL(m1, m2, RL, RR)

        nrows = size(result, 1)
        ncols = size(result, 2)

        unsafe_store!(out_ncols_ptr, Cint(ncols))
        unsafe_store!(out_nrows_ptr, Cint(nrows))

        out = unsafe_wrap(Array, out_ptr, (Int(max_rows), ncols))
        out[1:nrows, :] .= result
    catch e
        @error "osj_regsl error" exception=(e, catch_backtrace())
        unsafe_store!(out_nrows_ptr, Cint(-1))
    end
    return nothing
end

# ── REGSL_plot ─────────────────────────────────────────────────
Base.@ccallable function osj_regsl_plot(
    sl_ptr::Ptr{Float64}, sl_rows_p::Ptr{Cint}, sl_cols_p::Ptr{Cint},
    sr_ptr::Ptr{Float64}, sr_rows_p::Ptr{Cint}, sr_cols_p::Ptr{Cint},
    rl_ptr::Ptr{Float64}, rl_rows_p::Ptr{Cint}, rl_cols_p::Ptr{Cint},
    rr_ptr::Ptr{Float64}, rr_rows_p::Ptr{Cint}, rr_cols_p::Ptr{Cint},
    out_ptr::Ptr{Float64}, out_max_p::Ptr{Cint},
    out_n_ref_ptr::Ptr{Cint}, out_total_ptr::Ptr{Cint}
)::Cvoid
    try
        sl_rows = unsafe_load(sl_rows_p); sl_cols = unsafe_load(sl_cols_p)
        sr_rows = unsafe_load(sr_rows_p); sr_cols = unsafe_load(sr_cols_p)
        rl_rows = unsafe_load(rl_rows_p); rl_cols = unsafe_load(rl_cols_p)
        rr_rows = unsafe_load(rr_rows_p); rr_cols = unsafe_load(rr_cols_p)
        out_max = unsafe_load(out_max_p)

        SL = _wrap_matrix(sl_ptr, sl_rows, sl_cols)
        SR = _wrap_matrix(sr_ptr, sr_rows, sr_cols)
        RL = _wrap_matrix(rl_ptr, rl_rows, rl_cols)
        RR = _wrap_matrix(rr_ptr, rr_rows, rr_cols)

        result = REGSL_plot(SL, SR, RL, RR)

        refd_1 = result[1]
        refd_2 = result[2]
        dsum_1 = result[3]
        dsum_2 = result[4]

        n_ref = length(refd_1)
        total = 2 * n_ref + 2

        unsafe_store!(out_n_ref_ptr, Cint(n_ref))
        unsafe_store!(out_total_ptr, Cint(total))

        out = unsafe_wrap(Array, out_ptr, (Int(out_max),))
        out[1:n_ref] .= refd_1
        out[n_ref+1:2*n_ref] .= refd_2
        out[2*n_ref+1] = dsum_1
        out[2*n_ref+2] = dsum_2
    catch e
        @error "osj_regsl_plot error" exception=(e, catch_backtrace())
        unsafe_store!(out_total_ptr, Cint(-1))
    end
    return nothing
end

# ── Init / shutdown (kept for direct ccall usage) ──────────────
Base.@ccallable function osj_init()::Cint
    return Cint(0)
end

Base.@ccallable function osj_shutdown()::Cint
    return Cint(0)
end
