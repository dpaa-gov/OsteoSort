# HTTP server: JSON API under /api, static frontend for everything else.

# What the app says of itself goes out as plain lines: what is going on to
# standard output, what has gone wrong to standard error. Julia's own log
# messages are not used, because in a trimmed program they print nothing.
say(line::String) = (println(Core.stdout, line); nothing)
complain(line::String) = (println(Core.stderr, line); nothing)

# An error in words, for the log. The kinds this app raises itself are given
# with what they say; any other is named by its kind, which is as much as a
# trimmed build can tell of an error it was not told to expect.
function describe(@nospecialize(e))::String
    e isa RequestError && return e.message
    e isa PG.Error && return PG.describe(e)
    kind = String(nameof(typeof(e)))
    if e isa ErrorException
        said = e.msg
        return said isa String ? said : kind
    elseif e isa ArgumentError
        said = e.msg
        return said isa String ? kind * ": " * said : kind
    elseif e isa SystemError
        return kind * ": " * e.prefix # what was being done, such as opening a named file
    elseif e isa TaskFailedException
        return "a task failed: " * describe(e.task.exception)
    end
    return kind
end

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
        say("Reference data loaded: " * string(length(snapshot.groups)) * " groups, " * string(length(snapshot.bones)) * " bones")
        return true
    catch e
        @atomic state.load_error = describe(e)
        complain("Reference data load failed: " * describe(e))
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
        recently_attempted(state) || wait(Threads.@spawn (refresh_reference!(state); nothing))
    end
    return
end

# Requests are handled on the interactive thread, which HTTP.jl keeps to
# itself. Anything slow runs on a worker thread instead, so the server keeps
# answering other requests meanwhile.
# `T` is what the work gives back. The task keeps its result to itself and
# hands back nothing: one that hands a value back is accepted by a trimmed
# build and then fails when it is run.
function off_thread(::Type{T}, work::F)::T where {T, F}
    result = Ref{Union{Nothing, T}}(nothing)
    refused = Ref{Union{Nothing, RequestError}}(nothing)
    task = Threads.@spawn begin
        try
            result[] = work()
        catch e
            # an answer for the user is passed on as it is; anything else fails
            # the task, so the log shows where on the worker thread it failed
            e isa RequestError || rethrow()
            refused[] = e
        end
        nothing
    end
    wait(task)
    problem = refused[]
    problem === nothing || throw(problem)
    return result[]::T
end

# A download's body: a result table, written out as CSV as it is sent, not
# held whole. It is the one answer written that way. `write_download` writes
# it and returns whether it wrote all of it; `download_finished` is called
# once the response is over, however it ended (both in api.jl).
struct Download <: HTTP.AbstractBody
    table::ResultTable
    jobs::JobStore      # its job is looked for here before each piece: cleared results stop it
    id::String
    target::String      # the request, for the log
    deadline::Float64   # when it stops, as `time()` gives it
    seconds::Int        # the time it was allowed, for the log
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
        complain("Reference data unavailable: " * load_error)
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
    file = state.config.web_dir
    for part in parts
        file = joinpath(file, part)
    end
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

# Which part of the app a request is for. The routes are few and fixed, so
# they are told apart here by name; a table of routes looked up as each
# request arrives is something a trimmed build cannot follow.
#
# A path is taken a part at a time, so a doubled or closing slash makes no
# difference, and what follows a question mark is not part of it. A job's
# results are found by the id that follows `/api/jobs/`.
function route(state::AppState, req::HTTP.Request)::HTTP.Response
    parts = filter(!isempty, split(first(split(req.target, '?'; limit = 2)), "/"))
    is(names::String...) = length(parts) == length(names) && all(i -> parts[i] == names[i], eachindex(names))
    # /api/jobs/{id}, then what follows the id
    of_job(rest::String...) = length(parts) == 3 + length(rest) && parts[1] == "api" && parts[2] == "jobs" &&
        all(i -> parts[3 + i] == rest[i], eachindex(rest))
    if is("healthz")
        req.method == "GET" || return HTTP.Response(405)
        return HTTP.Response(200, ["Content-Type" => "text/plain"], "ok")
    elseif length(parts) > 1 && parts[1] == "api"
        if req.method == "GET"
            is("api", "meta") && return meta_handler(state)
            is("api", "template.csv") && return template_handler(state)
            of_job() && return job_handler(state, String(parts[3]))
            of_job("rows") && return rows_handler(state, req, String(parts[3]))
            of_job("download") && return download_handler(state, req, String(parts[3]))
        elseif req.method == "POST"
            is("api", "single") && return single_handler(state, req)
            is("api", "multiple") && return multiple_handler(state, req)
            of_job("release") && return release_handler(state, String(parts[3]))
        end
        return error_response(404, "Not found")
    end
    return static_handler(state, req)
end

function handler(state::AppState)
    return function (req::HTTP.Request)
        try
            return route(state, req)
        catch e
            e isa RequestError && return error_response(e.status, e.message)
            complain("Request failed: " * String(req.method) * " " * String(req.target) * ": " * describe(e))
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

# Reads the next piece of a request's body into `piece`. Returns how much
# came: none once it has all been read.
#
# HTTP.jl's own `readbytes!(stream, piece)` does this, but a trimmed build
# cannot take it (HTTP.jl 2.9.0): HTTP.jl keeps the body as a body of any
# kind and narrows it only part way, which leaves the reading code to be
# chosen while the program runs. So the kinds an HTTP/1.1 server makes are
# named here in full, HTTP.jl's internal `_ConnReader` among them. Unlike
# `readbytes!`, this does not answer `Expect: 100-continue`, which browsers
# do not send.
#
# Whether HTTP.jl has fixed it: put `readbytes!(stream, piece)` back and run
# the trim checker. If it no longer reports `body_read!`, this can go.
const BODY_READER = HTTP._ConnReader
function read_piece!(stream::HTTP.Stream, piece::Vector{UInt8})::Int
    body = stream.request_body
    body isa HTTP.EmptyBody && return 0
    body isa HTTP.FixedLengthBody{BODY_READER} && return HTTP.body_read!(body, piece)
    body isa HTTP.ChunkedBody{BODY_READER} && return HTTP.body_read!(body, piece)
    body isa HTTP.EOFBody{BODY_READER} && return HTTP.body_read!(body, piece)
    throw(ArgumentError("a request body of a kind not read here"))
end

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
        while (n = read_piece!(stream, piece)) > 0
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
        while (n = read_piece!(stream, piece)) > 0
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
mutable struct Sending{S <: HTTP.Stream} <: IO
    const stream::S
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
function write_streamed(stream, body::Download, target)
    sending = Sending(stream, false)
    complete = try
        HTTP.startwrite(stream)
        write_download(sending, body)
    catch e
        sending.failed && rethrow() # the client went away, or was closed for taking nothing; HTTP.jl closes it quietly
        complain("Response failed part way: " * target * ": " * describe(e))
        false
    finally
        download_finished(body)
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

# Reads a request within its limits and answers it: `handle` is given the
# request once its body has been read.
function answer(handle::H, stream::HTTP.Stream, request::HTTP.Request)::HTTP.Response where {H}
    limit = body_limit(request.target)
    body = read_body(stream, limit)
    if body === :slow
        complain("Request refused, it took too long to arrive: " * request.target)
        return refusal(408, "The request took too long to arrive")
    elseif body isa Symbol
        too_large(request, limit)
        discard(stream, DISCARD_BYTES)
        return refusal(413, limit == MAX_BODY_BYTES ? TOO_LARGE : REQUEST_TOO_LARGE)
    end
    return handle(with_body(request, body))
end

too_large(request::HTTP.Request, limit::Int) = complain("Request refused, larger than its limit of " * string(limit) *
    " bytes: " * request.target * " (declared " * HTTP.header(request, "Content-Length", "not given") * ")")

# Reads an upload and hands it to `handle`. Returns the answer, or :large or
# :slow for one that was not read.
function read_upload_request(handle::H, stream::HTTP.Stream, request::HTTP.Request)::Union{Symbol, HTTP.Response} where {H}
    body = read_body(stream, MAX_BODY_BYTES)
    body isa Symbol && return body
    return handle(with_body(request, body))
end

# The same for an upload, which is read in its turn. The turn is kept until
# the run has been queued: until then the file is here whole, and again as
# it was read out of the request.
function answer_upload(handle::H, stream::HTTP.Stream, request::HTTP.Request, turns::Turns, wait::Real)::HTTP.Response where {H}
    if !take_turn!(turns, wait)
        complain("Upload refused, no turn came in " * string(wait) * " seconds: " * request.target)
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
        complain("Upload refused, it took too long to arrive: " * request.target)
        return refusal(408, UPLOAD_TOO_SLOW) # the rest of it is not waited for
    end
    too_large(request, MAX_BODY_BYTES)
    discard(stream, DISCARD_BYTES)
    return refusal(413, TOO_LARGE)
end

# What the server runs for each request. A request whose body is not read to
# its end, as when it is refused, is answered and its connection closed by
# HTTP.jl: what is left of it is not waited for.
function limited(handle::H; turns::Turns = Turns(), wait::Real = UPLOAD_WAIT_SECONDS) where {H}
    return function (stream::HTTP.Stream)
        request = HTTP.startread(stream)
        response = body_limit(request.target) == MAX_BODY_BYTES ?
            answer_upload(handle, stream, request, turns, wait) : answer(handle, stream, request)
        HTTP.setstatus(stream, response.status)
        for header in response.headers
            HTTP.setheader(stream, header)
        end
        # an answer is one of these
        body = response.body
        if body isa Download
            write_streamed(stream, body, request.target)
        elseif body isa String || body isa Vector{UInt8}
            write(stream, body)
        elseif !(body isa HTTP.EmptyBody)
            throw(ArgumentError("an answer of a kind not written here"))
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
function serve(config::Config; host::String = "0.0.0.0", port::Int = config.port, sweep::Real = SWEEP_SECONDS)
    state = AppState(config)
    Threads.@spawn begin
        try
            ensure_fresh!(state)
        catch e
            complain("The first load of reference data failed: " * describe(e))
        end
        nothing
    end
    server = listen(handler(state), host, port)
    # results nobody has used for an hour are dropped even when no other run comes along
    Threads.@spawn begin
        try
            while isopen(server)
                sleep(sweep)
                sweep!(state.jobs)
            end
        catch e
            complain("Dropping unused results failed, and is not tried again: " * describe(e))
        end
        nothing
    end
    say("OsteoSort listening on " * host * ":" * string(port) * ", version " * config.version)
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
        println(Core.stderr, "OsteoSort could not start: ", describe(e))
        return 1
    end
    return 0
end
