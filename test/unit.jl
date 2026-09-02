@testset "extract_flag!" begin
    args = ["--verbose", "--jobs=4", "test1"]
    result = ParallelTestRunner.extract_flag!(args, "--verbose")
    @test result === Some(nothing)
    @test args == ["--jobs=4", "test1"]

    args = ["--verbose", "--jobs=4", "test1"]
    result = ParallelTestRunner.extract_flag!(args, "--jobs"; typ=Int)
    @test something(result) == 4
    @test args == ["--verbose", "test1"]

    args = ["--verbose", "test1"]
    result = ParallelTestRunner.extract_flag!(args, "--jobs")
    @test result === nothing
    @test args == ["--verbose", "test1"]

    args = ["--format=json"]
    result = ParallelTestRunner.extract_flag!(args, "--format")
    @test something(result) == "json"
    @test isempty(args)

    # values containing `=` are preserved
    args = ["--format=key=value"]
    result = ParallelTestRunner.extract_flag!(args, "--format")
    @test something(result) == "key=value"
    @test isempty(args)

    # flags sharing a prefix are not captured
    args = ["--listing"]
    result = ParallelTestRunner.extract_flag!(args, "--list")
    @test result === nothing
    @test args == ["--listing"]

    # a typed flag without a value is an error
    args = ["--jobs"]
    @test_throws ErrorException ParallelTestRunner.extract_flag!(args, "--jobs"; typ=Int)

    # a typed flag with an unparseable value is an error
    args = ["--jobs=abc"]
    @test_throws ErrorException ParallelTestRunner.extract_flag!(args, "--jobs"; typ=Int)
end

@testset "parse_args" begin
    @testset "individual flags" begin
        args = parse_args(["--verbose"])
        @test args.verbose !== nothing
        @test args.jobs === nothing
        @test args.quickfail === nothing
        @test args.list === nothing
        @test isempty(args.positionals)

        args = parse_args(["--jobs=4"])
        @test something(args.jobs) == 4
        @test args.verbose === nothing

        args = parse_args(["--quickfail"])
        @test args.quickfail !== nothing
        @test args.verbose === nothing

        args = parse_args(["--list"])
        @test args.list !== nothing
    end

    @testset "combined flags" begin
        args = parse_args(["--verbose", "--quickfail", "--jobs=2"])
        @test args.verbose !== nothing
        @test args.quickfail !== nothing
        @test something(args.jobs) == 2
    end

    @testset "positional arguments" begin
        args = parse_args(["--verbose", "basic", "subdir"])
        @test args.verbose !== nothing
        @test args.positionals == ["basic", "subdir"]

        args = parse_args(["test1", "test2"])
        @test args.positionals == ["test1", "test2"]
    end

    @testset "custom arguments" begin
        args = parse_args(["--gpu", "--nocuda"]; custom=["gpu", "nocuda", "other"])
        @test args.custom["gpu"] !== nothing
        @test args.custom["nocuda"] !== nothing
        @test args.custom["other"] === nothing
    end

    @testset "unknown flags" begin
        @test_throws ErrorException parse_args(["--unknown-flag"])
        @test_throws ErrorException parse_args(["--verbose", "--bogus"])
    end

    @testset "malformed and lookalike flags" begin
        # prefix lookalikes are unknown options, not misparsed builtin flags
        @test_throws ErrorException parse_args(["--verbose-foo"])
        @test_throws ErrorException parse_args(["--jobs2=3"])

        # a custom flag sharing a builtin's prefix is not captured by the builtin
        args = parse_args(["--listing"]; custom=["listing"])
        @test args.list === nothing
        @test args.custom["listing"] !== nothing

        # missing or invalid values produce a clean error
        @test_throws ErrorException parse_args(["--jobs"])
        @test_throws ErrorException parse_args(["--jobs=abc"])

        # boolean flags reject values
        @test_throws ErrorException parse_args(["--verbose=5"])
    end

    @testset "no arguments" begin
        args = parse_args(String[])
        @test args.jobs === nothing
        @test args.verbose === nothing
        @test args.quickfail === nothing
        @test args.list === nothing
        @test isempty(args.positionals)
        @test isempty(args.custom)
    end
end

@testset "filter_tests!" begin
    @testset "empty positionals preserves all tests" begin
        testsuite = Dict("a" => :(), "b" => :(), "c" => :())
        args = parse_args(String[])
        @test filter_tests!(testsuite, args) == true
        @test length(testsuite) == 3
    end

    @testset "startswith matching" begin
        testsuite = Dict("basic" => :(), "advanced" => :(), "basic_extra" => :())
        args = parse_args(["basic"])
        @test filter_tests!(testsuite, args) == false
        @test haskey(testsuite, "basic")
        @test haskey(testsuite, "basic_extra")
        @test !haskey(testsuite, "advanced")
    end

    @testset "multiple positional filters" begin
        testsuite = Dict("unit/a" => :(), "unit/b" => :(), "integration/c" => :(), "perf/d" => :())
        args = parse_args(["unit", "integration"])
        @test filter_tests!(testsuite, args) == false
        @test haskey(testsuite, "unit/a")
        @test haskey(testsuite, "unit/b")
        @test haskey(testsuite, "integration/c")
        @test !haskey(testsuite, "perf/d")
    end

    @testset "exclude tests basic" begin
        testsuite = Dict("unit/a" => :(), "unit/b" => :(), "integration/c" => :(), "perf/d" => :())
        args = parse_args(["!unit"])
        @test filter_tests!(testsuite, args) == false
        @test !haskey(testsuite, "unit/a")
        @test !haskey(testsuite, "unit/b")
        @test haskey(testsuite, "integration/c")
        @test haskey(testsuite, "perf/d")
    end

    @testset "exclude included tests" begin
        testsuite = Dict("unit/a" => :(), "unit/b" => :(), "integration/c" => :(), "perf/d" => :())
        args = parse_args(["unit", "!unit/a"])
        @test filter_tests!(testsuite, args) == false
        @test !haskey(testsuite, "unit/a")
        @test haskey(testsuite, "unit/b")
        @test !haskey(testsuite, "integration/c")
        @test !haskey(testsuite, "perf/d")
    end

    @testset "no matches yields empty suite" begin
        testsuite = Dict("a" => :(), "b" => :())
        args = parse_args(["nonexistent"])
        @test filter_tests!(testsuite, args) == false
        @test isempty(testsuite)
    end

    @testset "listing preserves all tests" begin
        testsuite = Dict("a" => :(), "b" => :(), "c" => :())
        args = parse_args(["--list"])
        @test filter_tests!(testsuite, args) == false
        @test length(testsuite) == 3
    end

    @testset "listing ignores positional filters" begin
        testsuite = Dict("a" => :(), "b" => :())
        args = parse_args(["--list", "a"])
        @test filter_tests!(testsuite, args) == false
        @test length(testsuite) == 2
    end
end

@testset "find_tests edge cases" begin
    @testset "empty directory" begin
        mktempdir() do dir
            @test isempty(find_tests(dir))
        end
    end

    @testset "only runtests.jl" begin
        mktempdir() do dir
            write(joinpath(dir, "runtests.jl"), "@test true")
            @test isempty(find_tests(dir))
        end
    end

    @testset "nested subdirectories" begin
        mktempdir() do dir
            mkpath(joinpath(dir, "a", "b"))
            write(joinpath(dir, "test1.jl"), "@test true")
            write(joinpath(dir, "a", "test2.jl"), "@test true")
            write(joinpath(dir, "a", "b", "test3.jl"), "@test true")
            ts = find_tests(dir)
            @test length(ts) == 3
            @test haskey(ts, "test1")
            @test haskey(ts, "a/test2")
            @test haskey(ts, "a/b/test3")
        end
    end

    @testset "non-.jl files ignored" begin
        mktempdir() do dir
            write(joinpath(dir, "test.jl"), "@test true")
            write(joinpath(dir, "readme.md"), "# Readme")
            write(joinpath(dir, "data.csv"), "1,2,3")
            ts = find_tests(dir)
            @test length(ts) == 1
            @test haskey(ts, "test")
        end
    end
end

@testset "get_max_worker_rss" begin
    rss = withenv("JULIA_TEST_MAXRSS_MB" => nothing) do
        ParallelTestRunner.get_max_worker_rss()
    end
    @test rss > 0

    rss = withenv("JULIA_TEST_MAXRSS_MB" => "1024") do
        ParallelTestRunner.get_max_worker_rss()
    end
    @test rss == 1024 * 2^20
end

@testset "test_exe" begin
    exe = ParallelTestRunner.test_exe(false)
    @test any(contains("--color=no"), exe.exec)
    @test any(contains("--project="), exe.exec)

    exe = ParallelTestRunner.test_exe(true)
    @test any(contains("--color=yes"), exe.exec)
end

@testset "truncate_line" begin
    # short lines are untouched
    @test ParallelTestRunner.truncate_line("short", 80) == "short"
    @test ParallelTestRunner.truncate_line("x"^80, 80) == "x"^80

    truncated = ParallelTestRunner.truncate_line("x"^100, 80)
    @test length(truncated) == 80
    @test endswith(truncated, "...")

    # multi-byte characters must not break the cut: with byte indexing these
    # would throw a StringIndexError when the cut lands mid-character
    truncated = ParallelTestRunner.truncate_line("t" * "α"^100, 80)
    @test length(truncated) == 80
    @test endswith(truncated, "...")

    truncated = ParallelTestRunner.truncate_line("€"^100, 40)
    @test length(truncated) == 40
    @test endswith(truncated, "...")
end

@testset "TestHistoryEntry" begin
    flow = ParallelTestRunner.TestHistoryEntry(1,true)
    fhigh = ParallelTestRunner.TestHistoryEntry(10,true)

    slow = ParallelTestRunner.TestHistoryEntry(1,false)
    shigh = ParallelTestRunner.TestHistoryEntry(10,false)

    # irreflexive: lt(x, x) always yields false
    @test !isless(flow, flow)
    @test !isless(slow, slow)
    @test !isless(fhigh, fhigh)
    @test !isless(shigh, shigh)

    # asymmetric: if lt(x, y) yields true then lt(y, x) yields false
    @test isless(flow, fhigh)
    @test !isless(fhigh, flow)
    @test isless(shigh, flow)
    @test !isless(flow, shigh)

    # transitive: lt(x, y) && lt(y, z) implies lt(x, z)
    @test isless(slow, shigh)
    @test isless(shigh, flow)
    @test isless(slow, flow)
end
