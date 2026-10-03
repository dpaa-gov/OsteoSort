# ARDS reference data, loaded once and shared by every request. The group
# and bone-table types it fills are OSJ's.

const Measurement = @NamedTuple{code::String, bone::String, name::Union{String, Nothing}}

struct ReferenceSnapshot
    groups::Vector{ReferenceGroup}
    measurements::Vector{Measurement}
    bones::Vector{String}
    disabled::Vector{String} # ARDS measurements switched off for OsteoSort
    loaded_at::DateTime
end

quote_identifier(name) = "\"" * replace(name, "\"" => "\"\"") * "\""

query(conn, sql, params = ()) = Tables.columntable(LibPQ.execute(conn, sql, collect(params)))

function load_reference(config::Config)
    conn = LibPQ.Connection(conninfo(config))
    try
        return load_reference(conn)
    finally
        close(conn)
    end
end

function load_reference(conn::LibPQ.Connection)
    group_rows = query(conn, """
        SELECT DISTINCT i.collection || ' ' || i.ancestry || ' ' || i.sex AS group_label,
               i.collection, i.ancestry, i.sex
        FROM osteometry.individuals i
        INNER JOIN osteometry.collections c ON i.collection = c.collection
        WHERE c.osteosort_method = TRUE AND i.osteosort_method = TRUE
        ORDER BY i.collection, i.ancestry, i.sex""")
    groups = ReferenceGroup[]
    for i in eachindex(group_rows.group_label)
        fields = (group_rows.group_label[i], group_rows.collection[i], group_rows.ancestry[i], group_rows.sex[i])
        any(ismissing, fields) && continue # individuals without ancestry or sex belong to no group
        push!(groups, ReferenceGroup(fields..., Dict{String, BoneTable}()))
    end
    group_index = Dict((g.collection, g.ancestry, g.sex) => i for (i, g) in enumerate(groups))

    measurement_rows = query(conn, """
        SELECT ards, bone, full_name FROM osteometry.measurements
        WHERE osteosort_method = TRUE ORDER BY bone, ards""")
    measurements = Measurement[
        (code = lowercase(measurement_rows.ards[i]), bone = measurement_rows.bone[i],
         name = coalesce(measurement_rows.full_name[i], nothing))
        for i in eachindex(measurement_rows.ards)
    ]
    bones = unique(m.bone for m in measurements)
    disabled = lowercase.(query(conn, """
        SELECT ards FROM osteometry.measurements WHERE osteosort_method = FALSE ORDER BY ards""").ards)

    for bone in bones
        isempty(groups) && break
        codes = [m.code for m in measurements if m.bone == bone]
        # PostgreSQL folded the original unquoted measurement identifiers to lower case.
        table = "osteometry." * quote_identifier(replace(lowercase(bone), " " => "_"))
        columns = join(("b." * quote_identifier(code) for code in codes), ", ")
        rows = try
            query(conn, """
                SELECT i.collection, i.ancestry, i.sex, i.accession, b.side, $columns
                FROM $table b
                INNER JOIN osteometry.individuals i ON b.accession = i.accession
                INNER JOIN osteometry.collections c ON c.collection = i.collection
                WHERE i.osteosort_method = TRUE AND c.osteosort_method = TRUE""")
        catch e
            # A bone ARDS lists but has no table or column for is left out. Any
            # other failure fails the load, so the previous snapshot is kept.
            e isa Union{LibPQ.Errors.UndefinedTable, LibPQ.Errors.UndefinedColumn} || rethrow()
            @warn "Could not load reference data" bone exception = e
            continue
        end
        members = [Int[] for _ in groups]
        for r in eachindex(rows.accession)
            key = (rows.collection[r], rows.ancestry[r], rows.sex[r])
            any(ismissing, key) && continue
            g = get(group_index, key, 0)
            g == 0 || push!(members[g], r)
        end
        value_columns = [getproperty(rows, Symbol(code)) for code in codes]
        for (g, idx) in enumerate(members)
            isempty(idx) && continue
            values = Matrix{Union{Missing, Float64}}(undef, length(idx), length(codes))
            for (j, column) in enumerate(value_columns), (i, r) in enumerate(idx)
                values[i, j] = column[r]
            end
            groups[g].bones[bone] = BoneTable(rows.accession[idx], rows.side[idx], codes, values)
        end
    end
    return ReferenceSnapshot(groups, measurements, bones, disabled, now(UTC))
end
