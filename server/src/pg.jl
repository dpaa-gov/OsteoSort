# A thin PostgreSQL client: what the reference load needs and no more, calling
# the PostgreSQL C library (libpq) directly. Every value comes back as the
# text the server sent, and is read out as the type its column is known to be.
#
# It stands in for LibPQ.jl, which brought a logging framework, time zones,
# intervals, decimals and some thirty packages with it, none of them used
# here, and which a trimmed build cannot take.
module PG

using LibPQ_jll

# Where the PostgreSQL C library is, known once the program has started
libpq::String = ""
__init__() = (global libpq = String(LibPQ_jll.LIBPQ_HANDLE_path); nothing)

struct Error <: Exception
    message::String
    sqlstate::String # PostgreSQL's five-character code: "42P01" no such table, "42703" no such column
end

# The error in words
describe(e::Error)::String = "PostgreSQL: " * String(strip(e.message)) * (isempty(e.sqlstate) ? "" : " (" * e.sqlstate * ")")

Base.showerror(io::IO, e::Error) = print(io, describe(e))

undefined_table(e::Error) = e.sqlstate == "42P01"
undefined_column(e::Error) = e.sqlstate == "42703"

mutable struct Connection
    handle::Ptr{Cvoid}
end

text(pointer::Cstring)::String = pointer == C_NULL ? "" : unsafe_string(pointer)

# Connects with a libpq connection string. `connect_timeout` and `options` in
# it apply as libpq documents them. The call waits in C, and says so to
# Julia, so that the rest of the program is not held up meanwhile.
function connect(conninfo::String)::Connection
    handle = @ccall gc_safe = true libpq.PQconnectdb(conninfo::Cstring)::Ptr{Cvoid}
    handle == C_NULL && throw(Error("could not allocate a connection", ""))
    if (@ccall libpq.PQstatus(handle::Ptr{Cvoid})::Cint) != 0 # CONNECTION_OK
        message = text(@ccall libpq.PQerrorMessage(handle::Ptr{Cvoid})::Cstring)
        @ccall libpq.PQfinish(handle::Ptr{Cvoid})::Cvoid
        throw(Error(message, ""))
    end
    return Connection(handle)
end

function Base.close(conn::Connection)::Nothing
    conn.handle == C_NULL || @ccall libpq.PQfinish(conn.handle::Ptr{Cvoid})::Cvoid
    conn.handle = C_NULL
    return nothing
end

# A query's rows: each cell the text the server sent, or nothing for NULL
struct Result
    names::Vector{String}
    cells::Matrix{Union{Nothing, String}}
end

rows(result::Result)::Int = size(result.cells, 1)

function query(conn::Connection, sql::String)::Result
    conn.handle == C_NULL && throw(Error("the connection is closed", ""))
    res = @ccall gc_safe = true libpq.PQexec(conn.handle::Ptr{Cvoid}, sql::Cstring)::Ptr{Cvoid}
    res == C_NULL && throw(Error(text(@ccall libpq.PQerrorMessage(conn.handle::Ptr{Cvoid})::Cstring), ""))
    try
        status = @ccall libpq.PQresultStatus(res::Ptr{Cvoid})::Cint
        if status != 2 && status != 1 # PGRES_TUPLES_OK, PGRES_COMMAND_OK
            message = text(@ccall libpq.PQresultErrorMessage(res::Ptr{Cvoid})::Cstring)
            state = text(@ccall libpq.PQresultErrorField(res::Ptr{Cvoid}, Cint('C')::Cint)::Cstring)
            throw(Error(message, state))
        end
        n = Int(@ccall libpq.PQntuples(res::Ptr{Cvoid})::Cint)
        m = Int(@ccall libpq.PQnfields(res::Ptr{Cvoid})::Cint)
        names = String[text(@ccall libpq.PQfname(res::Ptr{Cvoid}, (j - 1)::Cint)::Cstring) for j in 1:m]
        cells = Matrix{Union{Nothing, String}}(undef, n, m)
        for j in 1:m, i in 1:n
            null = (@ccall libpq.PQgetisnull(res::Ptr{Cvoid}, (i - 1)::Cint, (j - 1)::Cint)::Cint) != 0
            cells[i, j] = null ? nothing : text(@ccall libpq.PQgetvalue(res::Ptr{Cvoid}, (i - 1)::Cint, (j - 1)::Cint)::Cstring)
        end
        return Result(names, cells)
    finally
        @ccall libpq.PQclear(res::Ptr{Cvoid})::Cvoid
    end
end

function column_index(result::Result, name::String)::Int
    j = findfirst(==(name), result.names)
    j === nothing && throw(Error("no column named " * name, ""))
    return j
end

# A column, read as the type the caller expects.

# Text from a column that is never NULL
function texts(result::Result, name::String)::Vector{String}
    j = column_index(result, name)
    column = Vector{String}(undef, rows(result))
    for i in 1:rows(result)
        cell = result.cells[i, j]
        cell === nothing && throw(Error("column " * name * " has an empty value where none is allowed", ""))
        column[i] = cell
    end
    return column
end

function strings(result::Result, name::String)::Vector{Union{Missing, String}}
    j = column_index(result, name)
    return Union{Missing, String}[(cell = result.cells[i, j]; cell === nothing ? missing : cell) for i in 1:rows(result)]
end

function floats(result::Result, name::String)::Vector{Union{Missing, Float64}}
    j = column_index(result, name)
    return Union{Missing, Float64}[(cell = result.cells[i, j]; cell === nothing ? missing : parse(Float64, cell)) for i in 1:rows(result)]
end

# PostgreSQL writes a boolean as t or f
function bools(result::Result, name::String)::Vector{Union{Missing, Bool}}
    j = column_index(result, name)
    return Union{Missing, Bool}[(cell = result.cells[i, j]; cell === nothing ? missing : cell == "t") for i in 1:rows(result)]
end

end
