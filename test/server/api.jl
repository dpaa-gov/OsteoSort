# The HTTP API end to end. What it returns must be what OSJ computes for the
# same input, in the form the page shows it.

const API = "http://127.0.0.1:8766"

post(path, body) = HTTP.post(API * path, ["Content-Type" => "application/json"], JSON3.write(body); status_exception = false)
get_json(path) = JSON3.read(HTTP.get(API * path; status_exception = false).body)

function wait_for(job)
    for _ in 1:600
        status = get_json("/api/jobs/$job")
        status.status == "running" || return status
        sleep(0.05)
    end
    error("job did not finish")
end

@testset "api" begin
    case_csv = read(joinpath(DATA, "classic_case_data.csv"), String)
    upload = OSS.read_upload(case_csv)
    references = String.(collect(meta.default_references))
    groups = [only(g for g in snapshot.groups if g.label == label) for label in references]
    settings = (absolute = false, yeojohnson = false, zeromean = false, tails = 2)
    osj_settings = OSJ.Settings(false, false, false, 2)
    common = (references = references, alpha = 0.1)
    server, state = OSS.serve(config; host = "127.0.0.1", port = 8766)
    try
        @testset "single" begin
            left = Dict("hum_01" => 306, "hum_02" => 63, "hum_03" => 45, "hum_06" => 43.9)
            right = Dict("hum_01" => 306, "hum_02" => 63, "hum_03" => 42.6, "hum_06" => 48.2)
            response = post("/api/single", merge(common, (analysis = "pairmatch", settings = settings, element = "humerus", left = left, right = right)))
            @test response.status == 200
            body = JSON3.read(response.body)
            # a reference group named twice counts once
            twice = post("/api/single", merge(common, (references = vcat(references, references), analysis = "pairmatch",
                settings = settings, element = "humerus", left = left, right = right)))
            @test JSON3.read(twice.body).results.rows == body.results.rows
            direct = OSJ.ttest(OSJ.prepare_single_pair_match(groups, "humerus", left, right), 0.1, osj_settings)
            @test collect(body.results.columns) ==
                  ["Accession 1", "Element 1", "Side 1", "Accession 2", "Element 2", "Side 2", "Measurements", "n", "Mean", "SD", "p", "Result", "Reference"]
            row = only(body.results.rows)
            @test row[1:6] == ["X", "Humerus", "Left", "Y", "Humerus", "Right"]      # capitalised for display
            @test row[7] == "Hum_01 Hum_02 Hum_03 Hum_06"
            found = direct.results
            @test (row[8], row[9], row[10], row[11], row[12]) == (only(found.n), only(found.mean), only(found.sd), only(found.p), only(found.result))
            @test row[13] == only(found.reference) && count(',', row[13]) == 3      # all four groups contributed
            @test collect(body.plot.reference) == direct.plot.reference && body.plot.specimen == direct.plot.specimen
            @test length(body.plot.reference) == row[8]

            values_a = Dict("hum_01" => 306, "hum_02" => 63)
            values_b = Dict("fem_01" => 489, "fem_02" => 483, "fem_03" => 92)
            response = post("/api/single", merge(common, (analysis = "regression", element_a = "humerus", element_b = "femur",
                side_a = "Left", side_b = "Left", values_a = values_a, values_b = values_b)))
            @test response.status == 200
            body = JSON3.read(response.body)
            direct = OSJ.regression_test(OSJ.prepare_single_regression(groups, "humerus", "femur", "Left", "Left", values_a, values_b), 0.1)
            row = only(body.results.rows)
            @test collect(body.results.columns)[8:11] == ["n", "R²", "p", "Result"]
            @test collect(body.results.columns)[1:6] == ["Accession 1", "Element 1", "Side 1", "Accession 2", "Element 2", "Side 2"]
            @test (row[8], row[9], row[10], row[11]) ==
                  (only(direct.results.n), only(direct.results.r2), only(direct.results.p), only(direct.results.result))
            @test row[10] == round(row[10]; digits = 4)                              # four places, like every other p-value
            @test length(body.plot.ref_x) == row[8] == length(body.plot.band.fit)
            @test all(body.plot.band.lower .< body.plot.band.fit .< body.plot.band.upper)

            response = post("/api/single", merge(common, (analysis = "articulation", settings = settings, element_a = "humerus",
                element_b = "ulna", side = "Left", values_a = (hum_06 = 45.5,), values_b = (uln_11 = 28.7,))))
            @test response.status == 200
            row = only(JSON3.read(response.body).results.rows)
            pairs = OSJ.articulation_pairs(groups, OSS.articulation_config(config))
            direct = OSJ.ttest(OSJ.prepare_single_articulation(groups, pairs, "humerus", "ulna", "Left",
                Dict("hum_06" => 45.5), Dict("uln_11" => 28.7)), 0.1, osj_settings; articulation = true)
            @test row[[2, 5, 7]] == ["Humerus", "Ulna", "Hum_06 Uln_11"] && row[11] == only(direct.results.p)
        end

        @testset "request errors" begin
            base = (analysis = "pairmatch", references = ["DPAA white male"], alpha = 0.1, settings = settings,
                    element = "humerus", left = (hum_01 = 300,), right = (hum_01 = 301,))
            @test post("/api/single", base).status == 200
            @test post("/api/single", merge(base, (alpha = 5,))).status == 400
            @test post("/api/single", merge(base, (analysis = "nope",))).status == 400
            @test post("/api/single", merge(base, (references = ["No such group"],))).status == 409
            @test post("/api/single", merge(base, (left = (hum_01 = nothing,),))).status == 422
            # a typed measurement must be above zero
            for bad in (0, -300)
                refused = post("/api/single", merge(base, (left = (hum_01 = bad,),)))
                @test refused.status == 400 && JSON3.read(refused.body).error == "Hum_01 must be a number above 0"
            end
            # a batch with a field missing is refused when it is asked for, not after it has queued
            incomplete = post("/api/multiple", merge(common, (analysis = "pairmatch", settings = settings, csv = "a,b,c,d\n")))
            @test incomplete.status == 400 && JSON3.read(incomplete.body).error == "Missing field: element"
            # a run is refused when it would make more comparisons than may be held
            @test OSS.check_size(2_000_000, 2_000_000)
            too_big = try OSS.check_size(9_000_000, 2_000_000) catch e; e end
            @test too_big isa OSS.RequestError && occursin("9,000,000 comparisons", too_big.message) && occursin("2,000,000", too_big.message)
            @test HTTP.post(API * "/api/single", [], "not json"; status_exception = false).status == 400
            @test HTTP.get(API * "/api/jobs/unknown"; status_exception = false).status == 404
        end

        @testset "multiple" begin
            measurements = [m for m in OSJ.available_measurements(groups, "humerus") if m in upload.measurements]
            direct = OSJ.ttest(OSJ.prepare_pair_match(groups, upload, "humerus", measurements), 0.1, osj_settings)
            found = direct.results
            response = post("/api/multiple", merge(common, (analysis = "pairmatch", settings = settings,
                element = "humerus", measurements = measurements, csv = case_csv)))
            @test response.status == 202
            job = JSON3.read(response.body).job
            status = wait_for(job)
            @test status.status == "done"
            kept = findall(==("Cannot Exclude"), found.result)
            excluded = findall(==("Excluded"), found.result)
            @test !isempty(kept) && !isempty(excluded)
            @test status.summary.comparisons == length(found.result)
            @test status.summary.potential_matches == length(kept)
            @test status.summary.exclusions == length(excluded)
            @test status.summary.rejected == length(direct.rejected.reason)
            @test status.summary.specimens == length(union(found.id_1, found.id_2))
            @test status.tables.not_excluded.total == length(kept) && status.tables.excluded.total == length(excluded)
            @test sum(status.histogram.cannot_exclude) + sum(status.histogram.excluded) + status.histogram.outside == length(found.result)
            @test sum(status.histogram.excluded) == length(excluded)

            page = get_json("/api/jobs/$job/rows?table=excluded&offset=0&limit=25")
            @test length(page.rows) == 25 && page.total == page.filtered == length(excluded)
            first_excluded = excluded[1]
            row = collect(page.rows[1])
            @test row[[1, 4]] == [found.id_1[first_excluded], found.id_2[first_excluded]]
            @test row[2:3] == ["Humerus", "Left"] && row[11] == found.p[first_excluded] && row[8] == found.n[first_excluded]
            last_page = get_json("/api/jobs/$job/rows?table=excluded&offset=$(page.total - 3)&limit=25")
            @test length(last_page.rows) == 3
            sorted = get_json("/api/jobs/$job/rows?table=excluded&sort=11&dir=desc&limit=1000")
            @test issorted([r[11] for r in sorted.rows]; rev = true)
            found_rows = get_json("/api/jobs/$job/rows?table=excluded&search=%5Ea%24&limit=1000") # ^a$
            @test 0 < found_rows.filtered < found_rows.total
            @test all(r -> "a" in r, found_rows.rows)

            csv = String(HTTP.get(API * "/api/jobs/$job/download?table=excluded").body)
            rows = OSS.parse_csv(csv)
            @test length(rows) == page.total + 1
            @test rows[1][13] == "Reference" && occursin("white male", rows[2][13])   # the download says which groups were used
            @test parse(Float64, rows[2][11]) == found.p[first_excluded] && !occursin("e-", csv)   # p-values in fixed notation

            # releasing a run frees its results at once
            @test HTTP.post(API * "/api/jobs/$job/release").status == 204
            @test HTTP.get(API * "/api/jobs/$job"; status_exception = false).status == 404
            @test HTTP.get(API * "/api/jobs/$job/rows?table=excluded"; status_exception = false).status == 404
            @test HTTP.post(API * "/api/jobs/$job/release").status == 204       # and doing it twice is harmless

            failed = wait_for(JSON3.read(post("/api/multiple", merge(common, (analysis = "pairmatch", settings = settings,
                element = "humerus", measurements = ["hum_01"], csv = "accession,side\n1,left\n"))).body).job)
            @test failed.status == "error"
            @test occursin("accession, side and element", failed.error)
        end

        @testset "results held in memory are capped" begin
            # a store that may hold 1,000 result rows; each of these batches has 400
            store = OSS.JobStore(max_rows = 1000)
            direct = OSJ.ttest(OSJ.prepare_pair_match(groups, OSS.read_upload(read(joinpath(OSS.REPO_ROOT, "web", "files", "example_data.csv"), String)),
                "humerus", OSJ.available_measurements(groups, "humerus")), 0.1, osj_settings)
            output = OSS.job_output("pairmatch", direct, 0.1, 0.0)
            @test sum(length(first(t)) for t in values(output.tables)) == 400
            ids = String[]
            for _ in 1:5
                job = OSS.start_job!(_ -> output, store)
                push!(ids, job.id)
                while (@atomic job.status) == "running"
                    sleep(0.01)
                end
                sleep(1.1)   # finish times are compared, and they are kept to the millisecond
            end
            held = [id for id in ids if OSS.find_job(store, id) !== nothing]
            @test held == ids[4:5]                                   # the two newest fit; older ones were dropped
            # one batch bigger than the whole cap is still kept, alone
            small = OSS.JobStore(max_rows = 100)
            a = OSS.start_job!(_ -> output, small); sleep(1.1)
            b = OSS.start_job!(_ -> output, small); sleep(0.5)
            @test OSS.find_job(small, a.id) === nothing && OSS.find_job(small, b.id) !== nothing
        end

        @testset "a run released while it waits is not computed" begin
            store = OSS.JobStore()
            output = OSS.JobOutput("pairmatch", Dict{String, NamedTuple}(), (;), (;))
            ran = Threads.Atomic{Bool}(false)
            first = OSS.start_job!(_ -> (sleep(0.5); output), store)
            second = OSS.start_job!(_ -> (ran[] = true; output), store)   # waits for its turn behind the first
            OSS.release_job!(store, second.id)
            sleep(1.0)
            @test (@atomic first.status) == "done" && !ran[]
        end

        @testset "uploads and waiting runs are limited" begin
            # an upload over 5 MB is refused
            oversized = post("/api/multiple", merge(common, (analysis = "pairmatch", settings = settings, element = "humerus",
                measurements = ["hum_01"], csv = "accession,side,element,Hum_01\n" * repeat("H1,Left,Humerus,300\n", 320_000))))
            @test oversized.status == 413 && occursin("at most 5 MB", JSON3.read(oversized.body).error)
            # the limit is on the file, not on the request carrying it: a file with every cell in
            # quotes is under 5 MB although its request is well over
            quoted = "accession,side,element,Hum_01,Hum_02,Hum_03,Hum_04,Hum_05\n" *
                     repeat("\"H1\",\"Left\",\"Humerus\",\"300\",\"\",\"\",\"\",\"\"\n", 120_000)
            request = merge(common, (analysis = "pairmatch", settings = settings, element = "humerus", measurements = ["hum_01"], csv = quoted))
            @test sizeof(quoted) < 5 * 1024^2 && sizeof(JSON3.write(request)) > 6 * 1024^2
            accepted = post("/api/multiple", request)
            @test accepted.status == 202
            wait_for(JSON3.read(accepted.body).job)
            # twenty runs may compute or wait; the next is told the server is busy, until one finishes
            store = OSS.JobStore()
            output = OSS.JobOutput("pairmatch", Dict{String, NamedTuple}(), (;), (;))
            gate = Base.Event()
            jobs = [OSS.start_job!(_ -> (wait(gate); output), store) for _ in 1:OSS.MAX_QUEUED_JOBS]
            refused = try OSS.start_job!(_ -> output, store) catch e; e end
            @test refused isa OSS.RequestError && refused.status == 503 && refused.message == OSS.BUSY
            notify(gate)
            while any(job -> (@atomic job.status) == "running", jobs)
                sleep(0.01)
            end
            sleep(0.1)
            @test store.queued[] == 0
            @test OSS.start_job!(_ -> output, store) isa OSS.Job
        end

        @testset "results in use are kept" begin
            store = OSS.JobStore()
            output = OSS.JobOutput("pairmatch", Dict{String, NamedTuple}(), (;), (;))
            finish(job) = while (@atomic job.status) == "running"; sleep(0.01); end
            viewed, idle = OSS.start_job!(_ -> output, store), OSS.start_job!(_ -> output, store)
            finish(viewed); finish(idle)
            # both finished two hours ago; one was looked at a minute ago
            for job in (viewed, idle)
                @atomic job.finished = OSS.now(OSS.UTC) - OSS.Hour(2)
                @atomic job.used = OSS.now(OSS.UTC) - OSS.Hour(2)
            end
            @atomic viewed.used = OSS.now(OSS.UTC) - OSS.Minute(1)
            finish(OSS.start_job!(_ -> output, store))   # the next run prunes the store
            sleep(0.1)
            @test OSS.find_job(store, viewed.id) !== nothing && OSS.find_job(store, idle.id) === nothing
            # and with no other run coming along, the periodic sweep drops what has gone unused
            @atomic viewed.used = OSS.now(OSS.UTC) - OSS.Hour(2)
            OSS.sweep!(store)
            @test OSS.find_job(store, viewed.id) === nothing
        end

        @testset "work off the request thread" begin
            @test OSS.off_thread(() -> 41 + 1) == 42
            # an answer meant for the user comes back as it was thrown
            refused = try OSS.off_thread(() -> throw(OSS.RequestError(422, "no"))) catch e; e end
            @test refused isa OSS.RequestError && refused.message == "no"
            # anything else arrives with the worker thread's own backtrace attached
            failed = try OSS.off_thread(() -> error("boom")) catch e; e end
            @test failed isa TaskFailedException && occursin("boom", sprint(showerror, failed))
        end

        @testset "memory is given back when results are dropped" begin
            store = OSS.JobStore()
            output = OSS.JobOutput("pairmatch", Dict{String, NamedTuple}(), (;), (;))
            job = OSS.start_job!(_ -> output, store)
            while (@atomic job.status) == "running"
                sleep(0.01)
            end
            sleep(2.5)                                   # let any earlier tidy-up finish
            cleanups = Base.gc_num().full_sweep
            OSS.release_job!(store, "no such job")       # nothing dropped, nothing to clear out
            @test !OSS.TIDYING[]
            OSS.release_job!(store, job.id)              # as Clear, a new run or closing the page does
            @test OSS.TIDYING[]
            sleep(2.5)
            @test Base.gc_num().full_sweep > cleanups && !OSS.TIDYING[]
        end

        @testset "search sees what the table shows" begin
            @test OSS.cell_text(1.0e-4) == "0.0001" && OSS.cell_text(0.5) == "0.5" && OSS.cell_text(261) == "261"
            @test OSS.cell_text("Humerus") == "Humerus"
            table = (accession = ["a", "b"], p = [1.0e-4, 0.25])
            @test OSS.table_page(table, Dict("search" => "0.0001")).filtered == 1
            @test OSS.table_page(table, Dict("search" => "e-4")).filtered == 0
            # the reference breakdown is not on screen, so a search does not match it
            hidden = (accession = ["UT1", "b"], p = [0.5, 0.25], reference = ["UT white male 12", "UT white male 12"])
            @test OSS.table_page(hidden, Dict("search" => "UT")).filtered == 1
            # a search that runs past its time limit is stopped with a message; within it, it answers
            late = try OSS.table_page(table, Dict("search" => "a"); seconds = -1) catch e; e end
            @test late isa OSS.RequestError && late.status == 422 && late.message == "The search took too long. Try a simpler one."
            @test OSS.table_page(table, Dict("search" => "a")).filtered == 1
            @test OSS.table_page(table, Dict{String, String}(); seconds = -1).filtered == 2   # no search, no limit
        end

        @testset "several users at once" begin
            # three large batches at the same time, while another user keeps loading the page
            lines = split(read(joinpath(OSS.REPO_ROOT, "web", "files", "example_data.csv"), String), '\n'; keepempty = false)
            big_csv = join(vcat(lines[1:1], repeat(lines[2:end], 12)), "\n")
            request = merge(common, (analysis = "pairmatch", settings = merge(settings, (yeojohnson = true,)), element = "femur",
                measurements = OSJ.available_measurements(groups, "femur"), csv = big_csv))
            started = time()
            jobs = [JSON3.read(post("/api/multiple", request).body).job for _ in 1:3]
            slowest, checks = 0.0, 0
            while any(job -> get_json("/api/jobs/$job").status == "running", jobs)
                slowest = max(slowest, @elapsed HTTP.get(API * "/healthz"))
                slowest = max(slowest, @elapsed HTTP.get(API * "/"))
                slowest = max(slowest, @elapsed HTTP.get(API * "/api/meta"))
                checks += 1
            end
            finished = [wait_for(job) for job in jobs]
            @test all(status -> status.status == "done", finished)
            @test length(unique(status.summary.comparisons for status in finished)) == 1
            @test checks > 5
            @test slowest < 1.0
            println("Three batches of ", finished[1].summary.comparisons, " comparisons at once took ",
                round(time() - started; digits = 1), " s; slowest of ", 2checks, " page requests meanwhile: ",
                round(slowest * 1000; digits = 1), " ms")
        end
    finally
        close(server)
    end
end
