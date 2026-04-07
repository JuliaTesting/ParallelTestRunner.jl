module ParallelTestRunner

export runtests, addworkers, addworker, find_tests, parse_args, filter_tests!

using Malt
using Dates
using Printf: @sprintf
using Base.Filesystem: path_separator
using Statistics
using Scratch
using Serialization
import Test
import Random
import IOCapture
using Test: DefaultTestSet

function anynonpass(ts::Test.AbstractTestSet)
    @static if VERSION >= v"1.13.0-DEV.1037"
        return Test.anynonpass(ts)
    else
        Test.get_test_counts(ts)
        return ts.anynonpass
    end
end

const ID_COUNTER = Threads.Atomic{Int}(0)

# Thin wrapper around Malt.Worker, to handle the stdio loop differently.
struct PTRWorker <: Malt.AbstractWorker
    w::Malt.Worker
    io::IOBuffer
    io_lock::ReentrantLock
    id::Int
end

function PTRWorker(; exename=Base.julia_cmd()[1], exeflags=String[], env=String[])
    io = IOBuffer()
    io_lock = ReentrantLock()
    wrkr = Malt.Worker(; exename, exeflags, env, monitor_stdout=false, monitor_stderr=false)
    stdio_loop(wrkr, io, io_lock)
    id = ID_COUNTER[] += 1
    return PTRWorker(wrkr, io, io_lock, id)
end

worker_id(wrkr::PTRWorker) = wrkr.id
Malt.isrunning(wrkr::PTRWorker) = Malt.isrunning(wrkr.w)
Malt.stop(wrkr::PTRWorker) = Malt.stop(wrkr.w)

#Always set the max rss so that if tests add large global variables (which they do) we don't make the GC's life too hard
function get_max_worker_rss()
    mb = if haskey(ENV, "JULIA_TEST_MAXRSS_MB")
        parse(Int, ENV["JULIA_TEST_MAXRSS_MB"])
    elseif Sys.WORD_SIZE == 64
        Sys.total_memory() > 8*Int64(2)^30 ? 3800 : 3000
    else
        # Assume that we only have 3.5GB available to a single process, and that a single
        # test can take up to 2GB of RSS.  This means that we should instruct the test
        # framework to restart any worker that comes into a test set with 1.5GB of RSS.
        1536
    end
    return mb * 2^20
end

function with_testset(f, testset)
    @static if VERSION >= v"1.13.0-DEV.1044"
        Test.@with_testset testset f()
    else
        Test.push_testset(testset)
        try
            f()
        finally
            Test.pop_testset()
        end
    end
    return nothing
end

if VERSION >= v"1.13.0-DEV.1044"
    using Base.ScopedValues
end

abstract type AbstractTestRecord end

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

function memory_usage(rec::TestRecord)
    return rec.rss
end

function Base.getindex(rec::TestRecord)
    return rec.value
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
end

function test_IOContext(stdout::IO, stderr::IO, lock::ReentrantLock, name_align::Int, verbose::Bool)
    elapsed_align = textwidth("time (s)")
    compile_align = textwidth("Compile")
    gc_align = textwidth("GC (s)")
    percent_align = textwidth("GC %")
    alloc_align = textwidth("Alloc (MB)")
    rss_align = textwidth("RSS (MB)")

    color = get(stdout, :color, false)

    return TestIOContext(
        stdout, stderr, color, verbose, lock, name_align, elapsed_align, compile_align, gc_align, percent_align,
        alloc_align, rss_align
    )
end

function print_header(ctx::TestIOContext, testgroupheader, workerheader)
    lock(ctx.lock)
    try
        # header top
        printstyled(ctx.stdout, " "^(ctx.name_align + textwidth(testgroupheader) - 3), " │ ")
        printstyled(ctx.stdout, "  Test   │", color = :white)
        ctx.verbose && printstyled(ctx.stdout, "   Init   │", color = :white)
        VERSION >= v"1.11" && ctx.verbose && printstyled(ctx.stdout, " Compile │", color = :white)
        printstyled(ctx.stdout, " ──────────────── CPU ──────────────── │\n", color = :white)

        # header bottom
        printstyled(ctx.stdout, testgroupheader, color = :white)
        printstyled(ctx.stdout, lpad(workerheader, ctx.name_align - textwidth(testgroupheader) + 1), " │ ", color = :white)
        printstyled(ctx.stdout, "time (s) │", color = :white)
        ctx.verbose && printstyled(ctx.stdout, " time (s) │", color = :white)
        VERSION >= v"1.11" && ctx.verbose && printstyled(ctx.stdout, "   (%)   │", color = :white)
        printstyled(ctx.stdout, " GC (s) │ GC % │ Alloc (MB) │ RSS (MB) │\n", color = :white)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_started(wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        printstyled(ctx.stdout, test, lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │", color = :white)
        printstyled(
            ctx.stdout,
            " "^ctx.elapsed_align, "started at $(now())\n", color = :light_black
        )
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_finished(record::TestRecord, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        printstyled(ctx.stdout, test, color = :white)
        printstyled(ctx.stdout, lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │ ", color = :white)

        time_str = @sprintf("%7.2f", record.time)
        printstyled(ctx.stdout, lpad(time_str, ctx.elapsed_align, " "), " │ ", color = :white)

        if ctx.verbose
            # pre-testset time
            init_time_str = @sprintf("%7.2f", record.total_time - record.time)
            printstyled(ctx.stdout, lpad(init_time_str, ctx.elapsed_align, " "), " │ ", color = :white)

            # compilation time
            if VERSION >= v"1.11"
                init_time_str = @sprintf("%7.2f", Float64(100*record.compile_time/record.time))
                printstyled(ctx.stdout, lpad(init_time_str, ctx.compile_align, " "), " │ ", color = :white)
            end
        end

        gc_str = @sprintf("%5.2f", record.gctime)
        printstyled(ctx.stdout, lpad(gc_str, ctx.gc_align, " "), " │ ", color = :white)
        percent_str = @sprintf("%4.1f", 100 * record.gctime / record.time)
        printstyled(ctx.stdout, lpad(percent_str, ctx.percent_align, " "), " │ ", color = :white)
        alloc_str = @sprintf("%5.2f", record.bytes / 2^20)
        printstyled(ctx.stdout, lpad(alloc_str, ctx.alloc_align, " "), " │ ", color = :white)

        rss_str = @sprintf("%5.2f", record.rss / 2^20)
        printstyled(ctx.stdout, lpad(rss_str, ctx.rss_align, " "), " │\n", color = :white)

        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_failed(record::TestRecord, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        printstyled(ctx.stderr, test, color = :red)
        printstyled(
            ctx.stderr,
            lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │"
            , color = :red
        )

        time_str = @sprintf("%7.2f", record.time)
        printstyled(ctx.stderr, lpad(time_str, ctx.elapsed_align + 1, " "), " │", color = :red)

        if ctx.verbose
            init_time_str = @sprintf("%7.2f", record.total_time - record.time)
            printstyled(ctx.stdout, lpad(init_time_str, ctx.elapsed_align + 1, " "), " │ ", color = :red)
        end

        failed_str = "failed at $(now())\n"
        # 11 -> 3 from " │ " 3x and 2 for each " " on either side
        fail_align = (11 + ctx.gc_align + ctx.percent_align + ctx.alloc_align + ctx.rss_align - textwidth(failed_str)) ÷ 2 + textwidth(failed_str)
        failed_str = lpad(failed_str, fail_align, " ")
        printstyled(ctx.stderr, failed_str, color = :red)

        # TODO: print other stats?

        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end

function print_test_crashed(wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        printstyled(ctx.stderr, test, color = :red)
        printstyled(
            ctx.stderr,
            lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " "), " │",
            " "^ctx.elapsed_align, " crashed at $(now())\n", color = :red
        )

        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end

# Adapted from `Malt._stdio_loop`
function stdio_loop(worker::Malt.Worker, io, io_lock::ReentrantLock)
    Threads.@spawn while !eof(worker.stdout) && Malt.isrunning(worker)
        try
            bytes = readavailable(worker.stdout)
            @lock io_lock write(io, bytes)
        catch
            break
        end
    end
    Threads.@spawn while !eof(worker.stderr) && Malt.isrunning(worker)
        try
            bytes = readavailable(worker.stderr)
            @lock io_lock write(io, bytes)
        catch
            break
        end
    end
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

function runtest(f, name, init_code, start_time)
    function inner()
        # generate a temporary module to execute the tests in
        mod = @eval(Main, module $(gensym(name)) end)
        @eval(mod, using ParallelTestRunner: Test, Random)
        @eval(mod, using .Test, .Random)
        # Both bindings must be imported since `@testset` can't handle fully-qualified names when VERSION < v"1.11.0-DEV.1518".
        @eval(mod, using ParallelTestRunner: WorkerTestSet)
        @eval(mod, using Test: DefaultTestSet)

        Core.eval(mod, init_code)

        data = @eval mod begin
            GC.gc(true)
            Random.seed!(1)

            # @testset CustomTestRecord switches the all lower-level testset to our custom testset,
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

@static if Sys.isapple()

mutable struct VmStatistics64
	free_count::UInt32
	active_count::UInt32
	inactive_count::UInt32
	wire_count::UInt32
	zero_fill_count::UInt64
	reactivations::UInt64
	pageins::UInt64
	pageouts::UInt64
	faults::UInt64
	cow_faults::UInt64
	lookups::UInt64
	hits::UInt64
	purges::UInt64
	purgeable_count::UInt32

	speculative_count::UInt32

	decompressions::UInt64
	compressions::UInt64
	swapins::UInt64
	swapouts::UInt64
	compressor_page_count::UInt32
	throttled_count::UInt32
	external_page_count::UInt32
	internal_page_count::UInt32
	total_uncompressed_pages_in_compressor::UInt64

	VmStatistics64() = new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
end


function available_memory()
	vms = Ref{VmStatistics64}(VmStatistics64())
	mach_host_self = @ccall mach_host_self()::UInt32
	count = UInt32(sizeof(VmStatistics64) ÷ sizeof(Int32))
	ref_count = Ref(count)
	@ccall host_statistics64(mach_host_self::UInt32, 4::Int64, pointer_from_objref(vms[])::Ptr{Int64}, ref_count::Ref{UInt32})::Int64

	page_size = Int(@ccall sysconf(29::UInt32)::UInt32)

	return (Int(vms[].free_count) + Int(vms[].inactive_count) + Int(vms[].purgeable_count) + Int(vms[].compressor_page_count)) * page_size
end

else

available_memory() = Sys.free_memory()

end

# This is an internal function, not to be used by end users.  The keyword
# arguments are only for testing purposes.
"""
    default_njobs()

Determine default number of parallel jobs.
"""
function default_njobs(; cpu_threads = Sys.CPU_THREADS, free_memory = available_memory())
    jobs = cpu_threads
    memory_jobs = Int64(free_memory) ÷ (2 * Int64(2)^30)
    return max(1, min(jobs, memory_jobs))
end

# Historical test duration database
function get_history_file(mod::Module)
    scratch_dir = @get_scratch!("durations")
    return joinpath(scratch_dir, "v$(VERSION.major).$(VERSION.minor)", "$(nameof(mod)).jls")
end
function load_test_history(mod::Module)
    history_file = get_history_file(mod)
    if isfile(history_file)
        try
            return deserialize(history_file)
        catch e
            @warn "Failed to load test history from $history_file" exception=e
            return Dict{String, Float64}()
        end
    else
        return Dict{String, Float64}()
    end
end
function save_test_history(mod::Module, history::Dict{String, Float64})
    history_file = get_history_file(mod)
    try
        mkpath(dirname(history_file))
        serialize(history_file, history)
    catch e
        @warn "Failed to save test history to $history_file" exception=e
    end
end

function test_exe(color::Bool=false)
    test_exeflags = Base.julia_cmd()
    push!(test_exeflags.exec, "--project=$(Base.active_project())")
    push!(test_exeflags.exec, "--color=$(color ? "yes" : "no")")
    return test_exeflags
end

"""
    addworkers(; env=Vector{Pair{String, String}}(), init_worker_code = :(), exename=nothing, exeflags=nothing, color::Bool=false)

Add `X` worker processes.
To add a single worker, use [`addworker`](@ref).

## Arguments
- `env`: Vector of environment variable pairs to set for the worker process.
- `init_worker_code`: Code use to initialize each worker. This is run only once per worker instead of once per test.
- `exename`: Custom executable to use for the worker process.
- `exeflags`: Custom flags to pass to the worker process.
- `color`: Boolean flag to decide whether to start `julia` with `--color=yes` (if `true`) or `--color=no` (if `false`).
"""
addworkers(X; kwargs...) = [addworker(; kwargs...) for _ in 1:X]

"""
    addworker(; env=Vector{Pair{String, String}}(), init_worker_code = :(), exename=nothing, exeflags=nothing; color::Bool=false)

Add a single worker process.
To add multiple workers, use [`addworkers`](@ref).

## Arguments
- `env`: Vector of environment variable pairs to set for the worker process.
- `init_worker_code`: Code use to initialize each worker. This is run only once per worker instead of once per test.
- `exename`: Custom executable to use for the worker process.
- `exeflags`: Custom flags to pass to the worker process.
- `color`: Boolean flag to decide whether to start `julia` with `--color=yes` (if `true`) or `--color=no` (if `false`).
"""
function addworker(;
        env = Vector{Pair{String, String}}(),
        init_worker_code = :(),
        exename = nothing,
        exeflags = nothing,
        color::Bool = false,
    )
    exe = test_exe(color)
    if exename === nothing
        exename = exe[1]
    end
    if exeflags !== nothing
        exeflags = vcat(exe[2:end], exeflags)
    else
        exeflags = exe[2:end]
    end

    push!(env, "JULIA_NUM_THREADS" => "1")
    # Malt already sets OPENBLAS_NUM_THREADS to 1
    push!(env, "OPENBLAS_NUM_THREADS" => "1")
    wrkr =  PTRWorker(; exename, exeflags, env)
    if init_worker_code != :()
        Malt.remote_eval_wait(Main, wrkr.w, init_worker_code)
    end
    return wrkr
end

"""
    find_tests(dir::String) -> Dict{String, Expr}

Discover test files in a directory and return a test suite dictionary.

Walks through `dir` and finds all `.jl` files (excluding `runtests.jl`), returning a
dictionary mapping test names to expression that include each test file.
"""
function find_tests(dir::String)
    tests = Dict{String, Expr}()
    for (rootpath, _dirs, files) in walkdir(dir)
        # find Julia files
        filter!(files) do file
            endswith(file, ".jl") && file !== "runtests.jl"
        end
        isempty(files) && continue

        # strip extension
        files = map(files) do file
            file[1:(end - 3)]
        end

        # prepend subdir
        subdir = relpath(rootpath, dir)
        if subdir != "."
            files = map(files) do file
                joinpath(subdir, file)
            end
        end

        # unify path separators
        files = map(files) do file
            replace(file, path_separator => '/')
        end

        for file in files
            path = joinpath(rootpath, basename(file * ".jl"))
            tests[file] = :(include($path))
        end
    end
    return tests
end

"""
    ParsedArgs

Struct representing parsed command line arguments, to be passed to [`runtests`](@ref).
`ParsedArgs` objects are typically obtained by using [`parse_args`](@ref).

Fields are

* `jobs::Union{Some{Int}, Nothing}`: the number of jobs
* `verbose::Union{Some{Nothing}, Nothing}`: whether verbose printing was enabled
* `quickfail::Union{Some{Nothing}, Nothing}`: whether quick fail was enabled
* `list::Union{Some{Nothing}, Nothing}`: whether tests should be listed
* `custom::Dict{String,Any}`: a dictionary of custom arguments
* `positionals::Vector{String}`: the list of positional arguments passed on the command line, i.e. the explicit list of test files (to be matches with `startswith`)
"""
struct ParsedArgs
    jobs::Union{Some{Int}, Nothing}
    verbose::Union{Some{Nothing}, Nothing}
    quickfail::Union{Some{Nothing}, Nothing}
    list::Union{Some{Nothing}, Nothing}

    custom::Dict{String,Any}

    positionals::Vector{String}
end

# parse some command-line arguments
function extract_flag!(args, flag; typ = Nothing)
    for f in args
        if startswith(f, flag)
            # Check if it's just `--flag` or if it's `--flag=foo`
            val = if f == flag
                nothing
            else
                parts = split(f, '=')
                if typ === Nothing || typ <: AbstractString
                    parts[2]
                else
                    parse(typ, parts[2])
                end
            end

            # Drop this value from our args
            filter!(x -> x != f, args)
            return Some(val)
        end
    end
    return nothing
end

"""
    parse_args(args; [custom::Array{String}]) -> ParsedArgs

Parse command-line arguments for `runtests`. Typically invoked by passing `Base.ARGS`.

Fields of this structure represent command-line options, containing `nothing` when the
option was not specified, or `Some(optional_value=nothing)` when it was.

Custom arguments can be specified via the `custom` keyword argument, which should be
an array of strings representing custom flag names (without the `--` prefix). Presence
of these flags will be recorded in the `custom` field of the returned [`ParsedArgs`](@ref) object.
"""
function parse_args(args; custom::Array{String} = String[])
    args = copy(args)

    help = extract_flag!(args, "--help")
    if help !== nothing
        usage =
            """
            Usage: runtests.jl [--help] [--list] [--jobs=N] [TESTS...]

               --help             Show this text.
               --list             List all available tests.
               --verbose          Print more information during testing.
               --quickfail        Fail the entire run as soon as a single test errored.
               --jobs=N           Launch `N` processes to perform tests."""

        if !isempty(custom)
            usage *= "\n\nCustom arguments:"
            for flag in custom
                usage *= "\n   --$flag"
            end
        end
        usage *= "\n\nRemaining arguments filter the tests that will be executed."
        println(usage)
        exit(0)
    end

    jobs = extract_flag!(args, "--jobs"; typ = Int)
    verbose = extract_flag!(args, "--verbose")
    quickfail = extract_flag!(args, "--quickfail")
    list = extract_flag!(args, "--list")

    custom_args = Dict{String,Any}()
    for flag in custom
        custom_args[flag] = extract_flag!(args, "--$flag")
    end

    ## no options should remain
    optlike_args = filter(startswith("-"), args)
    if !isempty(optlike_args)
        error("Unknown test options `$(join(optlike_args, " "))` (try `--help` for usage instructions)")
    end

    return ParsedArgs(jobs, verbose, quickfail, list, custom_args, args)
end

"""
    filter_tests!(testsuite, args::ParsedArgs) -> Bool

Filter tests in `testsuite` based on command-line arguments in `args`.

Returns `true` if additional filtering may be done by the caller, `false` otherwise.
"""
function filter_tests!(testsuite, args::ParsedArgs)
    # the user did not request specific tests, so let the caller do its own filtering
    isempty(args.positionals) && return true

    # only select tests matching positional arguments
    tests = collect(keys(testsuite))
    for test in tests
        if !any(arg -> startswith(test, arg), args.positionals)
            delete!(testsuite, test)
        end
    end

    # the user requested specific tests, so don't allow further filtering
    return false
end

"""
    partition_tests(tests::Vector{String}, serial::Vector{String}) -> (serial_tests, parallel_tests)

Split `tests` into two ordered vectors: tests named in `serial` (preserving their
order in `tests`) and the remaining parallel tests. Throws `ArgumentError` if any
name in `serial` is not present in `tests`.
"""
function partition_tests(tests::Vector{String}, serial::Vector{String})
    serial_set = Set(serial)
    unknown = setdiff(serial_set, Set(tests))
    if !isempty(unknown)
        throw(ArgumentError("serial test(s) not found in testsuite: $(join(sort!(collect(unknown)), ", "))"))
    end
    serial_tests = filter(t -> t in serial_set, tests)
    parallel_tests = filter(t -> !(t in serial_set), tests)
    return serial_tests, parallel_tests
end

"""
    runtests(mod::Module, args::Union{ParsedArgs,Array{String}};
             testsuite::Dict{String,Expr}=find_tests(pwd()),
             init_code = :(),
             init_worker_code = :(),
             test_worker = Returns(nothing),
             stdout = Base.stdout,
             stderr = Base.stderr,
             max_worker_rss = get_max_worker_rss(),
             serial = String[],
             serial_position::Symbol = :before)
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
- `stdout` and `stderr`: I/O streams to write to (default: `Base.stdout` and `Base.stderr`)
- `max_worker_rss`: RSS threshold where a worker will be restarted once it is reached.
- `serial`: A vector of test names (keys of `testsuite`) that should be run one at a time
  instead of in parallel. An `ArgumentError` is thrown if any name is not found in the testsuite.
- `serial_position`: When to run serial tests relative to the parallel batch.
  Must be `:before` (default) or `:after`.

## Command Line Options

- `--help`: Show usage information and exit
- `--list`: List all available test files and exit
- `--verbose`: Print more detailed information during test execution
- `--quickfail`: Stop the entire test run as soon as any test fails
- `--jobs=N`: Use N worker processes (default: based on CPU threads and available memory)
- `TESTS...`: Filter test files by name, matched using `startswith`

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

testsuite = find_tests(pwd())
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
"""
function runtests(mod::Module, args::ParsedArgs;
                  testsuite::Dict{String,Expr} = find_tests(pwd()),
                  init_code = :(), init_worker_code = :(), test_worker = Returns(nothing),
                  stdout = Base.stdout, stderr = Base.stderr, max_worker_rss = get_max_worker_rss(),
                  serial::Vector{String} = String[], serial_position::Symbol = :before)
    #
    # set-up
    #

    # list tests, if requested
    if args.list !== nothing
        println(stdout, "Available tests:")
        for test in keys(testsuite)
            println(stdout, " - $test")
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
    historical_durations = load_test_history(mod)
    sort!(tests, by = x -> -get(historical_durations, x, Inf))

    # partition into serial and parallel groups
    serial_tests, parallel_tests = partition_tests(tests, serial)

    # determine parallelism
    jobs = something(args.jobs, default_njobs())
    jobs = clamp(jobs, 1, max(1, length(parallel_tests)))
    worker_pool = Channel{Union{Nothing, PTRWorker}}(jobs)
    for _ in 1:jobs
        put!(worker_pool, nothing)
    end
    println(stdout, "Running $(length(tests)) tests using $jobs parallel jobs. If this is too many concurrent jobs, specify the `--jobs=N` argument to the tests, or set the `JULIA_CPU_THREADS` environment variable.")
    if !isempty(serial_tests)
        println(stdout, "  $(length(serial_tests)) serial test(s) will run $(serial_position) the parallel batch.")
    end
    !isnothing(args.verbose) && println(stdout, "Available memory: $(Base.format_bytes(available_memory()))")

    t0 = time()
    results = []
    running_tests = Dict{String, Float64}()  # test => start_time
    test_lock = ReentrantLock() # to protect crucial access to tests and running_tests
    results_lock = ReentrantLock() # to protect concurrent access to results

    worker_tasks = Task[]

    serial_worker = Ref{Union{Nothing, PTRWorker}}(nothing)

    test_phases = if serial_position === :before
        ((serial_tests, Base.Semaphore(1), serial_worker),
         (parallel_tests, Base.Semaphore(max(1, jobs)), nothing))
    else
        ((parallel_tests, Base.Semaphore(max(1, jobs)), nothing),
         (serial_tests, Base.Semaphore(1), serial_worker))
    end

    done = false
    function stop_work()
        if !done
            done = true
            for task in worker_tasks
                task == current_task() && continue
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

    io_ctx = test_IOContext(stdout, stderr, print_lock, name_align, !isnothing(args.verbose))
    print_header(io_ctx, testgroupheader, workerheader)

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
        # only draw if we have something to show
        isempty(running_tests) && return
        completed = Base.@lock results_lock length(results)
        total = length(tests)

        # line 1: empty line
        line1 = ""

        # line 2: running tests
        test_list = sort(collect(keys(running_tests)), by = x -> running_tests[x])
        status_parts = map(test_list) do test
            "$test"
        end
        line2 = "Running:  " * join(status_parts, ", ")
        ## truncate
        max_width = displaysize(io_ctx.stdout)[2]
        if length(line2) > max_width
            line2 = line2[1:max_width-3] * "..."
        end

        # line 3: progress + ETA
        line3 = "Progress: $completed/$total tests completed"
        if completed > 0
            # estimate per-test time (slightly pessimistic)
            durations_done = Base.@lock results_lock [end_time - start_time for (_, _,_, start_time, end_time) in results]
            μ = mean(durations_done)
            σ = length(durations_done) > 1 ? std(durations_done) : 0.0
            est_per_test = μ + 0.5σ

            est_remaining = 0.0
            ## currently-running
            for (test, start_time) in running_tests
                elapsed = time() - start_time
                duration = get(historical_durations, test, est_per_test)
                est_remaining += max(0.0, duration - elapsed)
            end
            ## yet-to-run
            for test in tests
                haskey(running_tests, test) && continue
                # Test is in any completed test
                any(r -> test == r.test, results) && continue
                est_remaining += get(historical_durations, test, est_per_test)
            end

            eta_sec = est_remaining / jobs
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
    # (:finished, test_name, worker_id, record)
    # (:crashed, test_name, worker_id, test_time)
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

                    if msg_type == :started
                        test_name, wrkr = msg[2], msg[3]

                        # Optionally print verbose started message
                        if args.verbose !== nothing
                            clear_status()
                            print_test_started(wrkr, test_name, io_ctx)
                        end

                    elseif msg_type == :finished
                        test_name, wrkr, record = msg[2], msg[3], msg[4]

                        clear_status()
                        if anynonpass(record[])
                            print_test_failed(record, wrkr, test_name, io_ctx)
                        else
                            print_test_finished(record, wrkr, test_name, io_ctx)
                        end

                    elseif msg_type == :crashed
                        test_name, wrkr = msg[2], msg[3]

                        clear_status()
                        print_test_crashed(wrkr, test_name, io_ctx)
                    end
                end

                # After a while, display a status line
                if !done && time() - t0 >= 5 && (got_message || (time() - last_status_update[] >= 1))
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
            if isempty(running_tests) && length(results) >= length(tests)
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
    # After parallel-before-serial: stop extra workers so only one process is alive for
    # serial tests, but keep one parallel worker so we do not add a third addworker (ID_COUNTER).
    function drain_pool_leaving_one_worker!(pool, njobs)
        alive = PTRWorker[]
        for _ in 1:njobs
            p = take!(pool)
            if p !== nothing && Malt.isrunning(p)
                push!(alive, p)
            end
        end
        while length(alive) > 1
            Malt.stop(pop!(alive))
        end
        kept = isempty(alive) ? nothing : alive[1]
        if kept !== nothing
            put!(pool, kept)
        end
        for _ in 1:(njobs - (kept === nothing ? 0 : 1))
            put!(pool, nothing)
        end
    end
    try
        phases = test_phases
        for i in 1:length(phases)
            phase_tests, sem, shared_worker = phases[i]
            isempty(phase_tests) && continue
            # for serial phases, reserve one pool slot for the shared worker
            if !isnothing(shared_worker)
                shared_worker[] = take!(worker_pool)
            end
            @sync for test in phase_tests
                push!(worker_tasks, Threads.@spawn begin
                          local p = nothing
                          acquired = false
                          try
                              Base.acquire(sem)
                              acquired = true
                              p = !isnothing(shared_worker) ? shared_worker[] : take!(worker_pool)
                              Threads.atomic_sub!(tests_to_start, 1)

                              done && return

                              test_t0 = Base.@lock test_lock begin
                                  test_t0 = time()
                                  running_tests[test] = test_t0
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
                              if wrkr === nothing || !Malt.isrunning(wrkr)
                                  wrkr = p = addworker(; init_worker_code, io_ctx.color)
                              end

                              # run the test
                              put!(printer_channel, (:started, test, worker_id(wrkr)))
                              result = try
                                  Malt.remote_eval_wait(Main, wrkr.w, :(import ParallelTestRunner))
                                  Malt.remote_call_fetch(invokelatest, wrkr.w, runtest,
                                                         testsuite[test], test, init_code, test_t0)
                              catch ex
                                  if isa(ex, InterruptException)
                                      # the worker got interrupted, signal other tasks to stop
                                      stop_work()
                                      return
                                  end

                                  ex
                              end
                              test_t1 = time()
                              output = Base.@lock wrkr.io_lock String(take!(wrkr.io))
                              Base.@lock results_lock push!(results, (; test, result, output, test_t0, test_t1))

                              # act on the results
                              if result isa AbstractTestRecord
                                  put!(printer_channel, (:finished, test, worker_id(wrkr), result))
                                  if anynonpass(result[]) && args.quickfail !== nothing
                                      stop_work()
                                      return
                                  end

                                  if memory_usage(result) > max_worker_rss
                                      # the worker has reached the max-rss limit, recycle it
                                      # so future tests start with a smaller working set
                                      Malt.stop(wrkr)
                                  end
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

                              Base.@lock test_lock begin
                                  delete!(running_tests, test)
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
            # parallel workers are not stopped while serial tests remain (tests_to_start > 0);
            # drain before serial-after so only one worker is alive for the serial phase
            if isnothing(shared_worker) && i < length(phases)
                next_tests, _, next_sw = phases[i+1]
                if !isempty(next_tests) && !isnothing(next_sw)
                    drain_pool_leaving_one_worker!(worker_pool, jobs)
                end
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
    for (testname, result, output, _start, _stop) in results
        if !isempty(output)
            print(io_ctx.stdout, "\nOutput generated during execution of '")
            if result isa Exception || anynonpass(result.value)
                printstyled(io_ctx.stdout, testname; color=:red)
            else
                printstyled(io_ctx.stdout, testname; color=:normal)
            end
            println(io_ctx.stdout, "':")
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
            for (testname, result, _output, start, stop) in results
                push!(completed_tests, testname)

                if result isa AbstractTestRecord
                    testset = result[]::DefaultTestSet
                    historical_durations[testname] = stop - start
                else
                    # If this test raised an exception that means the test runner itself had some problem,
                    # so we may have hit a segfault, deserialization errors or something similar.
                    # Record this testset as Errored.
                    # One of Malt.TerminatedWorkerException, Malt.RemoteException, or ErrorException
                    @assert result isa Exception
                    testset = create_testset(testname; start, stop)
                    Test.record(testset, Test.Error(:nontest_error, testname, nothing, Base.ExceptionStack(NamedTuple[(;exception = result, backtrace = [])]), LineNumberNode(1)))
                end

                with_testset(testset) do
                    Test.record(o_ts, testset)
                end
            end

            # mark remaining or running tests as interrupted
            for test in tests
                (test in completed_tests) && continue
                testset = create_testset(test)
                Test.record(testset, Test.Error(:test_interrupted, test, nothing, Base.ExceptionStack(NamedTuple[(;exception = "skipped", backtrace = [])]), LineNumberNode(1)))
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
    save_test_history(mod, historical_durations)

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
        printstyled(io_ctx.stdout, "    SUCCESS\n"; bold=true, color=:green)
    else
        printstyled(io_ctx.stderr, "    FAILURE\n\n"; bold=true, color=:red)
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

end
