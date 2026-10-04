# The numerical core: comparing specimens against a reference sample.
#
# Measurements are matrices with one row per bone and one column per
# measurement, `missing` where a measurement was not taken. Reference matrices
# come in pairs with the same rows: row i of both is the same individual.

const Measurements = AbstractMatrix{<:Union{Missing, Float64}}

measured(values::Measurements, row) = findall(!ismissing, view(values, row, :))

# ---------- Differences between two bones (pair-matching, articulation) ----------

# Sum over the given measurements of the difference between two bones
function summed_difference(a::Measurements, x, b::Measurements, j, used, absolute::Bool)
    total = 0.0
    for g in used
        difference = a[x, g] - b[j, g]
        total += absolute ? abs(difference) : difference
    end
    return total
end

# The reference sample for one set of measurements: every individual that has
# all of them on both bones.
struct ReferenceDifferences
    values::Vector{Float64}             # transformed when Yeo-Johnson is on
    lambda::Union{Nothing, Float64}     # the Yeo-Johnson parameter fitted to them
    mean::Float64
    sd::Float64
end

function reference_differences(refa::Measurements, refb::Measurements, used; absolute::Bool, yeojohnson::Bool, zeromean::Bool)
    values = Float64[]
    for i in axes(refa, 1)
        all(g -> !ismissing(refa[i, g]) && !ismissing(refb[i, g]), used) || continue
        push!(values, summed_difference(refa, i, refb, i, used, absolute))
    end
    fitted = nothing
    if yeojohnson
        fitted = lambda(values)[1]
        values = transform(values, fitted)
    end
    return ReferenceDifferences(values, fitted, zeromean ? 0.0 : mean(values), std(values))
end

# Every bone in `a` against every bone in `b`, in that order
struct PairComparisons
    a::Vector{Int}                      # row of the first bone
    b::Vector{Int}                      # row of the second bone
    used::Vector{Vector{Int}}           # measurements both have; empty when they share none
    value::Vector{Float64}              # the pair's summed difference, as tested
    n::Vector{Int}                      # reference sample size
    mean::Vector{Float64}
    sd::Vector{Float64}
    p::Vector{Float64}
    reference::Dict{Vector{Int}, ReferenceDifferences}   # by set of measurements
end

function compare_pairs(a::Measurements, b::Measurements, refa::Measurements, refb::Measurements;
                       tails::Integer, absolute::Bool = false, yeojohnson::Bool = false, zeromean::Bool = false)
    out = PairComparisons(Int[], Int[], Vector{Int}[], Float64[], Int[], Float64[], Float64[], Float64[],
        Dict{Vector{Int}, ReferenceDifferences}())
    # A run has many pairs but few distinct sets of measurements. Each set is
    # stored once, as the key of `out.reference`, and shared by its pairs.
    shared, none = Int[], Int[]
    for x in axes(a, 1), j in axes(b, 1)
        empty!(shared)
        for g in axes(a, 2)
            !ismissing(a[x, g]) && !ismissing(b[j, g]) && push!(shared, g)
        end
        push!(out.a, x)
        push!(out.b, j)
        if isempty(shared)
            push!(out.used, none)
            push!(out.value, NaN); push!(out.n, 0); push!(out.mean, NaN); push!(out.sd, NaN); push!(out.p, NaN)
            continue
        end
        used = getkey(out.reference, shared, nothing)
        if used === nothing
            used = copy(shared)
            out.reference[used] = reference_differences(refa, refb, used; absolute, yeojohnson, zeromean)
        end
        push!(out.used, used)
        reference = out.reference[used]
        value = summed_difference(a, x, b, j, used, absolute)
        yeojohnson && (value = yeo_johnson(value, reference.lambda))
        n = length(reference.values)
        t = (value - reference.mean) / reference.sd
        # absolute differences are tested in the upper tail only
        p = absolute ? tails * (1.0 - pt(t, n - 1)) : tails * pt(-abs(t), n - 1)
        push!(out.value, value); push!(out.n, n); push!(out.mean, reference.mean); push!(out.sd, reference.sd); push!(out.p, p)
    end
    return out
end

# ---------- Size of one bone predicted from another (regression) ----------

# Log of the summed measurements of one bone
log_size(values::Measurements, row) = log(sum(coalesce.(view(values, row, :), 0.0)))

# The reference sample for one pairing of measurement sets, and the
# least-squares line of bone B's size on bone A's.
struct ReferenceRegression
    x::Vector{Float64}
    y::Vector{Float64}
    intercept::Float64
    slope::Float64
    sigma::Float64                      # residual standard error
    r2::Float64
    mean_x::Float64
    sd_x::Float64
end

# Below `minimum` individuals no line is fitted and its statistics are NaN.
function reference_regression(refa::Measurements, refb::Measurements, useda, usedb; minimum::Integer = 0)
    x, y = Float64[], Float64[]
    for i in axes(refa, 1)
        all(g -> !ismissing(refa[i, g]), useda) && all(g -> !ismissing(refb[i, g]), usedb) || continue
        size_a = 0.0
        for g in useda
            size_a += refa[i, g]
        end
        size_b = 0.0
        for g in usedb
            size_b += refb[i, g]
        end
        push!(x, log(size_a))
        push!(y, log(size_b))
    end
    n = length(x)
    n < minimum && return ReferenceRegression(x, y, NaN, NaN, NaN, NaN, NaN, NaN)
    n >= 2 || throw(ArgumentError("Fewer than two reference individuals have these measurements on both bones"))
    mean_x, mean_y = mean(x), mean(y)
    slope = sum((x .- mean_x) .* (y .- mean_y)) / sum(abs2, x .- mean_x)
    intercept = mean_y - slope * mean_x
    sigma = sqrt(sum(abs2, y .- (intercept .+ slope .* x)) / (n - 2))
    return ReferenceRegression(x, y, intercept, slope, sigma, cor(x, y)^2, mean_x, std(x))
end

struct RegressionComparisons
    a::Vector{Int}
    b::Vector{Int}
    useda::Vector{Vector{Int}}
    usedb::Vector{Vector{Int}}
    x::Vector{Float64}                  # log size of the first bone
    y::Vector{Float64}                  # log size of the second
    n::Vector{Int}
    r2::Vector{Float64}
    p::Vector{Float64}
    reference::Dict{Tuple{Vector{Int}, Vector{Int}}, ReferenceRegression}
end

# Every bone in `a` (the predictor) against every bone in `b`. The test is
# two-tailed on the prediction error, with n - 2 degrees of freedom: a bone
# too large for its partner counts against a match as much as one too small,
# so there is no one-tailed form and the Tails setting does not apply.
function compare_regression(a::Measurements, b::Measurements, refa::Measurements, refb::Measurements; minimum::Integer = 0)
    out = RegressionComparisons(Int[], Int[], Vector{Int}[], Vector{Int}[], Float64[], Float64[], Int[], Float64[], Float64[],
        Dict{Tuple{Vector{Int}, Vector{Int}}, ReferenceRegression}())
    # one list of measurements per bone, shared by every pair it is in
    measureda, measuredb = [measured(a, o) for o in axes(a, 1)], [measured(b, j) for j in axes(b, 1)]
    for o in axes(a, 1), j in axes(b, 1)
        useda, usedb = measureda[o], measuredb[j]
        reference = get!(() -> reference_regression(refa, refb, useda, usedb; minimum), out.reference, (useda, usedb))
        x, y = log_size(a, o), log_size(b, j)
        n = length(reference.x)
        predicted = reference.intercept + reference.slope * x
        t = abs(predicted - y) /
            (reference.sigma * sqrt(1 + (1 / n) + ((x - reference.mean_x)^2) / ((n - 1) * (reference.sd_x^2))))
        push!(out.a, o); push!(out.b, j); push!(out.useda, useda); push!(out.usedb, usedb)
        push!(out.x, x); push!(out.y, y); push!(out.n, n); push!(out.r2, reference.r2)
        push!(out.p, 2 * pt(-abs(t), n - 2))
    end
    return out
end
