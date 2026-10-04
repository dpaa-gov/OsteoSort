# Analysis endpoints: request validation, single comparisons, batch jobs,
# paged results and CSV downloads.

# A case file can be at most 5 MB, about 30,000 specimens with every
# measurement filled in; the page checks that too. The request carrying it
# can be up to twice the size, as line ends and quotes are escaped.
const MAX_FILE_BYTES = 5 * 1024^2
const MAX_BODY_BYTES = 12 * 1024^2
const TOO_LARGE = "The file is too large: a case file can be at most 5 MB"
const REFERENCE_CHANGED = "The reference data has changed. Reload the page and try again."

bad_request(message) = throw(RequestError(400, message))

function read_json(req::HTTP.Request)
    length(req.body) <= MAX_BODY_BYTES || throw(RequestError(413, TOO_LARGE))
    body = try
        JSON3.read(req.body)
    catch
        bad_request("The request body is not valid JSON")
    end
    body isa JSON3.Object || bad_request("The request body must be a JSON object")
    return body
end

field(body, name) = haskey(body, name) ? body[name] : bad_request("Missing field: $name")

function text_field(body, name)
    value = field(body, name)
    value isa AbstractString || bad_request("$name must be text")
    return String(value)
end

function list_field(body, name)
    value = field(body, name)
    value isa AbstractVector && all(v -> v isa AbstractString, value) || bad_request("$name must be a list of text values")
    return String.(value)
end

function alpha_field(body)
    value = field(body, :alpha)
    value isa Real && 0 < value <= 1 || bad_request("alpha must be a number above 0 and at most 1")
    return Float64(value)
end

function settings_field(body)
    settings = field(body, :settings)
    settings isa JSON3.Object || bad_request("settings must be an object")
    flag(name) = (v = get(settings, name, false); v isa Bool ? v : bad_request("settings.$name must be true or false"))
    tails = get(settings, :tails, 2)
    tails in (1, 2) || bad_request("settings.tails must be 1 or 2")
    return Settings(flag(:absolute), flag(:yeojohnson), flag(:zeromean), Int(tails))
end

# Typed-in measurements by code; blank fields are null or left out
function values_field(body, name)
    value = field(body, name)
    value isa JSON3.Object || bad_request("$name must be an object of measurement values")
    entries = Dict{String, Any}()
    for (code, number) in pairs(value)
        number === nothing || number isa Real && isfinite(number) && number > 0 || bad_request("$(uppercasefirst(String(code))) must be a number above 0")
        entries[lowercase(String(code))] = number
    end
    return entries
end

function current_snapshot(state::AppState)
    (@atomic state.snapshot) === nothing && ensure_fresh!(state)
    snapshot = @atomic state.snapshot
    snapshot === nothing && throw(RequestError(503, "Reference data could not be loaded from ARDS"))
    return snapshot
end

function selected_groups(snapshot::ReferenceSnapshot, labels)
    isempty(labels) && bad_request("Select at least one reference group")
    by_label = Dict(group.label => group for group in snapshot.groups)
    all(label -> haskey(by_label, label), labels) || throw(RequestError(409, REFERENCE_CHANGED))
    return [by_label[label] for label in labels]
end

# --- Tables as JSON and CSV ---

# Column headings. The two specimens of a comparison are numbered:
# "accession 1", "element 1", "side 1", then "accession 2" and so on.
function display_name(name::Symbol)
    text = replace(String(name), r"^x_(.*)$" => s"\1_1", r"^y_(.*)$" => s"\1_2")
    text = replace(text, r"^id(?=_)" => "accession")
    text = replace(text, r"_([12])$" => s" \1")
    return text == "r2" ? "R²" : text
end

json_cell(value::AbstractFloat) = isfinite(value) ? value : nothing
json_cell(value) = value

row_count(table::NamedTuple) = isempty(table) ? 0 : length(first(table))

function table_json(table::NamedTuple, rows = 1:row_count(table))
    columns = collect(values(table))
    return (columns = [display_name(name) for name in keys(table)],
            rows = [[json_cell(column[i]) for column in columns] for i in rows])
end

csv_cell(value::AbstractString) = "\"" * replace(value, "\"" => "\"\"") * "\""
csv_cell(value::Integer) = string(value)
# Fixed notation. Every number in a result table is rounded to four places.
csv_cell(value::AbstractFloat) = isfinite(value) ? rstrip(rstrip(@sprintf("%.4f", value), '0'), '.') : string(value)

# A cell as the table shows it, which is what a search is matched against
cell_text(value::AbstractFloat) = csv_cell(value)
cell_text(value) = string(value)

function table_csv(table::NamedTuple)
    io = IOBuffer()
    println(io, join((csv_cell(display_name(name)) for name in keys(table)), ","))
    columns = collect(values(table))
    for i in 1:row_count(table)
        println(io, join((csv_cell(column[i]) for column in columns), ","))
    end
    return String(take!(io))
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

function prepare_single(state::AppState, body, analysis, groups)
    if analysis == "pairmatch"
        return prepare_single_pair_match(groups, text_field(body, :element),
            values_field(body, :left), values_field(body, :right))
    elseif analysis == "articulation"
        pairs = articulation_pairs(groups, state.articulation)
        return prepare_single_articulation(groups, pairs, text_field(body, :element_a), text_field(body, :element_b),
            text_field(body, :side), values_field(body, :values_a), values_field(body, :values_b))
    elseif analysis == "regression"
        return prepare_single_regression(groups, text_field(body, :element_a), text_field(body, :element_b),
            text_field(body, :side_a), text_field(body, :side_b),
            values_field(body, :values_a), values_field(body, :values_b))
    end
    bad_request("analysis must be pairmatch, articulation or regression")
end

function analyse(data, analysis, alpha, settings)
    result = try
        analysis == "regression" ? regression_test(data, alpha) :
        ttest(data, alpha, settings; articulation = analysis == "articulation")
    catch e
        @error "Analysis failed" analysis exception = (e, catch_backtrace())
        throw(RequestError(422, ANALYSIS_FAILED))
    end
    result === nothing && throw(RequestError(422, NO_RESULT))
    return result
end

function single_handler(state::AppState, req::HTTP.Request)
    body = read_json(req)
    analysis = text_field(body, :analysis)
    groups = selected_groups(current_snapshot(state), list_field(body, :references))
    alpha = alpha_field(body)
    settings = analysis == "regression" ? nothing : settings_field(body)
    data = prepare_single(state, body, analysis, groups)
    result = off_thread(() -> analyse(data, analysis, alpha, settings))
    if row_count(result.results) == 0
        reasons = result.rejected.reason
        throw(RequestError(422, isempty(reasons) ? NO_RESULT : "No comparison could be made. " * last(reasons)))
    end
    return json_response(200, (analysis = analysis, results = table_json(for_display(result.results)), plot = result.plot))
end

# --- Batch analyses ---

# What a batch is to be run on. Read from the request before the run is
# queued, so a waiting run does not hold the request, and a missing field is
# refused straight away.
function multiple_fields(body, analysis)
    measurements(name) = lowercase.(list_field(body, name))
    analysis == "pairmatch" && return (element = text_field(body, :element), measurements = measurements(:measurements))
    bones = (element_a = text_field(body, :element_a), element_b = text_field(body, :element_b),
             measurements_a = measurements(:measurements_a), measurements_b = measurements(:measurements_b))
    analysis == "articulation" && return merge(bones, (side = text_field(body, :side),))
    return merge(bones, (side_a = text_field(body, :side_a), side_b = text_field(body, :side_b)))
end

function prepare_multiple(f, analysis, groups, upload::SortTable)
    if analysis == "pairmatch"
        return prepare_pair_match(groups, upload, f.element, f.measurements)
    elseif analysis == "articulation"
        return prepare_articulation(groups, upload, f.element_a, f.element_b, f.side, f.measurements_a, f.measurements_b)
    end
    return prepare_regression(groups, upload, f.element_a, f.element_b, f.side_a, f.side_b, f.measurements_a, f.measurements_b)
end

thousands(n) = replace(string(n), r"(?<=\d)(?=(\d{3})+$)" => ",")

# Every pair becomes a result row held in memory, so a run that would make
# more than the store may hold is refused before it starts comparing.
check_size(comparisons, most) = comparisons <= most || throw(RequestError(422,
    "This run would make $(thousands(comparisons)) comparisons; the most one run can make is $(thousands(most)). " *
    "Analyse fewer specimens at a time."))

function multiple_handler(state::AppState, req::HTTP.Request)
    body = read_json(req)
    analysis = text_field(body, :analysis)
    analysis in ("pairmatch", "articulation", "regression") ||
        bad_request("analysis must be pairmatch, articulation or regression")
    groups = selected_groups(current_snapshot(state), list_field(body, :references))
    alpha = alpha_field(body)
    settings = analysis == "regression" ? nothing : settings_field(body)
    csv = text_field(body, :csv)
    sizeof(csv) <= MAX_FILE_BYTES || throw(RequestError(413, TOO_LARGE))
    fields = multiple_fields(body, analysis)
    job = start_job!(state.jobs) do job
        started = time()
        @atomic job.stage = "reading"
        upload = try
            read_upload(csv)
        catch e
            e isa ArgumentError ? throw(RequestError(400, e.msg)) : rethrow()
        end
        @atomic job.stage = "sorting"
        data = prepare_multiple(fields, analysis, groups, upload)
        data === nothing || check_size(length(data.sorta) * length(data.sortb), state.jobs.max_rows)
        @atomic job.stage = "comparing"
        result = analyse(data, analysis, alpha, settings)
        return job_output(analysis, result, alpha, time() - started)
    end
    return json_response(202, (job = job.id,))
end

function require_job(state::AppState, req::HTTP.Request)
    job = find_job(state.jobs, HTTP.getparams(req)["id"])
    job === nothing && throw(RequestError(404, "These results have expired. Run the analysis again."))
    @atomic job.used = now(UTC) # results in use are kept
    return job
end

function job_handler(state::AppState, req::HTTP.Request)
    job = require_job(state, req)
    status = @atomic job.status
    output = @atomic job.output
    status == "error" && return json_response(200, (id = job.id, status = status, error = (@atomic job.error)))
    (status == "running" || output === nothing) &&
        return json_response(200, (id = job.id, status = "running", stage = (@atomic job.stage)))
    return json_response(200, (
        id = job.id, status = status, analysis = output.analysis,
        summary = output.summary, histogram = output.histogram,
        tables = Dict(name => (columns = [display_name(k) for k in keys(table)], total = row_count(table))
                      for (name, table) in output.tables),
    ))
end

# The page calls this when a run's results are cleared, replaced by a new run,
# or the page is closed, so each open page holds at most one set of results.
# It is a POST so the browser can send it while a page is closing.
function release_handler(state::AppState, req::HTTP.Request)
    release_job!(state.jobs, HTTP.getparams(req)["id"])
    return HTTP.Response(204)
end

function require_table(state::AppState, req::HTTP.Request, query)
    output = @atomic require_job(state, req).output
    output === nothing && throw(RequestError(409, "The analysis has not finished"))
    table = get(output.tables, get(query, "table", ""), nothing)
    table === nothing && bad_request("table must be not_excluded, excluded or rejected")
    return table
end

query_int(query, name, default) = something(tryparse(Int, get(query, name, "")), default)

const SEARCH_SECONDS = 10

# One page of a result table, with the search box and column sorting applied.
function rows_handler(state::AppState, req::HTTP.Request)
    query = HTTP.queryparams(HTTP.URI(req.target))
    table = require_table(state, req, query)
    return json_response(200, off_thread(() -> table_page(table, query)))
end

function table_page(table, query; seconds = SEARCH_SECONDS)
    columns = collect(values(table))
    rows = collect(1:row_count(table))

    search = first(get(query, "search", ""), 200)
    if !isempty(search)
        # a regular expression; plain text if it is not valid
        pattern = try
            Regex(search)
        catch
            search
        end
        matches(cell) = try
            occursin(pattern, cell)
        catch
            false
        end
        # a pattern that backtracks badly could otherwise run for hours
        deadline = time() + seconds
        # the reference breakdown is not a column on screen, so it is not searched
        visible = [column for (name, column) in pairs(table) if name != :reference]
        rows = filter(rows) do i
            time() > deadline && throw(RequestError(422, "The search took too long. Try a simpler one."))
            any(column -> matches(cell_text(column[i])), visible)
        end
    end

    sort_column = query_int(query, "sort", 0)
    if 1 <= sort_column <= length(columns)
        column = columns[sort_column]
        rows = rows[sortperm(column[rows]; rev = get(query, "dir", "asc") == "desc")]
    end

    offset = max(0, query_int(query, "offset", 0))
    limit = clamp(query_int(query, "limit", 10), 1, 1000)
    page = rows[min(offset + 1, length(rows) + 1):min(offset + limit, length(rows))]
    return merge(table_json(table, page), (total = row_count(table), filtered = length(rows)))
end

function download_handler(state::AppState, req::HTTP.Request)
    query = HTTP.queryparams(HTTP.URI(req.target))
    table = require_table(state, req, query)
    return HTTP.Response(200, [
        "Content-Type" => "text/csv; charset=utf-8",
        "Content-Disposition" => "attachment; filename=\"$(query["table"]).csv\"",
        "Cache-Control" => "no-store",
    ], off_thread(() -> table_csv(table)))
end
