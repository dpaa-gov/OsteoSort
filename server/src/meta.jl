# Everything the browser needs to build and filter its dropdowns.

# Reference groups selected when the page opens (config/default_references.csv)
default_references(config::Config)::Vector{String} =
    String[row[1] for row in read_config_rows(joinpath(config.config_dir, "default_references.csv"))]

articulation_config(config::Config)::Vector{Tuple{String, String}} =
    Tuple{String, String}[(lowercase(row[1]), lowercase(row[2])) for row in read_config_rows(joinpath(config.config_dir, "articulation.csv"))]
regression_config(config::Config)::Vector{String} =
    String[lowercase(row[1]) for row in read_config_rows(joinpath(config.config_dir, "regression_bones.csv"))]

# What the page is told about one bone of one group, about a group, and in all
const ElementMeta = @NamedTuple{element::String, rows::Int, sides::Vector{String}, measurements::Vector{String}}
const GroupMeta = @NamedTuple{label::String, elements::Vector{ElementMeta}}
const Meta = @NamedTuple{version::String, loaded_at::String, default_references::Vector{String}, groups::Vector{GroupMeta},
    bones::Vector{String}, measurements::Vector{Measurement}, disabled_measurements::Vector{String},
    regression_bones::Vector{String}, articulation::Vector{@NamedTuple{a::String, b::String}}}

# A time as Julia writes one, 2026-10-09T18:30:05.250: the thousandths of a
# second only where there are any, and then all three figures of them
function timestamp(time::DateTime)::String
    two(n::Int)::String = n < 10 ? "0" * string(n) : string(n)
    year = Dates.year(time)
    written = (year < 10 ? "000" : year < 100 ? "00" : year < 1000 ? "0" : "") * string(year) * "-" * two(Dates.month(time)) * "-" *
        two(Dates.day(time)) * "T" * two(Dates.hour(time)) * ":" * two(Dates.minute(time)) * ":" * two(Dates.second(time))
    thousandths = Dates.millisecond(time)
    thousandths == 0 && return written
    return written * "." * string(thousandths ÷ 100) * string(thousandths ÷ 10 % 10) * string(thousandths % 10)
end

function build_meta(snapshot::ReferenceSnapshot, config::Config)::Meta
    labels = String[g.label for g in snapshot.groups]
    wanted = Set{String}(lowercase(label) for label in default_references(config))
    groups = GroupMeta[]
    for group in snapshot.groups
        elements = ElementMeta[]
        for bone in snapshot.bones
            table = get(group.bones, bone, nothing)
            table === nothing && continue
            push!(elements, (element = bone, rows = length(table.accession), sides = sort(unique(table.side)),
                             measurements = available_measurements(table)))
        end
        push!(groups, (label = group.label, elements = elements))
    end
    return (
        version = config.version,
        loaded_at = timestamp(snapshot.loaded_at) * "Z",
        default_references = String[label for label in labels if lowercase(label) in wanted],
        groups = groups,
        bones = snapshot.bones,
        measurements = snapshot.measurements,
        disabled_measurements = snapshot.disabled,
        regression_bones = regression_config(config),
        articulation = @NamedTuple{a::String, b::String}[(a = a, b = b) for (a, b) in articulation_config(config)],
    )
end
