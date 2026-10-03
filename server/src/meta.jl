# Everything the browser needs to build and filter its dropdowns.

# Reference groups selected when the page opens (config/default_references.csv)
default_references(config::Config) =
    [row[1] for row in read_config_rows(joinpath(config.config_dir, "default_references.csv"))]

articulation_config(config::Config) =
    [(lowercase(row[1]), lowercase(row[2])) for row in read_config_rows(joinpath(config.config_dir, "articulation.csv"))]
regression_config(config::Config) =
    [lowercase(row[1]) for row in read_config_rows(joinpath(config.config_dir, "regression_bones.csv"))]

function build_meta(snapshot::ReferenceSnapshot, config::Config)
    labels = [g.label for g in snapshot.groups]
    wanted = Set(lowercase.(default_references(config)))
    groups = map(snapshot.groups) do group
        elements = [
            (element = bone, rows = length(table.accession), sides = sort(unique(table.side)),
             measurements = available_measurements(table))
            for bone in snapshot.bones for table in (get(group.bones, bone, nothing),) if table !== nothing
        ]
        (label = group.label, elements = elements)
    end
    articulation = [(a = a, b = b) for (a, b) in articulation_config(config)]
    regression_bones = regression_config(config)
    return (
        version = config.version,
        loaded_at = string(snapshot.loaded_at) * "Z",
        default_references = [label for label in labels if lowercase(label) in wanted],
        groups = groups,
        bones = snapshot.bones,
        measurements = snapshot.measurements,
        disabled_measurements = snapshot.disabled,
        regression_bones = regression_bones,
        articulation = articulation,
    )
end
