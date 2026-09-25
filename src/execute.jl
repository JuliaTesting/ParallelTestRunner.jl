# Worker-side test execution: this code runs inside the spawned worker processes

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
