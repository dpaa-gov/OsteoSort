# Uploaded case data, read into OSJ's SortTable. A small RFC 4180 reader is
# enough for the template format and keeps a CSV package out of the image.

# The field read so far, added to its row
finish_field!(row::Vector{String}, field::IOBuffer) = push!(row, String(take!(field)))

# The end of a line: its last field is added, and the row kept if the line had anything on it
function finish_row!(rows::Vector{Vector{String}}, row::Vector{String}, field::IOBuffer, touched::Bool)
    finish_field!(row, field)
    touched && push!(rows, row)
    return
end

function parse_csv(text::AbstractString)
    rows = Vector{String}[]
    row = String[]
    field = IOBuffer()
    quoted = false      # inside a quoted field
    started = false     # current field has any content
    touched = false     # current line has any content
    chars = collect(startswith(text, '﻿') ? chop(text; head = 1, tail = 0) : text)
    i = 1
    while i <= length(chars)
        c = chars[i]
        if quoted
            if c == '"'
                if i < length(chars) && chars[i + 1] == '"'
                    write(field, '"')
                    i += 1
                else
                    quoted = false
                end
            else
                write(field, c)
            end
        elseif c == '"' && !started
            # a quote opens a quoted field only at its start; elsewhere it is an ordinary character
            quoted = true
            started = true
            touched = true
        elseif c == ','
            finish_field!(row, field)
            started = false
            touched = true
        elseif c == '\n' || (c == '\r' && !(i < length(chars) && chars[i + 1] == '\n'))
            # a line may end with "\n", "\r\n" or, in old Mac files, "\r" alone
            finish_row!(rows, row, field, touched)
            row = String[]
            started = false
            touched = false
        elseif c == '\r'
            # the "\r" of "\r\n": the "\n" ends the line
        else
            write(field, c)
            started = true
            touched = true
        end
        i += 1
    end
    (touched || !isempty(row)) && finish_row!(rows, row, field, touched)
    return rows
end

const NA_STRINGS = ("", " ", "NA")

na_string(value) = value in NA_STRINGS ? missing : value

# A measurement is a length: anything that is not a finite number above zero
# ("NaN", "Inf", 0, a negative, text) is read as not taken.
function na_number(value)
    value in NA_STRINGS && return missing
    number = tryparse(Float64, strip(value))
    return number !== nothing && isfinite(number) && number > 0 ? number : missing
end

const ID_COLUMNS = ("accession", "side", "element")

# Where the three id columns are. They are found by name, in any position;
# a file whose headings do not use those names is read as before, with the
# first three columns taken as accession, side and element.
function id_columns(header)
    named = [findfirst(==(name), header) for name in ID_COLUMNS]
    return any(isnothing, named) ? [1, 2, 3] : Int.(named)
end

# The table of measurements has a cell for every row under every column of
# the header, filled in or not, at 9 bytes each. A file's size on disk does
# not bound that: a very wide header over many near-empty rows is small to
# upload and gigabytes as a table, more than the pod has. So a file may have
# at most this many cells, about 90 MB: half as many again as 30,000
# specimens with every measurement ARDS has.
const MAX_UPLOAD_CELLS = 10_000_000

# Every other column is a measurement, matched to ARDS by lower-cased name.
function read_upload(text::AbstractString)
    rows = parse_csv(text)
    length(rows) >= 1 && length(rows[1]) > 3 ||
        throw(ArgumentError("The file needs accession, side and element columns followed by measurements"))
    header = lowercase.(strip.(rows[1]))
    ids = id_columns(header)
    columns = setdiff(eachindex(header), ids)
    data = rows[2:end]
    cells = length(data) * length(columns)
    cells <= MAX_UPLOAD_CELLS || throw(ArgumentError(
        "The file is too large a table: $(thousands(length(data))) rows by $(thousands(length(columns))) measurement columns " *
        "is $(thousands(cells)) cells, and a case file can have at most $(thousands(MAX_UPLOAD_CELLS)). " *
        "Remove the columns that are not measurements, or upload fewer specimens at a time."))
    cell(row, j) = j <= length(row) ? row[j] : ""
    values = Matrix{Union{Missing, Float64}}(undef, length(data), length(columns))
    for (i, row) in enumerate(data), (k, j) in enumerate(columns)
        values[i, k] = na_number(cell(row, j))
    end
    # spaces around an id are never meant: "Right " is the right side
    column(j) = Union{Missing, String}[na_string(String(strip(cell(row, j)))) for row in data]
    return SortTable(column(ids[1]), column(ids[2]), column(ids[3]), String.(header[columns]), values)
end
