# Runs the comparisons in core.jl on prepared rows and labels the results.

struct Settings
    absolute::Bool
    yeojohnson::Bool
    zeromean::Bool
    tails::Int
end

struct AnalysisResult
    results::NamedTuple   # one vector per column
    rejected::NamedTuple  # specimens and pairs that could not be compared, with the reason
    plot::Any             # single comparisons only
end

# Decimal places of every p-value. Exclusion is decided on the rounded value,
# so the result can always be checked against the p shown and alpha.
const P_DIGITS = 5

classify(p, alpha) = p <= alpha ? "Excluded" : "Cannot Exclude"

select_rows(table::NamedTuple, keep) = map(column -> column[keep], table)

# Which reference groups a comparison drew on, and how many individuals from
# each: "DPAA white male 43, UT mexican male 1". A reference individual counts
# when both of its bones have every measurement the comparison uses, so the
# numbers add up to the comparison's sample size. `useda` and `usedb` are the
# measurement columns used on each side.
function reference_breakdown(data::Prepared, useda, usedb)
    counts = Dict{String, Int}()
    for i in 1:length(data.refa)
        all(j -> !ismissing(data.refa.values[i, j]), useda) && all(j -> !ismissing(data.refb.values[i, j]), usedb) || continue
        label = data.refa.group[i]
        counts[label] = get(counts, label, 0) + 1
    end
    return join(("$label $(counts[label])" for label in sort!(collect(keys(counts)))), ", ")
end

# The same breakdown for every row, worked out once per distinct pattern
function reference_breakdowns(data::Prepared, patterns)
    seen = Dict{Any, String}()
    return [get!(() -> reference_breakdown(data, pattern...), seen, pattern) for pattern in patterns]
end

# Fewest reference individuals a comparison may be tested against. Below it
# the pair is rejected. Deliberately not a setting.
const MINIMUM_REFERENCE = 10

const UNMEASURED = "None of the selected measurements"
const NOTHING_IN_COMMON = "No measurements in common"
too_small(n, minimum) = "Reference sample too small: $n (minimum $minimum)"
const NOT_CALCULATED = "The comparison could not be calculated"

function ttest(data::Prepared, alpha, settings::Settings; articulation::Bool = false,
               minimum_reference::Integer = MINIMUM_REFERENCE)
    found = compare_pairs(data.sorta.values, data.sortb.values, data.refa.values, data.refb.values;
        tails = settings.tails, absolute = settings.absolute, yeojohnson = settings.yeojohnson, zeromean = settings.zeromean)
    plot = nothing
    if length(data.sorta) == 1 && length(data.sortb) == 1 && !isempty(only(found.used))
        # for a single comparison: the reference distribution and where the pair falls in it
        plot = (reference = found.reference[only(found.used)].values, specimen = only(found.value))
    end

    a, b = found.a, found.b
    if articulation
        # The two bones' measurements pair up by position, not by name: list
        # the ones compared, first bone's then second bone's.
        namesa, namesb = data.sorta.measurements, data.sortb.measurements
        measurements = [join(vcat(namesa[used], namesb[used]), " ") for used in found.used]
    else
        names = data.sorta.measurements
        measurements = [join(names[k] * " " for k in used) for used in found.used]
    end
    p = round.(found.p; digits = P_DIGITS)
    table = (
        id_1 = data.sorta.accession[a], element_1 = data.sorta.element[a], side_1 = data.sorta.side[a],
        id_2 = data.sortb.accession[b], element_2 = data.sortb.element[b], side_2 = data.sortb.side[b],
        measurements = measurements,
        n = found.n,
        mean = round.(found.mean; digits = 4),
        sd = round.(found.sd; digits = 4),
        p = p,
        result = classify.(p, alpha),
        reference = reference_breakdowns(data, [(used, used) for used in found.used]),
    )
    return split_rejected(table, data, plot, minimum_reference)
end

function regression_test(data::Prepared, alpha; minimum_reference::Integer = MINIMUM_REFERENCE)
    found = compare_regression(data.sorta.values, data.sortb.values, data.refa.values, data.refb.values;
        minimum = minimum_reference)
    plot = nothing
    if length(data.sorta) == 1 && length(data.sortb) == 1
        reference = only(values(found.reference))
        plot = (ref_x = reference.x, ref_y = reference.y, specimen_x = only(found.x), specimen_y = only(found.y),
                x_label = data.sorta.element[1], y_label = data.sortb.element[1], alphalevel = alpha,
                band = isnan(reference.slope) ? nothing : prediction_band(reference, alpha))
    end

    a, b = found.a, found.b
    namesa, namesb = data.sorta.measurements, data.sortb.measurements
    measurements = [join(vcat(namesa[found.useda[r]], namesb[found.usedb[r]]) .* " ") for r in eachindex(a)]
    p = round.(found.p; digits = P_DIGITS)
    table = (
        x_id = data.sorta.accession[a], x_element = data.sorta.element[a], x_side = data.sorta.side[a],
        y_id = data.sortb.accession[b], y_element = data.sortb.element[b], y_side = data.sortb.side[b],
        measurements = measurements,
        n = found.n,
        r2 = round.(found.r2; digits = 4),
        p = p,
        result = classify.(p, alpha),
        reference = reference_breakdowns(data, collect(zip(found.useda, found.usedb))),
    )
    return split_rejected(table, data, plot, minimum_reference)
end

# The fitted line at the reference points with its prediction interval at
# level 1 - alpha, ordered by x for drawing.
function prediction_band(reference::ReferenceRegression, alpha)
    x = reference.x
    n = length(x)
    n > 2 || return nothing
    fit = reference.intercept .+ reference.slope .* x
    sxx = (n - 1) * reference.sd_x^2
    half = qt(1 - alpha / 2, n - 2) .* reference.sigma .* sqrt.(1 .+ 1 / n .+ (x .- reference.mean_x) .^ 2 ./ sxx)
    order = sortperm(x)
    return (x = x[order], fit = fit[order], lower = (fit .- half)[order], upper = (fit .+ half)[order])
end

# Separates what could not be compared, each with its reason: specimens with
# none of the selected measurements (one row each, in their own specimen's
# columns), then pairs that share no measurement, then pairs whose reference
# sample is below the minimum, then pairs with no p-value.
function split_rejected(table, data::Prepared, plot, minimum)
    shared = table.measurements .!= ""
    small = shared .& (table.n .< minimum)
    unshared = .!shared
    # no p-value, as when the reference sample does not vary at all
    failed = shared .& .!small .& isnan.(table.p)
    ua, ub = data.unmeasureda, data.unmeasuredb
    na, nb = length(ua), length(ub)
    blank(n) = fill("", n)
    pairs(k) = vcat(table[k][unshared], table[k][small], table[k][failed])
    rejected = NamedTuple{(keys(table)[1:6]..., :reason)}((
        vcat(ua.accession, blank(nb), pairs(1)),
        vcat(ua.element, blank(nb), pairs(2)),
        vcat(ua.side, blank(nb), pairs(3)),
        vcat(blank(na), ub.accession, pairs(4)),
        vcat(blank(na), ub.element, pairs(5)),
        vcat(blank(na), ub.side, pairs(6)),
        vcat(fill(UNMEASURED, na + nb), fill(NOTHING_IN_COMMON, count(unshared)), too_small.(table.n[small], minimum),
            fill(NOT_CALCULATED, count(failed))),
    ))
    kept = shared .& .!small .& .!failed
    # a single comparison that was not made has no plot either
    return AnalysisResult(select_rows(table, kept), rejected, any(kept) ? plot : nothing)
end

# --- Multiple: an uploaded table against the selected reference groups ---

prepare_pair_match(groups, sort::SortTable, bone, measurements) =
    pair_match_input(groups, sort, bone, measurements)

prepare_articulation(groups, sort::SortTable, bonea, boneb, side, measurementsa, measurementsb) =
    two_bone_input(groups, sort, bonea, boneb, side, side, measurementsa, measurementsb)

prepare_regression(groups, sort::SortTable, bonea, boneb, sidea, sideb, measurementsa, measurementsb) =
    two_bone_input(groups, sort, bonea, boneb, sidea, sideb, measurementsa, measurementsb)

# --- Single: two typed-in specimens, labelled X and Y ---

# Typed-in values by measurement code; blank fields arrive as nothing or are absent
function entered(values, measurements)
    return Union{Missing, Float64}[
        (value = get(values, m, nothing); value === nothing || ismissing(value) ? missing : Float64(value))
        for m in measurements
    ]
end

function two_specimens(sides, elements, measurements, x, y)
    values = Matrix{Union{Missing, Float64}}(missing, 2, length(measurements))
    values[1, :] = x
    values[2, :] = y
    return SortTable(["X", "Y"], collect(lowercase.(sides)), collect(lowercase.(elements)), measurements, values)
end

function prepare_single_pair_match(groups, bone, left, right)
    measurements = available_measurements(groups, bone)
    l, r = entered(left, measurements), entered(right, measurements)
    any(k -> !ismissing(l[k]) && !ismissing(r[k]), eachindex(measurements)) || return nothing
    sort = two_specimens(("left", "right"), (bone, bone), measurements, l, r)
    return pair_match_input(groups, sort, bone, measurements)
end

function prepare_single_articulation(groups, pairs, bonea, boneb, side, valuesa, valuesb)
    bonea, boneb = lowercase(bonea), lowercase(boneb)
    matching = [p for p in pairs if lowercase(p.bonea) == bonea && lowercase(p.boneb) == boneb]
    isempty(matching) && return nothing
    measurementsa, measurementsb = unique(p.a for p in matching), unique(p.b for p in matching)
    a, b = entered(valuesa, measurementsa), entered(valuesb, measurementsb)
    (ismissing(a[1]) || ismissing(b[1])) && return nothing
    sort = two_specimens((side, side), (bonea, boneb), vcat(measurementsa, measurementsb),
        vcat(a, fill(missing, length(b))), vcat(fill(missing, length(a)), b))
    return prepare_articulation(groups, sort, bonea, boneb, side, measurementsa, measurementsb)
end

function prepare_single_regression(groups, bonea, boneb, sidea, sideb, valuesa, valuesb)
    measurementsa, measurementsb = available_measurements(groups, bonea), available_measurements(groups, boneb)
    a, b = entered(valuesa, measurementsa), entered(valuesb, measurementsb)
    (all(ismissing, a) || all(ismissing, b)) && return nothing
    sort = two_specimens((sidea, sideb), (bonea, boneb), vcat(measurementsa, measurementsb),
        vcat(a, fill(missing, length(b))), vcat(fill(missing, length(a)), b))
    return prepare_regression(groups, sort, bonea, boneb, sidea, sideb, measurementsa, measurementsb)
end

# Nothing prepared means nothing to compare (no usable reference or case rows)
ttest(::Nothing, alpha, settings::Settings; kwargs...) = nothing
regression_test(::Nothing, alpha; kwargs...) = nothing
