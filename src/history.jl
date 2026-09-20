module TestHistory

using Scratch
using Serialization
using FileWatching: Pidfile

import ..ParallelTestRunner as PTR

export TestHistoryEntry, PendingHistory
export load_test_history, record_test_history!, flush_test_history!, get_history_file, save_test_history, update_test_history!

# Struct used in runtests to sort failed tests before successful ones
struct TestHistoryEntry
    duration::Float64
    failed::Bool
end
# successful tests < failed tests, so when reversing the
# sort they are also in proper descending order
Base.isless(a::TestHistoryEntry, b::TestHistoryEntry) = a.failed == b.failed ? a.duration < b.duration : a.failed < b.failed

# Historical test duration database
function get_history_file(mod::Module, history_key::Union{Nothing, AbstractString} = nothing)
    # History file version. Change when modifying the history format
    hist_ver = "v2"
    scratch_dir = @get_scratch!("durations")
    name = string(nameof(mod))
    if history_key !== nothing
        isempty(history_key) && throw(ArgumentError("history_key must not be empty"))
        name *= "-" * replace(history_key, r"[^\w.-]" => "_")
    end
    return joinpath(scratch_dir, "v$(VERSION.major).$(VERSION.minor)", hist_ver, "$name.jls")
end
function load_test_history(mod::Module, history_key = nothing)
    history_file = get_history_file(mod, history_key)
    if isfile(history_file)
        try
            return deserialize(history_file)::Tuple{Dict{String, Float64}, Set{String}}
        catch e
            @warn "Failed to load test history from $history_file" exception=e
        end
    end
    return (Dict{String, Float64}(), Set{String}())
end

# Runs on the same machine share the history file, so all writes happen under a lock and go
# through a temporary file, which keeps readers from ever seeing a partially written history.
const history_lock_stale_age = 60

function with_history_lock(f, history_file)
    mkpath(dirname(history_file))
    lock_file = history_file * ".lock"
    # Without waiting, Pidfile removes a lock left behind by a dead process right away; when
    # waiting, it only checks for staleness after `stale_age` has passed.
    lock = try
        Pidfile.mkpidlock(lock_file; stale_age=history_lock_stale_age, wait=false)
    catch err
        err isa Pidfile.PidlockedError || rethrow()
        Pidfile.mkpidlock(lock_file; stale_age=history_lock_stale_age)
    end
    try
        return f()
    finally
        close(lock)
    end
end

function write_test_history(history_file, history::Tuple{Dict{String, Float64}, Set{String}})
    temporary_file = history_file * ".tmp.$(getpid())"
    serialize(temporary_file, history)
    mv(temporary_file, history_file; force=true)
    return nothing
end

"""
    update_test_history!(mod, durations, passed, failed)

Merge the outcome of the tests this run completed into the on-disk history of `mod`: `durations`
maps test names to seconds, `passed` and `failed` are the names to remove from and add to the
set of failing tests. Entries of tests not mentioned are left as they are, so concurrent runs
on the same machine only ever update their own tests.
"""
function update_test_history!(mod::Module, durations::Dict{String, Float64},
                            passed::Set{String}, failed::Set{String}; history_key = nothing)
    history_file = get_history_file(mod, history_key)
    try
        with_history_lock(history_file) do
            stored_durations, stored_failures = load_test_history(mod, history_key)
            merge!(stored_durations, durations)
            setdiff!(stored_failures, passed)
            union!(stored_failures, failed)
            write_test_history(history_file, (stored_durations, stored_failures))
        end
    catch e
        @warn "Failed to update test history in $history_file" exception=e
    end
    return nothing
end

# Outcomes of finished tests waiting to be merged into the history file. Writing them in
# batches keeps the number of lock, write and rename operations low on slow filesystems, while
# an interrupted run still keeps all but the last few measurements.
struct PendingHistory
    durations::Dict{String, Float64}
    passed::Set{String}
    failed::Set{String}
end
PendingHistory() = PendingHistory(Dict{String, Float64}(), Set{String}(), Set{String}())

function record_test_history!(pending::PTR.Lockable{PendingHistory}, mod::Module, test::String, result, duration::Real;
                            history_flush_every::Integer, history_key = nothing)
    failed = !(result isa PTR.AbstractTestRecord) || PTR.anynonpass(result[])
    batch = @lock pending begin
        pending[].durations[test] = Float64(duration)
        # a retried test is recorded once per attempt, and the last one is what counts
        delete!(failed ? pending[].passed : pending[].failed, test)
        push!(failed ? pending[].failed : pending[].passed, test)
        length(pending[].durations) >= history_flush_every ? take_pending_history!(pending[]) : nothing
    end
    batch === nothing || update_test_history!(mod, batch...; history_key)
    return nothing
end

function take_pending_history!(pending::PendingHistory)
    batch = (copy(pending.durations), copy(pending.passed), copy(pending.failed))
    empty!(pending.durations); empty!(pending.passed); empty!(pending.failed)
    return batch
end

function flush_test_history!(pending::PTR.Lockable{PendingHistory}, mod::Module; history_key = nothing)
    batch = @lock pending take_pending_history!(pending[])
    isempty(batch[1]) || update_test_history!(mod, batch...; history_key)
    return nothing
end

# Replace the whole history, e.g. to seed it in tests.
function save_test_history(mod::Module, history::Tuple{Dict{String, Float64}, Set{String}};
                        history_key = nothing)
    history_file = get_history_file(mod, history_key)
    try
        with_history_lock(history_file) do
            write_test_history(history_file, history)
        end
    catch e
        @warn "Failed to save test history to $history_file" exception=e
    end
    return nothing
end

end
