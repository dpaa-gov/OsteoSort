# Memory held by a run's results must go back to the system once they are
# released, as Clear does: on Atlas the pod has 2 GiB, and Julia by itself
# keeps what it has used. Needs no database: the reference group is made up.
# The limits are loose, since how much is collected when varies from run to
# run; the numbers under Atlas's limits are measured by hand before a release.

# Memory this process holds, as the system counts it against a pod
resident_mib() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 / 1024^2

# These two reach a result table, and are kept apart from the test below so
# that nothing of theirs is left there holding it: a table is only given back
# when nothing holds it at all.

# A table's first column, held so as not to count: `.value` is nothing once the table has gone
@noinline held_weakly(state, job, name) = WeakRef(first((@atomic OSS.find_job(state.jobs, job).output).tables[name]))

# A download given `seconds` to finish, straight from its handler: whether it did, and the lines it wrote
@noinline function download_within(state, job, name, seconds)
    request = HTTP.Request("GET", "/api/jobs/$job/download?table=$name")
    request.context[:params] = Dict("id" => job)
    body = OSS.download_handler(state, request; seconds).body
    written = IOBuffer()
    finished = body.write_to(written)
    body.finished()
    return finished, count(==(UInt8('\n')), take!(written))
end

@testset "memory is given back" begin
    if !Sys.islinux()
        @test_skip "needs /proc"
    else
        codes = ["hum_01", "hum_02", "hum_03"]
        n = 40
        values = Matrix{Union{Missing, Float64}}(undef, 2n, length(codes))
        for i in 1:n, j in eachindex(codes)
            values[i, j] = 40.0 + 7j + 0.9 * (i % 13) + 0.3 * (i % 5)
            values[n + i, j] = values[i, j] + 0.4 * ((i * j) % 5) - 1
        end
        table = OSJ.BoneTable(repeat(["R$i" for i in 1:n], 2), vcat(fill("left", n), fill("right", n)), codes, values)
        group = OSJ.ReferenceGroup("Sample group", "Sample", "group", "x", Dict("humerus" => table))
        measurements = OSS.Measurement[(code = code, bone = "humerus", name = nothing) for code in codes]
        snapshot = OSS.ReferenceSnapshot([group], measurements, ["humerus"], String[], OSS.now(OSS.UTC))
        config = OSS.Config("", 5432, "", "", "", 3838, 30, joinpath(OSS.REPO_ROOT, "web"),
            joinpath(pkgdir(OSS), "config"), "test")
        state = OSS.AppState(config)
        @atomic state.snapshot = snapshot
        @atomic state.last_attempt = OSS.now(OSS.UTC) # so nothing tries to reach ARDS
        respond = OSS.handler(state)

        # 1,140 left and 1,140 right humeri: 1,299,600 comparisons, as memory_after_clear.py
        per_side = 1140
        rows = ["accession,side,element," * join(codes, ",")]
        for side in ("Left", "Right"), i in 1:per_side
            push!(rows, "$(side[1])$i,$side,Humerus," * join((round(40 + (i * (k + 3)) % 23 + 7k; digits = 1) for k in 1:3), ","))
        end
        body = JSON.json((analysis = "pairmatch", references = ["Sample group"], alpha = 0.1, csv = join(rows, "\n"),
            element = "humerus", measurements = codes,
            settings = (absolute = false, yeojohnson = false, zeromean = false, tails = 2)))

        function run()
            response = respond(HTTP.Request("POST", "/api/multiple", ["Content-Type" => "application/json"], Vector{UInt8}(body)))
            job = JSON.parse(response.body).job
            status = nothing
            for _ in 1:1200
                status = JSON.parse(respond(HTTP.Request("GET", "/api/jobs/$job")).body)
                status.status == "running" || break
                sleep(0.05)
            end
            return job, status
        end
        release(job) = respond(HTTP.Request("POST", "/api/jobs/$job/release"))
        # the tidy-up runs a second after a release
        function settled()
            sleep(1.5)
            while OSS.TIDYING[]
                sleep(0.1)
            end
            return resident_mib()
        end

        # once first, so that what compiling the run takes is not counted
        job, status = run()
        @test status.status == "done" && status.summary.comparisons == per_side^2
        release(job)
        before = settled()

        job, _ = run()
        held = settled() # the run's own tidy-up has passed; the results remain
        release(job)
        after = settled()
        @info "Memory around one run of $(per_side^2) comparisons" before held after
        # About 150 MiB locally. How much of it shows depends on what the
        # process kept from the first run: GitHub's runner has measured 93.
        @test held - before > 50                     # the results really were in memory
        @test after - before < (held - before) / 4   # and most of it came back on release
        @test OSS.find_job(state.jobs, job) === nothing

        # A download is sent as it is written. Made whole first, each took its
        # file's size in memory, and twelve of this table at once 890 MiB.
        server = OSS.listen(respond, "127.0.0.1", 8775)
        try
            job, status = run()
            total = status.tables.excluded.total
            url = "http://127.0.0.1:8775/api/jobs/$job/download?table=excluded"
            # reads a download as a browser saving it would, keeping none of it; `after_first` runs once some
            # has come, and with `pause` it stops reading for that many seconds after every 8 MB
            # Each request here is made on a connection of its own. The client
            # would otherwise keep them to use again, and hand out ones the
            # server has since closed: with no second try, as here, that request fails.
            fresh() = HTTP.Pool(1)
            function download(after_first = () -> nothing; from = url, pause = 0)
                bytes, lines = 0, 0
                complete = try
                    HTTP.open("GET", from; retry = false, pool = fresh()) do io
                        HTTP.startread(io)
                        while !eof(io)
                            piece = readavailable(io)
                            bytes == 0 && after_first()
                            pause > 0 && bytes ÷ 8_000_000 < (bytes + length(piece)) ÷ 8_000_000 && sleep(pause)
                            bytes += length(piece)
                            lines += count(==(UInt8('\n')), piece)
                        end
                    end
                    true
                catch e
                    e isa HTTP.Exceptions.StatusError && @warn "Download refused" status = e.status
                    false
                end
                return (; complete, bytes, lines)
            end
            one = download() # once first, as above
            @test one.complete && one.lines == total + 1
            held = settled()
            peak = Ref(held)
            going = Ref(true)
            watcher = Threads.@spawn while going[]
                peak[] = max(peak[], resident_mib())
                sleep(0.02)
            end
            downloads = fetch.([@async download() for _ in 1:12])
            going[] = false
            wait(watcher)
            @info "Memory over twelve downloads at once of $(round(Int, downloads[1].bytes / 1e6)) MB each" held peak = peak[]
            @test all(d -> d.complete && d.lines == total + 1, downloads)
            # About 170 MiB locally, most of it not yet collected. Loose for
            # the same reason as above, and well under what it was.
            @test peak[] - held < 450

            # Only so many downloads run at once, each holding the piece it is
            # sending: one more is refused, and the page, which asks first, is
            # told so. Twenty here are begun and then left unread.
            ask(path) = HTTP.get("http://127.0.0.1:8775" * path; status_exception = false, retry = false, pool = fresh())
            asking = "/api/jobs/$job/download?table=excluded"
            @test OSS.MAX_DOWNLOADS == 20 && state.jobs.downloads[] == 0
            @test ask(asking * "&check=1").status == 204
            @test ask("/api/jobs/nope/download?table=excluded&check=1").status == 404
            go = Base.Event()
            waiting = [@async download(() -> wait(go)) for _ in 1:OSS.MAX_DOWNLOADS]
            @test timedwait(() -> state.jobs.downloads[] == OSS.MAX_DOWNLOADS, 30) == :ok
            for refused in (ask(asking), ask(asking * "&check=1"))
                @test refused.status == 503 && JSON.parse(refused.body).error == OSS.DOWNLOADS_BUSY
            end
            @test state.jobs.downloads[] == OSS.MAX_DOWNLOADS # a refusal takes no place
            # everything else is answered meanwhile
            @test ask("/healthz").status == 200 && ask("/api/jobs/$job/rows?table=excluded").status == 200
            notify(go)
            @test all(d -> d.complete && d.lines == total + 1, fetch.(waiting))
            # their places come back, and the next download is taken
            @test timedwait(() -> state.jobs.downloads[] == 0, 10) == :ok
            @test download().complete

            # A connection that has sent nothing for a while is closed, and a
            # download sends nothing: one that is being read must not count as
            # silent, however long it takes. Here silent is a second.
            patient = OSS.listen(respond, "127.0.0.1", 8776; idle_seconds = 1)
            try
                from = replace(url, "8775" => "8776")
                seconds = @elapsed slow = download(; from, pause = 0.3)
                @test seconds > 4 && slow.complete && slow.lines == total + 1
                # One that stops being read is closed, and its place comes
                # back, though the reader keeps its connection open. HTTP.jl
                # by itself leaves it: forty seconds on it still had its place.
                reader = HTTP.Sockets.connect("127.0.0.1", 8776)
                write(reader, "GET /api/jobs/$job/download?table=excluded HTTP/1.1\r\nHost: x\r\n\r\n")
                @test startswith(String(readavailable(reader)), "HTTP/1.1 200")
                @test timedwait(() -> state.jobs.downloads[] == 1, 5) == :ok
                @test timedwait(() -> state.jobs.downloads[] == 0, 10) == :ok
                close(reader)
            finally
                close(patient)
            end

            # However it is read, a download has so long and no longer. Asked
            # for here with no time at all, straight from its handler: the
            # headings go and nothing more.
            @test OSS.DOWNLOAD_SECONDS == 600
            @test download_within(state, job, "excluded", 0) == (false, 1)

            # Results cleared while they are being downloaded are given back
            # then, not when the download would have ended: it stops, short.
            column = held_weakly(state, job, "excluded")
            cut = download(() -> release(job))
            @test !cut.complete && 0 < cut.lines < total + 1
            @test OSS.find_job(state.jobs, job) === nothing
            settled()
            GC.gc()
            @test column.value === nothing # nothing still holds the table
            @test timedwait(() -> state.jobs.downloads[] == 0, 10) == :ok # however a download ended, its place came back
            @test ask("/healthz").status == 200
        finally
            close(server)
        end

        # An upload that has been answered leaves nothing behind it. Each
        # connection used to keep room for what it had been sent faster than
        # it was read, 8.5 MB of an upload, until a minute or two after it
        # had closed: the twenty here left 316 MiB.
        server = OSS.listen(respond, "127.0.0.1", 8778)
        try
            upload = "{\"pad\": \"" * "x"^(11 * 1024^2) * "\"}"
            function send()
                socket = HTTP.Sockets.connect("127.0.0.1", 8778)
                write(socket, "POST /api/multiple HTTP/1.1\r\nHost: x\r\nContent-Length: $(sizeof(upload))\r\n\r\n")
                write(socket, upload)
                answer = String(readavailable(socket))
                close(socket)
                return answer
            end
            # what Julia counts as in use once everything unused has been cleared out
            in_use() = (settled(); GC.gc(); Base.gc_live_bytes() / 1024^2)
            @test startswith(send(), "HTTP/1.1 400") # once first, as above; it is read, and is not a case file
            before = in_use()
            answers = fetch.([@async send() for _ in 1:20])
            @test all(startswith("HTTP/1.1 400"), answers)
            after = in_use()
            @info "In use around twenty uploads of 11 MB at once" before after
            @test after - before < 50
        finally
            close(server)
        end
    end
end
