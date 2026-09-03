@testset "retries" begin
    # A test that fails on its first attempt and passes on any subsequent one, by recording
    # attempts in a file: the worker running the retry is a different process, so the marker
    # has to live outside of it.
    flaky_test(marker, body=:( @test true )) = quote
        if isfile($marker)
            $body
        else
            touch($marker)
            @test false
        end
    end

    @testset "failed test passing on retry is reported as passing" begin
        mktempdir() do dir
            testsuite = Dict(
                "flaky" => flaky_test(joinpath(dir, "flaky")),
                "passes" => :( @test true ),
            )
            io = IOBuffer()
            @show_if_error io ParallelTestRunner._runtests(
                ParallelTestRunner, parse_args(["--jobs=1"]);
                testsuite,
                tests=["flaky", "passes"],
                stdout=io,
                stderr=io,
                retries=1,
            )
            str = String(take!(io))
            # Only the failed test is retried, and its retried result is the one reported.
            @test contains(str, "Retrying 1 failed test")
            @test contains(str, "SUCCESS")
            # Two results in total: the failed attempt of `flaky` was replaced by the
            # retried one, rather than reported next to it.
            @test contains(str, r"Overall +\| +2 +2 ")
        end
    end

    @testset "persistent failure is retried and reported once" begin
        testsuite = Dict(
            "always_fails" => :( @test false ),
            "passes" => :( @test true ),
        )
        io = IOBuffer()
        @test_throws Test.FallbackTestSetException begin
            ParallelTestRunner._runtests(
                ParallelTestRunner, parse_args(["--jobs=1"]);
                testsuite,
                tests=["always_fails", "passes"],
                stdout=io,
                stderr=io,
                retries=2,
            )
        end
        str = String(take!(io))
        @test contains(str, "FAILURE")
        # Both retry rounds run, and each of them fails again.
        @test length(collect(eachmatch(r"always_fails.*failed", str))) == 3
        # Despite the three attempts, the test is reported exactly once, as a failure.
        @test contains(str, r"always_fails +\| +1 +1 ")
    end

    # `serial_position=:after` returns the live serial worker to the pool immediately
    # before the retry phase, so it is the configuration where the "alone" invariant is
    # easiest to break.
    @testset "retried test runs alone (serial=$serial, $serial_position)" for
            (serial, serial_position) in ((String[], :before),
                                          (["pass3"], :before),
                                          (["pass3"], :after))
        mktempdir() do dir
            # On its retry, the flaky test checks it is the only worker left alive.
            check_alone = quote
                children = _count_child_pids($(getpid()))
                if children >= 0
                    @test children == 1
                end
            end
            testsuite = Dict(
                "flaky" => flaky_test(joinpath(dir, "flaky"), check_alone),
                "pass1" => :( @test true ),
                "pass2" => :( @test true ),
                "pass3" => :( @test true ),
            )
            io = IOBuffer()
            @show_if_error io ParallelTestRunner._runtests(
                ParallelTestRunner, parse_args(["--jobs=3"]);
                testsuite,
                tests=["flaky", "pass1", "pass2", "pass3"],
                init_code=:(include($(joinpath(@__DIR__, "utils.jl")))),
                serial,
                serial_position,
                stdout=io,
                stderr=io,
                retries=1,
            )
            str = String(take!(io))
            @test length(collect(eachmatch(r"failed", str))) == 2
            @test contains(str, "SUCCESS")
        end
    end

    @testset "failing retry does not reuse its worker" begin
        testsuite = Dict(
            "failA" => :( @test false ),
            "failB" => :( @test false ),
        )
        io = IOBuffer()
        old_id_counter = ParallelTestRunner.ID_COUNTER[]
        @test_throws Test.FallbackTestSetException begin
            ParallelTestRunner._runtests(
                ParallelTestRunner, parse_args(["--jobs=1"]);
                testsuite,
                tests=["failA", "failB"],
                stdout=io,
                stderr=io,
                retries=1,
            )
        end
        str = String(take!(io))
        main, retry = split(str, "Retrying")
        ids(s) = [m[1] for m in eachmatch(r"fail[AB] +\((\d+)\)", s)]
        # the main run reuses one worker across failures:
        # `recycle_on_failure` is off by default
        @test length(ids(main)) == 2 && allequal(ids(main))
        # 1 initial worker + 1 replacement per retried test
        @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + 3
        # the retry round recycles after every non-pass, so each test gets its own worker
        @test length(ids(retry)) == 2 && allunique(ids(retry))
    end

    @testset "no retries by default" begin
        mktempdir() do dir
            testsuite = Dict("flaky" => flaky_test(joinpath(dir, "flaky")))
            io = IOBuffer()
            @test_throws Test.FallbackTestSetException begin
                ParallelTestRunner._runtests(
                    ParallelTestRunner, parse_args(["--jobs=1"]);
                    testsuite,
                    tests=["flaky"],
                    stdout=io,
                    stderr=io,
                )
            end
            str = String(take!(io))
            @test !contains(str, "Retrying")
            @test contains(str, "FAILURE")
        end
    end

    @testset "quickfail skips retries" begin
        mktempdir() do dir
            testsuite = Dict(
                "flaky" => flaky_test(joinpath(dir, "flaky")),
                "passes" => :( @test true ),
            )
            io = IOBuffer()
            @test_throws Test.FallbackTestSetException begin
                ParallelTestRunner._runtests(
                    ParallelTestRunner, parse_args(["--quickfail", "--jobs=1"]);
                    testsuite,
                    tests=["flaky", "passes"],
                    stdout=io,
                    stderr=io,
                    retries=1,
                )
            end
            str = String(take!(io))
            # The run stopped early on purpose, retrying would defeat that.
            @test !contains(str, "Retrying")
            @test contains(str, "FAILURE")
        end
    end
end
