# Analysis endpoints: request validation, single comparisons, batch jobs,
# paged results and CSV downloads.

# A case file can be at most 5 MB, about 30,000 specimens with every
# measurement filled in; the page checks that too. The request carrying it
# can be up to twice the size, as line ends and quotes are escaped.
const MAX_FILE_BYTES = 5 * 1024^2
const MAX_BODY_BYTES = 12 * 1024^2
const TOO_LARGE = "The file is too large: a case file can be at most 5 MB"
const REFERENCE_CHANGED = "The reference data has changed. Reload the page and try again."

bad_request(message::String) = throw(RequestError(400, message))

# A request as it is read: an object of named values, each of which may be
# anything JSON can hold. Every value is told to be one exact kind of thing
# before it is used: a trimmed build has to know which.
const Body = JSON.Object{String, Any}

# The most digits in a row a number in a request may have. No measurement or
# setting needs more than 17; a number of millions of digits takes the parser
# minutes to read, and the server answers nothing else while it does.
const MAX_NUMBER_DIGITS = 40
const NUMBER_TOO_LONG = "A number in the request is too long to be read"

# Whether a JSON text has a run of more than `most` digits outside its
# strings. A case file travels inside a string, where a long run of digits is
# text (an accession number, say) and costs nothing to read.
function long_number(text::AbstractVector{UInt8}, most = MAX_NUMBER_DIGITS)
    in_string = false
    escaped = false
    run = 0
    @inbounds for byte in text
        if in_string
            if escaped
                escaped = false
            elseif byte == UInt8('\\')
                escaped = true
            elseif byte == UInt8('"')
                in_string = false
            end
        elseif UInt8('0') <= byte <= UInt8('9')
            (run += 1) > most && return true
        else
            run = 0
            byte == UInt8('"') && (in_string = true)
        end
    end
    return false
end

# A request's bytes, in whichever form HTTP.jl holds them. Those the server
# read itself are used as they are: a case file copied would be held twice.
# One sent with no body at all is as good as empty.
function request_bytes(req::HTTP.Request)::Vector{UInt8}
    body = req.body
    body isa HTTP.EmptyBody && return UInt8[]
    body isa HTTP.BytesBody{Vector{UInt8}} && body.next_index == 1 && return body.data
    return Vector{UInt8}(copy(body))
end

function read_json(req::HTTP.Request)::Body
    bytes = request_bytes(req)
    length(bytes) <= MAX_BODY_BYTES || throw(RequestError(413, TOO_LARGE))
    long_number(bytes) && bad_request(NUMBER_TOO_LONG)
    body = try
        JSON.parse(bytes)
    catch
        bad_request("The request body is not valid JSON")
    end
    body isa Body || bad_request("The request body must be a JSON object")
    return body
end

field(body::Body, name::String) = haskey(body, name) ? body[name] : bad_request("Missing field: " * name)

function text_field(body::Body, name::String)::String
    value = field(body, name)
    value isa String || bad_request(name * " must be text")
    return value
end

function list_field(body::Body, name::String)::Vector{String}
    value = field(body, name)
    value isa Vector{Any} || bad_request(name * " must be a list of text values")
    list = String[]
    for item in value
        item isa String || bad_request(name * " must be a list of text values")
        push!(list, item)
    end
    return list
end

# A number from a request as an ordinary one, or NaN for anything else. JSON
# gives a number as one of these four kinds. One too large or too small to be
# ordinary arrives as a big number that passes a check itself but is infinite
# or zero once converted, so it is converted before it is checked. True and
# false are not numbers here, though Julia counts them as 1 and 0.
plain_number(value)::Float64 =
    value isa Float64 ? value :
    value isa Int64 ? Float64(value) :
    value isa BigInt ? Float64(value) :
    value isa BigFloat ? Float64(value) : NaN

function alpha_field(body::Body)::Float64
    alpha = plain_number(field(body, "alpha"))
    0 < alpha <= 1 || bad_request("alpha must be a number above 0 and at most 1")
    return alpha
end

function setting_flag(settings::Body, name::String)::Bool
    value = get(settings, name, false)
    value isa Bool || bad_request("settings." * name * " must be true or false")
    return value
end

function settings_field(body::Body)::Settings
    settings = field(body, "settings")
    settings isa Body || bad_request("settings must be an object")
    tails = get(settings, "tails", 2)
    tails isa Int64 || bad_request("settings.tails must be 1 or 2")
    tails in (1, 2) || bad_request("settings.tails must be 1 or 2")
    return Settings(setting_flag(settings, "absolute"), setting_flag(settings, "yeojohnson"), setting_flag(settings, "zeromean"), tails)
end

# Typed-in measurements by code; blank fields are null or left out
function values_field(body::Body, name::String)::Dict{String, Union{Nothing, Float64}}
    value = field(body, name)
    value isa Body || bad_request(name * " must be an object of measurement values")
    entries = Dict{String, Union{Nothing, Float64}}()
    for (code, number) in value
        amount = number === nothing ? nothing : plain_number(number)
        amount === nothing || isfinite(amount) && amount > 0 || bad_request(uppercasefirst(code) * " must be a number above 0")
        entries[lowercase(code)] = amount
    end
    return entries
end

function current_snapshot(state::AppState)::ReferenceSnapshot
    (@atomic state.snapshot) === nothing && ensure_fresh!(state)
    snapshot = @atomic state.snapshot
    snapshot === nothing && throw(RequestError(503, "Reference data could not be loaded from ARDS"))
    return snapshot
end

function selected_groups(snapshot::ReferenceSnapshot, labels::Vector{String})::Vector{ReferenceGroup}
    isempty(labels) && bad_request("Select at least one reference group")
    by_label = Dict{String, ReferenceGroup}(group.label => group for group in snapshot.groups)
    all(label -> haskey(by_label, label), labels) || throw(RequestError(409, REFERENCE_CHANGED))
    # a group named twice is one group: its individuals are not counted twice
    return ReferenceGroup[by_label[label] for label in unique(labels)]
end

# --- Tables as JSON and CSV ---

# Column headings. The two specimens of a comparison are numbered:
# "Accession 1", "Element 1", "Side 1", then "Accession 2" and so on. Words
# start with a capital; the symbols n and p keep the case they are written in.
function display_name(name::Symbol)::String
    text = replace(String(name), r"^x_(.*)$" => s"\1_1", r"^y_(.*)$" => s"\1_2")
    text = replace(text, r"^id(?=_)" => "accession")
    text = replace(text, r"_([12])$" => s" \1")
    text in ("n", "p") && return text
    return text == "r2" ? "R²" : text == "sd" ? "SD" : uppercasefirst(text)
end

# A cell as the page is sent it: a number, a count, text, or nothing where a
# number is not one (sent as null)
const Cell = Union{Nothing, Float64, Int, String}

function json_cell(column::Column, i::Int)::Cell
    if column isa Vector{Float64}
        value = column[i]
        return isfinite(value) ? value : nothing
    end
    column isa Vector{Int} && return column[i]
    return (column::Vector{String})[i]
end

const TableJSON = @NamedTuple{columns::Vector{String}, rows::Vector{Vector{Cell}}}

function table_json(table::ResultTable, rows::AbstractVector{Int} = 1:row_count(table))::TableJSON
    return (columns = String[display_name(name) for name in table.names],
            rows = Vector{Cell}[Cell[json_cell(column, i) for column in table.columns] for i in rows])
end

csv_cell(value::String)::String = "\"" * replace(value, "\"" => "\"\"") * "\""
csv_cell(value::Int)::String = string(value)
# Fixed notation. Every number in a result table is rounded to four places.
csv_cell(value::Float64)::String = isfinite(value) ? String(rstrip(rstrip(@sprintf("%.4f", value), '0'), '.')) : string(value)

function csv_cell(column::Column, i::Int)::String
    column isa Vector{String} && return csv_cell(column[i])
    column isa Vector{Int} && return csv_cell(column[i])
    return csv_cell((column::Vector{Float64})[i])
end

# A cell as the table shows it, which is what a search is matched against
cell_text(value::Float64)::String = csv_cell(value)
cell_text(value::Int)::String = string(value)
cell_text(value::String)::String = value

function cell_text(column::Column, i::Int)::String
    column isa Vector{String} && return cell_text(column[i])
    column isa Vector{Int} && return cell_text(column[i])
    return cell_text((column::Vector{Float64})[i])
end

csv_heading(table::ResultTable)::String = join((csv_cell(display_name(name)) for name in table.names), ",") * "\n"

function csv_rows(table::ResultTable, rows::AbstractVector{Int})::Vector{UInt8}
    io = IOBuffer()
    for i in rows
        println(io, join((csv_cell(column, i) for column in table.columns), ","))
    end
    return take!(io)
end

# A download is written this many rows at a time, about 1 MB, so that no more
# of it than that is in memory: whole, a table of 1.5 million rows is 266 MB.
const CSV_PIECE_ROWS = 5_000

# Writes a table to `io` as CSV, a piece at a time. `wanted` is asked before
# each piece and the writing stops when it says no. Returns whether the whole
# table was written.
function write_csv(io::IO, table::ResultTable; wanted::F = () -> true, piece::Int = CSV_PIECE_ROWS)::Bool where {F}
    write(io, csv_heading(table))
    total = row_count(table)
    for start in 1:piece:total
        wanted() || return false
        write(io, off_thread(Vector{UInt8}, () -> csv_rows(table, start:min(start + piece - 1, total))))
    end
    return true
end

# --- A plan's tables as one list ---

# The tables of a plan's tests are alike but for what each analysis reports:
# a t-test its mean and SD, a regression its R². Together they are one list
# with every such column, each row's test named first, and a cell left empty
# where its analysis has no such number. The columns are in this order
# whichever tests there are; one not known here would follow them.
const COMBINED_ORDER = ("Accession 1", "Element 1", "Side 1", "Accession 2", "Element 2", "Side 2",
                        "Measurements", "n", "Mean", "SD", "R²", "p", "Result", "Reference", "Reason")

function combined_headings(tables::Vector{ResultTable})::Vector{String}
    present = String[]
    for table in tables, name in table.names
        heading = display_name(name)
        heading in present || push!(present, heading)
    end
    return vcat(String[heading for heading in COMBINED_ORDER if heading in present],
                String[heading for heading in present if !(heading in COMBINED_ORDER)])
end

# Rows of one test's table under the list's headings. `places` says which of
# the table's columns is under each heading, 0 where it has none.
function combined_rows(test::String, table::ResultTable, places::Vector{Int}, rows::AbstractVector{Int})::Vector{UInt8}
    io = IOBuffer()
    named = csv_cell(test)
    for i in rows
        print(io, named)
        for j in places
            print(io, ",")
            j == 0 || print(io, csv_cell(table.columns[j], i))
        end
        print(io, "\n")
    end
    return take!(io)
end

# Writes the tables to `io` as one CSV, a piece at a time, as `write_csv`
# writes one. Returns whether all of it was written.
function write_combined(io::IO, tests::Vector{String}, tables::Vector{ResultTable};
                        wanted::F = () -> true, piece::Int = CSV_PIECE_ROWS)::Bool where {F}
    headings = combined_headings(tables)
    write(io, join((csv_cell(heading) for heading in vcat("Test", headings)), ",") * "\n")
    for (test, table) in zip(tests, tables)
        shown = String[display_name(name) for name in table.names]
        places = Int[something(findfirst(==(heading), shown), 0) for heading in headings]
        total = row_count(table)
        for start in 1:piece:total
            wanted() || return false
            write(io, off_thread(Vector{UInt8}, () -> combined_rows(test, table, places, start:min(start + piece - 1, total))))
        end
    end
    return true
end

# --- Case-file template ---

# Column headings for a case file: the three id columns, then every
# measurement ARDS currently has switched on for OsteoSort, bone by bone.
template_header(snapshot::ReferenceSnapshot) =
    vcat(["accession", "side", "element"], [uppercasefirst(m.code) for m in snapshot.measurements])

# An empty case file to fill in. Built from ARDS on request, so it never
# carries measurements that have been switched off or lacks new ones.
function template_handler(state::AppState)
    header = template_header(current_snapshot(state))
    return HTTP.Response(200, [
        "Content-Type" => "text/csv; charset=utf-8",
        "Content-Disposition" => "attachment; filename=\"template.csv\"",
        "Cache-Control" => "no-store",
    ], join(header, ",") * "\n")
end

# --- Single comparisons ---

function prepare_single(state::AppState, body::Body, analysis::String, groups::Vector{ReferenceGroup})
    if analysis == "pairmatch"
        return prepare_single_pair_match(groups, text_field(body, "element"),
            values_field(body, "left"), values_field(body, "right"))
    elseif analysis == "articulation"
        pairs = articulation_pairs(groups, state.articulation)
        return prepare_single_articulation(groups, pairs, text_field(body, "element_a"), text_field(body, "element_b"),
            text_field(body, "side"), values_field(body, "values_a"), values_field(body, "values_b"))
    elseif analysis == "regression"
        return prepare_single_regression(groups, text_field(body, "element_a"), text_field(body, "element_b"),
            text_field(body, "side_a"), text_field(body, "side_b"),
            values_field(body, "values_a"), values_field(body, "values_b"))
    end
    bad_request("analysis must be pairmatch, articulation or regression")
end

# The settings are nothing for a regression, which has none
function analyse(data, analysis::String, alpha::Float64, settings::Union{Nothing, Settings})::AnalysisResult
    result = try
        analysis == "regression" ? regression_test(data, alpha) :
        ttest(data, alpha, settings::Settings; articulation = analysis == "articulation")
    catch e
        complain("Analysis failed: " * analysis * ": " * describe(e))
        throw(RequestError(422, ANALYSIS_FAILED))
    end
    result === nothing && throw(RequestError(422, NO_RESULT))
    return result
end

function single_handler(state::AppState, req::HTTP.Request)
    body = read_json(req)
    analysis = text_field(body, "analysis")
    groups = selected_groups(current_snapshot(state), list_field(body, "references"))
    alpha = alpha_field(body)
    settings = analysis == "regression" ? nothing : settings_field(body)
    data = prepare_single(state, body, analysis, groups)
    result = in_line(AnalysisResult, () -> analyse(data, analysis, alpha, settings))
    if row_count(result.results) == 0
        reasons = result.rejected[:reason]::Vector{String}
        throw(RequestError(422, isempty(reasons) ? NO_RESULT : "No comparison could be made. " * last(reasons)))
    end
    results = table_json(for_display(result.results))
    # each kind of plot written as itself
    plot = result.plot
    plot isa OSJ.PairPlot && return json_response(200, (analysis = analysis, results = results, plot = plot))
    plot isa OSJ.RegressionPlot && return json_response(200, (analysis = analysis, results = results, plot = plot))
    return json_response(200, (analysis = analysis, results = results, plot = nothing))
end

# --- Batch analyses ---

# What a batch is to be run on. Read from the request before the run is
# queued, so a waiting run does not hold the request, and a missing field is
# refused straight away. Each analysis has fields of its own.
const PairMatchFields = @NamedTuple{element::String, measurements::Vector{String}}
const ArticulationFields = @NamedTuple{element_a::String, element_b::String, measurements_a::Vector{String},
                                       measurements_b::Vector{String}, side::String}
const RegressionFields = @NamedTuple{element_a::String, element_b::String, measurements_a::Vector{String},
                                     measurements_b::Vector{String}, side_a::String, side_b::String}

measurements_field(body::Body, name::String)::Vector{String} = String[lowercase(code) for code in list_field(body, name)]

function multiple_fields(body::Body, analysis::String)::Union{PairMatchFields, ArticulationFields, RegressionFields}
    analysis == "pairmatch" &&
        return PairMatchFields((text_field(body, "element"), measurements_field(body, "measurements")))
    element_a, element_b = text_field(body, "element_a"), text_field(body, "element_b")
    measurements_a, measurements_b = measurements_field(body, "measurements_a"), measurements_field(body, "measurements_b")
    analysis == "articulation" &&
        return ArticulationFields((element_a, element_b, measurements_a, measurements_b, text_field(body, "side")))
    return RegressionFields((element_a, element_b, measurements_a, measurements_b, text_field(body, "side_a"), text_field(body, "side_b")))
end

prepare_multiple(f::PairMatchFields, groups::Vector{ReferenceGroup}, upload::SortTable) =
    prepare_pair_match(groups, upload, f.element, f.measurements)
prepare_multiple(f::ArticulationFields, groups::Vector{ReferenceGroup}, upload::SortTable) =
    prepare_articulation(groups, upload, f.element_a, f.element_b, f.side, f.measurements_a, f.measurements_b)
prepare_multiple(f::RegressionFields, groups::Vector{ReferenceGroup}, upload::SortTable) =
    prepare_regression(groups, upload, f.element_a, f.element_b, f.side_a, f.side_b, f.measurements_a, f.measurements_b)

# The page's previous run, whose results this one replaces
function replaces_field(body::Body)::Union{Nothing, String}
    value = get(body, "replaces", nothing)
    value === nothing && return nothing
    value isa String || bad_request("replaces must be text")
    return value
end

thousands(n) = replace(string(n), r"(?<=\d)(?=(\d{3})+$)" => ",")

# Every pair becomes a result row held in memory, so a run that would make
# more than the store may hold is refused before it starts comparing.
check_size(comparisons, most) = comparisons <= most || throw(RequestError(422,
    "This run would make $(thousands(comparisons)) comparisons; the most one run can make is $(thousands(most)). " *
    "Analyse fewer specimens at a time."))

# A batch as the request asked for it, held while it waits for its turn
struct Batch
    analysis::String
    groups::Vector{ReferenceGroup}
    alpha::Float64
    settings::Union{Nothing, Settings}
    csv::String
    fields::Union{PairMatchFields, ArticulationFields, RegressionFields}
    replaces::Union{Nothing, String}
end

function multiple_handler(state::AppState, req::HTTP.Request)
    body = read_json(req)
    analysis = text_field(body, "analysis")
    analysis in ("pairmatch", "articulation", "regression") ||
        bad_request("analysis must be pairmatch, articulation or regression")
    groups = selected_groups(current_snapshot(state), list_field(body, "references"))
    alpha = alpha_field(body)
    settings = analysis == "regression" ? nothing : settings_field(body)
    csv = text_field(body, "csv")
    sizeof(csv) <= MAX_FILE_BYTES || throw(RequestError(413, TOO_LARGE))
    batch = Batch(analysis, groups, alpha, settings, csv, multiple_fields(body, analysis), replaces_field(body))
    job = start_job!(job -> run_batch(state, batch, job), state.jobs)
    return json_response(202, (job = job.id,))
end

# The uploaded file as a table. One that cannot be read is refused with what
# is wrong with it, in read_upload's words, which are always plain text.
function read_case(csv::String)::SortTable
    try
        return read_upload(csv)
    catch e
        e isa ArgumentError && (message = e.msg) isa String ? throw(RequestError(400, message)) : rethrow()
    end
end

# How many pairs an analysis is to compare: every specimen of the one kind
# with every specimen of the other
pairs_to_compare(data::Union{Nothing, OSJ.Prepared})::Int = data === nothing ? 0 : length(data.sorta) * length(data.sortb)

function run_batch(state::AppState, batch::Batch, job::Job)
    started = time()
    upload = read_case(batch.csv)
    @atomic job.stage = "sorting"
    data = prepare_multiple(batch.fields, batch.groups, upload)
    comparisons = pairs_to_compare(data)
    check_size(comparisons, state.jobs.max_rows)
    # the results this run replaces are forgotten first, so they do not count as in use against it
    replaces = batch.replaces
    replaces === nothing || release_job!(state.jobs, replaces)
    make_room!(state.jobs, comparisons)
    @atomic job.stage = "comparing"
    result = analyse(data, batch.analysis, batch.alpha, batch.settings)
    return job_output(batch.analysis, result, batch.alpha, time() - started)
end

# --- Plans: several analyses of one case file in one run ---

# A plan is one upload and one run, whose results are kept and dropped
# together like any other run's. Its tests are those of /api/multiple, each
# with the fields that analysis takes there; the reference groups, alpha and
# settings are given once and hold for all of them.

# The most tests in one plan: every bone pair-matched and every articulation
# on both sides is about forty.
const MAX_PLAN_TESTS = 100

const TestFields = Union{PairMatchFields, ArticulationFields, RegressionFields}

analysis_of(::PairMatchFields) = "pairmatch"
analysis_of(::ArticulationFields) = "articulation"
analysis_of(::RegressionFields) = "regression"

# A test's name in the names of its downloads, as in
# "regression-humerus-left-femur-right-excluded.csv". The words come from the
# request, so only letters and digits are kept, and not many of them.
slug(text::String)::String = first(strip(replace(lowercase(text), r"[^a-z0-9]+" => "-"), '-'), 30)
test_name(f::PairMatchFields)::String = "pairmatch-" * slug(f.element)
test_name(f::ArticulationFields)::String = "articulation-" * slug(f.element_a) * "-" * slug(f.element_b) * "-" * slug(f.side)
test_name(f::RegressionFields)::String =
    "regression-" * slug(f.element_a) * "-" * slug(f.side_a) * "-" * slug(f.element_b) * "-" * slug(f.side_b)

# A test as it is named beside its rows when a plan's tables are downloaded as
# one list. In plain letters, as a spreadsheet may not read any others.
bone_title(element::String)::String = uppercasefirst(lowercase(String(strip(element))))
test_title(f::PairMatchFields)::String = "Pair-match: " * bone_title(f.element)
test_title(f::ArticulationFields)::String =
    "Articulation: " * bone_title(f.element_a) * "-" * bone_title(f.element_b) * ", " * lowercase(f.side)
test_title(f::RegressionFields)::String = "Regression: " * bone_title(f.element_a) * " (" * lowercase(f.side_a) * ") to " *
    bone_title(f.element_b) * " (" * lowercase(f.side_b) * ")"

function tests_field(body::Body)::Vector{TestFields}
    value = field(body, "tests")
    value isa Vector{Any} || bad_request("tests must be a list of tests")
    isempty(value) && bad_request("Choose at least one test to run")
    length(value) <= MAX_PLAN_TESTS || bad_request("A plan can have at most $MAX_PLAN_TESTS tests")
    tests = TestFields[]
    for test in value
        test isa Body || bad_request("tests must be a list of tests")
        analysis = text_field(test, "analysis")
        analysis in ("pairmatch", "articulation", "regression") ||
            bad_request("analysis must be pairmatch, articulation or regression")
        push!(tests, multiple_fields(test, analysis))
    end
    return tests
end

check_plan_size(comparisons, most) = comparisons <= most || throw(RequestError(422,
    "This plan would make $(thousands(comparisons)) comparisons; the most one run can make is $(thousands(most)). " *
    "Run fewer tests at a time."))

# A plan as the request asked for it, held while it waits for its turn
struct Plan
    groups::Vector{ReferenceGroup}
    alpha::Float64
    settings::Union{Nothing, Settings} # nothing where every test is a regression, which has none
    csv::String
    tests::Vector{TestFields}
    replaces::Union{Nothing, String}
end

function plan_handler(state::AppState, req::HTTP.Request)
    body = read_json(req)
    groups = selected_groups(current_snapshot(state), list_field(body, "references"))
    alpha = alpha_field(body)
    tests = tests_field(body)
    settings = all(test -> test isa RegressionFields, tests) ? nothing : settings_field(body)
    csv = text_field(body, "csv")
    sizeof(csv) <= MAX_FILE_BYTES || throw(RequestError(413, TOO_LARGE))
    plan = Plan(groups, alpha, settings, csv, tests, replaces_field(body))
    job = start_job!(job -> run_plan(state, plan, job), state.jobs)
    return json_response(202, (job = job.id,))
end

# One test of a plan. A test that has nothing to compare, or fails, does not
# stop the rest: it is given back with the reason in place of results.
function run_test(plan::Plan, fields::TestFields, data::Union{Nothing, OSJ.Prepared})::PlanTest
    analysis = analysis_of(fields)
    started = time()
    try
        result = analyse(data, analysis, plan.alpha, analysis == "regression" ? nothing : plan.settings)
        return PlanTest(test_name(fields), test_title(fields), "", job_output(analysis, result, plan.alpha, time() - started))
    catch e
        e isa RequestError || rethrow()
        return PlanTest(test_name(fields), test_title(fields), e.message, no_output(analysis, plan.alpha))
    end
end

# The file is read once and every test is sorted out of it before any is
# compared, so a plan too large to hold is refused before the work is done,
# and room is made for the whole of it, as for a single run.
function run_plan(state::AppState, plan::Plan, job::Job)::PlanOutput
    started = time()
    upload = read_case(plan.csv)
    @atomic job.stage = "sorting"
    prepared = Union{Nothing, OSJ.Prepared}[prepare_multiple(fields, plan.groups, upload) for fields in plan.tests]
    comparisons = sum(pairs_to_compare, prepared; init = 0)
    check_plan_size(comparisons, state.jobs.max_rows)
    replaces = plan.replaces
    replaces === nothing || release_job!(state.jobs, replaces)
    make_room!(state.jobs, comparisons)
    @atomic job.steps = length(plan.tests)
    @atomic job.step = 1 # before the stage, so the page is never told it is on test 0
    @atomic job.stage = "comparing"
    # Cleared or replaced since it started, a plan stops: nobody will see the
    # rest, and every other run is waiting for this one's turn to end
    tests = run_tests(plan, prepared, job; wanted = () -> find_job(state.jobs, job.id) !== nothing)
    return PlanOutput(tests, round(time() - started; digits = 2))
end

# A plan's tests, one after another. `wanted` is asked before each, and the
# rest are left when it says no: what is given back is the tests done so far.
function run_tests(plan::Plan, prepared::Vector{Union{Nothing, OSJ.Prepared}}, job::Job; wanted::F)::Vector{PlanTest} where {F}
    tests = PlanTest[]
    for (i, fields) in enumerate(plan.tests)
        wanted() || break
        @atomic job.step = i
        push!(tests, run_test(plan, fields, prepared[i]))
        prepared[i] = nothing # its rows are not needed again
    end
    return tests
end

function require_job(state::AppState, id::String)
    job = find_job(state.jobs, id)
    job === nothing && throw(RequestError(404, "These results have expired. Run the analysis again."))
    @atomic job.used = now(UTC) # results in use are kept
    return job
end

function job_handler(state::AppState, id::String)
    job = require_job(state, id)
    status = @atomic job.status
    output = @atomic job.output
    status == "error" && return json_response(200, (id = job.id, status = status, error = (@atomic job.error)))
    (status == "running" || output === nothing) &&
        return json_response(200, (id = job.id, status = "running", stage = (@atomic job.stage),
                                   step = (@atomic job.step), steps = (@atomic job.steps)))
    output isa PlanOutput && return json_response(200, (
        id = job.id, status = status, analysis = "plan", seconds = output.seconds,
        tests = TestStatus[test_status(test) for test in output.tests],
    ))
    return json_response(200, (
        id = job.id, status = status, analysis = output.analysis,
        summary = output.summary, histogram = output.histogram,
        tables = table_summaries(output.tables),
    ))
end

# The result tables' headings and sizes, always in this order. They are kept
# in a dictionary, whose own order is not fixed and not the same from one
# JSON package to another.
const TABLE_ORDER = ("not_excluded", "excluded", "rejected")
const TableSummary = @NamedTuple{columns::Vector{String}, total::Int}

# JSON's own objects keep the order things are put in
function table_summaries(tables::Dict{String, ResultTable})::JSON.Object{String, TableSummary}
    summaries = JSON.Object{String, TableSummary}()
    for name in TABLE_ORDER
        haskey(tables, name) || continue
        table = tables[name]
        summaries[name] = (columns = String[display_name(k) for k in table.names], total = row_count(table))
    end
    return summaries
end

# One test of a finished plan, as a single run is told: what it found and the
# sizes of its tables. `error` is empty unless the test could not be run.
const TestStatus = @NamedTuple{name::String, analysis::String, error::String, summary::Summary, histogram::Histogram,
                               tables::JSON.Object{String, TableSummary}}

test_status(test::PlanTest)::TestStatus = (name = test.name, analysis = test.output.analysis, error = test.error,
    summary = test.output.summary, histogram = test.output.histogram, tables = table_summaries(test.output.tables))

# The page calls this when a run's results are cleared, replaced by a new run,
# or the page is closed, so each open page holds at most one set of results.
# It is a POST so the browser can send it while a page is closing.
function release_handler(state::AppState, id::String)
    release_job!(state.jobs, id)
    return HTTP.Response(204)
end

const Query = Dict{String, String}

query_int(query::Query, name::String, default::Int)::Int = something(tryparse(Int, get(query, name, "")), default)

# The test of a plan a request is about: `test=2` is the second
function plan_test(output::PlanOutput, query::Query)::PlanTest
    number = query_int(query, "test", 0)
    1 <= number <= length(output.tests) || bad_request("test must be the number of one of the plan's tests")
    return output.tests[number]
end

# The table a request is about and the name it is downloaded under. A plan's
# tables are found by test as well, and named after it.
function finished_output(state::AppState, id::String)::Union{JobOutput, PlanOutput}
    output = @atomic require_job(state, id).output
    output === nothing && throw(RequestError(409, "The analysis has not finished"))
    return output
end

const NO_SUCH_TABLE = "table must be not_excluded, excluded or rejected"

function require_table(state::AppState, id::String, query::Query)::Tuple{ResultTable, String}
    output = finished_output(state, id)
    name = get(query, "table", "")
    if output isa PlanOutput
        test = plan_test(output, query)
        tables, file = test.output.tables, test.name * "-" * name
    else
        tables, file = output.tables, name
    end
    table = get(tables, name, nothing)
    table === nothing && bad_request(NO_SUCH_TABLE)
    return table, file * ".csv"
end

# What a download is of: one table, or with `test=all` that table of every
# test of a plan that ran, to be written as a single list. Returns the
# tables, what each one's test is called (none for a table by itself) and the
# name of the file.
function download_tables(state::AppState, id::String, query::Query)::Tuple{Vector{ResultTable}, Vector{String}, String}
    if get(query, "test", "") != "all"
        table, file = require_table(state, id, query)
        return ResultTable[table], String[], file
    end
    output = finished_output(state, id)
    output isa PlanOutput || bad_request("Only a plan has tests to download together")
    name = get(query, "table", "")
    name in TABLE_ORDER || bad_request(NO_SUCH_TABLE)
    ran = PlanTest[test for test in output.tests if haskey(test.output.tables, name)]
    isempty(ran) && throw(RequestError(422, "None of the plan's tests has results to download"))
    return ResultTable[test.output.tables[name] for test in ran], String[test.title for test in ran], "plan-" * name * ".csv"
end

const SEARCH_SECONDS = 10

# One page of a result table, with the search box and column sorting applied.
function rows_handler(state::AppState, req::HTTP.Request, id::String)
    query = HTTP.queryparams(HTTP.URI(req.target))
    table, _ = require_table(state, id, query)
    return json_response(200, in_line(TablePage, () -> table_page(table, query)))
end

const TablePage = @NamedTuple{columns::Vector{String}, rows::Vector{Vector{Cell}}, total::Int, filtered::Int}

# Whether a cell matches a search: a regular expression, or plain text where
# what was typed is not a valid one
function matches(pattern::Union{Regex, String}, cell::String)::Bool
    try
        return occursin(pattern, cell)
    catch
        return false
    end
end

# These rows, in the order of their values in one column
function sorted(column::Column, rows::Vector{Int}, rev::Bool)::Vector{Int}
    column isa Vector{String} && return rows[sortperm(column[rows]; rev)]
    column isa Vector{Int} && return rows[sortperm(column[rows]; rev)]
    return rows[sortperm((column::Vector{Float64})[rows]; rev)]
end

function table_page(table::ResultTable, query::Query; seconds::Real = SEARCH_SECONDS)::TablePage
    rows = collect(1:row_count(table))

    search = first(get(query, "search", ""), 200)
    if !isempty(search)
        pattern::Union{Regex, String} = try
            Regex(search)
        catch
            search
        end
        # a pattern that backtracks badly could otherwise run for hours
        deadline = time() + seconds
        # the reference breakdown is not a column on screen, so it is not searched
        visible = Column[column for (name, column) in zip(table.names, table.columns) if name != :reference]
        rows = filter(rows) do i
            time() > deadline && throw(RequestError(422, "The search took too long. Try a simpler one."))
            any(column -> matches(pattern, cell_text(column, i)), visible)
        end
    end

    sort_column = query_int(query, "sort", 0)
    if 1 <= sort_column <= length(table.columns)
        rows = sorted(table.columns[sort_column], rows, get(query, "dir", "asc") == "desc")
    end

    offset = max(0, query_int(query, "offset", 0))
    limit = clamp(query_int(query, "limit", 10), 1, 1000)
    page = rows[min(offset + 1, length(rows) + 1):min(offset + limit, length(rows))]
    return merge(table_json(table, page), (total = row_count(table), filtered = length(rows)))
end

# The longest a download may take. None should need a minute; one read slowly
# on purpose could otherwise keep its connection for hours.
const DOWNLOAD_SECONDS = 600

function download_handler(state::AppState, req::HTTP.Request, id::String; seconds::Int = DOWNLOAD_SECONDS)
    query = HTTP.queryparams(HTTP.URI(req.target))
    tables, tests, file = download_tables(state, id, query)
    downloads = state.jobs.downloads
    # The page asks before it starts a download, which the browser saves by
    # itself: an answer that is an error would be saved as the file.
    if haskey(query, "check")
        downloads[] >= MAX_DOWNLOADS && throw(RequestError(503, DOWNLOADS_BUSY))
        return HTTP.Response(204)
    end
    if Threads.atomic_add!(downloads, 1) >= MAX_DOWNLOADS
        Threads.atomic_sub!(downloads, 1)
        throw(RequestError(503, DOWNLOADS_BUSY))
    end
    return HTTP.Response(200, [
        "Content-Type" => "text/csv; charset=utf-8",
        "Content-Disposition" => "attachment; filename=\"" * file * "\"",
        "Cache-Control" => "no-store",
    ], Download(tables, tests, state.jobs, id, req.target, time() + seconds, seconds))
end

# A download reads its table for as long as it is being sent. Results cleared
# meanwhile could not be given back until it ended, so it stops.
function still_wanted(body::Download)::Bool
    time() < body.deadline && return find_job(body.jobs, body.id) !== nothing
    complain("Download stopped, it took longer than its limit of " * string(body.seconds) * " seconds: " * body.target)
    return false
end

write_download(io::IO, body::Download)::Bool =
    isempty(body.tests) ? write_csv(io, only(body.tables); wanted = () -> still_wanted(body)) :
    write_combined(io, body.tests, body.tables; wanted = () -> still_wanted(body))

download_finished(body::Download) = (Threads.atomic_sub!(body.jobs.downloads, 1); nothing)
