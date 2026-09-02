@testset "test output" begin
    msg = "This is some output from the test"
    testsuite = Dict(
        "output" => quote
            println($(msg))
        end
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test contains(str, r"output .+ started at")
    @test contains(str, msg)
    @test contains(str, "SUCCESS")

    msg2 = "More output"
    testsuite = Dict(
        "verbose-1" => quote
            print($(msg))
        end,
        "verbose-2" => quote
            println($(msg2))
        end,
        "silent" => quote
            @test true
        end,
    )
    io = IOBuffer()
    # Run all tests on the same worker, makre sure all the output is captured
    # and attributed to the correct test set.
    runtests(ParallelTestRunner, ["--verbose", "--jobs=1"]; testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test contains(str, r"verbose-1 .+ started at")
    @test contains(str, r"verbose-2 .+ started at")
    @test contains(str, r"silent .+ started at")
    @test contains(str, "Output generated during execution of 'verbose-1':\n[ $(msg)")
    @test contains(str, "Output generated during execution of 'verbose-2':\n[ $(msg2)")
    @test !contains(str, "Output generated during execution of 'silent':")
    @test contains(str, "SUCCESS")
end

@testset "warnings" begin
    testsuite = Dict(
        "warning" => quote
            @test_warn "3.0" @warn "3.0"
        end
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test contains(str, r"warning .+ started at")
    @test contains(str, "SUCCESS")
end

# Issue <https://github.com/JuliaTesting/ParallelTestRunner.jl/issues/69>.
@testset "colorful output" begin
    testsuite = Dict(
        "color" => quote
            printstyled("Roses Are Red"; color=:red)
        end
    )
    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    runtests(ParallelTestRunner, String[]; testsuite, stdout=ioc, stderr=ioc)
    str = String(take!(io))
    @test contains(str, "\e[31mRoses Are Red\e[39m\n")
    @test contains(str, "SUCCESS")

    testsuite = Dict(
        "no color" => quote
            print("Violets are ")
            printstyled("blue"; color=:blue)
        end
    )
    io = IOBuffer()
    ioc = IOContext(io, :color => false)
    runtests(ParallelTestRunner, String[]; testsuite, stdout=ioc, stderr=ioc)
    str = String(take!(io))
    @test contains(str, "Violets are blue\n")
    @test contains(str, "SUCCESS")
end

@testset "non-verbose mode" begin
    testsuite = Dict("quiet" => :())
    io = IOBuffer()
    runtests(ParallelTestRunner, String[]; testsuite, stdout=io, stderr=io)
    str = String(take!(io))
    @test !contains(str, "started at")
    @test !contains(str, "Available memory:")
    @test !contains(str, "Max worker RSS:")
    @test contains(str, "SUCCESS")
end

@testset "positional filter end-to-end" begin
    testsuite = Dict(
        "unit/math" => :( @test 1 + 1 == 2 ),
        "unit/string" => :( @test "a" * "b" == "ab" ),
        "integration/api" => :( @test true ),
    )
    io = IOBuffer()
    runtests(ParallelTestRunner, ["unit"]; testsuite, stdout=io, stderr=io)
    str = String(take!(io))
    @test contains(str, "Running 2 tests")
    @test contains(str, "SUCCESS")
end

@testset "--list output" begin
    # `--list` exits the process, so it has to run in a subprocess
    mod = Module(:ListOutputTest)
    history_file = ParallelTestRunner.get_history_file(mod)
    function list_output()
        code = """
            using ParallelTestRunner
            testsuite = Dict(name => :(@test true) for name in ("beta", "alpha", "gamma_longer"))
            runtests(Module(:ListOutputTest), ["--list"]; testsuite)
            """
        readlines(`$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) --color=yes -e $code`)
    end

    rm(history_file; force=true)
    @test list_output() == [
            "Available tests:",
            " - alpha",
            " - beta",
            " - gamma_longer"]

    ParallelTestRunner.save_test_history(mod, (Dict("alpha" => 1.234, "gamma_longer" => 123.456), Set(["gamma_longer"])))
    try
        @test list_output() == [
            "Available tests:",
            " - alpha           (1.23s)",
            " - beta",
            "\e[31m × gamma_longer  (123.46s)\e[39m",
        ]
    finally
        rm(history_file; force=true)
    end
end

@testset "empty test suite" begin
    testsuite = Dict{String,Expr}()
    io = IOBuffer()
    runtests(ParallelTestRunner, String[]; testsuite, stdout=io, stderr=io)
    str = String(take!(io))
    @test contains(str, "Running 0 tests")
    @test contains(str, "SUCCESS")
end
