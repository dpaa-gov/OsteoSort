# Memory held by a run's results must go back to the system once they are
# released, as Clear does: on Atlas the pod has 2 GiB, and Julia by itself
# keeps what it has used. Needs no database: the reference group is made up.
# The limits are loose, since how much is collected when varies from run to
# run; the numbers under Atlas's limits are measured by hand before a release.

# Memory this process holds, as the system counts it against a pod
resident_mib() = parse(Int, split(read("/proc/self/statm", String))[2]) * 4096 / 1024^2

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
    end
end
