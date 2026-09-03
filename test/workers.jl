@testset "custom worker" begin
    # Custom workers are handled differently:
    # <https://github.com/JuliaTesting/ParallelTestRunner.jl/pull/107#issuecomment-3980645143>.
    # But we still want to make sure they're terminated at the end, so keep track of them.
    procs = Base.Process[]
    procs_lock = ReentrantLock()
    function test_worker(name)
        wrkr = if name == "needs env var"
            addworker(env = ["SPECIAL_ENV_VAR" => "42"])
        elseif name == "threads/2"
            addworker(exeflags = ["--threads=2"])
        else
            return nothing
        end
        Base.@lock procs_lock push!(procs, wrkr.w.proc)
        return wrkr
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
    @test length(procs) == 2
    @test all(!Base.process_running, procs)
end

@testset "global worker kwargs" begin
    # `exename`/`exeflags`/`env` on runtests should propagate to every
    # default-pool worker. We verify via an environment variable propagated
    # through `env`, Julia flags threaded through `exeflags`, and `exename`
    # supplied as a `Cmd` prefixing the julia binary (what CUDA.jl uses to
    # wrap julia with `compute-sanitizer`).
    testsuite = Dict(
        "env var" => quote
            @test ENV["GLOBAL_WORKER_TEST"] == "yes"
        end,
        "threads" => quote
            @test Base.Threads.nthreads() == 2
        end,
    )
    io = IOBuffer()
    runtests(ParallelTestRunner, ["--verbose"]; testsuite,
             env = ["GLOBAL_WORKER_TEST" => "yes"],
             exeflags = ["--threads=2"],
             exename = `$(Base.julia_cmd()[1])`,  # trivial Cmd wrapping julia
             stdout = io, stderr = io)
    str = String(take!(io))
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

# Issue <https://github.com/JuliaTesting/ParallelTestRunner.jl/issues/106>.
@testset "default workers reused and stopped at end" begin
    # Use default workers (no test_worker) so the framework creates and should stop them.
    # More tests than workers so that workers are reused, and so that some tasks finish
    # early and must stop their worker.
    testsuite = Dict(
        "t1" => :(),
        "t2" => :(),
        "t3" => :(),
        "t4" => :(),
        "t5" => :(),
        "t6" => quote
            # Make this test run longer than the others so that it runs alone...
            sleep(5)
            children = _count_child_pids($(getpid()))
            # ...then check there's only one worker still running. WARNING: this test may be
            # flaky on very busy systems, if at this point some of the other tests are still
            # running, hope for the best.
            if children >= 0
                @test children == 1
            end
        end,
    )
    before = _count_child_pids()
    old_id_counter = ParallelTestRunner.ID_COUNTER[]
    njobs = 2
    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    @show_if_error io runtests(ParallelTestRunner, ["--jobs=$(njobs)", "--verbose"];
                               testsuite, stdout=ioc, stderr=ioc, init_code=:(include($(joinpath(@__DIR__, "utils.jl")))))
    str = String(take!(io))
    @test contains(str, "Running $(length(testsuite)) tests using $(njobs) parallel jobs")
    @test contains(str, "SUCCESS")
    # Make sure we didn't spawn more workers than expected: the same workers ran all tests.
    @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + njobs
    if before < 0
        # Counting child PIDs not supported on this platform
        @test_skip false
    else
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

@testset "addworkers" begin
    workers = addworkers(2)
    @test length(workers) == 2
    @test all(w -> w isa ParallelTestRunner.PTRWorker, workers)
    @test all(w -> Base.process_running(w.w.proc), workers)
    for w in workers
        ParallelTestRunner.Malt.stop(w)
    end
    sleep(0.5)
    @test all(w -> !Base.process_running(w.w.proc), workers)
end

@testset "worker RSS recycling" begin
    testsuite = Dict(
        "alloc1" => :( @test true ),
        "alloc2" => :( @test true ),
        "alloc3" => :( @test true ),
        "alloc4" => :( @test true ),
    )
    io = IOBuffer()
    old_id_counter = ParallelTestRunner.ID_COUNTER[]
    runtests(ParallelTestRunner, ["--jobs=1"]; testsuite, stdout=io, stderr=io, max_worker_rss=0)
    str = String(take!(io))
    @test contains(str, "SUCCESS")
    @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + length(testsuite)
end

@testset "recycle_on_failure" begin
    # Call `_runtests` so that we can enforce a run order, and use a single job, so that
    # all tests share the same pool slot: a test only gets a new worker if the previous one
    # was recycled. The default behaviour (workers reused across failures) is covered by
    # the "failing retry does not reuse its worker" testset in `retries.jl`.
    testsuite = Dict(
        "fail1" => :( @test false ),
        "pass1" => :( @test true ),
        "fail2" => :( @test false ),
        "pass2" => :( @test true ),
    )
    tests = ["fail1", "pass1", "fail2", "pass2"]

    io = IOBuffer()
    old_id_counter = ParallelTestRunner.ID_COUNTER[]
    @test_throws Test.FallbackTestSetException begin
        ParallelTestRunner._runtests(
            ParallelTestRunner, parse_args(["--jobs=1"]);
            testsuite,
            tests,
            stdout=io,
            stderr=io,
            recycle_on_failure=true,
        )
    end
    str = String(take!(io))
    @test contains(str, "FAILURE")
    # `fail1` and `fail2` recycle their worker, so `pass1` and `pass2` each need a fresh
    # one: 1 initial worker + 2 replacements.
    @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + 3
end
