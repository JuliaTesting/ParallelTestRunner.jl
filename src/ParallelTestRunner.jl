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
using StyledStrings: Face, @styled_str, addface!

function anynonpass(ts::Test.AbstractTestSet)
    @static if VERSION >= v"1.13.0-DEV.1037"
        return Test.anynonpass(ts)
    else
        Test.get_test_counts(ts)
        return ts.anynonpass
    end
end

# Thin compatibility shim for using `Lockable` also in Julia v1.10
if VERSION >= v"1.11.0-DEV.1568"
    const Lockable = Base.Lockable
else
    # Adapted from <https://github.com/JuliaLang/julia/pull/52898>.
    struct Lockable{T, L <: Base.AbstractLock}
        value::T
        lock::L
    end

    Lockable(value) = Lockable(value, ReentrantLock())
    Base.getindex(l::Lockable) = (Base.assert_havelock(l.lock); l.value)

    Base.lock(l::Lockable) = Base.lock(l.lock)
    Base.trylock(l::Lockable) = Base.trylock(l.lock)
    Base.unlock(l::Lockable) = Base.unlock(l.lock)
end

const ID_COUNTER = Threads.Atomic{Int}(1)

# Thin wrapper around Malt.Worker, to handle the stdio loop differently.
struct PTRWorker <: Malt.AbstractWorker
    w::Malt.Worker
    io::Lockable{IOBuffer, ReentrantLock}
    id::Int
end

function PTRWorker(; exename=Base.julia_cmd()[1], exeflags=String[], env=String[])
    io = Lockable(IOBuffer())
    wrkr = Malt.Worker(; exename, exeflags, env, monitor_stdout=false, monitor_stderr=false)
    stdio_loop(wrkr, io)
    id = Threads.atomic_add!(ID_COUNTER, 1)
    return PTRWorker(wrkr, io, id)
end

worker_id(wrkr::PTRWorker) = wrkr.id
Malt.isrunning(wrkr::PTRWorker) = Malt.isrunning(wrkr.w)
Malt.stop(wrkr::PTRWorker) = Malt.stop(wrkr.w)

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
        alloc_align, rss_align, max_worker_rss, Ref(:ptr_error)
    )
end


function print_header(::Type{<:AbstractTestRecord}, ctx::TestIOContext, testgroupheader, workerheader)
    lock(ctx.lock)
    try
        # header top
        name_pad_str = " "^(ctx.name_align + textwidth(testgroupheader) - 3) * " │ "
        init_str = ctx.verbose ? "   Init   │" : ""
        compile_str = VERSION >= v"1.11" && ctx.verbose ? " Compile │" : ""
        header_top_str = styled"{ptr_default:$name_pad_str  Test   │$init_str$compile_str ──────────────── CPU ──────────────── │}\n"
        print(ctx.stdout, header_top_str)

        # header bottom
        workerheaderstr = lpad(workerheader, ctx.name_align - textwidth(testgroupheader) + 1)
        init_time_str = ctx.verbose ? " time (s) │" : ""
        comp_time_str = VERSION >= v"1.11" && ctx.verbose ? "   (%)   │" : ""
        bottom_header_str = styled"{ptr_default:$testgroupheader$workerheaderstr │ time (s) │$init_time_str$comp_time_str GC (s) │ GC % │ Alloc (MB) │ RSS (MB) │}\n"
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
        out_str = styled"{ptr_default:$(test)$padded_wrkr │}{ptr_light:$(\" \"^ctx.elapsed_align) started at $(now())}\n"
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
        mem_face = mem_use > ctx.max_worker_rss ? :ptr_warn : :ptr_default
        rss_str = @sprintf("%5.2f", mem_use / 2^20)
        padded_rss = lpad(rss_str, ctx.rss_align, " ")

        out_str = styled"{ptr_default:$test$padded_wrkr │ $padded_time │ $padded_init_time$padded_comp_time$padded_gc │ $padded_percent │ $padded_alloc │ {$mem_face:$padded_rss} │\n}"
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

# Adapted from `Malt._stdio_loop`
function stdio_loop(worker::Malt.Worker, io::Lockable)
    Threads.@spawn while !eof(worker.stdout) && Malt.isrunning(worker)
        try
            bytes = readavailable(worker.stdout)
            @lock io write(io[], bytes)
        catch
            break
        end
    end
    Threads.@spawn while !eof(worker.stderr) && Malt.isrunning(worker)
        try
            bytes = readavailable(worker.stderr)
            @lock io write(io[], bytes)
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

#
# memory statistics and pressure monitoring
#

# Mirror of the first 24 fields (rev0 + rev1) of `struct vm_statistics64` from macOS'
# `<mach/vm_statistics.h>`. All `*_count` fields are instantaneous page counts, the
# `UInt64` fields without a `_count` suffix are monotonic lifetime counters.
# `host_statistics64` only fills as many words as we ask for, so mirroring a prefix of
# the newer, longer kernel struct is safe. The struct itself is defined on every
# platform so that reports can be constructed (and tested) anywhere; only sampling it
# from the kernel is macOS-specific.
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

vm_page_size() = Int(ccall(:jl_getpagesize, Clong, ()))

# Pages the runner considers available for new workers: free + inactive + purgeable
# + compressor. This is optimistic under pressure since compressor pages cost CPU
# (or disk) to reclaim; see `MemoryPressureReport` for the dynamic picture.
function available_pages(vms::VmStatistics64)
	return Int(vms.free_count) + Int(vms.inactive_count) + Int(vms.purgeable_count) + Int(vms.compressor_page_count)
end

"""
    MemoryPressureThresholds(; kwargs...)

Thresholds used to decide whether a [`MemoryPressureReport`](@ref) is `:normal` or
`:contentious`. All rates are in bytes per second averaged over the sampling interval.
A report is contentious as soon as any one threshold is exceeded.

- `swap_rate`: swap traffic (`swapins + swapouts`) above this is contentious.
  Defaults to `0.0`, i.e. any swap activity at all, since swapping compressor segments
  to disk is the most severe form of thrashing on macOS.
- `compressor_churn_rate`: `compressions + decompressions` above this is contentious.
  Pages being compressed and immediately decompressed means the compressor is churning
  working-set memory rather than cold data (default: 64 MiB/s).
- `pageout_rate`: `pageouts` above this is contentious (default: 64 MiB/s).
- `available_fraction`: available memory below this fraction of physical memory is
  contentious (default: `0.05`). Availability uses the same formula as the runner
  uses to pick the default number of jobs.
"""
Base.@kwdef struct MemoryPressureThresholds
	swap_rate::Float64 = 0.0
	compressor_churn_rate::Float64 = 64 * 2.0^20
	pageout_rate::Float64 = 64 * 2.0^20
	available_fraction::Float64 = 0.05
end

"""
    MemoryPressureReport

One sample produced by a [`MemoryPressureMonitor`](@ref), describing the state of the
macOS virtual memory system over the interval since the previous sample. Instantaneous
quantities are in bytes; rates are in bytes per second, obtained by differencing the
kernel's lifetime page counters and scaling by the page size.

Fields:

- `time`: wall-clock time of the sample, as returned by `time()`.
- `interval`: seconds since the previous sample.
- `page_size`: VM page size in bytes.
- `total`: physical memory.
- `available`: free + inactive + purgeable + compressor memory. Same formula as the
  runner uses to pick the default number of jobs.
- `free`, `inactive`, `purgeable`, `wired`, `internal` (anonymous), `external`
  (file-backed): resident memory by category.
- `compressor`: physical memory used to hold compressed pages.
- `uncompressed_in_compressor`: logical size of the data held in the compressor.
  Comparing this to `compressor` gives the effective compression ratio.
- `compression_rate`, `decompression_rate`: compressor traffic. Both high at the same
  time is the first sign of thrashing on macOS.
- `swapin_rate`, `swapout_rate`: compressor segments moved to and from disk. Any
  sustained value here is severe thrashing.
- `pagein_rate`, `pageout_rate`: pages read from and written to backing store.
- `reactivation_rate`: inactive pages promoted back to active because they were used
  again, i.e. the reclaim pipeline failing to find truly cold memory.
- `fault_rate`: all page faults, including soft faults. Mostly useful as a denominator.
- `status`: `:normal` or `:contentious`, decided by [`MemoryPressureThresholds`](@ref).
- `reasons`: human-readable explanations for a `:contentious` status; empty otherwise.
"""
struct MemoryPressureReport
	time::Float64
	interval::Float64
	page_size::Int

	total::Int
	available::Int
	free::Int
	inactive::Int
	purgeable::Int
	wired::Int
	internal::Int
	external::Int
	compressor::Int
	uncompressed_in_compressor::Int

	compression_rate::Float64
	decompression_rate::Float64
	swapin_rate::Float64
	swapout_rate::Float64
	pagein_rate::Float64
	pageout_rate::Float64
	reactivation_rate::Float64
	fault_rate::Float64

	status::Symbol
	reasons::Vector{String}
end

# Build a report from two consecutive snapshots.
function MemoryPressureReport(t0::Real, prev::VmStatistics64, t1::Real, cur::VmStatistics64;
                              thresholds::MemoryPressureThresholds = MemoryPressureThresholds(),
                              page_size::Integer = vm_page_size(),
                              total::Integer = Sys.total_memory())
	interval = Float64(t1 - t0)
	interval > 0 || throw(ArgumentError("sample times must be strictly increasing"))
	bytes(pages) = Int(pages) * Int(page_size)
	# lifetime counters are monotonic, but guard against a wrapped or reset counter
	rate(f) = max(0.0, Float64(Int(getfield(cur, f)) - Int(getfield(prev, f)))) * page_size / interval

	available = bytes(available_pages(cur))
	compression_rate = rate(:compressions)
	decompression_rate = rate(:decompressions)
	swapin_rate = rate(:swapins)
	swapout_rate = rate(:swapouts)
	pageout_rate = rate(:pageouts)

	reasons = String[]
	swap = swapin_rate + swapout_rate
	if swap > thresholds.swap_rate
		push!(reasons, "swap traffic at $(Base.format_bytes(round(Int, swap)))/s")
	end
	churn = compression_rate + decompression_rate
	if churn > thresholds.compressor_churn_rate
		push!(reasons, "compressor churn at $(Base.format_bytes(round(Int, churn)))/s")
	end
	if pageout_rate > thresholds.pageout_rate
		push!(reasons, "pageouts at $(Base.format_bytes(round(Int, pageout_rate)))/s")
	end
	if available < thresholds.available_fraction * total
		pct = round(100 * available / total; digits=1)
		push!(reasons, "only $(Base.format_bytes(available)) ($pct%) of memory available")
	end
	status = isempty(reasons) ? :normal : :contentious

	return MemoryPressureReport(
		Float64(t1), interval, Int(page_size),
		Int(total), available,
		bytes(cur.free_count), bytes(cur.inactive_count), bytes(cur.purgeable_count),
		bytes(cur.wire_count), bytes(cur.internal_page_count), bytes(cur.external_page_count),
		bytes(cur.compressor_page_count), bytes(cur.total_uncompressed_pages_in_compressor),
		compression_rate, decompression_rate, swapin_rate, swapout_rate,
		rate(:pageins), pageout_rate, rate(:reactivations), rate(:faults),
		status, reasons,
	)
end

function Base.show(io::IO, r::MemoryPressureReport)
	fmt(x) = Base.format_bytes(round(Int, x))
	print(io, "MemoryPressureReport(", r.status,
	      ": available ", fmt(r.available), "/", fmt(r.total),
	      ", compressor ", fmt(r.compressor),
	      ", compress ", fmt(r.compression_rate), "/s",
	      ", decompress ", fmt(r.decompression_rate), "/s",
	      ", swap ", fmt(r.swapin_rate + r.swapout_rate), "/s",
	      ", pageout ", fmt(r.pageout_rate), "/s)")
end

function Base.show(io::IO, ::MIME"text/plain", r::MemoryPressureReport)
	fmt(x) = Base.format_bytes(round(Int, x))
	println(io, "MemoryPressureReport (", r.status, ") over ", round(r.interval; digits=2), " s")
	println(io, "  available:      ", fmt(r.available), " of ", fmt(r.total))
	println(io, "  free/inactive:  ", fmt(r.free), " / ", fmt(r.inactive))
	println(io, "  wired/internal: ", fmt(r.wired), " / ", fmt(r.internal))
	println(io, "  external:       ", fmt(r.external))
	println(io, "  compressor:     ", fmt(r.compressor), " holding ", fmt(r.uncompressed_in_compressor))
	println(io, "  compressions:   ", fmt(r.compression_rate), "/s, decompressions ", fmt(r.decompression_rate), "/s")
	println(io, "  swap:           in ", fmt(r.swapin_rate), "/s, out ", fmt(r.swapout_rate), "/s")
	println(io, "  paging:         in ", fmt(r.pagein_rate), "/s, out ", fmt(r.pageout_rate), "/s")
	print(io,   "  reactivations:  ", fmt(r.reactivation_rate), "/s, faults ", fmt(r.fault_rate), "/s")
	for reason in r.reasons
		print(io, "\n  ! ", reason)
	end
end

# One-line summary of a report for the runner's status bar. Plain text so it can be
# truncated to the terminal width; the caller colors it when contentious.
function memory_status_line(r::MemoryPressureReport)
	fmt(x) = Base.format_bytes(round(Int, x))
	if r.status === :contentious
		return "Memory:   contentious │ " * join(r.reasons, ", ")
	else
		return "Memory:   normal │ available $(fmt(r.available)) │ compressor $(fmt(r.compressor)) " *
		       "(in $(fmt(r.compression_rate))/s, out $(fmt(r.decompression_rate))/s) │ " *
		       "swap $(fmt(r.swapin_rate + r.swapout_rate))/s"
	end
end

"""
    MemoryPressureMonitor

Handle returned by [`start_memory_pressure_monitor`](@ref). Iterate `monitor.channel`
to receive [`MemoryPressureReport`](@ref)s; call [`stop_memory_pressure_monitor`](@ref)
to stop sampling, which also closes the channel once the last report has been delivered.
"""
mutable struct MemoryPressureMonitor
	channel::Channel{MemoryPressureReport}
	timer::Timer
	task::Task
	interval::Float64
	thresholds::MemoryPressureThresholds
end

"""
    stop_memory_pressure_monitor(monitor::MemoryPressureMonitor)

Stop sampling and close `monitor.channel`. Reports already in the channel remain
available to consumers. Returns once the sampling task has exited.
"""
function stop_memory_pressure_monitor(monitor::MemoryPressureMonitor)
	close(monitor.timer)
	wait(monitor.task)
	return
end

"""
    start_memory_pressure_monitor(; interval = 5.0,
                                    thresholds = MemoryPressureThresholds(),
                                    channel = Channel{MemoryPressureReport}(64),
                                    drop_oldest = true)

Start a background task that samples the macOS virtual memory statistics every
`interval` seconds and puts a [`MemoryPressureReport`](@ref) into `channel`. Each report
covers the interval since the previous sample and carries a `:normal` or `:contentious`
verdict, decided by `thresholds`.

A baseline sample is taken immediately, so the first report arrives after `interval`
seconds. If nobody drains the channel and it fills up, the oldest report is discarded to
make room when `drop_oldest` is `true`; otherwise the sampler blocks until a consumer
takes a report. Closing the channel from the consumer side stops the monitor.

Returns a [`MemoryPressureMonitor`](@ref). Stop it with
[`stop_memory_pressure_monitor`](@ref).

```julia
monitor = ParallelTestRunner.start_memory_pressure_monitor(; interval = 2.0)
consumer = @async for report in monitor.channel
    report.status === :contentious && @warn "memory pressure" report
end
runtests(MyPackage, ARGS)
ParallelTestRunner.stop_memory_pressure_monitor(monitor)
wait(consumer)
```

Only available on macOS; on other platforms this throws an `ErrorException`.
"""
function start_memory_pressure_monitor end

@static if Sys.isapple()

const HOST_VM_INFO64 = Cint(4)
const KERN_SUCCESS = Cint(0)

# Take a snapshot of the kernel's VM statistics.
function vm_statistics64()
	vms = VmStatistics64()
	host = @ccall mach_host_self()::UInt32
	count = Ref(UInt32(sizeof(VmStatistics64) ÷ sizeof(Int32)))
	kr = GC.@preserve vms begin
		@ccall host_statistics64(host::UInt32, HOST_VM_INFO64::Cint,
		                         pointer_from_objref(vms)::Ptr{Cvoid},
		                         count::Ref{UInt32})::Cint
	end
	# `mach_host_self` hands out a new send right on every call; release it so a
	# long-running sampler does not accumulate references.
	task = unsafe_load(cglobal(:mach_task_self_, UInt32))
	@ccall mach_port_deallocate(task::UInt32, host::UInt32)::Cint
	kr == KERN_SUCCESS || error("host_statistics64 failed with kern_return_t = $kr")
	return vms
end

available_memory() = available_pages(vm_statistics64()) * vm_page_size()

function start_memory_pressure_monitor(; interval::Real = 5.0,
                                         thresholds::MemoryPressureThresholds = MemoryPressureThresholds(),
                                         channel::Channel{MemoryPressureReport} = Channel{MemoryPressureReport}(64),
                                         drop_oldest::Bool = true)
	interval > 0 || throw(ArgumentError("interval must be positive, got $interval"))
	page_size = vm_page_size()
	total = Sys.total_memory()
	timer = Timer(interval; interval)
	task = @async begin
		t0, prev = time(), vm_statistics64()
		try
			while isopen(timer) && isopen(channel)
				try
					wait(timer)
				catch ex
					# closing the timer wakes waiters with an EOFError
					ex isa EOFError && break
					rethrow()
				end
				t1, cur = time(), vm_statistics64()
				report = MemoryPressureReport(t0, prev, t1, cur; thresholds, page_size, total)
				t0, prev = t1, cur
				try
					if drop_oldest
						lock(channel)
						try
							if Base.n_avail(channel) >= channel.sz_max
								take!(channel)
							end
						finally
							unlock(channel)
						end
					end
					put!(channel, report)
				catch ex
					# the consumer closed the channel; we're done
					ex isa InvalidStateException && break
					rethrow()
				end
			end
		finally
			close(timer)
			close(channel)
		end
	end
	return MemoryPressureMonitor(channel, timer, task, Float64(interval), thresholds)
end

else

available_memory() = Sys.free_memory()

vm_statistics64() = error("VM statistics sampling is only supported on macOS")

start_memory_pressure_monitor(; kwargs...) =
	error("memory pressure monitoring is only supported on macOS")

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

# Struct used in runtests to sort failed tests before successful ones
struct TestHistoryEntry
    duration::Float64
    failed::Bool
end
# successful tests < failed tests, so when reversing the
# sort they are also in proper descending order
Base.isless(a::TestHistoryEntry, b::TestHistoryEntry) = a.failed == b.failed ? a.duration < b.duration : a.failed < b.failed

# Historical test duration database
function get_history_file(mod::Module)
    # History file version. Change when modifying the history format
    hist_ver = "v2"
    scratch_dir = @get_scratch!("durations")
    return joinpath(scratch_dir, "v$(VERSION.major).$(VERSION.minor)", hist_ver, "$(nameof(mod)).jls")
end
function load_test_history(mod::Module)
    history_file = get_history_file(mod)
    if isfile(history_file)
        try
            return deserialize(history_file)::Tuple{Dict{String, Float64}, Set{String}}
        catch e
            @warn "Failed to load test history from $history_file" exception=e
        end
    end
    return (Dict{String, Float64}(), Set{String}())
end
function save_test_history(mod::Module, history::Tuple{Dict{String, Float64}, Set{String}})
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

    # don't mutate the caller's vector; multiple workers may share a default
    worker_env = copy(env)
    push!(worker_env, "JULIA_NUM_THREADS" => "1")
    # Malt already sets OPENBLAS_NUM_THREADS to 1
    push!(worker_env, "OPENBLAS_NUM_THREADS" => "1")
    wrkr = PTRWorker(; exename, exeflags, env = worker_env)
    # make ParallelTestRunner available to `init_worker_code`; users commonly
    # need it to reference `AbstractTestRecord`, `execute`, etc. when defining
    # custom record types.
    Malt.remote_eval_wait(Main, wrkr.w, :(import ParallelTestRunner))
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
        # only accept the exact flag or `--flag=value`, so that flags sharing a
        # prefix (e.g. `--list` and `--listing`) don't capture each other
        if f == flag || startswith(f, flag * "=")
            # Check if it's just `--flag` or if it's `--flag=foo`
            val = if f == flag
                typ === Nothing ||
                    error("Option `$flag` requires a value (use `$flag=<value>`)")
                nothing
            else
                _, value = split(f, '='; limit = 2)
                if typ === Nothing || typ <: AbstractString
                    value
                else
                    parsed = tryparse(typ, value)
                    parsed === nothing &&
                        error("Invalid value `$value` for option `$flag` (expected a value of type $typ)")
                    parsed
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
        usage *= "\nPrefix your argument with '!' to instead exclude those tests"
        println(usage)
        exit(0)
    end

    jobs = extract_flag!(args, "--jobs"; typ = Int)
    verbose = extract_flag!(args, "--verbose")
    quickfail = extract_flag!(args, "--quickfail")
    list = extract_flag!(args, "--list")

    # boolean flags don't take values
    for (flag, val) in (("--verbose", verbose), ("--quickfail", quickfail), ("--list", list))
        if val isa Some && something(val) !== nothing
            error("Option `$flag` does not take a value")
        end
    end

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

When `--list` is requested, the full `testsuite` is preserved and `false` is
returned so that callers skip any conditional filtering of their own: listing
should show every available test, not just the ones that would run by default.
"""
function filter_tests!(testsuite::Dict{<:AbstractString, <:Any}, args::ParsedArgs)
    # when only listing tests, keep the full catalog and let the caller skip its
    # own filtering, so that every available test is shown
    args.list !== nothing && return false

    # the user did not request specific tests, so let the caller do its own filtering
    isempty(args.positionals) && return true

    exclude_idxs = startswith.(args.positionals, "!")
    exclude_args = lstrip.(args.positionals[exclude_idxs], Ref(['!']))
    include_args = args.positionals[.!exclude_idxs]

    # only select tests matching positional arguments
    tests = collect(keys(testsuite))
    if !isempty(include_args)
        for test in tests
            if !any(arg -> startswith(test, arg), include_args)
                delete!(testsuite, test)
            end
        end
    end

    # remove explicitly excluded tests
    included_tests = collect(keys(testsuite))
    if !isempty(exclude_args)
        for test in included_tests
            if any(arg -> startswith(test, arg), exclude_args)
                delete!(testsuite, test)
            end
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
             RecordType::Type{<:AbstractTestRecord} = TestRecord,
             custom_args = (;),
             exename = nothing,
             exeflags = nothing,
             env = Vector{Pair{String, String}}(),
             stdout = Base.stdout,
             stderr = Base.stderr,
             max_worker_rss = get_max_worker_rss(),
             serial = String[],
             serial_position::Symbol = :before,
             recycle_on_failure::Bool = false,
             retries::Integer = 0,
             monitor_memory::Bool = true)
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
- `serial`: A vector of test names (keys of `testsuite`) that should be run one at a time
  instead of in parallel.
- `serial_position`: When to run serial tests relative to the parallel batch.
  Must be `:before` (default) or `:after`.
- `recycle_on_failure`: Whether to recycle a worker after any test that did not pass
  (default: `false`). See the Failure Handling section below.
- `retries`: How many times to re-run tests that did not pass after the main run completes
  (default: `0`). See the Failure Handling section below.
- `monitor_memory`: Whether to sample the kernel's virtual memory counters during the run
  and warn when the machine is thrashing (default: `true`). Only active on macOS; see the
  Memory Management section below.

## Command Line Options

- `--help`: Show usage information and exit
- `--list`: List all available test files and exit
- `--verbose`: Print more detailed information during test execution
- `--quickfail`: Stop the entire test run as soon as any test fails
- `--jobs=N`: Use N worker processes (default: based on CPU threads and available memory)
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

On macOS, with `monitor_memory = true` (the default), the kernel's virtual memory counters
are sampled every 5 seconds while tests run. The latest sample is shown as a `Memory:`
line in the status bar below the progress line, flagged as contentious when the machine
is thrashing (swap traffic, heavy compressor churn or pageouts, or very little memory
left), and a summary is printed at the end of the run if any sample was contentious.
This helps distinguish a run that merely uses a lot of memory from one where too many
parallel jobs are fighting over it. See
[`start_memory_pressure_monitor`](@ref) to consume the same reports programmatically.

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
                  recycle_on_failure::Bool = false,
                  retries::Integer = 0,
                  monitor_memory::Bool = true,
                  )
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
    historical_durations, historical_failures = load_test_history(mod)
    get_historical_duration(test) = TestHistoryEntry(get(historical_durations, test, Inf), test in historical_failures)
    sort!(tests, by = x -> get_historical_duration(x), rev = true)

    return _runtests(
        mod, args;
        testsuite,
        tests,
        historical_durations,
        historical_failures,
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
        recycle_on_failure,
        retries,
        monitor_memory,
    )
end

# Helper function, to be used for testing, with `tests` already sorted.
function _runtests(mod::Module, args::ParsedArgs;
                   testsuite::Dict{String,Expr} = find_tests(pwd()),
                   tests::Vector{String},
                   historical_durations::Dict{String, Float64} = Dict{String, Float64}(),
                   historical_failures::Set{String} = Set{String}(),
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
                   recycle_on_failure::Bool = false,
                   retries::Integer = 0,
                   monitor_memory::Bool = true,
                   # the two below are only meant for testing the memory monitor integration
                   memory_interval::Real = 5.0,
                   memory_thresholds::MemoryPressureThresholds = MemoryPressureThresholds(),
                   )

    # partition into serial and parallel groups
    serial_tests, parallel_tests = partition_tests(tests, serial)

    # determine parallelism
    _jobs = something(args.jobs, default_njobs())
    jobs = clamp(_jobs, 1, max(1, length(parallel_tests)))
    worker_pool = Channel{Union{Nothing, PTRWorker}}(jobs)
    for _ in 1:jobs
        put!(worker_pool, nothing)
    end
    println(stdout, "Running $(length(tests)) tests using $jobs parallel jobs. If this is too many concurrent jobs, specify the `--jobs=N` argument to the tests, or set the `JULIA_CPU_THREADS` environment variable.")
    if !isempty(serial_tests)
        println(stdout, "  $(length(serial_tests)) serial test(s) will run $(serial_position) the parallel batch.")
    end
    monitor_memory = monitor_memory && Sys.isapple()
    if !isnothing(args.verbose)
        println(stdout, styled"Available memory: {bold:$(Base.format_bytes(available_memory()))}; Max worker RSS: {bold:$(Base.format_bytes(max_worker_rss))}")
        if monitor_memory
            println(stdout, styled"Monitoring memory pressure every {bold:$(memory_interval) s}")
        end
    end

    t0 = time()
    results = Lockable([])
    running_tests = Lockable(Dict{String, Float64}())  # test => start_time

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

    # memory pressure state, fed by the printer task and shown in the status bar
    latest_pressure = Ref{Union{Nothing, MemoryPressureReport}}(nothing)
    pressure_samples = Ref(0)
    pressure_contentious = Ref(0)

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

            est_remaining = 0.0
            ## currently-running
            for (test, start_time) in running_snapshot
                elapsed = time() - start_time
                duration = get(historical_durations, test, est_per_test)
                est_remaining += max(0.0, duration - elapsed)
            end
            ## yet-to-run
            for test in tests
                haskey(running_snapshot, test) && continue
                # Test is in any completed test
                any(r -> test == r.test, results_snapshot) && continue
                est_remaining += get(historical_durations, test, est_per_test)
            end

            eta_sec = est_remaining / jobs
            eta_mins = round(Int, eta_sec / 60)
            line3 *= " │ ETA: ~$eta_mins min"
        end

        # line 4 (optional): memory pressure
        report = latest_pressure[]
        line4 = if report === nothing
            nothing
        else
            line = truncate_line(memory_status_line(report), max_width)
            report.status === :contentious ? styled"{ptr_warn:$line}" : line
        end

        # only display the status bar on actual terminals
        # (but make sure we cover this code in CI)
        if io_ctx.stdout isa Base.TTY
            clear_status()
            println(io_ctx.stdout, line1)
            println(io_ctx.stdout, line2)
            if line4 === nothing
                print(io_ctx.stdout, line3)
                status_lines_visible[] = 3
            else
                println(io_ctx.stdout, line3)
                print(io_ctx.stdout, line4)
                status_lines_visible[] = 4
            end
            flush(io_ctx.stdout)
        end
    end

    # Message types for the printer channel
    # (:started, test_name, worker_id)
    # (:finished, test_name, worker_id, record)
    # (:crashed, test_name, worker_id, test_time)
    # (:retry, tests_n, retry_n)
    # (:nonpass_face, face)
    # (:memory_pressure, report)
    printer_channel = Channel{Tuple}(100)

    # memory pressure monitoring (macOS only): reports are routed through the printer so
    # that warnings land between result rows instead of in the middle of one
    memory_monitor = nothing
    memory_forwarder = nothing
    if monitor_memory
        memory_monitor = start_memory_pressure_monitor(; interval = memory_interval,
                                                         thresholds = memory_thresholds)
        memory_forwarder = @async for report in memory_monitor.channel
            put!(printer_channel, (:memory_pressure, report))
        end
    end

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

                        clear_status()
                        if anynonpass(record[])
                            print_test_failed(record, wrkr, test_name, io_ctx)
                        else
                            print_test_finished(record, wrkr, test_name, io_ctx)
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
                            println(io_ctx.stdout, styled"{ptr_default:Retrying $tests_n failed test$(tests_n > 1 ? \"s\" : \" \") ($retry_n)}")
                            flush(io_ctx.stdout)
                        finally
                            unlock(io_ctx.lock)
                        end

                    elseif msg_type === :nonpass_face
                        # routed through the channel rather than set directly so it lands
                        # in order with the results it applies to: the coordinator flips it
                        # while this task may still be draining the previous round
                        io_ctx.nonpass_face[] = msg[2]

                    elseif msg_type === :memory_pressure
                        # shown by `update_status` below; no line of its own so that a
                        # long stretch of pressure doesn't flood the results table
                        report = msg[2]
                        latest_pressure[] = report
                        pressure_samples[] += 1
                        report.status === :contentious && (pressure_contentious[] += 1)
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
                          if wrkr === nothing || !Malt.isrunning(wrkr)
                              wrkr = p = addworker(; init_worker_code, io_ctx.color,
                                                   exename, exeflags, env)
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
                              elseif (recycle_on_failure || retry_mode) && anynonpass(result[])
                                  # a failing test may have left the worker in a bad state
                                  # (e.g. a wedged GPU driver whose every later allocation
                                  # fails); recycle it so future tests get a fresh process
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

    # stop sampling memory pressure; the forwarder exits once the monitor's channel
    # is drained, so every report reaches the printer before it is closed below
    if memory_monitor !== nothing
        stop_memory_pressure_monitor(memory_monitor)
        wait(memory_forwarder)
    end

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
                :ptr_default
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
                    historical_durations[testname] = stop - start
                    # push to historical_failures on failure and delete on success
                    push_or_delete! = anynonpass(result[]) ? push! : delete!
                    push_or_delete!(historical_failures, testname)
                    result[]
                else
                    # If this test raised an exception that means the test runner itself had some problem,
                    # so we may have hit a segfault, deserialization errors or something similar.
                    # Record this testset as Errored.
                    # One of Malt.TerminatedWorkerException, Malt.RemoteException, or ErrorException
                    @assert result isa Exception
                    err_ts = create_testset(testname; start, stop)
                    Test.record(err_ts, Test.Error(:nontest_error, testname, nothing, Base.ExceptionStack(NamedTuple[(;exception = result, backtrace = Union{Ptr{Nothing}, Base.InterpreterIP}[])]), LineNumberNode(1)))
                    push!(historical_failures, testname)
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
    save_test_history(mod, (historical_durations, historical_failures))

    # summarize memory pressure, if the machine was thrashing at any point
    if pressure_contentious[] > 0
        println(io_ctx.stdout)
        println(io_ctx.stdout, styled"{ptr_warn:Memory pressure was contentious in $(pressure_contentious[]) of $(pressure_samples[]) samples. Consider lowering `--jobs=N`, moving large tests to `serial`, or lowering `max_worker_rss`.}")
    end

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
    addface!(:ptr_default => Face(inherit=:default))
    addface!(:ptr_warn => Face(inherit=:yellow))
    addface!(:ptr_error => Face(inherit=:red))
    addface!(:ptr_light => Face(inherit=:light))
end

end
