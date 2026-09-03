@testset "basic use" begin
    io = IOBuffer()
    io_color = IOContext(io, :color => true)
    testsuite = find_tests(joinpath(@__DIR__, "sample_tests"))
    runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=io_color, stderr=io_color)
    str = String(take!(io))

    println()
    println("Showing the output of one test run:")
    println("-"^80)
    print(str)
    println("-"^80)
    println()

    @test contains(str, "SUCCESS")

    # --verbose output
    @test contains(str, r"basic .+ started at")

    @test contains(str, "time (s)")

    @test contains(str, "Available memory:")
    @test contains(str, "Max worker RSS:")
    @test contains(str, "Init")

    # compile time as part of the struct not available before 1.11
    if VERSION >= v"1.11"
        @test contains(str, "Compile")
        @test contains(str, "(%)")
    end

    @test isfile(ParallelTestRunner.get_history_file(ParallelTestRunner))
end

@testset "default njobs" begin
    @test ParallelTestRunner.default_njobs(; cpu_threads=4, free_memory=UInt64(2) ^ 28) == 1
    @test ParallelTestRunner.default_njobs(; cpu_threads=4, free_memory=UInt64(2) ^ 30) == 1
    @test ParallelTestRunner.default_njobs(; cpu_threads=4, free_memory=UInt64(2) ^ 31) == 1
    @test ParallelTestRunner.default_njobs(; cpu_threads=4, free_memory=UInt64(2) ^ 32) == 2
    @test ParallelTestRunner.default_njobs(; cpu_threads=4, free_memory=UInt64(2) ^ 33) == 4
    @test ParallelTestRunner.default_njobs(; cpu_threads=4, free_memory=UInt64(2) ^ 34) == 4
end

@testset "subdir use" begin
    d = joinpath(@__DIR__, "sample_tests")
    testsuite = find_tests(d)
    @test last(testsuite["basic"].args) == joinpath(d, "basic.jl")
    @test last(testsuite["subdir/subdir_test"].args) == joinpath(d, "subdir", "subdir_test.jl")
end

@testset "custom tests" begin
    testsuite = Dict(
        "custom" => quote
            @test true
        end
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test !contains(str, r"basic .+ started at")
    @test contains(str, r"custom .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "test start order" begin
    # Tests must start in the given order, regardless of the
    # number of threads of the host Julia process (issue #139).
    testsuite = Dict(
        "sort$(n)" => :(@test true)
        for n in 1:5
    )
    tests = ["sort$(n)" for n in 1:length(testsuite)]

    io = IOBuffer()
    # with a single job, tests start strictly in acquisition order
    ParallelTestRunner._runtests(
        ParallelTestRunner, parse_args(["--jobs=1", "--verbose"]);
        testsuite,
        tests,
        stdout=io,
        stderr=io,
    )

    str = String(take!(io))
    @test contains(str, "SUCCESS")
    started_at = map(tests) do name
        m = match(Regex("$(name) .+ started at"), str)
        @test m !== nothing
        m === nothing ? typemax(Int) : m.offset
    end
    @test issorted(started_at)
end

@testset "init code" begin
    init_code = quote
        using Test
        should_be_defined() = true

        macro should_also_be_defined()
            return :(true)
        end
    end
    testsuite = Dict(
        "custom" => quote
            @test should_be_defined()
            @test @should_also_be_defined()
        end
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; init_code, testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test contains(str, r"custom .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "init worker code" begin
    init_worker_code = quote
        should_be_defined() = true

        macro should_also_be_defined()
            return :(true)
        end
    end
    init_code = quote
        using Test
        import ..should_be_defined, ..@should_also_be_defined
    end

    testsuite = Dict(
        "custom" => quote
            @test should_be_defined()
            @test @should_also_be_defined()
        end
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; init_code, init_worker_code, testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test contains(str, r"custom .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "custom record type" begin
    # Custom record wraps the default `TestRecord` and adds one field. It must
    # be defined on both the main process and every worker (via
    # init_worker_code) because the record crosses the Malt serialization
    # boundary.
    init_worker_code = quote
        using ParallelTestRunner: TestRecord
        struct MyRecord <: ParallelTestRunner.AbstractTestRecord
            base::TestRecord
            extra::String
        end
        function ParallelTestRunner.execute(
            ::Type{MyRecord}, mod::Module, f, name, start_time, custom_args,
            )
            base = ParallelTestRunner.execute(TestRecord, mod, f, name, start_time, custom_args)
            MyRecord(base, custom_args.tag)
        end
        function ParallelTestRunner.print_test_finished(
            record::MyRecord, wrkr, test, ctx::ParallelTestRunner.TestIOContext,
            )
            lock(ctx.lock)
            try
                println(ctx.stdout, "EXTRA[$test]=$(record.extra)")
                flush(ctx.stdout)
            finally
                unlock(ctx.lock)
            end
        end
    end

    # Also define on the main process so the record deserializes: it has to live in `Main`,
    # as on the workers, since this test file itself runs in a sandbox module.
    Core.eval(Main, init_worker_code)

    testsuite = Dict(
        "custom" => quote
            @test 1 + 1 == 2
        end,
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; testsuite,
             init_worker_code, RecordType = Main.MyRecord,
             custom_args = (; tag = "hello"),
             stdout = io, stderr = io)
    str = String(take!(io))

    @test contains(str, "EXTRA[custom]=hello")
    @test contains(str, "SUCCESS")
end

# All workers must have been stopped once `runtests` returns.
@testset "no workers running" begin
    children = _count_child_pids()
    if children >= 0
        @test children == 0
    end
end
