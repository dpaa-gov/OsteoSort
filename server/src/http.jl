# HTTP server: JSON API under /api, static frontend for everything else.

mutable struct AppState
    const config::Config
    const refresh_lock::ReentrantLock
    const articulation::Vector{Tuple{String, String}}
    const jobs::JobStore
    @atomic snapshot::Union{Nothing, ReferenceSnapshot}
    @atomic meta_json::String
    @atomic load_error::String
    @atomic last_attempt::DateTime
end

AppState(config::Config) =
    AppState(config, ReentrantLock(), articulation_config(config), JobStore(), nothing, "", "", DateTime(0))

function refresh_reference!(state::AppState)
    @atomic state.last_attempt = now(UTC)
    try
        snapshot = load_reference(state.config)
        meta_json = JSON3.write(build_meta(snapshot, state.config))
        @atomic state.snapshot = snapshot
        @atomic state.meta_json = meta_json
        @atomic state.load_error = ""
        @info "Reference data loaded" groups = length(snapshot.groups) bones = length(snapshot.bones)
        return true
    catch e
        @atomic state.load_error = sprint(showerror, e)
        @error "Reference data load failed" exception = (e, catch_backtrace())
        return false
    end
end

recently_attempted(state::AppState) =
    now(UTC) - (@atomic state.last_attempt) < Second(state.config.reference_max_age_seconds)

# Each page load gets current ARDS data: the snapshot is reloaded when it is
# older than the configured age. Page loads that arrive during a reload wait
# for it and share its result; a failed reload keeps the previous snapshot.
function ensure_fresh!(state::AppState)
    lock(state.refresh_lock) do
        # on a worker thread, so the server keeps answering other requests
        recently_attempted(state) || fetch(Threads.@spawn refresh_reference!(state))
    end
    return
end

# Requests are all handled on one thread. Anything slow runs on a worker
# thread instead, so the server keeps answering other requests meanwhile.
function off_thread(work)
    task = Threads.@spawn work()
    try
        return fetch(task)
    catch e
        # an answer for the user is passed on as it is; anything else is
        # rethrown whole, so the log shows where on the worker thread it failed
        e isa TaskFailedException && e.task.exception isa RequestError && throw(e.task.exception)
        rethrow()
    end
end

json_response(status, body::AbstractString) =
    HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"], body)
json_response(status, body) = json_response(status, JSON3.write(body))
error_response(status, message) = json_response(status, (error = message,))

function meta_handler(state::AppState)
    ensure_fresh!(state)
    meta_json = @atomic state.meta_json
    if isempty(meta_json)
        load_error = @atomic state.load_error
        @error "Reference data unavailable" load_error
        return error_response(503, "Reference data could not be loaded from ARDS")
    end
    return json_response(200, meta_json)
end

const CONTENT_TYPES = Dict(
    ".html" => "text/html; charset=utf-8", ".js" => "text/javascript; charset=utf-8",
    ".css" => "text/css; charset=utf-8", ".json" => "application/json; charset=utf-8",
    ".csv" => "text/csv; charset=utf-8", ".png" => "image/png", ".svg" => "image/svg+xml",
    ".ico" => "image/x-icon", ".woff2" => "font/woff2", ".map" => "application/json",
)

function static_handler(state::AppState, req::HTTP.Request)
    req.method in ("GET", "HEAD") || return error_response(405, "Method not allowed")
    path = HTTP.URIs.unescapeuri(HTTP.URI(req.target).path)
    parts = filter(!isempty, split(path, "/"))
    any(part -> part == ".." || startswith(part, "."), parts) && return error_response(404, "Not found")
    file = joinpath(state.config.web_dir, parts...)
    isdir(file) && (file = joinpath(file, "index.html"))
    isfile(file) || return error_response(404, "Not found")
    content_type = get(CONTENT_TYPES, lowercase(splitext(file)[2]), "application/octet-stream")
    # The browser keeps the file and asks each time whether it has changed, so
    # a page load sends it once and a new release is picked up straight away.
    info = stat(file)
    etag = "\"" * string(info.size; base = 16) * "-" * string(floor(Int, info.mtime); base = 16) * "\""
    headers = ["Content-Type" => content_type, "ETag" => etag, "Cache-Control" => "no-cache"]
    HTTP.header(req, "If-None-Match") == etag && return HTTP.Response(304, headers)
    return HTTP.Response(200, headers, read(file))
end

function router(state::AppState)
    r = HTTP.Router(req -> static_handler(state, req))
    HTTP.register!(r, "GET", "/healthz", _ -> HTTP.Response(200, ["Content-Type" => "text/plain"], "ok"))
    HTTP.register!(r, "GET", "/api/meta", _ -> meta_handler(state))
    HTTP.register!(r, "GET", "/api/template.csv", _ -> template_handler(state))
    HTTP.register!(r, "POST", "/api/single", req -> single_handler(state, req))
    HTTP.register!(r, "POST", "/api/multiple", req -> multiple_handler(state, req))
    HTTP.register!(r, "GET", "/api/jobs/{id}", req -> job_handler(state, req))
    HTTP.register!(r, "GET", "/api/jobs/{id}/rows", req -> rows_handler(state, req))
    HTTP.register!(r, "GET", "/api/jobs/{id}/download", req -> download_handler(state, req))
    HTTP.register!(r, "POST", "/api/jobs/{id}/release", req -> release_handler(state, req))
    HTTP.register!(r, "/api/**", _ -> error_response(404, "Not found"))
    return r
end

function handler(state::AppState)
    route = router(state)
    return function (req::HTTP.Request)
        try
            return route(req)
        catch e
            e isa RequestError && return error_response(e.status, e.message)
            @error "Request failed" method = req.method target = req.target exception = (e, catch_backtrace())
            return error_response(500, "Internal server error")
        end
    end
end

# Starts listening straight away; the first reference load runs in the
# background so the health check answers while the database is slow or down.
function serve(config::Config; host = "0.0.0.0", port = config.port)
    state = AppState(config)
    errormonitor(Threads.@spawn ensure_fresh!(state))
    server = HTTP.serve!(handler(state), host, port)
    # results nobody has used for an hour are dropped even when no other run comes along
    errormonitor(Threads.@spawn while isopen(server)
        sleep(SWEEP_SECONDS)
        sweep!(state.jobs)
    end)
    @info "OsteoSort listening" host port version = config.version
    return server, state
end

function main()
    server, _ = serve(Config())
    wait(server)
end

# Entry point of the compiled program (build/Dockerfile)
function julia_main()::Cint
    try
        main()
    catch e
        Base.invokelatest(Base.display_error, e, catch_backtrace())
        return 1
    end
    return 0
end
