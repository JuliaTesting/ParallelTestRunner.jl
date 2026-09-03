@testset "serial tests" begin
    @testset "partition_tests" begin
        @testset "basic partitioning preserves order" begin
            tests = ["a", "b", "c", "d", "e"]
            serial, parallel = ParallelTestRunner.partition_tests(tests, ["c", "a"])
            @test serial == ["a", "c"]
            @test parallel == ["b", "d", "e"]
        end

        @testset "empty serial list" begin
            tests = ["x", "y", "z"]
            serial, parallel = ParallelTestRunner.partition_tests(tests, String[])
            @test isempty(serial)
            @test parallel == tests
        end

        @testset "all tests serial" begin
            tests = ["a", "b"]
            serial, parallel = ParallelTestRunner.partition_tests(tests, ["a", "b"])
            @test serial == ["a", "b"]
            @test isempty(parallel)
        end

        @testset "unknown serial name throws" begin
            tests = ["a", "b"]
            @test_throws ArgumentError ParallelTestRunner.partition_tests(tests, ["a", "missing"])
        end
    end

    @testset "serial tests run before parallel (default)" begin
        serial_test_body = quote
            children = _count_child_pids($(getpid()))
            # Make sure serial tests run alone.
            if children >= 0
                @test children == 1
            end
        end
        testsuite = Dict(
            "serial_1" => serial_test_body,
            "serial_2" => serial_test_body,
            "serial_3" => serial_test_body,
            "parallel_1" => :(),
            "parallel_2" => :(),
            "parallel_3" => :(),
        )
        io = IOBuffer()
        jobs = 2
        old_id_counter = ParallelTestRunner.ID_COUNTER[]
        @show_if_error io runtests(ParallelTestRunner, ["--jobs=$(jobs)", "--verbose"];
                                   testsuite, stdout=io, stderr=io,
                                   init_code=:(include($(joinpath(@__DIR__, "utils.jl")))),
                                   serial=["serial_1", "serial_2", "serial_3"])
        str = String(take!(io))
        @test contains(str, "Running 6 tests using 2 parallel jobs")
        @test contains(str, "3 serial test(s) will run before")
        @test contains(str, "SUCCESS")
        @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + jobs
    end

    @testset "serial tests run after parallel" begin
        serial_test_body = quote
            children = _count_child_pids($(getpid()))
            # Make sure serial tests run alone.
            if children >= 0
                @test children == 1
            end
        end
        testsuite = Dict(
            "serial_1" => serial_test_body,
            "serial_2" => serial_test_body,
            "serial_3" => serial_test_body,
            "parallel_1" => :(),
            "parallel_2" => :(),
            "parallel_3" => :(),
        )
        io = IOBuffer()
        ioc = IOContext(io, :color => true)
        old_id_counter = ParallelTestRunner.ID_COUNTER[]
        @show_if_error io runtests(ParallelTestRunner, ["--jobs=2", "--verbose"];
                                   testsuite, stdout=ioc, stderr=ioc,
                                   init_code=:(include($(joinpath(@__DIR__, "utils.jl")))),
                                   serial=["serial_1", "serial_2", "serial_3"], serial_position=:after)
        str = String(take!(io))
        @test contains(str, "Running 6 tests using 2 parallel jobs")
        @test contains(str, "3 serial test(s) will run after")
        @test contains(str, "SUCCESS")
        @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + 2
    end

    @testset "serial_position validation" begin
        testsuite = Dict("a" => :())
        io = IOBuffer()
        @test_throws ArgumentError runtests(ParallelTestRunner, String[];
                                            testsuite, stdout=io, stderr=io,
                                            serial_position=:middle)
    end

    @testset "all tests serial" begin
        testsuite = Dict(
            "a" => :(),
            "b" => :(),
            "c" => :(),
            "d" => :(),
        )
        io = IOBuffer()
        old_id_counter = ParallelTestRunner.ID_COUNTER[]
        runtests(ParallelTestRunner, ["--jobs=3", "--verbose"];
                 testsuite, stdout=io, stderr=io,
                 serial=["a", "b", "c", "d"])
        str = String(take!(io))
        @test contains(str, "Running 4 tests using 1 parallel jobs")
        @test contains(str, "4 serial test(s) will run before")
        @test contains(str, "SUCCESS")
        @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + 1
    end

    @testset "empty serial list is a no-op" begin
        testsuite = Dict(
            "a" => :(),
            "b" => :(),
        )
        io = IOBuffer()
        runtests(ParallelTestRunner, ["--jobs=2"]; testsuite, stdout=io, stderr=io,
                 serial=String[])
        str = String(take!(io))
        @test !contains(str, "serial")
        @test contains(str, "SUCCESS")
    end

    @testset "parallel tests less than requested jobs" begin
        testsuite = Dict(
            "s1" => :(),
            "s2" => :(),
            "p1" => :(),
            "p2" => :(),
        );
        io = IOBuffer()
        old_id_counter = ParallelTestRunner.ID_COUNTER[]
        runtests(ParallelTestRunner, ["--jobs=3"]; testsuite, stdout=io, stderr=io,
                 serial=["s1", "s2"])
        str = String(take!(io))
        # We have 4 total tests, requested 3 jobs, but only 2 tests are run in parallel, so
        # 2 is the maximum parallelism we expect, and the number of new workers we spawn.
        @test contains(str, "Running 4 tests using 2 parallel jobs")
        @test contains(str, "2 serial test(s)")
        @test contains(str, "SUCCESS")
        @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + 2
    end

    @testset "serial names filtered by positional args" begin
        testsuite = Dict(
            "unit/a" => :(),
            "unit/b" => :(),
            # This test file shouldn't called, we use `@test false` to make sure it's not.
            "integration/c" => :(@test false),
        )
        io = IOBuffer()
        runtests(ParallelTestRunner, ["unit"]; testsuite, stdout=io, stderr=io,
                 serial=["unit/a", "integration/c"])
        str = String(take!(io))
        @test contains(str, "Running 2 tests")
        @test contains(str, "1 serial test(s)")
        @test contains(str, "SUCCESS")
    end

    @testset "crashing serial test" begin
        serial_test_body = quote
            children = _count_child_pids($(getpid()))
            # Make sure serial tests run alone.
            if children >= 0
                @test children == 1
            end
        end

        testsuite = Dict(
            "s1" => serial_test_body,
            "s2" => serial_test_body,
            "s3" => serial_test_body,
            "s4" => :(ccall(:abort, Nothing, ())),
            "p1" => :(),
            "p2" => :(),
        )
        io = IOBuffer()
        ioc = IOContext(io, :color => true)
        old_id_counter = ParallelTestRunner.ID_COUNTER[]
        jobs = 2
        @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
            runtests(ParallelTestRunner, ["--jobs=$(jobs)", "--verbose"];
                     testsuite, stdout=ioc, stderr=ioc,
                     init_code=:(include($(joinpath(@__DIR__, "utils.jl")))),
                     serial=["s1", "s2", "s3", "s4"])
        end
        str = String(take!(io))
        @test contains(str, "Running 6 tests using 2 parallel jobs")
        @test contains(str, "4 serial test(s)")
        @test contains(str, "FAILURE")
        # We'll use jobs + 1 workers because one will crash.
        @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + jobs + 1
    end

    @testset "quickfail in serial phase before parallel" begin
        # The failing serial test runs first: the remaining serial tests and the whole
        # parallel batch should never be started.
        testsuite = Dict(
            "fail-serial" => :( @test false ),
            "pass-serial1" => :( @test true ),
            "pass-serial2" => :( @test true ),
            "pass-parallel1" => :( @test true ),
            "pass-parallel2" => :( @test true ),
            "pass-parallel3" => :( @test true ),
        )
        io = IOBuffer()
        @test_throws Test.FallbackTestSetException begin
            # Call `_runtests` so that we can enforce a run order.
            ParallelTestRunner._runtests(
                ParallelTestRunner, parse_args(["--quickfail", "--verbose", "--jobs=2"]);
                testsuite,
                tests=["fail-serial", "pass-serial1", "pass-serial2",
                       "pass-parallel1", "pass-parallel2", "pass-parallel3"],
                serial=["fail-serial", "pass-serial1", "pass-serial2"],
                stdout=io,
                stderr=io,
            )
        end
        str = String(take!(io))
        @test contains(str, "3 serial test(s) will run before")
        @test contains(str, r"fail-serial .+ started at")
        @test contains(str, r"fail-serial .+ failed at")
        @test contains(str, "FAILURE")
        # `fail-serial` is always launched first, the other tests are never started.
        @test !contains(str, r"pass-serial[12] .+ started at")
        @test !contains(str, r"pass-parallel[1-3] .+ started at")
    end

    @testset "quickfail in parallel phase with serial tests after" begin
        # The failing parallel test runs first: the remaining parallel tests and the
        # whole serial batch should never be started.
        testsuite = Dict(
            "fail-parallel" => :( @test false ),
            "pass-parallel1" => :( @test true ),
            "pass-parallel2" => :( @test true ),
            "pass-serial1" => :( @test true ),
            "pass-serial2" => :( @test true ),
        )
        io = IOBuffer()
        @test_throws Test.FallbackTestSetException begin
            # Call `_runtests` so that we can enforce a run order.
            ParallelTestRunner._runtests(
                # Use a single job to make sure only `fail-parallel` is started.
                ParallelTestRunner, parse_args(["--quickfail", "--verbose", "--jobs=1"]);
                testsuite,
                tests=["fail-parallel", "pass-parallel1", "pass-parallel2",
                       "pass-serial1", "pass-serial2"],
                serial=["pass-serial1", "pass-serial2"],
                serial_position=:after,
                stdout=io,
                stderr=io,
            )
        end
        str = String(take!(io))
        @test contains(str, "2 serial test(s) will run after")
        @test contains(str, r"fail-parallel .+ started at")
        @test contains(str, r"fail-parallel .+ failed at")
        @test contains(str, "FAILURE")
        # `fail-parallel` is always launched first, the other tests are never started.
        @test !contains(str, r"pass-parallel[12] .+ started at")
        @test !contains(str, r"pass-serial[12] .+ started at")
    end

    @testset "quickfail in serial phase after parallel" begin
        # All parallel tests pass, then the failing serial test runs first in the serial
        # phase: the remaining serial tests should never be started.
        testsuite = Dict(
            "pass-parallel1" => :( @test true ),
            "pass-parallel2" => :( @test true ),
            "fail-serial" => :( @test false ),
            "pass-serial1" => :( @test true ),
            "pass-serial2" => :( @test true ),
        )
        io = IOBuffer()
        @test_throws Test.FallbackTestSetException begin
            # Call `_runtests` so that we can enforce a run order.
            ParallelTestRunner._runtests(
                ParallelTestRunner, parse_args(["--quickfail", "--verbose", "--jobs=2"]);
                testsuite,
                tests=["pass-parallel1", "pass-parallel2",
                       "fail-serial", "pass-serial1", "pass-serial2"],
                serial=["fail-serial", "pass-serial1", "pass-serial2"],
                serial_position=:after,
                stdout=io,
                stderr=io,
            )
        end
        str = String(take!(io))
        @test contains(str, "3 serial test(s) will run after")
        # The parallel batch runs to completion before the serial phase starts.
        @test contains(str, r"pass-parallel1 .+ started at")
        @test contains(str, r"pass-parallel2 .+ started at")
        @test contains(str, r"fail-serial .+ started at")
        @test contains(str, r"fail-serial .+ failed at")
        @test contains(str, "FAILURE")
        # The serial tests after `fail-serial` are never started.
        @test !contains(str, r"pass-serial[12] .+ started at")
    end

    @testset "run previously failed tests first" begin
        # a previously-failed test must start before previously-passing tests,
        # even if it has a much shorter historical duration than they do
        mod = @eval(Main, module $(gensym(:failfirstserial)) end)

        testsuite = Dict(
            "long-serial-pass" => :(@test true),
            "mid-omitted-serial-pass" => :(@test true),
            "short-serial-fail" => :(@test true),
            "long-pass" => :(@test true),
            "mid-omitted-pass" => :(@test true),
            "mid-pass" => :(@test true),
            "short-fail" => :(@test true),
        )
        serial = filter(collect(keys(testsuite))) do k
            contains(k, "serial")
        end

        ParallelTestRunner.save_test_history(mod, (Dict(
            "long-serial-pass" => 10.0,
            "short-serial-fail" => 1.0,
            "long-pass" => 10.0,
            "mid-pass" => 5.0,
            "short-fail" => 1.0,
        ), Set(["short-serial-fail", "short-fail"])))

        io = IOBuffer()
        runtests(
            mod, parse_args(["--jobs=1", "--verbose"]);
            testsuite,
            stdout=io,
            stderr=io,
            serial
        )

        str = String(take!(io))
        @test contains(str, "SUCCESS")

        # create a mapping of test names to the character offset of their start times (lower is earlier)
        started_at = Dict(
            name => (m = match(Regex("$(name) .+ started at"), str); @test m !== nothing; m === nothing ? typemax(Int) : m.offset)
            for name in keys(testsuite)
        )

        # normal
        @test started_at["short-fail"] < started_at["mid-pass"]
        @test started_at["short-fail"] < started_at["long-pass"]
        @test started_at["short-fail"] < started_at["mid-omitted-pass"]
        # among the remaining (previously-passing) tests, longer ones still run first
        @test started_at["long-pass"] < started_at["mid-pass"]

        # serial
        @test started_at["short-serial-fail"] < started_at["long-serial-pass"]
        @test started_at["short-serial-fail"] < started_at["mid-omitted-serial-pass"]
    end
end

# All workers must have been stopped once `runtests` returns.
@testset "no workers running" begin
    children = _count_child_pids()
    if children >= 0
        @test children == 0
    end
end
