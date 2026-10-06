# Batch analyses run in the background and the browser polls for the outcome:
# the Atlas gateway drops any request whose response takes over 30 seconds.

struct RequestError <: Exception
    status::Int
    message::String
end

const NO_RESULT = "No comparison could be made with this input and reference data"
const ANALYSIS_FAILED = "The analysis failed for this input and reference data"

struct JobOutput
    analysis::String
    tables::Dict{String, NamedTuple}
    summary::NamedTuple
    histogram::NamedTuple
end

mutable struct Job
    const id::String
    @atomic status::String # running, done or error
    @atomic stage::String
    @atomic error::String
    @atomic finished::DateTime
    @atomic used::DateTime # when its results were last asked for
    @atomic output::Union{Nothing, JobOutput}
end

struct JobStore
    lock::ReentrantLock
    jobs::Dict{String, Job}
    max_rows::Int
    turn::Base.Semaphore # one batch computes at a time
    queued::Threads.Atomic{Int} # batches computing or waiting for their turn
end

const JOB_TTL = Hour(1)
const SWEEP_SECONDS = 300
const MAX_FINISHED_JOBS = 50
# Most result rows held across all finished jobs, and most comparisons in
# one run: about 380 MB at 190 bytes a row
const MAX_RESULT_ROWS = 2_000_000

# Each waiting batch holds its uploaded file, so only so many may wait
const MAX_QUEUED_JOBS = 20
const BUSY = "The server is busy with other analyses. Try again in a minute."

JobStore(; max_rows = MAX_RESULT_ROWS) =
    JobStore(ReentrantLock(), Dict{String, Job}(), max_rows, Base.Semaphore(1), Threads.Atomic{Int}(0))

function result_rows(job::Job)
    output = @atomic job.output
    return output === nothing ? 0 : sum(row_count, values(output.tables); init = 0)
end

# Julia only clears memory out when it needs room for something new, so on an
# idle server the results just dropped would stay counted against the pod.
# This gives them back a moment later; requests arriving together share one.
const TIDYING = Threads.Atomic{Bool}(false)
function tidy()
    ccall(:jl_generating_output, Cint, ()) == 1 && return   # not while the package is being compiled
    Threads.atomic_cas!(TIDYING, false, true) && return      # one is already on its way
    Threads.@spawn try
        sleep(1)
        GC.gc()
        # Julia has now let go of the memory, but the C library keeps what it
        # was handed for reuse; this passes it back to the system
        Sys.islinux() && ccall(:malloc_trim, Cint, (Cint,), 0)
    finally
        TIDYING[] = false
    end
    return
end

# Results asked for within this long are in use: they are never dropped to
# make room for another run.
const IN_USE = Minute(15)
in_use(job::Job, at) = (@atomic job.used) > at - IN_USE

finished_jobs(store::JobStore) = [job for job in values(store.jobs) if (@atomic job.status) != "running"]

function drop!(store::JobStore, job::Job)
    delete!(store.jobs, job.id)
    tidy()
    return
end

# Drops finished jobs not used for an hour. Should what is held be over the
# limits all the same (room is made before a run, in `make_room!`, from what
# it is expected to produce), the least recently used go, but never one in use.
function prune!(store::JobStore; at = now(UTC))
    finished = sort!(finished_jobs(store); by = job -> (@atomic job.used))
    held = sum(result_rows, finished; init = 0)
    count = length(finished)
    for job in finished
        expired = (@atomic job.used) < at - JOB_TTL
        over = (held > store.max_rows || count > MAX_FINISHED_JOBS) && !in_use(job, at)
        expired || over || continue
        held -= result_rows(job)
        count -= 1
        drop!(store, job)
    end
    return
end

# Makes room for a run about to produce `rows` result rows, before it is
# computed. Results nobody has asked for in 15 minutes are dropped, the least
# recently used first, until the run fits. Results in use are left alone: if
# they leave no room, the run is refused, and told how long until enough of
# them will have gone unused. One batch computes at a time, so the room found
# here is still there when the run finishes.
function make_room!(store::JobStore, rows::Integer; at = now(UTC))
    lock(store.lock) do
        prune!(store; at)
        finished = sort!(finished_jobs(store); by = job -> (@atomic job.used))
        held = sum(result_rows, finished; init = 0)
        count = length(finished)
        fits() = held + rows <= store.max_rows && count < MAX_FINISHED_JOBS
        for job in finished
            (fits() || in_use(job, at)) && break
            held -= result_rows(job)
            count -= 1
            drop!(store, job)
        end
        fits() && return
        # everything left is in use; the wait is until the last of those that must go has gone unused
        minutes = Dates.value(IN_USE)
        for job in finished
            haskey(store.jobs, job.id) || continue
            held -= result_rows(job)
            count -= 1
            if fits()
                minutes = max(1, ceil(Int, Dates.value((@atomic job.used) + IN_USE - at) / 60_000))
                break
            end
        end
        throw(RequestError(503, no_room(minutes)))
    end
    return
end

no_room(minutes) = "The server is holding results that other analyses are still using, and has no room for this run. " *
    "Try again in about $minutes minute$(minutes == 1 ? "" : "s")."

sweep!(store::JobStore) = lock(() -> prune!(store), store.lock)

# The id is the only key to a job's results, so it must be unguessable.
function create_job!(store::JobStore)
    job = Job(bytes2hex(rand(Random.RandomDevice(), UInt8, 16)), "running", "queued", "", DateTime(0), now(UTC), nothing)
    lock(store.lock) do
        prune!(store)
        store.jobs[job.id] = job
    end
    return job
end

find_job(store::JobStore, id) = lock(() -> get(store.jobs, id, nothing), store.lock)

# Forgets a job and its results. One waiting for its turn is not computed;
# one already computing finishes unseen.
function release_job!(store::JobStore, id)
    lock(() -> pop!(store.jobs, id, nothing), store.lock) === nothing || tidy()
    return
end

# Runs `work(job)` on a worker thread; it returns the JobOutput. Batches take
# turns, which leaves the other worker thread free for single comparisons,
# table searches and reference reloads.
function start_job!(work, store::JobStore)
    if Threads.atomic_add!(store.queued, 1) >= MAX_QUEUED_JOBS
        Threads.atomic_sub!(store.queued, 1)
        throw(RequestError(503, BUSY))
    end
    job = create_job!(store)
    Threads.@spawn begin
        try
            # released while it waited for its turn: nobody will see the result
            output = Base.acquire(() -> find_job(store, job.id) === nothing ? nothing : work(job), store.turn)
            @atomic job.output = output
            @atomic job.finished = now(UTC)
            @atomic job.used = now(UTC)
            @atomic job.status = "done"
            lock(() -> prune!(store), store.lock)
            tidy() # what the run used along the way, beyond the results it leaves
        catch e
            if e isa RequestError
                @atomic job.error = e.message
            else
                @error "Batch analysis failed" job = job.id exception = (e, catch_backtrace())
                @atomic job.error = ANALYSIS_FAILED
            end
            @atomic job.finished = now(UTC)
            @atomic job.status = "error"
        finally
            Threads.atomic_sub!(store.queued, 1)
        end
    end
    return job
end

const HISTOGRAM_BIN = 0.025

# p-value counts per bin over [0, 1] for each outcome. Values above 1 (possible
# with absolute differences and two tails) fall outside the axis, as before.
function p_histogram(table, alpha)
    bins = round(Int, 1 / HISTOGRAM_BIN)
    counts = Dict("Cannot Exclude" => zeros(Int, bins), "Excluded" => zeros(Int, bins))
    outside = 0
    for (p, result) in zip(table.p, table.result)
        if isnan(p) || p < 0 || p > 1
            outside += 1
        else
            counts[result][min(bins, floor(Int, p / HISTOGRAM_BIN) + 1)] += 1
        end
    end
    return (bin_width = HISTOGRAM_BIN, cannot_exclude = counts["Cannot Exclude"], excluded = counts["Excluded"],
            outside = outside, alpha = alpha)
end

# Result tables as they are shown, searched, sorted and downloaded: bone
# names, sides and measurement codes start with a capital, as everywhere else
# in the app ("Humerus", "Left", "Hum_01 Hum_02"). OSJ's own tables keep the
# lower-case names ARDS uses.
function for_display(table::NamedTuple)
    capitals(text) = join(uppercasefirst.(split(text, " "; keepempty = false)), " ")
    # a column holds few distinct values: each is capitalised once and the rows share it
    function each(change, column)
        done = Dict{eltype(column), String}()
        return String[get!(() -> change(value), done, value) for value in column]
    end
    shown(name, column) =
        name == :measurements ? each(capitals, column) :
        occursin(r"element|side", String(name)) ? each(uppercasefirst, column) : column
    return NamedTuple{keys(table)}(Tuple(shown(name, column) for (name, column) in pairs(table)))
end

function job_output(analysis, result::AnalysisResult, alpha, seconds)
    table = result.results
    kept = table.result .== "Cannot Exclude"
    comparisons = length(kept)
    matches = count(kept)
    specimens = length(union(Set(table[1]), Set(table[4])))
    summary = (
        seconds = round(seconds; digits = 2),
        comparisons = comparisons,
        specimens = specimens,
        potential_matches = matches,
        exclusions = comparisons - matches,
        exclusion_percent = comparisons == 0 ? nothing :
                            round(100 * round((comparisons - matches) / comparisons; digits = 3); digits = 1),
        rejected = length(result.rejected[1]),
    )
    tables = Dict{String, NamedTuple}(
        "not_excluded" => for_display(OSJ.select_rows(table, kept)),
        "excluded" => for_display(OSJ.select_rows(table, .!kept)),
        "rejected" => for_display(result.rejected),
    )
    return JobOutput(analysis, tables, summary, p_histogram(table, alpha))
end
