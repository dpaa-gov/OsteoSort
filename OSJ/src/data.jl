# The data an osteometric sorting analysis works on: reference measurements
# grouped by population, and the case specimens to be sorted.

# One bone's rows for one reference group. `values` is rows × measurements.
struct BoneTable
    accession::Vector{String}
    side::Vector{String}
    measurements::Vector{String}
    values::Matrix{Union{Missing, Float64}}
end

# A reference population (collection, ancestry, sex) and its bones by name.
struct ReferenceGroup
    label::String
    collection::String
    ancestry::String
    sex::String
    bones::Dict{String, BoneTable}
end

# Case measurements as entered: one row per bone, missing where blank.
struct SortTable
    accession::Vector{Union{Missing, String}}
    side::Vector{Union{Missing, String}}
    element::Vector{Union{Missing, String}}
    measurements::Vector{String}
    values::Matrix{Union{Missing, Float64}}
end

# Measurements with at least one value, in column order.
function available_measurements(table::BoneTable)
    return [code for (j, code) in enumerate(table.measurements)
            if any(!ismissing, view(table.values, :, j))]
end
