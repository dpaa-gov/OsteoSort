# A table of results: named columns, each a vector of text, whole numbers or
# decimals. Each analysis has columns of its own, so which there are is not
# known in advance; but every column is one of these three kinds, and code
# that works on any column tells them apart itself, so that a trimmed build
# can follow it.

const Column = Union{Vector{String}, Vector{Int}, Vector{Float64}}

struct ResultTable
    names::Vector{Symbol}
    columns::Vector{Column}
end

# A table from named columns, as in `ResultTable((id = ["a"], p = [0.5]))`
ResultTable(table::NamedTuple) = ResultTable(collect(Symbol, keys(table)), Column[column for column in table])

# The column of that name
function Base.getindex(table::ResultTable, name::Symbol)::Column
    j = findfirst(==(name), table.names)
    j === nothing && throw(KeyError(name))
    return table.columns[j]
end

row_count(table::ResultTable)::Int = isempty(table.columns) ? 0 : length(first(table.columns))

# Some of a column's rows, in the order of `keep` (row numbers or one flag per row)
function select(column::Column, keep)::Column
    column isa Vector{String} && return column[keep]
    column isa Vector{Int} && return column[keep]
    return (column::Vector{Float64})[keep]
end

select_rows(table::ResultTable, keep)::ResultTable = ResultTable(table.names, Column[select(column, keep) for column in table.columns])
