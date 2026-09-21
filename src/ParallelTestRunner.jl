module ParallelTestRunner

export runtests, addworkers, addworker, find_tests, parse_args, filter_tests!

using Malt
using Dates
using Printf: @sprintf
using Base.Filesystem: path_separator
using Statistics
import Test
import Random
import IOCapture
using Test: DefaultTestSet
using StyledStrings: Face, @styled_str, addface!

if VERSION >= v"1.13.0-DEV.1044"
    using Base.ScopedValues
end

# anyonpass, Lockable, with_testset, available_memory
include("compatutils.jl")

# PTRWorker, worker_id, test_exe, addworkers, addworker
include("ptrworker.jl")

# find_tests, ParsedArgs, extract_flag!, parse_args, filter_tests!, partition_tests
include("args.jl")

include("history.jl")
using .TestHistory

# Always set the max rss so that if tests add large global variables
#  (which they do) we don't make the GC's life too hard. Apple's memory
#  management makes setting this value more complicated than it should
function get_max_worker_rss()
    mb = if haskey(ENV, "JULIA_TEST_MAXRSS_MB")
        parse(Int, ENV["JULIA_TEST_MAXRSS_MB"])
    elseif Sys.WORD_SIZE == 64
        totalmem = Sys.total_memory()
        if Sys.isapple()
            if totalmem <= 8*Int64(2)^30
                2000
            elseif totalmem <= 16*Int64(2)^30
                2500
            else
                3800
            end
        elseif totalmem > 8*Int64(2)^30
            3800
        else # Low memory not on macOS
            3000
        end
    else
        # Assume that we only have 3.5GB available to a single process, and that a single
        # test can take up to 2GB of RSS.  This means that we should instruct the test
        # framework to restart any worker that comes into a test set with 1.5GB of RSS.
        1536
    end
    return mb * 2^20
end

"""
    AbstractTestRecord

Abstract supertype for per-test result records. [`TestRecord`](@ref) is the
default concrete subtype, carrying the captured test set and baseline timing /
memory statistics. Custom subtypes can attach extra per-test data (e.g. GPU
statistics) by carrying a `base::TestRecord` field and dispatching
[`execute`](@ref) on the new type. See the `RecordType` argument of
[`runtests`](@ref) for how to plug a custom record type into a run.
"""
abstract type AbstractTestRecord end

"""
    TestRecord <: AbstractTestRecord

Default per-test record. Holds the captured `DefaultTestSet` alongside the
baseline timing and memory statistics that [`runtests`](@ref) prints and
persists. Custom [`AbstractTestRecord`](@ref) subtypes wrap a `TestRecord` in a
`base` field; [`parent`](@ref) returns that baseline so the default `print_*`
methods work unchanged.
"""
struct TestRecord <: AbstractTestRecord
    value::DefaultTestSet

    # stats
    time::Float64
    bytes::UInt64
    gctime::Float64
    compile_time::Float64
    rss::UInt64
    total_time::Float64
end

"""
    parent(rec::AbstractTestRecord) -> TestRecord

Return the [`TestRecord`](@ref) baseline that a custom record type wraps. By
default, subtypes of `AbstractTestRecord` are expected to carry a
`base::TestRecord` field; override `parent` for a different layout. The default
`print_*` methods read baseline fields through `parent`, so wrapped types
inherit the standard output unchanged.
"""
Base.parent(rec::AbstractTestRecord) = rec.base
Base.parent(rec::TestRecord) = rec

function memory_usage(rec::AbstractTestRecord)
    return parent(rec).rss
end

function init_time(rec::AbstractTestRecord)
    base = parent(rec)
    return base.total_time - base.time
end

function Base.getindex(rec::AbstractTestRecord)
    return parent(rec).value
end


#
# overridable I/O context for pretty-printing
#

struct TestIOContext
    stdout::IO
    stderr::IO
    color::Bool
    verbose::Bool
    lock::ReentrantLock
    name_align::Int
    elapsed_align::Int
    compile_align::Int
    gc_align::Int
    percent_align::Int
    alloc_align::Int
    rss_align::Int
    max_worker_rss::Int
    recycled::Ref{Bool}
    nonpass_face::Ref{Symbol}
end

function test_IOContext(::Type{<:AbstractTestRecord}, stdout::IO, stderr::IO, lock::ReentrantLock, name_align::Int, verbose::Bool, max_worker_rss::Int)
    elapsed_align = textwidth("time (s)")
    compile_align = textwidth("Compile")
    gc_align = textwidth("GC (s)")
    percent_align = textwidth("GC %")
    alloc_align = textwidth("Alloc (MB)")
    rss_align = textwidth("RSS (MB)")

    color = get(stdout, :color, false)

    return TestIOContext(
        stdout, stderr, color, verbose, lock, name_align, elapsed_align, compile_align, gc_align, percent_align,
        alloc_align, rss_align, max_worker_rss, Ref(false), Ref(:ptr_error)
    )
end


function print_header(::Type{<:AbstractTestRecord}, ctx::TestIOContext, testgroupheader, workerheader)
    lock(ctx.lock)
    try
        # header top
        name_pad_str = " "^(ctx.name_align + textwidth(testgroupheader) - 3) * " │ "
        init_str = ctx.verbose ? "   Init   │" : ""
        compile_str = VERSION >= v"1.11" && ctx.verbose ? " Compile │" : ""
        header_top_str = "$name_pad_str  Test   │$init_str$compile_str ──────────────── CPU ──────────────── │\n"
        print(ctx.stdout, header_top_str)

        # header bottom
        workerheaderstr = lpad(workerheader, ctx.name_align - textwidth(testgroupheader) + 1)
        init_time_str = ctx.verbose ? " time (s) │" : ""
        comp_time_str = VERSION >= v"1.11" && ctx.verbose ? "   (%)   │" : ""
        bottom_header_str = "$testgroupheader$workerheaderstr │ time (s) │$init_time_str$comp_time_str GC (s) │ GC % │ Alloc (MB) │ RSS (MB) │\n"
        print(ctx.stdout, bottom_header_str)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_started(::Type{<:AbstractTestRecord}, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")
        # StyledStrings 1.0.3 (used on Julia 1.10) cannot print a styled string whose leading
        # unstyled text ends in a multi-byte character (e.g. `│`), so style it explicitly
        out_str = styled"{default:$(test)$padded_wrkr │}{ptr_light:$(\" \"^ctx.elapsed_align) started at $(now())}\n"
        print(ctx.stdout, out_str)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_finished(record::AbstractTestRecord, wrkr, test, ctx::TestIOContext)
    base = parent(record)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")
        wrkr_face = ctx.recycled[] ? :ptr_warn : :default

        time_str = @sprintf("%7.2f", base.time)
        padded_time = lpad(time_str, ctx.elapsed_align, " ")

        padded_init_time, padded_comp_time = if ctx.verbose
            # pre-testset time
            init_time_str = @sprintf("%7.2f", base.total_time - base.time)
            init_time = lpad(init_time_str, ctx.elapsed_align, " ") * " │ "

            # compilation time
            comp_time = if VERSION >= v"1.11"
                comp_time_str = @sprintf("%7.2f", Float64(100*base.compile_time/base.time))
                lpad(comp_time_str, ctx.compile_align, " ") * " │ "
            else
                ""
            end
            init_time, comp_time
        else
            "", ""
        end

        gc_str = @sprintf("%5.2f", base.gctime)
        padded_gc = lpad(gc_str, ctx.gc_align, " ")

        percent_str = @sprintf("%4.1f", 100 * base.gctime / base.time)
        padded_percent = lpad(percent_str, ctx.percent_align, " ")

        alloc_str = @sprintf("%5.2f", base.bytes / 2^20)
        padded_alloc = lpad(alloc_str, ctx.alloc_align, " ")

        mem_use = memory_usage(record)
        mem_face = mem_use > ctx.max_worker_rss ? :ptr_warn : :default
        rss_str = @sprintf("%5.2f", mem_use / 2^20)
        padded_rss = lpad(rss_str, ctx.rss_align, " ")

        # see `print_test_started` for why `test` is styled explicitly
        out_str = styled"{default:$test}{$wrkr_face:$padded_wrkr} │ $padded_time │ $padded_init_time$padded_comp_time$padded_gc │ $padded_percent │ $padded_alloc │ {$mem_face:$padded_rss} │\n"
        print(ctx.stdout, out_str)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_failed(record::AbstractTestRecord, wrkr, test, ctx::TestIOContext)
    base = parent(record)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")

        time_str = @sprintf("%7.2f", base.time)
        padded_time = lpad(time_str, ctx.elapsed_align + 1, " ")

        padded_init_time = if ctx.verbose
            init_time_str = @sprintf("%7.2f", base.total_time - base.time)
            lpad(init_time_str, ctx.elapsed_align + 1, " ") * " │ "
        else
            ""
        end

        failed_str = "failed at $(now())"
        # 11 -> 3 from " │ " 3x and 2 for each " " on either side
        fail_align = (11 + ctx.gc_align + ctx.percent_align + ctx.alloc_align + ctx.rss_align - textwidth(failed_str)) ÷ 2 + textwidth(failed_str)
        failed_str = lpad(failed_str, fail_align, " ")

        # TODO: print other stats?

        out_str = styled"{$(ctx.nonpass_face[]):$test$padded_wrkr │$padded_time │$padded_init_time$failed_str}\n"
        print(ctx.stderr, out_str)
        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end

function print_test_crashed(::Type{<:AbstractTestRecord}, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")
        out_str = styled"{$(ctx.nonpass_face[]):$(test)$padded_wrkr │$(\" \"^ctx.elapsed_align) crashed at $(now())}\n"
        print(ctx.stderr, out_str)
        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end

# Truncate `line` to at most `max_width` characters, appending "..." when truncated.
function truncate_line(line::AbstractString, max_width::Int)
    if length(line) > max_width
        line = first(line, max(0, max_width - 3)) * "..."
    end
    return line
end

#
# entry point
#
"""
    WorkerTestSet

A test set wrapper used internally by worker processes.
`Base.DefaultTestSet` detects when it is the top-most and throws
a `TestSetException` containing very little information. By inserting this
wrapper as the top-most test set, we can capture the full results.
"""
mutable struct WorkerTestSet <: Test.AbstractTestSet
    const name::String
    wrapped_ts::Test.DefaultTestSet
    function WorkerTestSet(name::AbstractString)
        new(name)
    end
end

function Test.record(ts::WorkerTestSet, res)
    @assert res isa Test.DefaultTestSet
    @assert !isdefined(ts, :wrapped_ts)
    ts.wrapped_ts = res
    return nothing
end

function Test.finish(ts::WorkerTestSet)
    # This testset is just a placeholder so it must be the top-most
    @assert Test.get_testset_depth() == 0
    @assert isdefined(ts, :wrapped_ts)
    # Return the wrapped_ts so that we don't need to handle WorkerTestSet anywhere else
    return ts.wrapped_ts
end

"""
    execute(::Type{R}, mod::Module, f, name, start_time, custom_args) where {R<:AbstractTestRecord}

Run the test expression `f` inside the sandbox module `mod` and return an
`R <: AbstractTestRecord`. This is the extension point for custom record
types: dispatch `execute(::Type{MyRecord}, …)` to collect additional per-test
statistics without re-implementing the sandbox scaffolding.

The default method for [`TestRecord`](@ref) wraps the test set in a
[`WorkerTestSet`](@ref) placeholder (so `DefaultTestSet` doesn't swallow
results at the top level), captures `@timed` stats, and records `Sys.maxrss()`.
Custom implementations commonly call `execute(TestRecord, mod, f, name,
start_time, custom_args)` to reuse that baseline and wrap the returned record
in a new record type.

Arguments:

- `mod` — the per-test sandbox module; the test expression `f` is evaluated
  into it via `@eval mod`.
- `f` — the test expression from the `testsuite` dictionary.
- `name` — the test name (used as the top-level `@testset` name).
- `start_time` — wall-clock time at which the scheduler picked up this test;
  subtract from `time()` to get total elapsed time including worker wait.
- `custom_args` — the `custom_args` value forwarded from [`runtests`](@ref)
  (arbitrary, typically a `NamedTuple`).
"""
function execute(::Type{TestRecord}, mod::Module, f, name, start_time, _custom_args)
    data = @eval mod begin
        GC.gc(true)
        Random.seed!(1)

        # @testset CustomTestSet switches the all lower-level testset to our custom testset,
        # so we need to have two layers here such that the user-defined testsets are using `DefaultTestSet`.
        # This also guarantees our invariant about `WorkerTestSet` containing a single `DefaultTestSet`.
        stats = @timed @testset WorkerTestSet "placeholder" begin
            @testset DefaultTestSet $name begin
                $f
            end
        end

        compile_time = @static VERSION >= v"1.11" ? stats.compile_time : 0.0
        (; testset=stats.value, stats.time, stats.bytes, stats.gctime, compile_time)
    end

    # process results
    rss = Sys.maxrss()
    record = TestRecord(data..., rss, time() - start_time)

    GC.gc(true)
    return record
end

function runtest(RecordType::Type{<:AbstractTestRecord}, f, name, init_code, start_time, custom_args)
    function inner()
        # generate a temporary module to execute the tests in
        mod = @eval(Main, module $(gensym(name)) end)
        @eval(mod, using ParallelTestRunner: Test, Random)
        @eval(mod, using .Test, .Random)
        # Both bindings must be imported since `@testset` can't handle fully-qualified names when VERSION < v"1.11.0-DEV.1518".
        @eval(mod, using ParallelTestRunner: WorkerTestSet)
        @eval(mod, using Test: DefaultTestSet)

        Core.eval(mod, init_code)

        return execute(RecordType, mod, f, name, start_time, custom_args)
    end

    @static if VERSION >= v"1.13.0-DEV.1044"
        @with Test.TESTSET_PRINT_ENABLE => false begin
            inner()
        end
    else
        old_print_setting = Test.TESTSET_PRINT_ENABLE[]
        Test.TESTSET_PRINT_ENABLE[] = false
        try
            inner()
        finally
            Test.TESTSET_PRINT_ENABLE[] = old_print_setting
        end
    end
end

# Assumed memory footprint of a single test worker, used to clamp the default
# number of jobs on memory-constrained machines (e.g. many cores but little
# memory). Packages whose tests are heavier can pass a larger
# `memory_per_worker` to `runtests`.
const DEFAULT_MEMORY_PER_WORKER = 2 * Int64(2)^30

"""
    default_njobs(; memory_per_worker = 2 * 2^30)

A function used to determine the default number of parallel jobs. Calculated as the
number of CPU threads, clamped such that each worker can be assumed to use `memory_per_worker`
bytes of the available system memory.
"""
function default_njobs(;
        memory_per_worker = DEFAULT_MEMORY_PER_WORKER,
        # Just use Sys.EFFECTIVE_CPU_THREADS when min VERSION >= v"1.13"
        _cpu_threads = (@static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS),
        _free_memory = available_memory(),
    )
    memory_jobs = Int64(_free_memory) ÷ memory_per_worker
    return max(1, min(_cpu_threads, memory_jobs))
end

"""
    runtests(mod::Module, args::Union{ParsedArgs,Array{String}};
             testsuite::Dict{String,Expr}=find_tests(pwd()),
             init_code = :(),
             init_worker_code = :(),
             test_worker = Returns(nothing),
             RecordType::Type{<:AbstractTestRecord} = TestRecord,
             custom_args = (;),
             exename = nothing,
             exeflags = nothing,
             env = Vector{Pair{String, String}}(),
             stdout = Base.stdout,
             stderr = Base.stderr,
             max_worker_rss = get_max_worker_rss(),
             memory_per_worker = 2 * 2^30)
             serial = String[],
             serial_position::Symbol = :before,
             recycle_on_failure::Bool = false,
             retries::Integer = 0,
             history_flush_every::Integer = 20,
             history_key = nothing,
             )
    runtests(mod::Module, ARGS; ...)

Run Julia tests in parallel across multiple worker processes.

## Arguments

- `mod`: The module calling runtests
- `ARGS`: Command line arguments.
  This can be either the vector of strings of the arguments, typically from [`Base.ARGS`](https://docs.julialang.org/en/v1/base/constants/#Base.ARGS), or a [`ParsedArgs`](@ref) object, typically constructed with [`parse_args`](@ref).
  When you run the tests with [`Pkg.test`](https://pkgdocs.julialang.org/v1/api/#Pkg.test), the command line arguments passed to the script can be changed with the `test_args` keyword argument.
  If the caller needs to accept arguments too, consider using [`parse_args`](@ref) to parse the arguments first.

Several keyword arguments are also supported:

- `testsuite`: Dictionary mapping test names to expressions to execute (default: [`find_tests(pwd())`](@ref)).
  By default, automatically discovers all `.jl` files in the test directory and its subdirectories.
- `init_code`: Code use to initialize each test's sandbox module (e.g., import auxiliary
  packages, define constants, etc).
- `init_worker_code`: Code use to initialize each worker. This is run only once per worker instead of once per test.
- `test_worker`: Optional function that takes a test name and `init_worker_code` if `init_worker_code` is defined and returns a specific worker.
  When returning `nothing`, the test will be assigned to any available default worker.
- `RecordType`: Concrete subtype of [`AbstractTestRecord`](@ref) used to collect
  per-test statistics. Defaults to [`TestRecord`](@ref). To extend the default
  record with extra data, define `struct MyRecord <: AbstractTestRecord;
  base::TestRecord; …; end` and dispatch [`execute`](@ref) on the new type —
  typically by calling `execute(TestRecord, mod, f, name, start_time,
  custom_args)` and wrapping the result. The default `print_*` methods read
  baseline fields through [`parent`](@ref), so wrapped types inherit the
  standard output; override `print_*` only when you need different layout.
  The record type must be defined on both the main process and all workers
  (e.g. via `init_worker_code`) since it crosses the Malt serialization
  boundary.
- `custom_args`: Arbitrary value (typically a `NamedTuple`) forwarded to
  [`execute`](@ref). Lets callers thread per-run configuration into a custom
  `RecordType`'s `execute` method without going through `init_code`.
- `exename`, `exeflags`, `env`: Forwarded to every internal `addworker` call, so
  they affect all default-pool workers (and any respawns). `exename` may be a
  `String` or a `Cmd` — passing a `Cmd` lets callers wrap the julia invocation
  with a tool such as `compute-sanitizer`. Custom workers created from inside a
  `test_worker` hook are the caller's responsibility.
- `stdout` and `stderr`: I/O streams to write to (default: `Base.stdout` and `Base.stderr`)
- `max_worker_rss`: RSS threshold where a worker will be restarted once it is reached.
- `memory_per_worker`: Assumed memory footprint (in bytes) of a single worker, used to
  clamp the default number of jobs on memory-constrained machines (default: 2 GiB).
  Packages whose tests use less memory can pass a smaller value to increase the default
  parallelism. Ignored when the number of jobs is set explicitly via `--jobs=N` or the
  `PTR_NUM_JOBS` environment variable.
- `serial`: A vector of test names (keys of `testsuite`) that should be run one at a time
  instead of in parallel.
- `serial_position`: When to run serial tests relative to the parallel batch.
  Must be `:before` (default) or `:after`.
- `recycle_on_failure`: Whether to recycle a worker after any test that did not pass
  (default: `false`). See the Failure Handling section below.
- `retries`: How many times to re-run tests that did not pass after the main run completes
  (default: `0`). See the Failure Handling section below.
- `history_flush_every`: How many finished tests to accumulate before merging their
  durations and outcomes into the on-disk test history (default: `20`); whatever is left is
  written when the run ends. Larger values mean fewer lock, write and rename operations,
  which matters on slow filesystems, while an interrupted run loses at most that many
  measurements.
- `history_key`: Keep a separate history of test durations and failures for this
  configuration, e.g. `"gpu"` or the name of a CI job, when the same test suite is run in
  configurations whose timings differ. By default all runs of `mod` share one history.

## Command Line Options

- `--help`: Show usage information and exit
- `--list`: List all available tests alphabetically and exit. Each entry shows the
  test's historical duration, if known, and is marked with `×` and printed in red if its last run failed.
- `--verbose`: Print more detailed information during test execution
- `--quickfail`: Stop the entire test run as soon as any test fails
- `--jobs=N`: Use N worker processes (default: based on CPU threads and available memory;
  can also be set with the `PTR_NUM_JOBS` environment variable, with
  `--jobs=N` taking precedence)
- `TESTS...`: Filter test files by name, matched using `startswith`. Arguments starting with '!' will instead be excluded from the test selection.

## Behavior

- Automatically discovers all `.jl` files in the test directory (excluding `runtests.jl`)
- Sorts test files by runtime (longest-running are started first) for load balancing
- Launches worker processes with appropriate Julia flags for testing
- Monitors memory usage and recycles workers that exceed memory limits
- Provides real-time progress output with timing and memory statistics
- Handles interruptions gracefully (Ctrl+C)
- Returns `nothing`, but throws `Test.FallbackTestSetException` if any tests fail

## Examples

Run all tests with default settings (auto-discovers `.jl` files)

```julia
using ParallelTestRunner
using MyPackage

runtests(MyPackage, ARGS)
```

Run only tests matching "integration" (matched with `startswith`):
```julia
using ParallelTestRunner
using MyPackage

runtests(MyPackage, ["integration"])
```

Define a custom test suite
```julia
using ParallelTestRunner
using MyPackage

testsuite = Dict(
    "custom" => quote
        @test 1 + 1 == 2
    end
)

runtests(MyPackage, ARGS; testsuite)
```

Customize the test suite
```julia
using ParallelTestRunner
using MyPackage

testsuite = find_tests(@__DIR__)
args = parse_args(ARGS)
if filter_tests!(testsuite, args)
    # Remove a specific test
    delete!(testsuite, "slow_test")
end
runtests(MyPackage, args; testsuite)
```

Run memory-hungry tests serially before the parallel batch
```julia
using ParallelTestRunner
using MyPackage

runtests(MyPackage, ARGS; serial=["big_alloc_test", "huge_matrix"])
```

## Memory Management

Workers are automatically recycled when they exceed memory limits to prevent out-of-memory
issues during long test runs. The memory limit is set based on system architecture.

## Failure Handling

With `recycle_on_failure = true`, a worker is recycled after any test that did not pass, so
a test that corrupts process-wide state (e.g. wedges a GPU driver) cannot poison subsequent
tests on the same worker.

With `retries = N` (default 0), tests that did not pass are re-run sequentially up to `N`
times after the main run completes. Only the final attempt of each test is reported.
"""
function runtests(mod::Module, args::ParsedArgs;
                  testsuite::Dict{String,Expr} = find_tests(pwd()),
                  init_code = :(), init_worker_code = :(), test_worker = Returns(nothing),
                  RecordType::Type{<:AbstractTestRecord} = TestRecord,
                  custom_args = (;),
                  exename = nothing,
                  exeflags = nothing,
                  env = Vector{Pair{String, String}}(),
                  serial::Vector{String} = String[],
                  serial_position::Symbol = :before,
                  stdout = Base.stdout,
                  stderr = Base.stderr,
                  max_worker_rss = get_max_worker_rss(),
                  memory_per_worker = DEFAULT_MEMORY_PER_WORKER,
                  recycle_on_failure::Bool = false,
                  retries::Integer = 0,
                  history_flush_every::Integer = 20,
                  history_key::Union{Nothing, AbstractString} = nothing,
                  )
    #
    # set-up
    #

    # list tests, if requested
    if args.list !== nothing
        historical_durations, historical_failures = load_test_history(mod, history_key)
        sorted_tests = sort(collect(keys(testsuite)))
        name_align = isempty(sorted_tests) ? 0 : maximum(textwidth, sorted_tests)
        duration_strs = Dict(
            test => (haskey(historical_durations, test) ? @sprintf("(%.2fs)", historical_durations[test]) : "")
            for test in sorted_tests
        )
        duration_align = isempty(duration_strs) ? 0 : maximum(textwidth, values(duration_strs))
        println(stdout, "Available tests:")
        for test in sorted_tests
            failed = test in historical_failures
            bullet = failed ? "×" : "-"
            face = failed ? :ptr_error : :default
            line = rstrip(" $bullet $(rpad(test, name_align))  $(lpad(duration_strs[test], duration_align))")
            println(stdout, styled"{$face:$line}")
        end
        exit(0)
    end

    # validate serial_position
    serial_position in (:before, :after) ||
        throw(ArgumentError("serial_position must be :before or :after, got :$serial_position"))

    # filter tests
    filter_tests!(testsuite, args)

    # filter serial list to only include tests that survived filtering
    serial = filter(t -> haskey(testsuite, t), serial)

    # determine test order
    tests = collect(keys(testsuite))
    Random.shuffle!(tests)
    historical_durations, historical_failures = load_test_history(mod, history_key)
    get_historical_duration(test) = TestHistoryEntry(get(historical_durations, test, Inf), test in historical_failures)
    sort!(tests, by = x -> get_historical_duration(x), rev = true)

    return _runtests(
        mod, args;
        testsuite,
        tests,
        historical_durations,
        historical_failures,
        history_key,
        init_code,
        init_worker_code,
        test_worker,
        RecordType,
        custom_args,
        exename,
        exeflags,
        env,
        serial,
        serial_position,
        stdout,
        stderr,
        max_worker_rss,
        memory_per_worker,
        recycle_on_failure,
        retries,
        history_flush_every,
    )
end

# the user is warned once a warm worker's init time exceeds this multiple of the cold-start cost...
const SLOW_INIT_FACTOR = 2
# ... but only if it also exceeds this many seconds, to avoid false positives in test suites
# with a short cold worker init
const SLOW_INIT_MIN_TIME = 10.0

# Helper function, to be used for testing, with `tests` already sorted.
function _runtests(mod::Module, args::ParsedArgs;
                   testsuite::Dict{String,Expr} = find_tests(pwd()),
                   tests::Vector{String},
                   historical_durations::Dict{String, Float64} = Dict{String, Float64}(),
                   historical_failures::Set{String} = Set{String}(),
                   history_key = nothing,
                   init_code = :(),
                   init_worker_code = :(),
                   test_worker = Returns(nothing),
                   RecordType::Type{<:AbstractTestRecord} = TestRecord,
                   custom_args = (;),
                   exename = nothing,
                   exeflags = nothing,
                   env = Vector{Pair{String, String}}(),
                   serial::Vector{String} = String[],
                   serial_position::Symbol = :before,
                   stdout = Base.stdout,
                   stderr = Base.stderr,
                   max_worker_rss = get_max_worker_rss(),
                   memory_per_worker = DEFAULT_MEMORY_PER_WORKER,
                   recycle_on_failure::Bool = false,
                   retries::Integer = 0,
                   history_flush_every::Integer = 20,
                   )

    # partition into serial and parallel groups
    serial_tests, parallel_tests = partition_tests(tests, serial)

    # determine parallelism
    env_jobs = tryparse(Int, get(ENV, "PTR_NUM_JOBS", ""))
    _jobs = @something args.jobs env_jobs default_njobs(; memory_per_worker)
    jobs = clamp(_jobs, 1, max(1, length(parallel_tests)))
    worker_pool = Channel{Union{Nothing, PTRWorker}}(jobs)
    for _ in 1:jobs
        put!(worker_pool, nothing)
    end
    println(stdout, "Running $(length(tests)) tests using $jobs parallel jobs. To change the number of jobs, specify the `--jobs=N` argument to the tests, or set the `PTR_NUM_JOBS` environment variable.")
    if !isempty(serial_tests)
        println(stdout, "  $(length(serial_tests)) serial test(s) will run $(serial_position) the parallel batch.")
    end
    if !isnothing(args.verbose)
        println(stdout, styled"Available memory: {bold:$(Base.format_bytes(available_memory()))}; Max worker RSS: {bold:$(Base.format_bytes(max_worker_rss))}")
    end

    t0 = time()
    results = Lockable([])
    pending_history = Lockable(PendingHistory())
    running_tests = Lockable(Dict{String, Float64}())  # test => start_time
    # init time of a test on a freshly spawned worker, i.e. the cost of recycling one
    cold_init_time = Threads.Atomic{Float64}(Inf)
    # the slow init warning is only printed once per run
    slow_init_warned = Threads.Atomic{Bool}(false)

    worker_tasks = Task[]

    serial_worker = Ref{Union{Nothing, PTRWorker}}(nothing)

    test_phases = if serial_position === :before
        ((serial_tests, Base.Semaphore(1), serial_worker),
         (parallel_tests, Base.Semaphore(max(1, jobs)), nothing))
    else
        ((parallel_tests, Base.Semaphore(max(1, jobs)), nothing),
         (serial_tests, Base.Semaphore(1), serial_worker))
    end

    done = Ref(false)
    function stop_work()
        if !done[]
            done[] = true
            for task in worker_tasks
                task === current_task() && continue
                Base.istaskdone(task) && continue
                try; schedule(task, InterruptException(); error=true); catch; end
            end
        end
    end

    #
    # output
    #

    # pretty print information about gc and mem usage
    testgroupheader = "Test"
    workerheader = "(Worker)"
    name_align = maximum(
        [
            textwidth(testgroupheader) + textwidth(" ") + textwidth(workerheader);
            map(x -> textwidth(x) + 5, tests)
        ]
    )

    print_lock = stdout isa Base.LibuvStream ? stdout.lock : ReentrantLock()
    if stderr isa Base.LibuvStream
        stderr.lock = print_lock
    end

    io_ctx = test_IOContext(RecordType, stdout, stderr, print_lock, name_align, !isnothing(args.verbose), max_worker_rss)
    print_header(RecordType, io_ctx, testgroupheader, workerheader)

    status_lines_visible = Ref(0)

    function clear_status()
        if status_lines_visible[] > 0
            for _ in 1:(status_lines_visible[]-1)
                print(io_ctx.stdout, "\033[2K")  # Clear entire line
                print(io_ctx.stdout, "\033[1A")  # Move up one line
            end
            print(io_ctx.stdout, "\r")  # Move to start of line
            status_lines_visible[] = 0
        end
    end

    function update_status()
        # take consistent snapshots once, so the rest of this function operates on
        # frozen data rather than racing with workers that mutate these collections
        running_snapshot = @lock running_tests copy(running_tests[])
        isempty(running_snapshot) && return
        results_snapshot = @lock results copy(results[])
        completed = length(results_snapshot)
        completed_names = Set(r.test for r in results_snapshot)
        total = length(tests)

        # line 1: empty line
        line1 = ""

        # line 2: running tests
        test_list = sort(collect(keys(running_snapshot)), by = x -> running_snapshot[x])
        status_parts = map(test_list) do test
            "$test"
        end
        line2 = "Running:  " * join(status_parts, ", ")
        ## truncate
        max_width = displaysize(io_ctx.stdout)[2]
        line2 = truncate_line(line2, max_width)

        # line 3: progress + ETA
        line3 = "Progress: $completed/$total tests completed"
        if completed > 0
            # estimate per-test time (slightly pessimistic)
            durations_done = [end_time - start_time for (_, _,_, start_time, end_time) in results_snapshot]
            μ = mean(durations_done)
            σ = length(durations_done) > 1 ? std(durations_done) : 0.0
            est_per_test = μ + 0.5σ

            parallel_remaining = 0.0
            serial_remaining = 0.0
            longest_remaining = 0.0
            now = time()
            for test in tests
                duration = get(historical_durations, test, est_per_test)
                remaining = if haskey(running_snapshot, test)
                    max(0.0, duration - (now - running_snapshot[test]))
                elseif test in completed_names
                    continue
                else
                    duration
                end
                if test in serial_tests
                    serial_remaining += remaining
                else
                    parallel_remaining += remaining
                end
                longest_remaining = max(longest_remaining, remaining)
            end

            eta_sec = max(serial_remaining + parallel_remaining / jobs, longest_remaining)
            eta_mins = round(Int, eta_sec / 60)
            line3 *= " │ ETA: ~$eta_mins min"
        end

        # only display the status bar on actual terminals
        # (but make sure we cover this code in CI)
        if io_ctx.stdout isa Base.TTY
            clear_status()
            println(io_ctx.stdout, line1)
            println(io_ctx.stdout, line2)
            print(io_ctx.stdout, line3)
            flush(io_ctx.stdout)
            status_lines_visible[] = 3
        end
    end

    # Message types for the printer channel
    # (:started, test_name, worker_id)
    # (:finished, test_name, worker_id, record, recycled)
    # (:slow_init, test_name, init_time, cold_init_time)
    # (:crashed, test_name, worker_id, test_time)
    # (:retry, tests_n, retry_n)
    # (:nonpass_face, face)
    printer_channel = Channel{Tuple}(100)

    printer_task = @async begin
        last_status_update = Ref(time())
        try
            while isopen(printer_channel) || isready(printer_channel)
                got_message = false
                while isready(printer_channel)
                    # Try to get a message from the channel (with timeout)
                    msg = take!(printer_channel)
                    got_message = true
                    msg_type = msg[1]

                    if msg_type === :started
                        test_name, wrkr = msg[2], msg[3]

                        # Optionally print verbose started message
                        if args.verbose !== nothing
                            clear_status()
                            print_test_started(RecordType, wrkr, test_name, io_ctx)
                        end

                    elseif msg_type === :finished
                        test_name, wrkr, record = msg[2], msg[3], msg[4]
                        io_ctx.recycled[] = msg[5]

                        clear_status()
                        if anynonpass(record[])
                            print_test_failed(record, wrkr, test_name, io_ctx)
                        else
                            print_test_finished(record, wrkr, test_name, io_ctx)
                        end

                    elseif msg_type === :slow_init
                        test_name, init_t, cold_t = msg[2], msg[3], msg[4]

                        clear_status()
                        lock(io_ctx.lock)
                        try
                            msg_str = styled"""
                            {ptr_warn,bold:Warning:} {ptr_light:Init time of `$test_name` ({default:$(round(init_t; digits=2))s}) was much longer than usual ({default:$(round(cold_t; digits=2))s} on a freshly spawned worker).
                            This usually means too many workers for the available memory; see the docs for more information.}
                            """
                            print(io_ctx.stderr, msg_str)
                            flush(io_ctx.stderr)
                        finally
                            unlock(io_ctx.lock)
                        end

                    elseif msg_type === :crashed
                        test_name, wrkr = msg[2], msg[3]

                        clear_status()
                        print_test_crashed(RecordType, wrkr, test_name, io_ctx)

                    elseif msg_type === :retry
                        tests_n, retry_n = msg[2], msg[3]

                        clear_status()
                        lock(io_ctx.lock)
                        try
                            println(io_ctx.stdout, "Retrying $tests_n failed test$(tests_n > 1 ? "s" : " ") ($retry_n)")
                            flush(io_ctx.stdout)
                        finally
                            unlock(io_ctx.lock)
                        end

                    elseif msg_type === :nonpass_face
                        # routed through the channel rather than set directly so it lands
                        # in order with the results it applies to: the coordinator flips it
                        # while this task may still be draining the previous round
                        io_ctx.nonpass_face[] = msg[2]
                    end
                end

                # After a while, display a status line
                if !done[] && time() - t0 >= 5 && (got_message || (time() - last_status_update[] >= 20))
                    update_status()
                    last_status_update[] = time()
                end

                isopen(printer_channel) && sleep(0.1)
            end
        catch ex
            if isa(ex, InterruptException)
                # the printer should keep on running,
                # but we need to signal other tasks to stop
                stop_work()
            else
                rethrow()
            end
            isa(ex, InterruptException) || rethrow()
        finally
            n_running = @lock running_tests length(running_tests[])
            n_results = @lock results length(results[])
            if n_running == 0 && n_results >= length(tests)
                # XXX: only erase the status if we completed successfully.
                #      in other cases we'll have printed "caught interrupt"
                clear_status()
            end
        end
    end

    #
    # execution
    #

    tests_to_start = Threads.Atomic{Int}(length(tests))
    # Stop all but `n` workers in the pool. Only safe at a
    # phase boundary, where all `njobs` slots have been returned.
    function drain_pool_leaving_n_workers!(pool, njobs, n)
        alive = PTRWorker[]
        for _ in 1:njobs
            p = take!(pool)
            if p !== nothing && Malt.isrunning(p)
                push!(alive, p)
            end
        end
        while length(alive) > n
            Malt.stop(pop!(alive))
        end
        for p in alive
            put!(pool, p)
        end
        for _ in 1:(njobs - length(alive))
            put!(pool, nothing)
        end
    end
    # `retry_mode` forces worker recycling after every non-passing test regardless
    #  of the value of `recycle_on_failure` and enables deletion of an old failed
    #  run of the test that just finished
    function run_test_phase(phase_tests, sem, shared_worker; retry_mode::Bool=false)
        # for serial phases, reserve one pool slot for the shared worker
        if !isnothing(shared_worker)
            shared_worker[] = take!(worker_pool)
        end

        next_test = Threads.Atomic{Int}(1)
        @sync for _ in eachindex(phase_tests)
            push!(worker_tasks, Threads.@spawn begin
                      local p = nothing
                      acquired = false
                      try
                          Base.acquire(sem)
                          acquired = true
                          p = !isnothing(shared_worker) ? shared_worker[] : take!(worker_pool)
                          Threads.atomic_sub!(tests_to_start, 1)

                          done[] && return

                          # with multiple threads, tasks reach this point in arbitrary order,
                          # so pick the next test to run only now, rather than at spawn time,
                          # to preserve the sorted test order (issue #139)
                          test = phase_tests[Threads.atomic_add!(next_test, 1)]

                          test_t0 = @lock running_tests begin
                              test_t0 = time()
                              running_tests[][test] = test_t0
                          end

                          # pass in init_worker_code to custom worker function if defined
                          wrkr = if init_worker_code == :()
                              test_worker(test)
                          else
                              test_worker(test, init_worker_code)
                          end
                          if wrkr === nothing
                              wrkr = p
                          end
                          # if a worker failed, spawn a new one
                          fresh_worker = false
                          if wrkr === nothing || !Malt.isrunning(wrkr)
                              wrkr = p = addworker(; init_worker_code, io_ctx.color,
                                                   exename, exeflags, env)
                              fresh_worker = true
                          end

                          # run the test
                          put!(printer_channel, (:started, test, worker_id(wrkr)))
                          result = try
                              Malt.remote_eval_wait(Main, wrkr.w, :(import ParallelTestRunner))
                              Malt.remote_call_fetch(invokelatest, wrkr.w, runtest,
                                                     RecordType, testsuite[test], test,
                                                     init_code, test_t0, custom_args)
                          catch ex
                              if isa(ex, InterruptException)
                                  # the worker got interrupted, signal other tasks to stop
                                  stop_work()
                                  return
                              end

                              ex
                          end
                          test_t1 = time()
                          output = @lock wrkr.io String(take!(wrkr.io[]))
                          # a retry drops the record of the attempt it re-runs only once it
                          # has one to put in its place: dropping them up front would lose
                          # them outright if the phase is interrupted
                          @lock results begin
                              retry_mode && filter!(r -> r.test != test, results[])
                              push!(results[], (; test, result, output, test_t0, test_t1))
                          end
                          record_test_history!(pending_history, mod, test, result, test_t1 - test_t0; history_flush_every, history_key)

                          # act on the results
                          if result isa AbstractTestRecord
                              if fresh_worker
                                  Threads.atomic_min!(cold_init_time, init_time(result))
                              end
                              # the pre-test full GC has become much slower than spawning a
                              # new worker, which typically means there are too many workers
                              # for the available memory (e.g. macOS memory pressure, #124)
                              slow_init = wrkr === p && !fresh_worker &&
                                          init_time(result) > max(SLOW_INIT_FACTOR * cold_init_time[], SLOW_INIT_MIN_TIME)
                              # recycle a pool worker so future tests start with a smaller working
                              # set, or so that a failing test that may have left the worker in a
                              # bad state (e.g. a wedged GPU driver) cannot poison later tests
                              # (custom workers are stopped after every test regardless)
                              recycle = wrkr === p && (memory_usage(result) > max_worker_rss ||
                                                       ((recycle_on_failure || retry_mode) && anynonpass(result[])))
                              put!(printer_channel, (:finished, test, worker_id(wrkr), result, recycle))
                              if slow_init && !Threads.atomic_xchg!(slow_init_warned, true)
                                  put!(printer_channel, (:slow_init, test, init_time(result), cold_init_time[]))
                              end
                              if anynonpass(result[]) && args.quickfail !== nothing
                                  stop_work()
                                  return
                              end

                              recycle && Malt.stop(wrkr)
                          else
                              # One of Malt.TerminatedWorkerException, Malt.RemoteException, or ErrorException
                              @assert result isa Exception
                              put!(printer_channel, (:crashed, test, worker_id(wrkr)))
                              if args.quickfail !== nothing
                                  stop_work()
                                  return
                              end

                              # the worker encountered some serious failure, recycle it
                              Malt.stop(wrkr)
                          end

                          # get rid of the custom worker
                          if wrkr != p
                              Malt.stop(wrkr)
                          end

                          @lock running_tests begin
                              delete!(running_tests[], test)
                          end
                      catch ex
                          isa(ex, InterruptException) || rethrow()
                      finally
                          if acquired
                              if !isnothing(shared_worker)
                                  shared_worker[] = p
                              else
                                  # stop the worker if no more tests will need one from the pool
                                  if tests_to_start[] == 0 && p !== nothing && Malt.isrunning(p)
                                      Malt.stop(p)
                                      p = nothing
                                  end
                                  put!(worker_pool, p)
                              end
                              Base.release(sem)
                          end
                      end
                  end)
        end

        # return the serial worker to the pool for potential reuse
        if !isnothing(shared_worker)
            put!(worker_pool, shared_worker[])
            shared_worker[] = nothing
        end
    end
    try
        phases = test_phases

        potential_retries = retries > 0 && args.quickfail === nothing

        potential_retries && put!(printer_channel, (:nonpass_face, :ptr_warn))
        for i in 1:length(phases)
            phase_tests, sem, shared_worker = phases[i]
            isempty(phase_tests) && continue

            run_test_phase(phase_tests, sem, shared_worker)

            # parallel workers are not stopped while serial tests remain (tests_to_start > 0);
            # drain before serial-after so only one worker is alive for the serial phase.
            # one is kept rather than none so we do not add a third addworker (ID_COUNTER).
            if isnothing(shared_worker) && i < length(phases)
                next_tests, _, next_sw = phases[i+1]
                if !isempty(next_tests) && !isnothing(next_sw)
                    drain_pool_leaving_n_workers!(worker_pool, jobs, 1)
                end
            end
        end

        # retries
        if potential_retries
            for i in 1:retries
                # `stop_work()` may have been called from a worker task or the printer
                # without any exception reaching the `catch` below, so we cannot assume we
                # got here normally; there is no point retrying a run being torn down.
                done[] && break

                retry_tests = [r.test for r in results.value
                                    if r.result isa Exception || anynonpass(r.result[])]
                isempty(retry_tests) && break

                # the last attempt of a test is the one that gets reported, so print it red
                retries == i && put!(printer_channel, (:nonpass_face, :ptr_error))
                put!(printer_channel, (:retry, length(retry_tests), i))
                sem = Base.Semaphore(1)
                shared_worker = serial_worker

                # retries run on an otherwise-idle system: stop every worker left over
                # from the previous phase, so the retry worker is spawned fresh below and
                # no sibling process competes with it. `retry_mode` keeps it that way
                # after each test that does not pass.
                drain_pool_leaving_n_workers!(worker_pool, jobs, 0)

                run_test_phase(retry_tests, sem, shared_worker; retry_mode=true)
            end
        end
    catch err
        if !(err isa InterruptException)
            println(io_ctx.stderr, "\nCaught an error, stopping...")
        end
    finally
        stop_work()
    end

    #
    # finalization
    #

    # wait for the printer to finish so that all results have been printed
    close(printer_channel)
    wait(printer_task)

    # wait for worker tasks to catch unhandled exceptions
    for task in worker_tasks
        try
            wait(task)
        catch err
            # unwrap TaskFailedException
            while isa(err, TaskFailedException)
                err = current_exceptions(err.task)[1].exception
            end

            isa(err, InterruptException) || rethrow()
        end
    end

    # clean up remaining workers in the pool
    close(worker_pool)
    for p in worker_pool
        if p !== nothing && Malt.isrunning(p)
            Malt.stop(p)
        end
    end

    # print the output generated by each testset
    # (`@sync` above joined all writers, so `results` is quiescent from here on)
    for (testname, result, output, _start, _stop) in results.value
        if !isempty(output)
            testface = if result isa Exception || anynonpass(result[])
                :ptr_error
            else
                :default
            end
            println(io_ctx.stdout, styled"\nOutput generated during execution of '{$testface:$testname}':")
            lines = collect(eachline(IOBuffer(output)))

            for (i,line) in enumerate(lines)
                prefix = if length(lines) == 1
                    "["
                elseif i == 1
                    "┌"
                elseif i == length(lines)
                    "└"
                else
                    "│"
                end
                println(io_ctx.stdout, prefix, " ", line)
            end
        end
    end

    # process test results and convert into a testset
    function create_testset(name; start=nothing, stop=nothing, kwargs...)
        if start === nothing
            testset = Test.DefaultTestSet(name; kwargs...)
        elseif VERSION >= v"1.13.0-DEV.1297"
            testset = Test.DefaultTestSet(name; time_start=start, kwargs...)
        elseif VERSION < v"1.13.0-DEV.1037"
            testset = Test.DefaultTestSet(name; kwargs...)
            testset.time_start = start
        else
            # no way to set time_start retroactively
            testset = Test.DefaultTestSet(name; kwargs...)
        end

        if stop !== nothing
            if VERSION < v"1.13.0-DEV.1037"
                testset.time_end = stop
            elseif VERSION >= v"1.13.0-DEV.1297"
                @atomic testset.time_end = stop
            else
                # if we can't set the start time, also don't set a stop one
                # to avoid negative timings
            end
        end

        return testset
    end
    t1 = time()
    o_ts = create_testset("Overall"; start=t0, stop=t1, verbose=!isnothing(args.verbose))
    function collect_results()
        with_testset(o_ts) do
            completed_tests = Set{String}()
            for (testname, result, _output, start, stop) in results.value
                push!(completed_tests, testname)

                testset = if result isa AbstractTestRecord
                    result[]
                else
                    # If this test raised an exception that means the test runner itself had some problem,
                    # so we may have hit a segfault, deserialization errors or something similar.
                    # Record this testset as Errored.
                    # One of Malt.TerminatedWorkerException, Malt.RemoteException, or ErrorException
                    @assert result isa Exception
                    err_ts = create_testset(testname; start, stop)
                    Test.record(err_ts, Test.Error(:nontest_error, testname, nothing, Base.ExceptionStack(NamedTuple[(;exception = result, backtrace = Union{Ptr{Nothing}, Base.InterpreterIP}[])]), LineNumberNode(1)))
                    err_ts
                end

                with_testset(testset) do
                    Test.record(o_ts, testset)
                end
            end

            # mark remaining or running tests as interrupted
            for test in tests
                (test in completed_tests) && continue
                testset = create_testset(test)
                Test.record(testset, Test.Error(:test_interrupted, test, nothing, Base.ExceptionStack(NamedTuple[(;exception = "skipped", backtrace = Union{Ptr{Nothing}, Base.InterpreterIP}[])]), LineNumberNode(1)))
                with_testset(testset) do
                    Test.record(o_ts, testset)
                end
            end
        end
    end
    @static if VERSION >= v"1.13.0-DEV.1044"
        @with Test.TESTSET_PRINT_ENABLE => false begin
            collect_results()
        end
    else
        old_print_setting = Test.TESTSET_PRINT_ENABLE[]
        Test.TESTSET_PRINT_ENABLE[] = false
        try
            collect_results()
        finally
            Test.TESTSET_PRINT_ENABLE[] = old_print_setting
        end
    end
    flush_test_history!(pending_history, mod; history_key)

    # display the results
    println(io_ctx.stdout)
    if VERSION >= v"1.13.0-DEV.1033"
        Test.print_test_results(io_ctx.stdout, o_ts, 1)
    else
        c = IOCapture.capture(; io_ctx.color) do
            Test.print_test_results(o_ts, 1)
        end
        print(io_ctx.stdout, c.output)
    end
    if !anynonpass(o_ts)
        print(io_ctx.stdout, styled"    {green,bold:SUCCESS}\n")
    else
        print(io_ctx.stderr, styled"    {ptr_error,bold:FAILURE}\n\n")
        if VERSION >= v"1.13.0-DEV.1033"
            Test.print_test_errors(io_ctx.stdout, o_ts)
        else
            c = IOCapture.capture(; io_ctx.color) do
                Test.print_test_errors(o_ts)
            end
            print(io_ctx.stdout, c.output)
        end
        throw(Test.FallbackTestSetException("Test run finished with errors"))
    end

    return
end

runtests(mod::Module, ARGS::Array{String}; kwargs...) = runtests(mod, parse_args(ARGS); kwargs...)

# register faces used in printing
function __init__()
    addface!(:ptr_warn => Face(inherit=:yellow))
    addface!(:ptr_error => Face(inherit=:red))
    addface!(:ptr_light => Face(inherit=:light))
end

end
