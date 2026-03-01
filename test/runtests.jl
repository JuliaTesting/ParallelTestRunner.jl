using ParallelTestRunner
using Test

cd(@__DIR__)

@testset "ParallelTestRunner" verbose=true begin

@testset "basic use" begin
    io = IOBuffer()
    io_color = IOContext(io, :color => true)
    runtests(ParallelTestRunner, ["--verbose"]; stdout=io_color, stderr=io_color)
    str = String(take!(io))

    println()
    println("Showing the output of one test run:")
    println("-"^80)
    print(str)
    println("-"^80)
    println()

    @test contains(str, r"basic .+ started at")
    @test contains(str, "SUCCESS")

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
    d = @__DIR__
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

@testset "custom worker" begin
    function test_worker(name)
        if name == "needs env var"
            return addworker(env = ["SPECIAL_ENV_VAR" => "42"])
        elseif name == "threads/2"
            return addworker(exeflags = ["--threads=2"])
        end
        return nothing
    end
    testsuite = Dict(
        "needs env var" => quote
            @test ENV["SPECIAL_ENV_VAR"] == "42"
        end,
        "doesn't need env var" => quote
            @test !haskey(ENV, "SPECIAL_ENV_VAR")
        end,
        "threads/1" => quote
            @test Base.Threads.nthreads() == 1
        end,
        "threads/2" => quote
            @test Base.Threads.nthreads() == 2
        end
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; test_worker, testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test contains(str, r"needs env var .+ started at")
    @test contains(str, r"doesn't need env var .+ started at")
    @test contains(str, r"threads/1 .+ started at")
    @test contains(str, r"threads/2 .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "custom worker with `init_worker_code`" begin
    init_worker_code = quote
        should_be_defined() = true
    end
    init_code = quote
        using Test
        import ..should_be_defined
    end
    function test_worker(name, init_worker_code)
        if name == "needs env var"
            return addworker(env = ["SPECIAL_ENV_VAR" => "42"]; init_worker_code)
        elseif name == "threads/2"
            return addworker(exeflags = ["--threads=2"]; init_worker_code)
        end
        return nothing
    end
    testsuite = Dict(
        "needs env var" => quote
            @test ENV["SPECIAL_ENV_VAR"] == "42"
            @test should_be_defined()
        end,
        "doesn't need env var" => quote
            @test !haskey(ENV, "SPECIAL_ENV_VAR")
            @test should_be_defined()
        end,
        "threads/1" => quote
            @test Base.Threads.nthreads() == 1
            @test should_be_defined()
        end,
        "threads/2" => quote
            @test Base.Threads.nthreads() == 2
            @test should_be_defined()
        end
    )

    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; test_worker, init_code, init_worker_code, testsuite, stdout=io, stderr=io)

    str = String(take!(io))
    @test contains(str, r"needs env var .+ started at")
    @test contains(str, r"doesn't need env var .+ started at")
    @test contains(str, r"threads/1 .+ started at")
    @test contains(str, r"threads/2 .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "failing test" begin
    testsuite = Dict(
        "failing test" => quote
            println("This test will fail")
            @test 1 == 2
        end
    )
    error_line = @__LINE__() - 3

    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=ioc, stderr=ioc)
    end

    str = String(take!(io))
    @test contains(str, r"failing test.+ failed at")
    @test contains(str, "$(basename(@__FILE__)):$error_line")
    @test contains(str, "FAILURE")
    @test contains(str, "Output generated during execution of '\e[31mfailing test\e[39m':")
    @test contains(str, "Test Failed")
    @test contains(str, "1 == 2")
end

@testset "nested failure" begin
    testsuite = Dict(
        "nested" => quote
            @test true
            @testset "foo" begin
                @test true
                @testset "bar" begin
                    @test false
                end
            end
        end
    )
    error_line = @__LINE__() - 5

    io = IOBuffer()
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=io, stderr=io)
    end

    str = String(take!(io))
    @test contains(str, r"nested .+ started at")
    @test contains(str, r"nested .+ failed at")
    @test contains(str, r"nested .+ \| .+ 2 .+ 1 .+ 3")
    @test contains(str, r"foo .+ \| .+ 1 .+ 1 .+ 2")
    @test contains(str, r"bar .+ \| .+ 1 .+ 1")
    @test contains(str, "FAILURE")
    @test contains(str, "Error in testset bar")
    @test contains(str, "$(basename(@__FILE__)):$error_line")
end

@testset "throwing test" begin
    testsuite = Dict(
        "throwing test" => quote
            error("This test throws an error")
        end
    )
    error_line = @__LINE__() - 3

    io = IOBuffer()
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=io, stderr=io)
    end

    str = String(take!(io))
    @test contains(str, r"throwing test .+ failed at")
    @test contains(str, "$(basename(@__FILE__)):$error_line")
    @test contains(str, "FAILURE")
    @test contains(str, "Error During Test")
    @test contains(str, "This test throws an error")
end

@testset "crashing test" begin
    msg = "This test will crash"
    testsuite = Dict(
        "abort" => quote
            println($(msg))
            abort() = ccall(:abort, Nothing, ())
            abort()
        end
    )

    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(ParallelTestRunner, ["--verbose"]; testsuite, stdout=ioc, stderr=ioc)
    end

    str = String(take!(io))
    @test contains(str, "Output generated during execution of '\e[31mabort\e[39m':")
    # Make sure we can capture the output generated by the crashed process, see
    # issue <https://github.com/JuliaTesting/ParallelTestRunner.jl/issues/83>.
    @test contains(str, msg)
    # "in expression starting at" comes from the abort trap, make sure we
    # captured that as well.
    @test contains(str, "in expression starting at")
    # Following are messages printed by ParallelTestRunner.
    @test contains(str, r"abort .+ started at")
    @test contains(str, r"abort.+ crashed at")
    @test contains(str, "FAILURE")
    @test contains(str, "Error During Test")
    @test contains(str, "Malt.TerminatedWorkerException")
end

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

@testset "reuse of workers" begin
    testsuite = Dict(
        "a" => :(),
        "b" => :(),
        "c" => :(),
        "d" => :(),
        "e" => :(),
        "f" => :(),
    )
    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    old_id_counter = ParallelTestRunner.ID_COUNTER[]
    njobs = 1
    runtests(ParallelTestRunner, ["--jobs=$(njobs)"]; testsuite, stdout=ioc, stderr=ioc)
    str = String(take!(io))
    @test contains(str, "Running $(njobs) tests in parallel")
    @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + njobs
end

# Count direct child processes of current process (for default-worker test).
# Returns -1 if unsupported so the test can be skipped.
function _count_child_pids()
    pid = getpid()
    if Sys.isunix() && !isnothing(Sys.which("ps"))
        pids = Int[]
        out = try
            readchomp(`ps -o ppid= -o pid= -A`)
        catch
            return -1
        end
        lines = split(out, '\n')
        for line in lines
            m = match(r" *(\d+) +(\d+)", line)
            if !isnothing(m)
                if parse(Int, m[1]) == pid
                    push!(pids, parse(Int, m[2]))
                end
            end
        end
        # The output of `ps` always contains `ps` itself because it's spawn by
        # the current process, so we subtract one to always exclude it.
        return length(pids) - 1
    else
        return -1
    end
end

# Issue <https://github.com/JuliaTesting/ParallelTestRunner.jl/issues/106>.
@testset "default workers stopped at end" begin
    # Use default workers (no test_worker) so the framework creates and should stop them.
    # More tests than workers so some tasks finish early and must stop their worker.
    testsuite = Dict(
        "t1" => :(),
        "t2" => :(),
        "t3" => :(),
        "t4" => :(),
        "t5" => :(),
        "t6" => :(),
    )
    before = _count_child_pids()
    if before < 0
        # Counting child PIDs not supported on this platform
        @test_broken false
    else
        old_id_counter = ParallelTestRunner.ID_COUNTER[]
        njobs = 2
        runtests(ParallelTestRunner, ["--jobs=$(njobs)", "--verbose"]; testsuite, stdout=devnull, stderr=devnull)
        @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + njobs
        # Allow a moment for worker processes to exit
        for _ in 1:50
            sleep(0.1)
            after = _count_child_pids()
            after >= 0 && after <= before && break
        end
        after = _count_child_pids()
        @test after >= 0
        @test after == before
    end
end

# Custom workers are handled differently:
# <https://github.com/JuliaTesting/ParallelTestRunner.jl/pull/107#issuecomment-3980645143>.
# But we still want to make sure they're terminated at the end.
@testset "custom workers stopped at end" begin
    testsuite = Dict(
        "a" => :(),
        "b" => :(),
        "c" => :(),
        "d" => :(),
        "e" => :(),
        "f" => :(),
    )
    procs = Base.Process[]
    procs_lock = ReentrantLock()
    function test_worker(name)
        wrkr = addworker()
        Base.@lock procs_lock push!(procs, wrkr.w.proc)
        return wrkr
    end
    runtests(ParallelTestRunner, Base.ARGS; test_worker, testsuite, stdout=devnull, stderr=devnull)
    @test all(!Base.process_running, procs)
end

end
