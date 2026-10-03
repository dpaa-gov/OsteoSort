# Selects and aligns reference and case rows for one analysis.

# Rows for one element, `missing` where a measurement was not taken.
# `group` is the reference group a row came from (empty for case specimens).
struct Rows
    accession::Vector{String}
    side::Vector{String}
    element::Vector{String}
    group::Vector{String}
    measurements::Vector{String}
    values::Matrix{Union{Missing, Float64}}
end

Base.length(rows::Rows) = length(rows.accession)
subset(rows::Rows, keep) =
    Rows(rows.accession[keep], rows.side[keep], rows.element[keep], rows.group[keep], rows.measurements, rows.values[keep, :])

# `unmeasured` holds the case rows left out because they have too few of the
# selected measurements, for the Rejected table.
const Prepared = @NamedTuple{refa::Rows, refb::Rows, sorta::Rows, sortb::Rows, unmeasureda::Rows, unmeasuredb::Rows}

# Reference rows for a bone across the selected groups, ordered by accession.
function reference_rows(groups, bone, measurements)
    accession = String[]
    side = String[]
    from = String[]
    blocks = Matrix{Union{Missing, Float64}}[]
    for group in groups, (name, table) in group.bones
        lowercase(name) == bone || continue
        block = Matrix{Union{Missing, Float64}}(missing, length(table.accession), length(measurements))
        for (j, code) in enumerate(measurements)
            column = findfirst(==(code), table.measurements)
            column === nothing || (block[:, j] = table.values[:, column])
        end
        append!(accession, table.accession)
        append!(side, lowercase.(table.side))
        append!(from, fill(group.label, length(table.accession)))
        push!(blocks, block)
    end
    values = reduce(vcat, blocks; init = Matrix{Union{Missing, Float64}}(undef, 0, length(measurements)))
    order = sortperm(accession)
    return Rows(accession[order], side[order], fill(bone, length(order)), from[order], collect(String, measurements), values[order, :])
end

# Case rows for a bone, in file order.
function sort_rows(sort::SortTable, bone, measurements)
    keep = [i for i in eachindex(sort.element)
            if !ismissing(sort.element[i]) && lowercase(sort.element[i]) == bone]
    values = Matrix{Union{Missing, Float64}}(missing, length(keep), length(measurements))
    for (j, code) in enumerate(measurements)
        column = findfirst(==(code), sort.measurements)
        column === nothing || (values[:, j] = sort.values[keep, column])
    end
    return Rows(
        String[coalesce(sort.accession[i], "NA") for i in keep],
        String[lowercase(coalesce(sort.side[i], "")) for i in keep],
        fill(bone, length(keep)), fill("", length(keep)), collect(String, measurements), values,
    )
end

on_side(rows::Rows, side) = subset(rows, rows.side .== side)
measured_in(measurements, sort::SortTable) = String[m for m in measurements if m in sort.measurements]

# Whether each specimen has any of the selected measurements
measured(rows::Rows) = [any(!ismissing, view(rows.values, i, :)) for i in 1:length(rows)]

# Reference individuals present on both sides, row for row.
function paired(a::Rows, b::Rows)
    return subset(a, in.(a.accession, Ref(Set(b.accession)))), subset(b, in.(b.accession, Ref(Set(a.accession))))
end

function prepared(refa, refb, sorta, sortb)
    (length(refa) == 0 || length(refb) == 0) && return nothing
    (length(sorta) == 0 || length(sortb) == 0) && return nothing
    keepa, keepb = measured(sorta), measured(sortb)
    return Prepared((refa, refb, subset(sorta, keepa), subset(sortb, keepb), subset(sorta, .!keepa), subset(sortb, .!keepb)))
end

# Left against right of the same bone.
function pair_match_input(groups, sort::SortTable, bone, measurements)
    measurements = measured_in(measurements, sort)
    isempty(measurements) && return nothing
    bone = lowercase(bone)
    ref = reference_rows(groups, bone, measurements)
    refleft, refright = paired(on_side(ref, "left"), on_side(ref, "right"))
    cases = sort_rows(sort, bone, measurements)
    return prepared(refleft, refright, on_side(cases, "left"), on_side(cases, "right"))
end

# Two different bones, each on its own side. Articulation uses the same side
# for both; regression lets them differ.
function two_bone_input(groups, sort::SortTable, bonea, boneb, sidea, sideb, measurementsa, measurementsb)
    measurementsa = measured_in(measurementsa, sort)
    measurementsb = measured_in(measurementsb, sort)
    (isempty(measurementsa) || isempty(measurementsb)) && return nothing
    bonea, boneb, sidea, sideb = lowercase.((bonea, boneb, sidea, sideb))
    refa, refb = paired(
        on_side(reference_rows(groups, bonea, measurementsa), sidea),
        on_side(reference_rows(groups, boneb, measurementsb), sideb),
    )
    return prepared(
        refa, refb,
        on_side(sort_rows(sort, bonea, measurementsa), sidea),
        on_side(sort_rows(sort, boneb, measurementsb), sideb),
    )
end

# Measurements of a bone with at least one value in the selected groups.
function available_measurements(groups, bone)
    bone = lowercase(bone)
    tables = [table for group in groups for (name, table) in group.bones if lowercase(name) == bone]
    isempty(tables) && return String[]
    return [code for (j, code) in enumerate(first(tables).measurements)
            if any(table -> any(!ismissing, view(table.values, :, j)), tables)]
end

# Bone whose table holds values for a measurement in the selected groups.
function measurement_bone(groups, code)
    for group in groups, (name, table) in group.bones
        column = findfirst(==(code), table.measurements)
        column !== nothing && any(!ismissing, view(table.values, :, column)) && return name
    end
    return nothing
end

const ArticulationPair = @NamedTuple{bonea::String, boneb::String, a::String, b::String}

# Articulating measurement pairs from the config that the selected groups have
# data for, with the bone each measurement belongs to.
function articulation_pairs(groups, config)
    pairs = ArticulationPair[]
    for (a, b) in config
        bonea, boneb = measurement_bone(groups, a), measurement_bone(groups, b)
        (bonea === nothing || boneb === nothing) && continue
        push!(pairs, (bonea = bonea, boneb = boneb, a = a, b = b))
    end
    return pairs
end
