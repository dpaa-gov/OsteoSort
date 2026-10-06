using Test
using HTTP
using JSON
using OsteoSortServer
using OSJ
const OSS = OsteoSortServer

const DATA = joinpath(@__DIR__, "data")
const HAVE_DB = !isempty(get(ENV, "DB_NAME", ""))

@testset "config" begin
    @test OSS.conninfo_value("a'b\\c") == "'a\\'b\\\\c'"
    @test_throws ErrorException OSS.Config(Dict("DB_NAME" => "ards"))
    config = OSS.Config(Dict("DB_NAME" => "ards", "DB_USER" => "u", "DB_PASS" => "p", "DB_PORT" => "x"))
    @test config.db_port == 5432
    @test config.port == 3838
end

# Bones are listed head to toe where the data collection manual numbers their
# measurements, by a bone's lowest number; the rest follow by name.
@testset "bone order" begin
    @test OSS.manual_number("45") == 45 && OSS.manual_number(" 45a") == 45
    @test OSS.manual_number(missing) === nothing && OSS.manual_number("MCAL") === nothing && OSS.manual_number("") === nothing
    bone_of = ["ulna", "ulna", "humerus", "talus", "capitate", "cranium", "humerus"]
    numbers = ["54", "55", "46", missing, missing, "1", "45"]
    # only the bones in use are listed, yet every measurement helps place its bone
    @test OSS.bone_order(["ulna", "talus", "humerus", "capitate", "ulna"], bone_of, numbers) == ["humerus", "ulna", "capitate", "talus"]
    @test OSS.bone_order(["talus", "capitate"], bone_of, fill(missing, 7)) == ["capitate", "talus"]
end

# No more of a request is read than its route allows: one of a gigabyte or two
# would otherwise be held in memory before anything could refuse it.
@testset "a request is read only as far as its limit" begin
    config = OSS.Config("", 5432, "", "", "", 3838, 30, joinpath(OSS.REPO_ROOT, "web"), joinpath(pkgdir(OSS), "config"), "test")
    state = OSS.AppState(config)
    @atomic state.last_attempt = OSS.now(OSS.UTC) # so nothing tries to reach ARDS
    inner = OSS.handler(state)
    largest = Ref(0) # the largest body the app itself was handed
    server = HTTP.serve!(OSS.limited(req -> (largest[] = max(largest[], length(req.body)); inner(req))), "127.0.0.1", 8771; stream = true)
    url = "http://127.0.0.1:8771"
    post(path, body) = HTTP.post(url * path, ["Content-Type" => "application/json"], body; status_exception = false, retry = false)
    message(response) = JSON.parse(response.body).error
    # a request written by hand, for what the client above will not send; the answer, or nothing if none came in time
    function raw(text; seconds = 10)
        socket = HTTP.Sockets.connect("127.0.0.1", 8771)
        write(socket, text)
        answer = @async String(read(socket))
        done = timedwait(() -> istaskdone(answer), seconds) == :ok
        close(socket)
        return done ? fetch(answer) : nothing
    end
    try
        @test OSS.body_limit("/api/multiple") == OSS.MAX_BODY_BYTES && OSS.body_limit("/api/single") == OSS.SMALL_BODY_BYTES
        # small requests reach the app as before
        small = "{\"analysis\": \"nope\"}"
        ordinary = post("/api/single", small)
        @test ordinary.status in (400, 503) && largest[] == sizeof(small)
        @test HTTP.get(url * "/healthz").status == 200
        # over a small route's limit: refused, and never handed to the app
        largest[] = 0
        over = post("/api/single", "{\"pad\": \"" * "x"^100_000 * "\"}")
        @test over.status == 413 && message(over) == OSS.REQUEST_TOO_LARGE && largest[] == 0
        # the upload route takes a case file's worth, and no more
        fits = post("/api/multiple", "{\"pad\": \"" * "x"^(11 * 1024^2) * "\"}")
        @test fits.status != 413 && largest[] > 11 * 1024^2
        largest[] = 0
        upload = post("/api/multiple", "{\"pad\": \"" * "x"^(13 * 1024^2) * "\"}")
        @test upload.status == 413 && message(upload) == OSS.TOO_LARGE && largest[] == 0
        # a request that says it is 2 GB is refused on its word: nothing of it is waited for or read
        seconds = @elapsed answer = raw("POST /api/multiple HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000000\r\n\r\n{\"csv\": \"")
        @test answer !== nothing && startswith(answer, "HTTP/1.1 413") && seconds < 5 && largest[] == 0
        # one that does not say how large it is is cut off once it has gone over
        chunk = string(16384; base = 16) * "\r\n" * "x"^16384 * "\r\n"
        answer = raw("POST /api/single HTTP/1.1\r\nHost: x\r\nConnection: close\r\nTransfer-Encoding: chunked\r\n\r\n" * chunk^8 * "0\r\n\r\n")
        @test answer !== nothing && startswith(answer, "HTTP/1.1 413") && largest[] == 0
        # and the server is still answering afterwards
        @test HTTP.get(url * "/healthz").status == 200
    finally
        close(server)
    end
end

# Connections that are opened and left silent must not keep others out: only
# so many are held at once, and one that sends nothing is closed.
@testset "connections are limited, and silent ones closed" begin
    config = OSS.Config("", 5432, "", "", "", 3838, 30, joinpath(OSS.REPO_ROOT, "web"), joinpath(pkgdir(OSS), "config"), "test")
    state = OSS.AppState(config)
    @atomic state.last_attempt = OSS.now(OSS.UTC) # so nothing tries to reach ARDS
    @test OSS.MAX_CONNECTIONS == 1000 && OSS.IDLE_SECONDS == 60 # above the 30 seconds Atlas allows an answer
    # a server that holds two connections and closes one silent for a second
    server = OSS.listen(OSS.handler(state), "127.0.0.1", 8773; max_connections = 2, idle_seconds = 1)
    health = "GET /healthz HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"
    function answer_to(socket; seconds = 15)
        answer = @async String(read(socket))
        return timedwait(() -> istaskdone(answer), seconds) == :ok ? fetch(answer) : nothing
    end
    ask() = (socket = HTTP.Sockets.connect("127.0.0.1", 8773); write(socket, health); answer_to(socket))
    try
        @test startswith(ask(), "HTTP/1.1 200")
        # two connections that send nothing take both places
        silent = [HTTP.Sockets.connect("127.0.0.1", 8773) for _ in 1:2]
        sleep(0.3)
        # a request arriving now has to wait, and is answered once a silent one has been closed
        waited = @elapsed answer = ask()
        @test answer !== nothing && startswith(answer, "HTTP/1.1 200")
        @test 0.5 < waited < 10
        # the silent ones were told so and closed
        closed = [answer_to(socket; seconds = 10) for socket in silent]
        @test all(text -> text !== nothing && startswith(text, "HTTP/1.1 408"), closed)
        # and the server carries on
        @test startswith(ask(), "HTTP/1.1 200")
    finally
        close(server)
    end
end

# A number of millions of digits takes the parser minutes, during which the
# server answers nothing: it is refused before it is parsed.
@testset "a number too long to be one is refused unread" begin
    bytes(text) = Vector{UInt8}(text)
    long(text) = OSS.long_number(bytes(text))
    @test !long("{\"alpha\": 0.1, \"n\": 306, \"x\": 0.30000000000000004, \"e\": 1.5e-7}")
    @test !long("{\"a\": " * "9"^40 * "}") && long("{\"a\": " * "9"^41 * "}")
    @test long("{\"a\": 0." * "9"^41 * "}") && long("{\"a\": 1e" * "9"^41 * "}") && long("[" * "1"^41 * "]")
    @test !long("{\"a\": 1e400, \"b\": 123456789012345678901234567890}")     # short to read; refused later for their size
    # digits inside a string are text: a case file's accession numbers, whatever their length
    @test !long("{\"csv\": \"accession,side\\n" * "7"^500 * ",Left\"}")
    @test !long("{\"csv\": \"a \\\"quoted\\\" " * "7"^100 * "\", \"n\": 5}")
    @test long("{\"csv\": \"a \\\"quoted\\\" " * "7"^100 * "\", \"n\": " * "5"^41 * "}")
    @test !long("{\"csv\": \"ends with a backslash \\\\\", \"n\": 12}") && long("{\"csv\": \"x\\\\\", \"n\": " * "1"^41 * "}")
    # through the request reader: refused in well under a second, where parsing it would take minutes
    huge = bytes("{\"analysis\": \"pairmatch\", \"alpha\": " * "9"^2_000_000 * "}")
    seconds = @elapsed refused = try
        OSS.read_json(HTTP.Request("POST", "/api/single", [], huge))
    catch e
        e
    end
    @test refused isa OSS.RequestError && refused.status == 400 && refused.message == OSS.NUMBER_TOO_LONG
    @test seconds < 1
    decimal = bytes("{\"alpha\": 0." * "9"^2_000_000 * "}")
    @test (try OSS.read_json(HTTP.Request("POST", "/api/single", [], decimal)) catch e; e end).message == OSS.NUMBER_TOO_LONG
    # an ordinary request is read as before
    @test OSS.read_json(HTTP.Request("POST", "/api/single", [], bytes("{\"alpha\": 0.1}"))).alpha == 0.1
end

# A file small on disk can be a table too large to hold: it is refused before
# the table is made. 70 KB here would be 540 MB.
@testset "an upload's table has a size limit" begin
    wide = "accession,side,element," * join(("m$i" for i in 1:2000), ",") * "\n" * "a\n"^30_000
    @test sizeof(wide) < 100_000
    allocated = @allocated error = try
        OSS.read_upload(wide)
    catch e
        e
    end
    @test error isa ArgumentError && occursin("30,000 rows by 2,000 measurement columns is 60,000,000 cells", error.msg)
    @test allocated < 100 * 1024^2 # refused without making the table
    # a file at the limit is read
    full = "accession,side,element," * join(("m$i" for i in 1:1000), ",") * "\n" * "a\n"^10_000
    @test size(OSS.read_upload(full).values) == (10_000, 1000)
end

include("memory.jl")

if HAVE_DB
    config = OSS.Config()
    snapshot = OSS.load_reference(config)

    # a stalled query fails after 15 seconds instead of holding every page load
    let conn = OSS.LibPQ.Connection(OSS.conninfo(config))
        @test only(OSS.query(conn, "SHOW statement_timeout").statement_timeout) == "15s"
        close(conn)
    end
    meta = JSON.parse(JSON.json(OSS.build_meta(snapshot, config)))

    # What the page builds its dropdowns from must describe the reference data as loaded
    @testset "page metadata" begin
        @test [g.label for g in meta.groups] == [g.label for g in snapshot.groups]
        @test allunique(g.label for g in meta.groups)
        @test collect(meta.bones) == snapshot.bones
        # the long bones head to toe, then the bones the manual has no numbers for, by name
        major = ["clavicle", "scapula", "humerus", "radius", "ulna", "os coxa", "femur", "tibia", "fibula", "calcaneus"]
        @test first(snapshot.bones, length(major)) == major
        @test issorted(snapshot.bones[length(major) + 1:end]) && "sacrum" ∉ snapshot.bones
        @test [m.bone for m in snapshot.measurements] == sort([m.bone for m in snapshot.measurements]; by = bone -> findfirst(==(bone), snapshot.bones))
        @test issorted(snapshot.disabled)
        @test [m.code for m in meta.measurements] == [m.code for m in snapshot.measurements]
        @test all(m -> m.code == lowercase(m.code) && m.bone in snapshot.bones, meta.measurements)
        @test isempty(intersect(collect(meta.disabled_measurements), [m.code for m in meta.measurements]))
        @test length(meta.default_references) == 4 && issubset(collect(meta.default_references), [g.label for g in meta.groups])
        @test issubset(collect(meta.regression_bones), snapshot.bones)
        codes = Set(m.code for m in meta.measurements)
        @test !isempty(meta.articulation) && all(p -> p.a in codes && p.b in codes, meta.articulation)

        mismatches = String[]
        for (group, loaded) in zip(meta.groups, snapshot.groups), element in group.elements
            table = loaded.bones[element.element]
            element.rows == length(table.accession) || push!(mismatches, "$(group.label) $(element.element): rows")
            collect(element.sides) == sort(unique(table.side)) || push!(mismatches, "$(group.label) $(element.element): sides")
            collect(element.measurements) == OSJ.available_measurements(table) ||
                push!(mismatches, "$(group.label) $(element.element): measurements")
        end
        @test isempty(mismatches)
        @test sum(length(g.elements) for g in meta.groups) == sum(length(g.bones) for g in snapshot.groups)
    end

    include("api.jl")
    include("edge.jl")

    @testset "http" begin
        server, state = OSS.serve(config; host = "127.0.0.1", port = 8765)
        try
            # Atlas's health check can use either address; neither touches ARDS
            @test HTTP.get("http://127.0.0.1:8765/healthz").status == 200
            page = HTTP.get("http://127.0.0.1:8765/")
            @test page.status == 200 && occursin("<title>OsteoSort</title>", String(page.body))
            response = HTTP.get("http://127.0.0.1:8765/api/meta")
            @test response.status == 200
            @test JSON.parse(response.body).version == config.version
            # a second page load inside the max age reuses the snapshot
            loaded_at = (@atomic state.snapshot).loaded_at
            HTTP.get("http://127.0.0.1:8765/api/meta")
            @test (@atomic state.snapshot).loaded_at == loaded_at
            # the browser keeps a static file and is told when it has not changed
            script = HTTP.get("http://127.0.0.1:8765/js/app.js")
            etag = HTTP.header(script, "ETag")
            @test !isempty(etag) && HTTP.header(script, "Cache-Control") == "no-cache"
            unchanged = HTTP.get("http://127.0.0.1:8765/js/app.js", ["If-None-Match" => etag]; status_exception = false)
            @test unchanged.status == 304 && isempty(unchanged.body)
            @test HTTP.get("http://127.0.0.1:8765/js/app.js", ["If-None-Match" => "\"other\""]).body == script.body
            @test HTTP.get("http://127.0.0.1:8765/api/nope"; status_exception = false).status == 404
            @test HTTP.get("http://127.0.0.1:8765/../server/Project.toml"; status_exception = false).status == 404
        finally
            close(server)
        end
    end

    # Results nobody has used for an hour go on their own: the running server
    # looks for them on a timer (every 5 minutes; every second here).
    @testset "unused results expire by themselves" begin
        server, state = OSS.serve(config; host = "127.0.0.1", port = 8769, sweep = 1)
        try
            output = OSS.JobOutput("pairmatch", Dict{String, NamedTuple}(), (;), (;))
            job = OSS.start_job!(_ -> output, state.jobs)
            while (@atomic job.status) == "running"
                sleep(0.01)
            end
            sleep(2.5)
            @test OSS.find_job(state.jobs, job.id) !== nothing        # in use within the hour: kept
            @atomic job.used = OSS.now(OSS.UTC) - OSS.Hour(2)
            cleanups = Base.gc_num().full_sweep
            sleep(4.0)
            @test OSS.find_job(state.jobs, job.id) === nothing        # dropped by the timer, no other run needed
            @test Base.gc_num().full_sweep > cleanups                 # and its memory cleared out
        finally
            close(server)
        end
    end
else
    @warn "DB_NAME is not set; skipping tests that need ARDS"
end
