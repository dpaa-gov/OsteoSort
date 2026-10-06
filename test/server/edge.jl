# Awkward case files, with the outcome spelled out for each situation. The
# expectations here are decisions about how the app should behave.
#
# data/edge_cases.csv (Windows line endings, byte-order mark) holds:
#   H1-H4    left humeri: three measurements, one, one, none at all (a short row)
#   H5, H6, H7, H11, "H12, a", H5 again   right humeri, with a side typed as
#            "Right " (trailing space), a non-numeric cell, a quoted accession
#            containing a comma, and a repeated accession
#   H8-H10   rows that match nothing: blank side, blank element, misspelt element
#   F1, F2, O1   one left femur, one right femur, one left os coxa
#   R1, R2   radii from the right side only
#   U1       an ulna with values only in a switched-off and an unknown column

@testset "edge cases" begin
    groups = [only(g for g in snapshot.groups if g.label == label)
              for label in JSON.parse(JSON.json(OSS.build_meta(snapshot, config))).default_references]
    text = read(joinpath(DATA, "edge_cases.csv"), String)
    upload = OSS.read_upload(text)
    settings = OSJ.Settings(false, false, false, 2)
    pair_match(measurements) = OSJ.ttest(OSJ.prepare_pair_match(groups, upload, "humerus", measurements), 0.1, settings)
    specimens(table, columns) = [(table[columns[1]][i], table[columns[2]][i], table[columns[3]][i]) for i in eachindex(table.reason)]

    @testset "reading the file" begin
        @test length(upload.accession) == 19                      # the blank line is skipped
        @test upload.measurements[1] == "hum_01"                  # byte-order mark removed, names lower-cased
        @test upload.measurements[end] == "bogus_99"              # line endings handled
        @test upload.accession[12] == "H12, a"                    # quoted comma kept
        @test upload.side[7] == "Right"                           # the space typed after it is dropped
        @test ismissing(upload.side[8]) && ismissing(upload.element[9])
        @test ismissing(upload.values[11, 1]) && upload.values[11, 2] == 59.0   # "abc" is not a number
        @test all(ismissing, upload.values[4, :])                 # short row padded with blanks

        # a measurement is a finite number above zero; anything else is read as not taken
        odd = OSS.read_upload("accession,side,element,Hum_01,Hum_02,Hum_03,Hum_04,Hum_05\nH1,Left,Humerus,0,-5,NaN,Inf,310\n")
        @test all(ismissing, odd.values[1, 1:4]) && odd.values[1, 5] == 310.0

        # old Mac line endings, and a quote in the middle of a cell, are read as the page reads them
        mac = OSS.read_upload("accession,side,element,Hum_01\rH1,Left,Humerus,310\rH2,Right,Humerus,305\r")
        @test mac.accession == ["H1", "H2"] && mac.values == reshape([310.0, 305.0], 2, 1)
        inch = OSS.read_upload("accession,side,element,Hum_01\n5\" long,Left,Humerus,310\n\"H2, a\",Right,Humerus,305\n")
        @test inch.accession == ["5\" long", "H2, a"] && inch.side == ["Left", "Right"]

        moved = OSS.read_upload("Hum_01,Element,Hum_02,ACCESSION,Side\n310,Humerus,62,H1,Left\n")
        @test (moved.accession, moved.side, moved.element) == (["H1"], ["Left"], ["Humerus"])
        @test moved.measurements == ["hum_01", "hum_02"] && moved.values == [310.0 62.0]
        unnamed = OSS.read_upload("ID,L or R,Bone,Hum_01\nH1,Left,Humerus,310\n")
        @test (unnamed.accession, unnamed.side, unnamed.element, unnamed.measurements) == (["H1"], ["Left"], ["Humerus"], ["hum_01"])
    end

    @testset "pair-match with several measurements" begin
        result = pair_match(["hum_01", "hum_02", "hum_03", "hum_06"])
        rejected = result.rejected
        # 3 measured left x 6 measured right = 18 pairs; 3 of them share no measurement
        @test length(result.results.result) == 15
        @test Set(result.results.id_1) == Set(["H1", "H2", "H3"])
        @test Set(result.results.id_2) == Set(["H5", "H6", "H7", "H11", "H12, a"])
        @test count(==("H5"), result.results.id_2) == 6           # both specimens numbered H5 are compared
        @test all(!isempty, result.results.measurements)
        # rows that match no side or element are simply not part of the analysis
        @test isempty(intersect(["H8", "H9", "H10"], vcat(result.results.id_1, result.results.id_2, rejected.id_1, rejected.id_2)))
        @test rejected.reason == vcat(OSJ.UNMEASURED, fill(OSJ.NOTHING_IN_COMMON, 3))
        @test specimens(rejected, (:id_1, :element_1, :side_1))[1] == ("H4", "humerus", "left")
        @test (rejected.id_2[1], rejected.element_2[1], rejected.side_2[1]) == ("", "", "")
        @test Set(zip(rejected.id_1[2:end], rejected.id_2[2:end])) == Set([("H2", "H6"), ("H3", "H6"), ("H3", "H11")])
    end

    @testset "pair-match with one measurement" begin
        result = pair_match(["hum_01"])
        @test length(result.results.result) == 8                  # H1, H3 x H5, H7, "H12, a", H5
        rejected = result.rejected
        @test all(==(OSJ.UNMEASURED), rejected.reason)
        @test rejected.id_1 == ["H2", "H4", "", ""]               # left specimens in the first columns
        @test rejected.id_2 == ["", "", "H6", "H11"]              # right specimens in the second
    end

    @testset "every specimen on one side unmeasured" begin
        result = pair_match(["hum_03"])                           # only three right humeri have it
        @test result !== nothing
        @test isempty(result.results.result)
        @test result.rejected.id_1 == ["H1", "H2", "H3", "H4", "", "", ""]
        @test result.rejected.id_2 == ["", "", "", "", "H6", "H7", "H12, a"]
        @test all(==(OSJ.UNMEASURED), result.rejected.reason)
        output = OSS.job_output("pairmatch", result, 0.1, 0.0)
        @test output.summary.comparisons == 0 && output.summary.rejected == 7
        @test output.summary.exclusion_percent === nothing
    end

    @testset "nothing to analyse" begin
        # a bone present on one side only
        @test OSJ.prepare_pair_match(groups, upload, "radius", ["rad_01"]) === nothing
        # none of the chosen measurements is a column of the file
        @test OSJ.prepare_pair_match(groups, upload, "humerus", ["hum_04"]) === nothing
        # values only in a switched-off and an unknown column
        @test OSJ.prepare_pair_match(groups, upload, "ulna", ["uln_11"]) === nothing
        # an element the file does not have
        @test OSJ.prepare_pair_match(groups, upload, "tibia", ["tib_01"]) === nothing
        # articulation needs both bones on the chosen side
        @test OSJ.prepare_articulation(groups, upload, "femur", "os coxa", "Right", ["fem_04"], ["osc_17"]) === nothing
    end

    @testset "articulation and regression" begin
        result = OSJ.ttest(OSJ.prepare_articulation(groups, upload, "femur", "os coxa", "Left", ["fem_04"], ["osc_17"]),
            0.1, settings; articulation = true)
        @test (result.results.id_1, result.results.id_2) == (["F1"], ["O1"])
        @test result.results.measurements == ["fem_04 osc_17"]
        @test isempty(result.rejected.reason)

        result = OSJ.regression_test(OSJ.prepare_regression(groups, upload, "humerus", "femur", "LEFT", "left",
            ["hum_01", "hum_02", "hum_06"], ["fem_01", "fem_04"]), 0.1)
        @test result.results.x_id == ["H1", "H2", "H3"] && all(==("F1"), result.results.y_id)
        @test result.rejected.x_id == ["H4"] && result.rejected.reason == [OSJ.UNMEASURED]
    end

    @testset "through the API" begin
        server, _ = OSS.serve(config; host = "127.0.0.1", port = 8767)
        api = "http://127.0.0.1:8767"
        submit(body) = JSON.parse(HTTP.post(api * "/api/multiple", ["Content-Type" => "application/json"],
            JSON.json(merge((references = [g.label for g in groups], alpha = 0.1, csv = text,
                settings = (absolute = false, yeojohnson = false, zeromean = false, tails = 2)), body))).body).job
        function finished(job)
            for _ in 1:1200
                status = JSON.parse(HTTP.get("$api/api/jobs/$job").body)
                status.status == "running" || return status
                sleep(0.05)
            end
            error("job did not finish")
        end
        try
            status = finished(submit((analysis = "pairmatch", element = "humerus", measurements = ["hum_01", "hum_02", "hum_03", "hum_06"])))
            @test status.status == "done"
            @test (status.summary.comparisons, status.summary.rejected, status.summary.specimens) == (15, 4, 8)
            page = JSON.parse(HTTP.get("$api/api/jobs/$(status.id)/rows?table=rejected").body)
            @test collect(page.columns) == ["Accession 1", "Element 1", "Side 1", "Accession 2", "Element 2", "Side 2", "Reason"]
            @test collect(page.rows[1]) == ["H4", "Humerus", "Left", "", "", "", OSJ.UNMEASURED]
            csv = OSS.parse_csv(String(HTTP.get("$api/api/jobs/$(status.id)/download?table=not_excluded").body))
            @test any(row -> "H12, a" in row, csv)                # the comma survives the download too

            # unknown and switched-off measurement names are ignored, not an error
            status = finished(submit((analysis = "pairmatch", element = "humerus", measurements = ["hum_01", "uln_06", "bogus_99", "nope"])))
            @test status.status == "done" && status.summary.comparisons == 8

            status = finished(submit((analysis = "pairmatch", element = "radius", measurements = ["rad_01"])))
            @test status.status == "error" && status.error == OSS.NO_RESULT

            # a large batch: 500 left against 500 right
            rows = ["accession,side,element,Hum_01,Hum_02,Hum_06"]
            for i in 1:500, side in ("Left", "Right")
                wobble = side == "Left" ? 0.0 : 0.3 * ((i * 7) % 5) - 0.6
                push!(rows, "$(side[1])$i,$side,Humerus,$(290 + 0.11i + wobble),$(55 + 0.03i + wobble / 2),$(i % 9 == 0 ? "" : 40 + 0.02i)")
            end
            started = time()
            job = JSON.parse(HTTP.post(api * "/api/multiple", ["Content-Type" => "application/json"],
                JSON.json((references = [g.label for g in groups], alpha = 0.1, csv = join(rows, "\n"), analysis = "pairmatch",
                    element = "humerus", measurements = ["hum_01", "hum_02", "hum_06"],
                    settings = (absolute = false, yeojohnson = true, zeromean = false, tails = 2)))).body).job
            status = finished(job)
            seconds = time() - started
            @test status.status == "done" && status.summary.comparisons == 250_000 && status.summary.specimens == 1000
            total = status.tables.excluded.total
            last_page = JSON.parse(HTTP.get("$api/api/jobs/$job/rows?table=excluded&offset=$(total - 5)&limit=10&sort=11&dir=desc").body)
            @test length(last_page.rows) == 5
            paging = @elapsed HTTP.get("$api/api/jobs/$job/rows?table=excluded&search=L250&sort=11&dir=desc")
            download = HTTP.get("$api/api/jobs/$job/download?table=excluded").body
            @test count(==(UInt8('\n')), download) == total + 1
            println("250,000 comparisons through the API in ", round(seconds; digits = 1), " s; a searched and sorted page in ",
                round(paging * 1000; digits = 0), " ms; excluded download ", round(length(download) / 1e6; digits = 1), " MB")
        finally
            close(server)
        end
    end
end

# Selecting several reference groups pools their individuals: sample sizes add
# up, the order the groups are picked in does not matter, and the pooled
# individuals are exactly the groups' individuals.
@testset "combining reference groups" begin
    upload = OSS.read_upload(read(joinpath(DATA, "classic_case_data.csv"), String))
    group(label) = only(g for g in snapshot.groups if g.label == label)
    settings = OSJ.Settings(false, false, false, 2)
    function sample_sizes(labels, bone, measurements)
        data = OSJ.prepare_pair_match(group.(labels), upload, bone, measurements)
        data === nothing && return nothing
        # the comparisons themselves, whatever the sample size: small groups are the point here
        return OSJ.compare_pairs(data.sorta.values, data.sortb.values, data.refa.values, data.refb.values; tails = 2)
    end
    pooled_pairs = 0
    for (a, b) in (("DPAA white male", "UT white male"), ("SI japanese female", "SI japanese male"),
                   ("SI japanese female", "DPAA white male"), ("UT white female", "UT white male")),
        (bone, measurements) in (("humerus", ["hum_01", "hum_02", "hum_03", "hum_06"]), ("femur", ["fem_01", "fem_02", "fem_04"]),
                                 ("tibia", ["tib_01", "tib_02"]))
        both, swapped = sample_sizes([a, b], bone, measurements), sample_sizes([b, a], bone, measurements)
        only_a, only_b = sample_sizes([a], bone, measurements), sample_sizes([b], bone, measurements)
        # the same comparisons are made whichever groups are chosen; only the reference sample changes
        @test both.a == only_a.a == only_b.a && both.b == only_a.b
        @test both.used == only_a.used
        @test both.n == only_a.n .+ only_b.n
        @test isequal(both.p, swapped.p) && isequal(both.mean, swapped.mean) && both.n == swapped.n
        pooled_pairs += length(both.n)

        # the individuals behind those sample sizes are the two groups' individuals, none shared
        prepared = OSJ.prepare_pair_match(group.([a, b]), upload, bone, measurements)
        separate = [OSJ.prepare_pair_match([group(label)], upload, bone, measurements).refa.accession for label in (a, b)]
        @test isempty(intersect(separate...))
        @test sort(prepared.refa.accession) == sort(vcat(separate...))
        @test prepared.refa.accession == prepared.refb.accession   # left and right rows stay paired by individual
    end
    println("Combining reference groups: sample sizes add up across ", pooled_pairs, " comparisons")

    # all four default groups together equal the sum of the four alone
    labels = collect(JSON.parse(JSON.json(OSS.build_meta(snapshot, config))).default_references)
    together = sample_sizes(labels, "humerus", ["hum_01", "hum_02"])
    @test together.n == sum(sample_sizes([label], "humerus", ["hum_01", "hum_02"]).n for label in labels)
end

# The example users download: a commingled assemblage sampled from ARDS
@testset "example file" begin
    path = joinpath(OSS.REPO_ROOT, "web", "files", "example_data.csv")
    example = OSS.parse_csv(read(path, String))
    @test example[1] == OSS.template_header(snapshot)               # same columns as the template
    @test length(example) == 1057 && allunique(r[1] for r in example[2:end])   # every bone has its own specimen number
    @test all(r -> lowercase(r[3]) in snapshot.bones && r[2] in ("Left", "Right"), example[2:end])
    @test length(unique(r[3] for r in example[2:end])) == 27
    # it gives a real analysis against its own population
    upload = OSS.read_upload(read(path, String))
    group = [only(g for g in snapshot.groups if g.label == "Chiba japanese male")]
    result = OSJ.ttest(OSJ.prepare_pair_match(group, upload, "humerus", OSJ.available_measurements(group, "humerus")),
        0.1, OSJ.Settings(false, false, false, 2))
    @test length(result.results.result) == 400 && 0 < count(==("Excluded"), result.results.result) < 400
end

# A comparison needs ten reference individuals; below that the pair is rejected with the reason
@testset "minimum reference sample" begin
    upload = OSS.read_upload(read(joinpath(DATA, "classic_case_data.csv"), String))
    group(label) = only(g for g in snapshot.groups if g.label == label)
    settings = OSJ.Settings(false, false, false, 2)
    humerus = ["hum_01", "hum_02", "hum_03", "hum_06"]
    @test OSJ.MINIMUM_REFERENCE == 10

    # two small groups: samples of 4 or 5, so nothing is tested
    small = OSJ.ttest(OSJ.prepare_pair_match(group.(["SI japanese female", "SI japanese male"]), upload, "humerus", humerus), 0.1, settings)
    @test isempty(small.results.result)
    @test count(startswith("Reference sample too small: "), small.rejected.reason) == 448
    @test all(endswith("(minimum 10)"), filter(startswith("Reference"), small.rejected.reason))
    output = OSS.job_output("pairmatch", small, 0.1, 0.0)
    @test output.summary.comparisons == 0 && output.summary.potential_matches == 0 && output.summary.rejected == 460

    # one individual: no p-value was ever possible, and it no longer reads as "Cannot Exclude"
    one = OSJ.ttest(OSJ.prepare_pair_match([group("SI japanese female")], upload, "humerus", humerus), 0.1, settings)
    @test isempty(one.results.result) && any(==("Reference sample too small: 1 (minimum 10)"), one.rejected.reason)

    # a small group added to a large one: only the combinations with too few individuals are rejected
    mixed = OSJ.ttest(OSJ.prepare_pair_match(group.(["DPAA white male", "SI japanese female"]), upload, "humerus", humerus), 0.1, settings)
    @test all(>=(10), mixed.results.n) && !any(isnan, mixed.results.p)

    # regression no longer stops on a pairing with no reference individuals: those pairs are rejected
    tiny = OSJ.regression_test(OSJ.prepare_regression([group("SI japanese female")], upload, "humerus", "femur", "Left", "Left",
        ["hum_01", "hum_02"], ["fem_01", "fem_02"]), 0.1)
    @test isempty(tiny.results.result) && all(startswith("Reference sample too small"), tiny.rejected.reason)
    @test_throws ArgumentError OSJ.regression_test(OSJ.prepare_regression([group("SI japanese female")], upload, "humerus", "femur",
        "Left", "Left", ["hum_01", "hum_02"], ["fem_01", "fem_02"]), 0.1; minimum_reference = 0)

    # a single comparison that cannot be made says why
    server, _ = OSS.serve(config; host = "127.0.0.1", port = 8768)
    try
        response = HTTP.post("http://127.0.0.1:8768/api/single", ["Content-Type" => "application/json"], JSON.json((
            analysis = "pairmatch", references = ["SI japanese female"], alpha = 0.1, element = "humerus",
            settings = (absolute = false, yeojohnson = false, zeromean = false, tails = 2),
            left = (hum_01 = 300,), right = (hum_01 = 301,))); status_exception = false)
        @test response.status == 422
        @test JSON.parse(response.body).error == "No comparison could be made. Reference sample too small: 1 (minimum 10)"
    finally
        close(server)
    end
end
