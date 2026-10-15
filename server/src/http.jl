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
        meta_json = JSON.json(build_meta(snapshot, state.config))
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

# Requests are handled on the interactive thread, which HTTP.jl keeps to
# itself. Anything slow runs on a worker thread instead, so the server keeps
# answering other requests meanwhile.
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

# A response's body where it is to be written out as it is made, not held
# whole: `write_to(io)` writes it, and returns whether it wrote all of it.
# `finished()` is called once the response is over, however it ended.
struct StreamedBody <: HTTP.AbstractBody
    write_to::Function
    finished::Function
end

json_response(status, body::AbstractString) =
    HTTP.Response(status, ["Content-Type" => "application/json; charset=utf-8", "Cache-Control" => "no-store"], body)
json_response(status, body) = json_response(status, JSON.json(body))
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

# --- Reading a request, within a size limit ---

# HTTP.jl's own way of handing a handler its request reads the whole body
# first, with one size limit for every route, and an upload has to wait its
# turn before it is read. Requests are read here instead, and no more of one
# is kept than its route allows.
const SMALL_BODY_BYTES = 64 * 1024
const REQUEST_TOO_LARGE = "The request is too large"
# How much of a refused request is read and thrown away so that its sender
# gets the answer; one larger than this is refused and the connection closed.
const DISCARD_BYTES = 32 * 1024^2

# A case file is uploaded to one route; every other request is small.
body_limit(target) = startswith(target, "/api/multiple") ? MAX_BODY_BYTES : SMALL_BODY_BYTES

# What HTTP.jl raises when a request has not arrived within BODY_SECONDS
const TOO_SLOW = HTTP.IOPoll.DeadlineExceededError

# Reads a request's body up to `limit`. Returns :large when it is larger:
# by the size it declares, without reading it, or, where it declares none,
# as soon as more than the limit has arrived. Returns :slow when it has not
# all arrived within the time HTTP.jl allows from the end of its headers.
function read_body(stream, limit)
    declared = tryparse(Int, HTTP.header(HTTP.startread(stream), "Content-Length"))
    declared !== nothing && declared > limit && return :large
    body = UInt8[]
    piece = Vector{UInt8}(undef, 64 * 1024)
    try
        while (n = readbytes!(stream, piece)) > 0
            append!(body, view(piece, 1:n))
            length(body) > limit && return :large
        end
    catch e
        e isa TOO_SLOW && return :slow
        rethrow()
    end
    return body
end

# The request as the app is given it: as it came, with the body read here
with_body(request, body) =
    HTTP.Request(request.method, request.target, request.headers, body; context = HTTP.get_request_context(request))

# --- Uploads, a few at a time ---

# Each upload being read is held in memory, up to MAX_BODY_BYTES of it and
# again as it is read out of the request, and the limit on waiting runs
# applies only once that is done: sixty arriving together took 740 MiB. So
# only this many are read at once, which took 170. The rest wait, unread.
const UPLOADS_AT_ONCE = 4
# How long an upload waits for its turn before it is told the server is busy
const UPLOAD_WAIT_SECONDS = 20
# How long an upload has to arrive once its turn has come, at the least. A
# sender that takes its time would otherwise keep the turn, and four of them
# every turn. HTTP.jl counts the time from the end of a request's headers, so
# it allows this and the wait for a turn together: see BODY_SECONDS.
const UPLOAD_SECONDS = 60
const UPLOAD_TOO_SLOW = "The file took too long to arrive. Check your connection and try again."

struct Turns
    most::Int
    taken::Threads.Atomic{Int}
end

Turns(most::Integer = UPLOADS_AT_ONCE) = Turns(most, Threads.Atomic{Int}(0))

# Takes a turn, waiting up to `seconds` for one. Returns whether it got one.
function take_turn!(turns::Turns, seconds)
    function take()
        Threads.atomic_add!(turns.taken, 1) < turns.most && return true
        Threads.atomic_sub!(turns.taken, 1)
        return false
    end
    return take() || timedwait(take, seconds; pollint = 0.05) == :ok
end

give_back!(turns::Turns) = (Threads.atomic_sub!(turns.taken, 1); nothing)

# Reads on, keeping nothing, until the request ends or `most` bytes have
# gone. Returns whether the whole request has now been read.
function discard(stream, most)
    declared = tryparse(Int, HTTP.header(HTTP.startread(stream), "Content-Length"))
    declared !== nothing && declared > most && return false
    gone = 0
    piece = Vector{UInt8}(undef, 64 * 1024)
    try
        while (n = readbytes!(stream, piece)) > 0
            (gone += n) > most && return false
        end
    catch e
        e isa TOO_SLOW && return false
        rethrow()
    end
    return true
end

# What a body that writes itself is written to: the response, noting whether
# writing to it failed, which is the client gone or no longer reading.
mutable struct Sending <: IO
    const stream::HTTP.Stream
    failed::Bool
end

function sent(write_to_stream, io::Sending)
    try
        return write_to_stream(io.stream)
    catch
        io.failed = true
        rethrow()
    end
end

Base.write(io::Sending, bytes::Vector{UInt8}) = sent(stream -> write(stream, bytes), io)
Base.unsafe_write(io::Sending, bytes::Ptr{UInt8}, n::UInt) = sent(stream -> unsafe_write(stream, bytes, n), io)

# Closes a connection at once, with nothing more sent on it. HTTP.jl would
# end a response that stopped part way as though it were complete.
drop(stream::HTTP.Stream) = close(stream.tracked.conn)

# Sends a body that writes itself. Its headers have gone by now, so one that
# stops part way cannot be answered with an error: the connection is dropped
# without the body's end being marked, which a browser reports as a download
# that did not complete.
#
# A client that stops reading is closed by HTTP.jl once a piece has waited
# WRITE_SECONDS to be taken.
function write_streamed(stream, body::StreamedBody, target)
    sending = Sending(stream, false)
    complete = try
        HTTP.startwrite(stream)
        body.write_to(sending)
    catch e
        sending.failed && rethrow() # the client went away, or was closed for taking nothing; HTTP.jl closes it quietly
        @error "Response failed part way" target exception = (e, catch_backtrace())
        false
    finally
        body.finished()
    end
    complete || drop(stream)
    return
end

# An answer refusing a request, after which its connection is closed
function refusal(status, message)
    response = error_response(status, message)
    HTTP.setheader(response, "Connection" => "close")
    return response
end

# Writes an answer that is held whole
function write_whole(stream, body)
    body isa HTTP.EmptyBody || write(stream, body)
    return
end

# Reads a request within its limits and answers it: `handle` is given the
# request once its body has been read.
function answer(handle, stream, request)
    limit = body_limit(request.target)
    body = read_body(stream, limit)
    if body === :slow
        @warn "Request refused: it took too long to arrive" target = request.target
        return refusal(408, "The request took too long to arrive")
    elseif body === :large
        @warn "Request refused: larger than its limit" target = request.target limit declared = HTTP.header(request, "Content-Length", "not given")
        discard(stream, DISCARD_BYTES)
        return refusal(413, limit == MAX_BODY_BYTES ? TOO_LARGE : REQUEST_TOO_LARGE)
    end
    return handle(with_body(request, body))
end

# Reads an upload and hands it to `handle`. Returns the answer, or :large or
# :slow for one that was not read.
function read_upload_request(handle, stream, request)
    body = read_body(stream, MAX_BODY_BYTES)
    body isa Symbol && return body
    return handle(with_body(request, body))
end

# The same for an upload, which is read in its turn. The turn is kept until
# the run has been queued: until then the file is here whole, and again as
# it was read out of the request.
function answer_upload(handle, stream, request, turns, wait)
    if !take_turn!(turns, wait)
        @warn "Upload refused: no turn came" target = request.target waited = wait
        discard(stream, DISCARD_BYTES)
        return refusal(503, BUSY)
    end
    outcome = try
        read_upload_request(handle, stream, request)
    finally
        give_back!(turns)
        # what reading it took is given back a moment later, not left until
        # Julia next needs the room: 150 MiB after sixty of them
        tidy()
    end
    outcome isa Symbol || return outcome
    if outcome === :slow
        @warn "Upload refused: it took too long to arrive" target = request.target
        return refusal(408, UPLOAD_TOO_SLOW) # the rest of it is not waited for
    end
    @warn "Request refused: larger than its limit" target = request.target limit = MAX_BODY_BYTES declared = HTTP.header(request, "Content-Length", "not given")
    discard(stream, DISCARD_BYTES)
    return refusal(413, TOO_LARGE)
end

# What the server runs for each request. A request whose body is not read to
# its end, as when it is refused, is answered and its connection closed by
# HTTP.jl: what is left of it is not waited for.
function limited(handle; turns = Turns(), wait = UPLOAD_WAIT_SECONDS)
    return function (stream::HTTP.Stream)
        request::HTTP.Request = HTTP.startread(stream)
        response = body_limit(request.target) == MAX_BODY_BYTES ?
            answer_upload(handle, stream, request, turns, wait) : answer(handle, stream, request)
        HTTP.setstatus(stream, response.status)
        for header in response.headers
            HTTP.setheader(stream, header)
        end
        if response.body isa StreamedBody
            write_streamed(stream, response.body, request.target)
        else
            write_whole(stream, response.body)
        end
        return
    end
end

# --- Connections ---

# A connection is closed when it is too slow at any stage, so that ones left
# open and silent hold nothing for long. None of these counts the time an
# answer takes to work out, for which Atlas allows 30 seconds.
# How long a request's headers may take to arrive, from a new connection or
# once the first of them has come on one kept open
const HEADER_SECONDS = 10
# How long its body may then take: for an upload, its wait for a turn and
# then its time to arrive
const BODY_SECONDS = UPLOAD_WAIT_SECONDS + UPLOAD_SECONDS
# How long a connection is kept open between requests
const IDLE_SECONDS = 60
# How long the client may take over each piece of an answer, about 1 MB of a
# download. One that stops reading is closed this long after.
const WRITE_SECONDS = 60

# Nothing here limits how many connections are held at once: HTTP.jl has no
# setting for it. Each costs about 30 KB until it is closed for its silence,
# and on Atlas none reaches the pod except through the gateway. HTTP.jl takes
# in nothing of a request until it is read, so one waiting holds no more.
#
# HTTP/2 without encryption is turned off: no browser uses it, and it carries
# many requests on one connection, which the limits above are not made for.
listen(handle, host, port; turns = Turns(), wait = UPLOAD_WAIT_SECONDS,
       header_seconds = HEADER_SECONDS, body_seconds = BODY_SECONDS, idle_seconds = IDLE_SECONDS, write_seconds = WRITE_SECONDS) =
    HTTP.listen!(limited(handle; turns, wait), host, port; allow_h2c = false, read_header_timeout = header_seconds,
        read_timeout = body_seconds, idle_timeout = idle_seconds, write_timeout = write_seconds)

# Starts listening straight away; the first reference load runs in the
# background so the health check answers while the database is slow or down.
function serve(config::Config; host = "0.0.0.0", port = config.port, sweep = SWEEP_SECONDS)
    state = AppState(config)
    errormonitor(Threads.@spawn ensure_fresh!(state))
    server = listen(handler(state), host, port)
    # results nobody has used for an hour are dropped even when no other run comes along
    errormonitor(Threads.@spawn while isopen(server)
        sleep(sweep)
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
