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

    script = "using ParallelTestRunner; print(any(==(\"--heap-size-hint=1073741824\"), ParallelTestRunner.test_exe().exec))"
    cmd = `$(Base.julia_cmd()) --project=$(Base.active_project()) --heap-size-hint=1G -e $script`
    @test read(cmd, String) == "true"
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

@testset "progress_bar_protocols" begin
    protocols(env...) = ParallelTestRunner.progress_bar_protocols(Dict{String, String}(env...))
    status, both = [:osc7501], [:osc7501, :osc94]

    # program status reports go to every terminal, as those that do not know them ignore them
    @test protocols() == status
    @test protocols("TERM_PROGRAM" => "Apple_Terminal") == status
    @test protocols("TERM" => "xterm-256color") == status
    # along with a progress bar for those known to draw one
    @test protocols("TERM_PROGRAM" => "ghostty") == both
    @test protocols("TERM_PROGRAM" => "WezTerm") == both
    @test protocols("TERM_PROGRAM" => "herdr") == both
    @test protocols("WT_SESSION" => "0c1f5e7a") == both
    @test protocols("ConEmuANSI" => "ON") == both
    @test protocols("ConEmuANSI" => "OFF") == status
    # but not for Rex, which takes the reports
    @test protocols("TERM_PROGRAM" => "rex") == status

    # nothing is sent to a terminal that would show the sequences
    @test protocols("TERM" => "dumb") == []
    @test protocols("TERM" => "dumb", "WT_SESSION" => "0c1f5e7a") == []

    # across SSH, Ghostty is only identified by `TERM`
    @test protocols("TERM" => "xterm-ghostty") == both

    # iTerm2 is only sent the progress bar if it reports the feature, as older versions
    # mistake progress for a notification
    @test protocols("TERM_PROGRAM" => "iTerm.app", "TERM_FEATURES" => "MBT2ScP") == both
    @test protocols("TERM_PROGRAM" => "iTerm.app", "TERM_FEATURES" => "MBT2Sc") == status
    @test protocols("TERM_PROGRAM" => "iTerm.app") == status
    # the feature is a code of its own, wherever it is, and not the start of another one
    @test protocols("TERM_FEATURES" => "PT2Sc") == both
    @test protocols("TERM_FEATURES" => "MPcT2") == status

    # Ptyxis and Konsole are supported from a given version on
    @test protocols("PTYXIS_VERSION" => "48.0") == both
    @test protocols("PTYXIS_VERSION" => "49.2") == both
    @test protocols("PTYXIS_VERSION" => "47.10") == status
    @test protocols("PTYXIS_VERSION" => "") == status
    @test protocols("PTYXIS_VERSION" => "dev") == status
    @test protocols("KONSOLE_VERSION" => "260400") == both
    @test protocols("KONSOLE_VERSION" => "251203") == status

    # the environment variable forces a single protocol, whatever the terminal
    @test protocols("PTR_TERM_PROGRESS" => "osc94") == [:osc94]
    @test protocols("PTR_TERM_PROGRESS" => "osc7501") == status
    @test protocols("PTR_TERM_PROGRESS" => "osc94", "TERM_PROGRAM" => "rex") == [:osc94]
    @test protocols("PTR_TERM_PROGRESS" => "OSC7501", "TERM_PROGRAM" => "ghostty") == status
    @test protocols("PTR_TERM_PROGRESS" => "osc7501", "TERM" => "dumb") == status
    @test protocols("PTR_TERM_PROGRESS" => "none", "TERM_PROGRAM" => "ghostty") == []
    @test protocols("PTR_TERM_PROGRESS" => "none", "TERM_PROGRAM" => "rex") == []
    @test protocols("PTR_TERM_PROGRESS" => "", "TERM_PROGRAM" => "ghostty") == both

    # and is ignored with a warning when it does not name one
    @test (@test_logs (:warn, r"PTR_TERM_PROGRESS") protocols("PTR_TERM_PROGRESS" => "true")) == status
    @test (@test_logs (:warn, r"PTR_TERM_PROGRESS") protocols("PTR_TERM_PROGRESS" => "osc9", "TERM_PROGRAM" => "ghostty")) == both
    @test_logs protocols("PTR_TERM_PROGRESS" => "none")
    @test_logs protocols("TERM_PROGRAM" => "ghostty")
end

@testset "progress_bar_sequence" begin
    sequence = ParallelTestRunner.progress_bar_sequence

    @test sequence(:osc94, :working, 0, 8) == "\e]9;4;1;0\a"
    @test sequence(:osc94, :working, 1, 3) == "\e]9;4;1;33\a"
    @test sequence(:osc94, :working, 8, 8) == "\e]9;4;1;100\a"
    @test sequence(:osc94, :working, 0, 0) == "\e]9;4;1;0\a"
    # failures turn the progress bar into an error
    @test sequence(:osc94, :failing, 4, 8) == "\e]9;4;2;50\a"
    # and it is removed at the end, whatever the outcome
    @test sequence(:osc94, :done) == sequence(:osc94, :error) == sequence(:osc94, :clear) == "\e]9;4;0\a"

    # the reports go to a record of their own, and name the program
    record = "id=ParallelTestRunner"
    # along with a message, which is encoded
    msg(text) = "msg=" * ParallelTestRunner.Base64.base64encode(text)
    @test sequence(:osc7501, :working, 1, 3, "1/3 tests completed │ ETA: ~2 min") == "\e]7501;state=working:progress=33:$(msg("1/3 tests completed │ ETA: ~2 min")):$record:app=julia\e\\"
    @test occursin(r"^[A-Za-z0-9+/=]+$", ParallelTestRunner.Base64.base64encode("151/151 tests completed │ ETA: ~11 min"))
    # failures are only reported as the outcome, which is left behind
    @test sequence(:osc7501, :failing, 4, 8, "4/8 tests completed") == "\e]7501;state=working:progress=50:$(msg("4/8 tests completed")):$record:app=julia\e\\"
    @test sequence(:osc7501, :done) == "\e]7501;state=done:$record:app=julia\e\\"
    @test sequence(:osc7501, :error) == "\e]7501;state=error:$record:app=julia\e\\"
    # clearing only that record, and not those of other programs
    @test sequence(:osc7501, :clear) == "\e]7501;state=clear:$record\e\\"
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
