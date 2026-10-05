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

# A measurement's number in the data collection manual (ARDS column utk2016),
# or nothing where it has none or it is not a number.
function manual_number(value)
    value isa AbstractString || return nothing
    found = match(r"^\s*(\d+)", value)
    return found === nothing ? nothing : parse(Int, found[1])
end

# The order bones are listed in. The manual numbers its measurements head to
# toe, so a bone's lowest number places it: clavicle, scapula, humerus, radius,
# ulna, os coxa, femur, tibia, fibula, calcaneus. Bones the manual does not
# cover (hand and foot bones, patella, talus) follow, by name. ARDS holds no
# order for bones as such; this one comes from numbers it keeps for another
# reason, across all of a bone's measurements, so switching a measurement off
# for OsteoSort never moves a bone.
function bone_order(bones, bone_of_measurement, numbers)
    lowest = Dict{String, Int}()
    for (bone, value) in zip(bone_of_measurement, numbers)
        number = manual_number(value)
        number === nothing || (lowest[bone] = min(get(lowest, bone, typemax(Int)), number))
    end
    return sort(unique(bones); by = bone -> (get(lowest, bone, typemax(Int)), bone))
end

# Every measurement ARDS lists, with whether it is switched on for OsteoSort.
# An ARDS without the manual's numbers still loads: its bones are then by name.
function measurement_list(conn)
    try
        return query(conn, "SELECT ards, bone, full_name, osteosort_method, utk2016 FROM osteometry.measurements ORDER BY bone, ards")
    catch e
        e isa LibPQ.Errors.UndefinedColumn || rethrow()
        rows = query(conn, "SELECT ards, bone, full_name, osteosort_method FROM osteometry.measurements ORDER BY bone, ards")
        return merge(rows, (utk2016 = fill(missing, length(rows.ards)),))
    end
end

function load_reference(config::Config)
    # LibPQ connects without blocking, where libpq ignores the connect_timeout
    # in the connection string; this is the one that applies. An ARDS that
    # does not answer fails the load in 10 seconds, not the system's two minutes.
    conn = LibPQ.Connection(conninfo(config); connect_timeout = 10)
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

    listed = measurement_list(conn)
    on = [i for i in eachindex(listed.ards) if listed.osteosort_method[i]]
    bones = bone_order(listed.bone[on], listed.bone, listed.utk2016)
    place = Dict(bone => i for (i, bone) in enumerate(bones))
    # bone by bone in that order, a bone's measurements by code
    measurements = Measurement[
        (code = lowercase(listed.ards[i]), bone = listed.bone[i], name = coalesce(listed.full_name[i], nothing))
        for i in sort(on; by = i -> (place[listed.bone[i]], listed.ards[i]))
    ]
    disabled = sort!(String[lowercase(listed.ards[i]) for i in eachindex(listed.ards) if !listed.osteosort_method[i]])

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
