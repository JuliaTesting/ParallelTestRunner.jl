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
# The cold init time of a worker varies between machines, so the "slow init warning"
# testset below needs a measurement of it: rather than spending a worker on a
# dedicated run, take it from the verbose output of the following testset.
cold_init_time = Ref(NaN)

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
            # Keep this test running until the other tests are done and their worker has
            # been stopped, so that this one is the only worker left. A fixed sleep is not
            # enough on slow machines, where each of the other tests takes seconds to init,
            # so poll instead (with a generous timeout).
            children = -1
            for _ in 1:1200
                children = _count_child_pids($(getpid()))
                (children < 0 || children == 1) && break
                sleep(0.1)
            end
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
    # The first test on each worker had a cold init: the slowest init is an upper bound.
    init_times = [parse(Float64, m[1]) for m in eachmatch(r"^t\d\s+\(\d+\) │\s+[\d.]+ │\s+([\d.]+) │"m, str)]
    @test length(init_times) == length(testsuite)
    cold_init_time[] = maximum(init_times)
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

@testset "slow init warning" begin
    init_worker_code = :( const slow_init_counter = Ref(0) )
    args = ["--verbose", "--jobs=1"]

    # `cold_init_time` was measured by the "default workers reused and stopped at end"
    # testset above; if that testset failed before recording it, measure it here instead
    # so that this testset stays independent.
    if isnan(cold_init_time[])
        io = IOBuffer()
        runtests(ParallelTestRunner, args; testsuite=Dict("cold" => :( @test true )), init_worker_code, stdout=io, stderr=io)
        cold_init_time[] = parse(Float64, match(r"^cold\s+\(\d+\) │\s+[\d.]+ │\s+([\d.]+) │"m, String(take!(io)))[1])
    end

    # every test after the first on the worker is slow to init
    slow_init = ceil(Int, max(1.5 * ParallelTestRunner.SLOW_INIT_FACTOR * cold_init_time[],
                              ParallelTestRunner.SLOW_INIT_MIN_TIME)) + 1
    init_code = quote
        Main.slow_init_counter[] += 1
        Main.slow_init_counter[] > 1 && sleep($slow_init)
    end
    testsuite = Dict("a" => :( @test true ), "b" => :( @test true ), "c" => :( @test true ))
    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    old_id_counter = ParallelTestRunner.ID_COUNTER[]
    runtests(ParallelTestRunner, args; testsuite, init_worker_code, init_code, stdout=ioc, stderr=ioc)
    str = String(take!(io))
    @test contains(str, "SUCCESS")
    # a slow init does not recycle the worker
    @test ParallelTestRunner.ID_COUNTER[] == old_id_counter + 1
    # both tests after the first are slow, but the warning is only printed once, and it is
    # the only thing printed in yellow
    @test count("Warning:", str) == 1
    @test count("\e[33m", str) == 1
    @test contains(str, r"Init time of `[abc]`")
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

# whether the process with PID `pid` is still running
function pid_running(pid)
    @static if Sys.iswindows()
        SYNCHRONIZE = 0x00100000
        WAIT_TIMEOUT = 0x00000102
        handle = ccall((:OpenProcess, "kernel32"), stdcall, Ptr{Cvoid},
                       (UInt32, Cint, UInt32), SYNCHRONIZE, false, pid)
        handle == C_NULL && return false
        running = ccall((:WaitForSingleObject, "kernel32"), stdcall, UInt32,
                        (Ptr{Cvoid}, UInt32), handle, 0) == WAIT_TIMEOUT
        ccall((:CloseHandle, "kernel32"), stdcall, Cint, (Ptr{Cvoid},), handle)
        return running
    else
        (@ccall kill(pid::Cint, 0::Cint)::Cint) == 0 || return false
        # a killed orphan may linger as a zombie until it's reaped
        Sys.islinux() || return true
        stat = try
            read("/proc/$(pid)/stat", String)
        catch
            return false
        end
        return split(stat[findlast(')', stat)+1:end])[1] != "Z"
    end
end

@testset "workers die with the manager" begin
    script = """
        using ParallelTestRunner
        const Malt = ParallelTestRunner.Malt
        workers = addworkers(2)
        for w in workers
            # keep the worker busy, so that it can't notice by itself that the manager is gone
            Malt.remote_eval(Main, w.w, :(let x = 0; while true; x += 1; end; end))
        end
        println(join([w.w.proc_pid for w in workers], ' '))
        sleep(600)
        """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) -e $script`
    # SIGKILL can't be handled by the manager, so we rely on the OS to kill the workers
    kill_supported = Sys.islinux() || Sys.isfreebsd() || (Sys.iswindows() && Sys.WORD_SIZE == 64)
    @testset "$(signum == Base.SIGKILL ? "SIGKILL" : "SIGTERM")" for signum in (Base.SIGTERM, Base.SIGKILL)
        if signum == Base.SIGKILL && !kill_supported
            @test_skip false
            continue
        end
        manager = open(pipeline(cmd; stderr=devnull))
        pids = parse.(Int, split(readline(manager)))
        try
            @test length(pids) == 2
            @test all(pid_running, pids)
            kill(manager, signum)
            # on SIGTERM the manager stops its workers without waiting for them too long,
            # except on Julia v1.10, where it hangs after running its `atexit` hooks
            if signum == Base.SIGKILL || VERSION >= v"1.11"
                @test timedwait(() -> process_exited(manager), 15) === :ok
            end
            @test timedwait(() -> !any(pid_running, pids), 10) === :ok
        finally
            kill(manager, Base.SIGKILL)
            for pid in filter(pid_running, pids)
                @static if Sys.iswindows()
                    run(ignorestatus(`taskkill /F /PID $(pid)`))
                else
                    @ccall kill(pid::Cint, Base.SIGKILL::Cint)::Cint
                end
            end
        end
    end
end

# All workers must have been stopped once `runtests` returns.
@testset "no workers running" begin
    children = _count_child_pids()
    if children >= 0
        @test children == 0
    end
end
