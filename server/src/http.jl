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

# A response's body where it is to be written out as it is made, not held
# whole: `write_to(io)` writes it, and returns whether it wrote all of it.
# `finished()` is called once the response is over, however it ended.
struct StreamedBody
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
# first, whatever its size, so a request of a gigabyte or two would fill the
# pod's memory before any check could refuse it. Requests are read here
# instead, and no more of one is kept than its route allows.
const SMALL_BODY_BYTES = 64 * 1024
const REQUEST_TOO_LARGE = "The request is too large"
# How much of a refused request is read and thrown away so that its sender
# gets the answer; one larger than this is refused and the connection closed.
const DISCARD_BYTES = 32 * 1024^2

# A case file is uploaded to one route; every other request is small.
body_limit(target) = startswith(target, "/api/multiple") ? MAX_BODY_BYTES : SMALL_BODY_BYTES

# Reads a request's body up to `limit`. Returns :large when it is larger:
# by the size it declares, without reading it, or, where it declares none,
# as soon as more than the limit has arrived. Returns :slow when it has not
# all arrived by `deadline`.
function read_body(stream, limit, deadline = Inf)
    declared = tryparse(Int, HTTP.header(stream.message, "Content-Length"))
    declared !== nothing && declared > limit && return :large
    body = UInt8[]
    while !eof(stream)
        append!(body, readavailable(stream))
        length(body) > limit && return :large
        time() > deadline && return :slow
    end
    return body
end

# --- Uploads, a few at a time ---

# Each upload being read is held in memory, up to MAX_BODY_BYTES of it and
# again as it is read out of the request, and the limit on waiting runs
# applies only once that is done: sixty arriving together took 740 MiB. So
# only this many are read at once, which took 170. The rest wait, with no
# more of them taken in than UNREAD_BYTES.
const UPLOADS_AT_ONCE = 4
# How long an upload waits for its turn before it is told the server is busy
const UPLOAD_WAIT_SECONDS = 20
# How long an upload has to arrive once its turn has come. A sender that
# takes its time would otherwise keep the turn, and four of them every turn.
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
    declared = tryparse(Int, HTTP.header(stream.message, "Content-Length"))
    declared !== nothing && declared > most && return false
    gone = 0
    while !eof(stream)
        gone += length(readavailable(stream))
        gone > most && return false
    end
    return true
end

# What a body that writes itself is written to. HTTP.jl closes a connection
# from which nothing has come for IDLE_SECONDS, and during a download nothing
# does: each piece the client has taken counts here as a sign of life.
mutable struct Sending <: IO
    const stream::HTTP.Stream
    taken::Float64 # when the client last took a piece
end

function Base.unsafe_write(io::Sending, bytes::Ptr{UInt8}, n::UInt)
    written = unsafe_write(io.stream, bytes, n)
    io.taken = time()
    io.stream.stream.timestamp = io.taken # HTTP.jl's record of when the connection was last heard from
    return written
end

# Closes a connection at once. An ordinary close first waits for everything
# written to it to be taken, which a client that has stopped reading never
# does: the close, and whatever was waiting on it, would wait for good.
function drop(stream::HTTP.Stream)
    socket = stream.stream.io
    socket isa Base.LibuvStream || return close(stream)
    Base.iolock_begin()
    if isopen(socket) && socket.status != Base.StatusClosing
        ccall(:jl_forceclose_uv, Cvoid, (Ptr{Cvoid},), socket.handle)
        socket.status = Base.StatusClosing
    end
    Base.iolock_end()
    return
end

# Sends a body that writes itself. Its headers have gone by now, so one that
# stops part way cannot be answered with an error: the connection is dropped
# without the body's end being marked, which a browser reports as a download
# that did not complete. HTTP.jl is told the connection went away, as below.
#
# A client that stops reading is dropped here once it has taken nothing for
# `idle` seconds. HTTP.jl would not: it closes a silent connection in the
# ordinary way, which waits behind the piece not taken.
function write_streamed(stream, response, idle)
    body::StreamedBody = response.body
    # the connection keeps its last response until its next request: not what this one was written from
    response.body = UInt8[]
    sending = Sending(stream, time())
    watch = Timer(1; interval = 1) do _
        time() - sending.taken > idle && drop(stream)
    end
    complete = try
        HTTP.startwrite(stream)
        body.write_to(sending)
    catch e
        e isa Base.IOError && rethrow() # the client went away, or was closed for taking nothing
        @error "Response failed part way" target = response.request.target exception = (e, catch_backtrace())
        false
    finally
        close(watch)
        body.finished()
    end
    complete && return
    drop(stream)
    throw(Base.IOError("response ended part way; connection closed", Base.UV_ECONNABORTED))
end

# Reads a request within its limits and answers it: `handle` is given the
# request once its body has been read. Returns the answer, and whether the
# whole request has been read.
function answer(handle, stream, request)
    limit = body_limit(request.target)
    body = read_body(stream, limit)
    if body === :large
        @warn "Request refused: larger than its limit" target = request.target limit declared = HTTP.header(request, "Content-Length", "not given")
        response = error_response(413, limit == MAX_BODY_BYTES ? TOO_LARGE : REQUEST_TOO_LARGE)
        HTTP.setheader(response, "Connection" => "close")
        return response, discard(stream, DISCARD_BYTES)
    end
    request.body = body
    return handle(request), true
end

# Reads an upload and hands it to `handle`. Returns the answer, or :large or
# :slow for one that was not read.
function read_upload_request(handle, stream, request, seconds)
    body = read_body(stream, MAX_BODY_BYTES, time() + seconds)
    body isa Symbol && return body
    request.body = body
    response = handle(request)
    request.body = UInt8[] # read and done with
    return response
end

# The same for an upload, which is read in its turn. The turn is kept until
# the run has been queued: until then the file is here whole, and again as
# it was read out of the request.
function answer_upload(handle, stream, request, turns, wait, seconds)
    if !take_turn!(turns, wait)
        @warn "Upload refused: no turn came" target = request.target waited = wait
        response = error_response(503, BUSY)
        HTTP.setheader(response, "Connection" => "close")
        return response, discard(stream, DISCARD_BYTES)
    end
    outcome = try
        read_upload_request(handle, stream, request, seconds)
    finally
        give_back!(turns)
        # what reading it took is given back a moment later, not left until
        # Julia next needs the room: 150 MiB after sixty of them
        tidy()
    end
    outcome isa Symbol || return outcome, true
    if outcome === :slow
        @warn "Upload refused: it took too long to arrive" target = request.target seconds
        response = error_response(408, UPLOAD_TOO_SLOW)
        HTTP.setheader(response, "Connection" => "close")
        return response, false # the rest of it is not waited for
    end
    @warn "Request refused: larger than its limit" target = request.target limit = MAX_BODY_BYTES declared = HTTP.header(request, "Content-Length", "not given")
    response = error_response(413, TOO_LARGE)
    HTTP.setheader(response, "Connection" => "close")
    return response, discard(stream, DISCARD_BYTES)
end

# What the server runs for each request.
function limited(handle; idle = IDLE_SECONDS, turns = Turns(), wait = UPLOAD_WAIT_SECONDS, seconds = UPLOAD_SECONDS)
    return function (stream::HTTP.Stream)
        request::HTTP.Request = stream.message
        response, finished = body_limit(request.target) == MAX_BODY_BYTES ?
            answer_upload(handle, stream, request, turns, wait, seconds) : answer(handle, stream, request)
        request.response = response
        response.request = request
        if response.body isa StreamedBody
            write_streamed(stream, response, idle)
        else
            HTTP.startwrite(stream)
            write(stream, response.body)
        end
        if !finished
            # The rest of the request is not going to be read: the answer is
            # completed and the connection dropped. HTTP.jl is told the
            # connection went away, which it takes quietly; leaving it to find
            # a request half read would be logged as a failure of the handler.
            HTTP.closewrite(stream)
            close(stream)
            throw(Base.IOError("request refused part read; connection closed", Base.UV_ECONNABORTED))
        end
        return
    end
end

# --- Connections ---

# The most connections held at once; more wait their turn. Each costs about
# 33 KB, so this bounds what any number of them can take, at about 330 MB:
# what is left of the pod's 2 GiB beside the largest batch (1.5 GB). A lower limit is easier to fill with silent connections,
# which keeps everyone else out, the health check included, until they are
# closed: 1,000 was, by 3,000 of them, for up to three minutes.
const MAX_CONNECTIONS = 10_000
# A connection that has sent nothing for this long is closed, so that ones
# left open and silent do not keep the places. HTTP.jl counts the time from
# the last data received, including while an answer is being worked out, so
# this must stay above the longest any answer takes: Atlas allows 30 seconds.
# It looks every one to two times this long, so a silent connection goes
# within one to three minutes.
const IDLE_SECONDS = 60

# The most a connection holds of what has been sent to it and not yet read.
# Julia would take in 10 MB, and keeps room that size once it has: an upload
# arriving faster than it was read left 8.5 MB behind it, held with its
# connection for a minute or two after that had closed, until the timer that
# closes silent connections next looked. Sixty uploads left 500 MiB. A sender
# with more than this to send waits for it to be read.
const UNREAD_BYTES = 16 * 1024

# Listens with the limits above. HTTP.jl's own log messages are turned off:
# it would otherwise write a warning for every idle connection it closes.
listen(handle, host, port; max_connections = MAX_CONNECTIONS, idle_seconds = IDLE_SECONDS) =
    HTTP.serve!(limited(handle; idle = idle_seconds), host, port; stream = true, max_connections, readtimeout = idle_seconds, verbose = -1,
        tcpisvalid = socket -> (socket.throttle = UNREAD_BYTES; true))

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
