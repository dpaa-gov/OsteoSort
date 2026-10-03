# OSJ's tests. They need no database: the data is made up here.

using Test
using OSJ

# ---------- made-up measurements ----------
# Left and right bones of `n` individuals: sizes that vary from one individual
# to the next, small left-right differences, and gaps in a fixed pattern.
function bones(n, columns; seed = 1, gaps = true)
    left = Matrix{Union{Missing, Float64}}(undef, n, columns)
    right = similar(left)
    for i in 1:n, j in 1:columns
        size = 30.0 + 12j + 0.7 * ((i * 17 + seed * 5) % 23) + 0.25 * ((i * j + seed) % 7)
        left[i, j] = gaps && (i + 3j + seed) % 9 == 0 ? missing : size
        right[i, j] = gaps && (2i + j + seed) % 11 == 0 ? missing : size + 0.45 * (((i + seed) * (j + 2)) % 5) - 0.9
    end
    return left, right
end

close(x, y; rtol = 1e-9) = isequal(x, y) || isapprox(x, y; rtol, atol = 1e-12)

# ---------- numbers that must not move ----------
# Recorded on 2026-10-03, when this code gave results identical to the R/Shiny
# OsteoSort 1.5 across 432,547 comparisons against ARDS, and to the functions
# it replaced. A change here is a change in what the method computes.
# Per setting: sum of p, then the first compared pair's p, reference mean,
# reference sd and reference n, then the sum of the tested values.
const PINNED_DIFFERENCES = Dict(
    (1, false, false, false) => (3.2540679025220336, 1.0362938873066137e-11, 0.8538461538461638, 1.106106531903243, 39, 517.0000000000013),
    (1, false, false, true) => (2.4208154313489496, 9.794832432293273e-11, 0.0, 1.106106531903243, 39, 517.0000000000013),
    (1, false, true, false) => (2.4038541190678253, 9.986368132944287e-31, 0.5526553087512927, 0.7891553541657874, 39, -6.232204019646121e6),
    (1, false, true, true) => (3.6337607245070713, 2.1126561503215512e-30, 0.0, 0.7891553541657874, 39, -6.232204019646121e6),
    (1, true, false, false) => (4.428032296809011, 0.0, 1.9615384615384637, 0.46727957630218625, 39, 1991.9000000000003),
    (1, true, false, true) => (0.43738009112549114, 0.0, 0.0, 0.46727957630218625, 39, 1991.9000000000003),
    (1, true, true, false) => (4.455911063725843, 2.7288817872062054e-9, 1.0015682050760073, 0.1373374632118089, 39, 305.1276846090025),
    (1, true, true, true) => (0.5497379585608927, 0.0, 0.0, 0.1373374632118089, 39, 305.1276846090025),
    (2, false, false, false) => (6.508135805044067, 2.0725877746132274e-11, 0.8538461538461638, 1.106106531903243, 39, 517.0000000000013),
    (2, false, false, true) => (4.841630862697899, 1.9589664864586546e-10, 0.0, 1.106106531903243, 39, 517.0000000000013),
    (2, false, true, false) => (4.807708238135651, 1.9972736265888573e-30, 0.5526553087512927, 0.7891553541657874, 39, -6.232204019646121e6),
    (2, false, true, true) => (7.267521449014143, 4.2253123006431024e-30, 0.0, 0.7891553541657874, 39, -6.232204019646121e6),
    (2, true, false, false) => (8.856064593618022, 0.0, 1.9615384615384637, 0.46727957630218625, 39, 1991.9000000000003),
    (2, true, false, true) => (0.8747601822509823, 0.0, 0.0, 0.46727957630218625, 39, 1991.9000000000003),
    (2, true, true, false) => (8.911822127451686, 5.457763574412411e-9, 1.0015682050760073, 0.1373374632118089, 39, 305.1276846090025),
    (2, true, true, true) => (1.0994759171217854, 0.0, 0.0, 0.1373374632118089, 39, 305.1276846090025),
)
# For one pair, per (absolute, yeojohnson): sum of the reference distribution,
# the pair's value in it, the reference n, and the fitted Yeo-Johnson parameter.
const PINNED_DISTRIBUTION = Dict(
    (false, false) => (33.30000000000039, -9.499999999999986, 39, nothing),
    (false, true) => (21.55355704130041, -26.903195660676424, 39, 0.38679644632776267),
    (true, false) => (76.50000000000009, 9.499999999999986, 39, nothing),
    (true, true) => (39.06115999796428, 2.0297203562449964, 39, -0.1283455862671165),
)

@testset "the numbers have not moved" begin
    refa, refb = bones(70, 5; seed = 1)
    a, _ = bones(9, 5; seed = 2)
    _, b = bones(11, 5; seed = 3)
    a[4, :] .= missing; a[4, 2] = 61.5                      # a bone with a single measurement
    b[7, :] .= missing; b[7, 5] = 93.0                      # shares nothing with that one

    @testset "differences, tails=$tails absolute=$absolute yeojohnson=$yeojohnson zeromean=$zeromean" for
            tails in (1, 2), absolute in (false, true), yeojohnson in (false, true), zeromean in (false, true)
        found = compare_pairs(a, b, refa, refb; tails, absolute, yeojohnson, zeromean)
        @test (found.a, found.b) == (repeat(1:9; inner = 11), repeat(1:11; outer = 9))   # every a against every b, in order
        compared = findall(!isempty, found.used)
        @test length(compared) == 96 && length(found.reference) == 14   # three pairs share nothing; 14 measurement sets
        total_p, p, mean, sd, n, total_value = PINNED_DIFFERENCES[(tails, absolute, yeojohnson, zeromean)]
        first = compared[1]
        # the Yeo-Johnson parameter comes from an optimiser, so those runs get a looser tolerance
        rtol = yeojohnson ? 1e-6 : 1e-9
        @test close(sum(found.p[compared]), total_p; rtol) && close(found.p[first], p; rtol = yeojohnson ? 1e-3 : 1e-9)
        @test close(found.mean[first], mean; rtol) && close(found.sd[first], sd; rtol) && found.n[first] == n
        @test close(sum(found.value[compared]), total_value; rtol)
        @test sum(found.n) == 3293
    end

    @testset "distribution behind a single comparison" begin
        for absolute in (false, true), yeojohnson in (false, true)
            found = compare_pairs(a[1:1, :], b[1:1, :], refa, refb; tails = 2, absolute, yeojohnson)
            reference = found.reference[only(found.used)]
            total, value, n, parameter = PINNED_DISTRIBUTION[(absolute, yeojohnson)]
            rtol = yeojohnson ? 1e-6 : 1e-9
            @test close(sum(reference.values), total; rtol) && close(only(found.value), value; rtol)
            @test length(reference.values) == n == only(found.n)
            @test parameter === nothing ? reference.lambda === nothing : close(reference.lambda, parameter; rtol = 1e-5)
        end
    end

    @testset "regression" begin
        refx, _ = bones(70, 4; seed = 4)
        _, refy = bones(70, 3; seed = 5)
        x, _ = bones(8, 4; seed = 6)
        _, y = bones(10, 3; seed = 7)
        found = compare_regression(x, y, refx, refy)
        @test (found.a, found.b) == (repeat(1:8; inner = 10), repeat(1:10; outer = 8))
        @test close(sum(found.p), 36.470029992552675) && close(sum(found.r2), 0.13594253196121364)
        @test close(found.p[1], 0.5109916513301282) && close(found.r2[1], 0.0002467774244752739)
        @test found.n[1] == 39 && sum(found.n) == 3001 && length(found.reference) == 12
        @test close(found.x[1], 5.498396978263695) && close(found.y[1], 4.765586907393996)
        line = found.reference[(found.useda[1], found.usedb[1])]
        @test close(line.intercept, 4.925822136766937) && close(line.slope, -0.018751644107075825) && close(line.sigma, 0.08187571767949714)
        # each bone uses whatever it has; the reference individuals must have all of it
        @test all(found.useda[r] == findall(!ismissing, x[found.a[r], :]) && found.usedb[r] == findall(!ismissing, y[found.b[r], :])
                  for r in eachindex(found.a))

        # too few reference individuals to fit a line
        @test_throws ArgumentError compare_regression(x, y, refx[1:1, :], refy[1:1, :])
    end
end

@testset "edge cases in the core" begin
    refa, refb = bones(40, 3; seed = 8)
    a, _ = bones(4, 3; seed = 9, gaps = false)
    _, b = bones(4, 3; seed = 10, gaps = false)

    # one measurement only: the matrices have a single column
    found = compare_pairs(a[:, 1:1], b[:, 1:1], refa[:, 1:1], refb[:, 1:1]; tails = 2)
    @test all(==([1]), found.used) && all(==(count(i -> !ismissing(refa[i, 1]) && !ismissing(refb[i, 1]), 1:40)), found.n)
    @test all(0 .<= found.p .<= 1)

    # a reference sample of one: there is no standard deviation, so no p-value
    onea, oneb = bones(1, 3; seed = 13, gaps = false)
    found = compare_pairs(a, b, onea, oneb; tails = 2)
    @test all(==(1), found.n) && all(isnan, found.sd) && all(isnan, found.p)

    # no reference individual has the measurements the pair shares
    empty_ref = Matrix{Union{Missing, Float64}}(missing, 5, 3)
    found = compare_pairs(a, b, empty_ref, empty_ref; tails = 2)
    @test all(==(0), found.n) && all(isnan, found.p)

    # every reference individual has the same difference: no spread at all, so a pair
    # is either exactly typical (no p-value) or impossibly far away (p of zero)
    flat_a = Matrix{Union{Missing, Float64}}(fill(50.0, 12, 3))
    flat_b = Matrix{Union{Missing, Float64}}(fill(49.0, 12, 3))
    found = compare_pairs(a, b, flat_a, flat_b; tails = 2)
    @test all(==(0.0), found.sd) && all(p -> isnan(p) || p == 0.0, found.p)

    # a bone with no measurements shares nothing with anything
    blank = copy(a); blank[2, :] .= missing
    found = compare_pairs(blank, b, refa, refb; tails = 2)
    @test all(isempty, found.used[found.a .== 2]) && all(!isempty, found.used[found.a .!= 2])
    @test all(isnan, found.p[found.a .== 2]) && !any(isnan, found.p[found.a .!= 2])

    # zero mean tests against zero whatever the reference mean is
    found = compare_pairs(a[1:1, :], b[1:1, :], refa, refb; tails = 1, absolute = true, yeojohnson = true, zeromean = true)
    @test only(found.mean) == 0.0 && 0 <= only(found.p) <= 1

    # one tail is half of two tails
    one, two = compare_pairs(a, b, refa, refb; tails = 1), compare_pairs(a, b, refa, refb; tails = 2)
    @test all(close.(2 .* one.p, two.p))

    # the order of the reference individuals does not matter
    shuffled = reverse(1:40)
    found, again = compare_pairs(a, b, refa, refb; tails = 2), compare_pairs(a, b, refa[shuffled, :], refb[shuffled, :]; tails = 2)
    @test found.n == again.n && all(close.(found.p, again.p; rtol = 1e-8))

    # absolute differences with two tails can exceed 1, as documented:
    # true pairs differ less than the reference average, which puts them in the lower tail
    wholea, wholeb = bones(40, 3; seed = 8, gaps = false)
    found = compare_pairs(wholea[1:6, :], wholeb[1:6, :], wholea, wholeb; tails = 2, absolute = true)
    @test all(0 .<= found.p .<= 2) && any(>(1), found.p)

    # regression: exactly two reference individuals give a line but no residual spread
    refx, _ = bones(2, 2; seed = 11, gaps = false)
    _, refy = bones(2, 2; seed = 12, gaps = false)
    @test all(isnan, compare_regression(a[:, 1:2], b[:, 1:2], refx, refy).p)
    # none at all cannot be fitted, unless a minimum sample says not to try
    @test_throws ArgumentError compare_regression(a[:, 1:2], b[:, 1:2], empty_ref[:, 1:2], empty_ref[:, 1:2])
    skipped = compare_regression(a[:, 1:2], b[:, 1:2], empty_ref[:, 1:2], empty_ref[:, 1:2]; minimum = 10)
    @test all(==(0), skipped.n) && all(isnan, skipped.p)
end

# ---------- the method on typed data ----------
function group(label, n; seed)
    humerus = bones(n, 3; seed)
    femur = bones(n, 2; seed = seed + 10, gaps = false)
    people = ["$label-$i" for i in 1:n]
    table(codes, (left, right)) = BoneTable(vcat(people, people), vcat(fill("left", n), fill("right", n)), codes, vcat(left, right))
    return ReferenceGroup(label, label, "x", "y",
        Dict("humerus" => table(["hum_01", "hum_02", "hum_03"], humerus), "femur" => table(["fem_01", "fem_02"], femur)))
end

function cases()
    values = Matrix{Union{Missing, Float64}}(missing, 8, 5)
    values[1, 1:3] = [52.0, 64.0, 75.5]        # L1: left humerus, all three
    values[2, 1] = 51.0                        # L2: hum_01 only
    values[3, 4:5] = [50.0, 62.0]              # L3: a left humerus with only femur columns filled
    values[4, 1:3] = [52.4, 63.1, 76.0]        # R1: right humerus
    values[5, 2] = 63.0                        # R2: hum_02 only, shares nothing with L2
    values[6, 4:5] = [49.0, 61.5]              # F1: left femur
    values[7, 4:5] = [49.6, 61.0]              # F2: right femur
    values[8, 1] = 50.0                        # no side given
    return SortTable(["L1", "L2", "L3", "R1", "R2", "F1", "F2", "X"],
        ["Left", "left", "LEFT", "Right", "right", "Left", "Right", missing],
        ["Humerus", "humerus", "Humerus", "Humerus", "Humerus", "Femur", "Femur", "Humerus"],
        ["hum_01", "hum_02", "hum_03", "fem_01", "fem_02"], values)
end

@testset "preparing and labelling" begin
    groups = [group("A", 40; seed = 1), group("B", 25; seed = 2)]
    upload = cases()
    settings = Settings(false, false, false, 2)
    humerus = ["hum_01", "hum_02", "hum_03"]

    result = ttest(prepare_pair_match(groups, upload, "Humerus", humerus), 0.1, settings)
    @test (result.results.id_1, result.results.id_2) == (["L1", "L1", "L2"], ["R1", "R2", "R1"])
    @test result.results.measurements == ["hum_01 hum_02 hum_03 ", "hum_02 ", "hum_01 "]
    @test all(in(("Excluded", "Cannot Exclude")), result.results.result)
    @test result.rejected.reason == [OSJ.UNMEASURED, OSJ.NOTHING_IN_COMMON]
    @test (result.rejected.id_1, result.rejected.id_2) == (["L3", "L2"], ["", "R2"])
    @test result.plot === nothing                           # only single comparisons carry plot data

    # sample sizes add up across groups, and the breakdown says so
    alone = [ttest(prepare_pair_match([g], upload, "humerus", humerus), 0.1, settings).results.n for g in groups]
    @test result.results.n == alone[1] .+ alone[2]
    @test result.results.reference == ["A $(alone[1][i]), B $(alone[2][i])" for i in 1:3]

    # fewer than ten reference individuals: the pair is rejected, not tested
    few = [group("F", 6; seed = 3)]
    limited = ttest(prepare_pair_match(few, upload, "humerus", humerus), 0.1, settings)
    @test isempty(limited.results.result)
    @test limited.rejected.reason[1] == OSJ.UNMEASURED && limited.rejected.reason[2] == OSJ.NOTHING_IN_COMMON
    @test all(startswith("Reference sample too small: "), limited.rejected.reason[3:end]) && length(limited.rejected.reason) == 5
    @test length(ttest(prepare_pair_match(few, upload, "humerus", humerus), 0.1, settings; minimum_reference = 0).results.result) == 3
    @test isempty(regression_test(prepare_regression(few, upload, "humerus", "femur", "Left", "left", humerus, ["fem_01", "fem_02"]), 0.1).results.result)

    # a group without the bone adds nothing
    empty_group = ReferenceGroup("C", "C", "x", "y", Dict{String, BoneTable}())
    @test ttest(prepare_pair_match(vcat(groups, empty_group), upload, "humerus", humerus), 0.1, settings).results.n == result.results.n

    # nothing to analyse
    @test prepare_pair_match(groups, upload, "tibia", ["tib_01"]) === nothing
    @test prepare_pair_match(groups, upload, "humerus", ["nope"]) === nothing
    @test prepare_pair_match([empty_group], upload, "humerus", humerus) === nothing

    regression = regression_test(prepare_regression(groups, upload, "humerus", "femur", "Left", "left", humerus, ["fem_01", "fem_02"]), 0.1)
    @test (regression.results.x_id, regression.results.y_id) == (["L1", "L2"], ["F1", "F1"])
    @test regression.results.measurements == ["hum_01 hum_02 hum_03 fem_01 fem_02 ", "hum_01 fem_01 fem_02 "]
    @test regression.rejected.x_id == ["L3"]

    # articulation with two configured measurement pairs: only the pairs both bones have are listed
    two = SortTable(["A1", "A2", "B1"], ["Left", "Left", "Left"], ["Humerus", "Humerus", "Femur"],
        ["hum_01", "hum_02", "fem_01", "fem_02"],
        Union{Missing, Float64}[52.0 64.0 missing missing; 51.0 missing missing missing; missing missing 50.0 62.0])
    joint = ttest(prepare_articulation(groups, two, "humerus", "femur", "Left", ["hum_01", "hum_02"], ["fem_01", "fem_02"]),
        0.1, settings; articulation = true)
    @test joint.results.id_1 == ["A1", "A2"]
    @test joint.results.measurements == ["hum_01 hum_02 fem_01 fem_02", "hum_01 fem_01"]

    single = ttest(prepare_single_pair_match(groups, "humerus", Dict("hum_01" => 52.0, "hum_02" => 64.0), Dict("hum_01" => 52.5)), 0.1, settings)
    @test single.results.measurements == ["hum_01 "] && length(single.plot.reference) == only(single.results.n)
    @test prepare_single_pair_match(groups, "humerus", Dict("hum_01" => 52.0), Dict("hum_02" => 60.0)) === nothing

    one = regression_test(prepare_single_regression(groups, "humerus", "femur", "Left", "Left",
        Dict("hum_01" => 52.0, "hum_02" => 64.0), Dict("fem_01" => 50.0, "fem_02" => 62.0)), 0.05)
    @test length(one.plot.band.x) == only(one.results.n) && issorted(one.plot.band.x)
    @test all(one.plot.band.lower .< one.plot.band.fit .< one.plot.band.upper)
    # a reference sample with no variation gives no p-value when the pair matches its mean exactly:
    # that pair is rejected with the reason, not called a potential match
    people = ["P$i" for i in 1:12]
    same_both_sides = Matrix{Union{Missing, Float64}}(reshape(vcat(50.0 .+ (1:12), 50.0 .+ (1:12)), :, 1))
    flat = ReferenceGroup("flat", "flat", "x", "y", Dict("humerus" =>
        BoneTable(vcat(people, people), vcat(fill("left", 12), fill("right", 12)), ["hum_01"], same_both_sides)))
    three = SortTable(["A", "B", "C"], ["Left", "Right", "Right"], fill("Humerus", 3), ["hum_01"],
        Matrix{Union{Missing, Float64}}(reshape([52.0, 52.0, 53.0], :, 1)))
    degenerate = ttest(prepare_pair_match([flat], three, "humerus", ["hum_01"]), 0.1, settings)
    @test (degenerate.rejected.id_1, degenerate.rejected.id_2, degenerate.rejected.reason) == (["A"], ["B"], [OSJ.NOT_CALCULATED])
    @test (degenerate.results.id_2, degenerate.results.p, degenerate.results.result) == (["C"], [0.0], ["Excluded"])

    # the band is drawn from the line the p-value was calculated with
    band = one.plot.band
    @test close([band.x[1], band.fit[1], band.lower[1], band.upper[end], sum(band.lower), sum(band.upper)],
        [4.579852378003801, 4.706575067959244, 4.530206950707549, 4.905908116653233, 227.34901137234652, 244.63683616914955])
end
