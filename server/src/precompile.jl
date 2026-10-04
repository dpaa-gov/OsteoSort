# Runs every kind of analysis once while the package is precompiled, on a
# small made-up reference group, so the first real request does not wait for
# Julia to compile. Nothing here touches the database.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    # Paired left and right rows with a few gaps; values vary so the fits are well defined
    function sample_table(codes, n)
        values = Matrix{Union{Missing, Float64}}(undef, 2n, length(codes))
        for i in 1:n, j in eachindex(codes)
            size = 40.0 + 7j + 0.9 * (i % 13) + 0.3 * (i % 5)
            values[i, j] = (i + j) % 7 == 0 ? missing : size
            values[n + i, j] = (i + 2j) % 11 == 0 ? missing : size + 0.4 * ((i * j) % 5) - 1
        end
        return BoneTable(repeat(["R$i" for i in 1:n], 2), vcat(fill("left", n), fill("right", n)), codes, values)
    end
    humerus, femur, ulna = ["hum_01", "hum_02", "hum_06"], ["fem_01", "fem_02"], ["uln_10", "uln_11"]
    group = ReferenceGroup("Sample group", "Sample", "group", "x",
        Dict("humerus" => sample_table(humerus, 40), "femur" => sample_table(femur, 40), "ulna" => sample_table(ulna, 40)))
    measurements = Measurement[(code = code, bone = bone, name = nothing)
                               for (bone, codes) in (("femur", femur), ("humerus", humerus), ("ulna", ulna)) for code in codes]
    snapshot = ReferenceSnapshot([group], measurements, ["femur", "humerus", "ulna"], String[], now(UTC))
    # 24 case bones: humeri, femora and ulnae, left and right
    csv = "accession,side,element,Hum_01,Hum_02,Hum_06,Fem_01,Fem_02,Uln_11\n" * join((
        "C$i,$(isodd(i) ? "left" : "right"),$(("Humerus", "Femur", "Ulna")[(i - 1) ÷ 2 % 3 + 1]),$(45 + i),$(52 + i),$(60 + i),$(47 + i),$(54 + 2i),$(66 + i)"
        for i in 1:24), "\n")
    config = Config("", 5432, "", "", "", 3838, 30, joinpath(REPO_ROOT, "web"),
        joinpath(pkgdir(@__MODULE__), "config"), "precompile")
    json(body) = Vector{UInt8}(JSON3.write(body))
    settings = (absolute = true, yeojohnson = true, zeromean = false, tails = 1)
    common = (references = ["Sample group"], alpha = 0.1)

    @compile_workload begin
        state = AppState(config)
        @atomic state.snapshot = snapshot
        @atomic state.meta_json = JSON3.write(build_meta(snapshot, config))
        @atomic state.last_attempt = now(UTC) # so nothing tries to reach ARDS
        respond = handler(state)
        post(path, body) = respond(HTTP.Request("POST", path, ["Content-Type" => "application/json"], json(body)))
        get(path) = respond(HTTP.Request("GET", path))

        get("/healthz")
        get("/api/meta")
        get("/api/template.csv")
        page = get("/")
        respond(HTTP.Request("GET", "/", ["If-None-Match" => HTTP.header(page, "ETag")]))
        for flags in (settings, (absolute = false, yeojohnson = false, zeromean = true, tails = 2))
            post("/api/single", merge(common, (analysis = "pairmatch", settings = flags, element = "humerus",
                left = (hum_01 = 50.0, hum_02 = 57.5), right = (hum_01 = 51.0, hum_02 = 56.0))))
        end
        post("/api/single", merge(common, (analysis = "regression", element_a = "humerus", element_b = "femur",
            side_a = "Left", side_b = "Left", values_a = (hum_01 = 50.0,), values_b = (fem_01 = 49.0,))))
        post("/api/single", merge(common, (analysis = "articulation", settings = settings, element_a = "humerus", element_b = "ulna",
            side = "Left", values_a = (hum_06 = 62.0,), values_b = (uln_11 = 68.0,))))
        post("/api/single", merge(common, (analysis = "nope",)))

        batches = (
            (analysis = "pairmatch", settings = settings, element = "humerus", measurements = humerus),
            (analysis = "regression", element_a = "humerus", element_b = "femur", side_a = "Left", side_b = "Left",
             measurements_a = humerus, measurements_b = femur),
            (analysis = "articulation", settings = settings, element_a = "humerus", element_b = "ulna", side = "Left",
             measurements_a = ["hum_06"], measurements_b = ["uln_11"]),
        )
        for batch in batches
            job = JSON3.read(post("/api/multiple", merge(common, batch, (csv = csv,))).body).job
            while JSON3.read(get("/api/jobs/$job").body).status == "running"
                sleep(0.01)
            end
            get("/api/jobs/$job/rows?table=not_excluded&limit=10&search=C&sort=1&dir=desc")
            get("/api/jobs/$job/rows?table=rejected")
            get("/api/jobs/$job/download?table=excluded")
            respond(HTTP.Request("POST", "/api/jobs/$job/release"))
        end
    end
end
