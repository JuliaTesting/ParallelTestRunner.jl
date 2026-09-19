using ParallelTestRunner: Pidfile, deserialize

history_module(name) = Module(Symbol("HistoryTest_", name))
history_file(mod) = ParallelTestRunner.get_history_file(mod)
lock_file(mod) = history_file(mod) * ".lock"

function remove_history(mod)
    rm(history_file(mod); force=true)
    rm(lock_file(mod); force=true)
end

const run_history_test_process = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project())`

function backdate!(path, seconds)
    t = time() - seconds
    req = Libc.malloc(Base._sizeof_uv_fs)
    ret = @ccall uv_fs_utime(C_NULL::Ptr{Cvoid}, req::Ptr{Cvoid}, path::Cstring, t::Cdouble, t::Cdouble, C_NULL::Ptr{Cvoid})::Cint
    Base.Filesystem.uv_fs_req_cleanup(req)
    Libc.free(req)
    ret < 0 && Base.uv_error("utime", ret)
    return nothing
end

@testset "merge keeps entries of tests this run did not execute" begin
    mod = history_module("merge")
    remove_history(mod)
    try
        ParallelTestRunner.save_test_history(mod, (Dict("a" => 1.0, "b" => 2.0), Set(["b"])))
        testsuite = Dict("a" => :(@test true), "c" => :(@test true))
        io = IOBuffer()
        runtests(mod, ["--jobs=1"]; testsuite, stdout=io, stderr=io)

        durations, failures = ParallelTestRunner.load_test_history(mod)
        @test Set(keys(durations)) == Set(["a", "b", "c"])
        @test durations["a"] != 1.0
        @test durations["b"] == 2.0
        @test failures == Set(["b"])
    finally
        remove_history(mod)
    end
end

@testset "failure flags follow the latest outcome" begin
    mod = history_module("failures")
    remove_history(mod)
    try
        ParallelTestRunner.save_test_history(mod, (Dict("a" => 1.0), Set(["a"])))
        testsuite = Dict("a" => :(@test true), "d" => :(@test false))
        io = IOBuffer()
        @test_throws Test.FallbackTestSetException runtests(mod, ["--jobs=1"]; testsuite, stdout=io, stderr=io)

        durations, failures = ParallelTestRunner.load_test_history(mod)
        @test haskey(durations, "a") && haskey(durations, "d")
        @test failures == Set(["d"])
    finally
        remove_history(mod)
    end
end

@testset "history is written in batches during the run" begin
    mod = history_module("batches")
    remove_history(mod)
    try
        file = history_file(mod)
        batch = ParallelTestRunner.history_flush_every
        names = ["parallel_$i" for i in 1:batch]
        testsuite = Dict(name => :(@test true) for name in names)
        # runs after the parallel batch and inspects the history from inside the worker:
        # the batch of `history_flush_every` tests must already be on disk
        testsuite["last"] = :(@test length(Main.ParallelTestRunner.deserialize($file)[1]) == $batch)
        io = IOBuffer()
        @show_if_error io runtests(mod, ["--jobs=2"]; testsuite, serial=["last"], serial_position=:after, stdout=io, stderr=io)
        durations, _ = ParallelTestRunner.load_test_history(mod)
        @test Set(keys(durations)) == Set([names; "last"])
    finally
        remove_history(mod)
    end
end

@testset "fewer tests than a batch are written at the end" begin
    mod = history_module("small_batch")
    remove_history(mod)
    try
        file = history_file(mod)
        testsuite = Dict(
            "first" => :(@test true),
            "last" => :(@test !isfile($file)),   # nothing flushed yet
        )
        io = IOBuffer()
        @show_if_error io runtests(mod, ["--jobs=1"]; testsuite, serial=["last"], serial_position=:after, stdout=io, stderr=io)
        durations, _ = ParallelTestRunner.load_test_history(mod)
        @test Set(keys(durations)) == Set(["first", "last"])
    finally
        remove_history(mod)
    end
end

@testset "update waits for a concurrent writer" begin
    mod = history_module("contention")
    remove_history(mod)
    try
        ParallelTestRunner.save_test_history(mod, (Dict("a" => 1.0), Set{String}()))
        code = """
            using ParallelTestRunner: Pidfile
            Pidfile.mkpidlock($(repr(lock_file(mod))); stale_age=60) do
                println("locked"); flush(stdout)
                sleep(2)
            end
            """
        holder = open(`$run_history_test_process -e $code`)
        @test readline(holder) == "locked"
        elapsed = @elapsed ParallelTestRunner.update_test_history!(mod, Dict("b" => 5.0), Set(["b"]), Set{String}())
        wait(holder)
        @test elapsed >= 1.0
        durations, _ = ParallelTestRunner.load_test_history(mod)
        @test durations == Dict("a" => 1.0, "b" => 5.0)
    finally
        remove_history(mod)
    end
end

@testset "two concurrent runs share one history file" begin
    mod = history_module("parallel")
    remove_history(mod)
    try
        function runner(names)
            code = """
                using ParallelTestRunner, Test
                testsuite = Dict(name => :(@test true) for name in $(repr(names)))
                runtests(Module($(repr(nameof(mod)))), ["--jobs=1"]; testsuite)
                """
            return run(pipeline(`$run_history_test_process -e $code`; stdout=devnull, stderr=devnull); wait=false)
        end
        processes = [runner(("p1", "p2")), runner(("q1", "q2"))]
        foreach(wait, processes)
        @test all(success, processes)
        durations, _ = ParallelTestRunner.load_test_history(mod)
        @test Set(keys(durations)) == Set(["p1", "p2", "q1", "q2"])
    finally
        remove_history(mod)
    end
end

@testset "history is written atomically" begin
    mod = history_module("atomic")
    remove_history(mod)
    try
        ParallelTestRunner.update_test_history!(mod, Dict("a" => 1.0), Set(["a"]), Set{String}())
        entries = readdir(dirname(history_file(mod)))
        @test basename(history_file(mod)) in entries
        @test !any(contains(".tmp."), entries)
        @test !isfile(lock_file(mod))
    finally
        remove_history(mod)
    end
end

@testset "stale lock is broken" begin
    mod = history_module("stale")
    remove_history(mod)
    try
        mkpath(dirname(history_file(mod)))
        # a lock left behind by a process that no longer exists, older than the stale age
        dead_pid = typemax(Cint) - 1
        write(lock_file(mod), "$dead_pid $(gethostname())")
        backdate!(lock_file(mod), 10 * 60)
        elapsed = @elapsed ParallelTestRunner.update_test_history!(mod, Dict("a" => 1.0), Set(["a"]), Set{String}())
        @test elapsed < 10
        durations, _ = ParallelTestRunner.load_test_history(mod)
        @test durations == Dict("a" => 1.0)
    finally
        remove_history(mod)
    end
end

@testset "corrupt history is tolerated" begin
    mod = history_module("corrupt")
    remove_history(mod)
    try
        mkpath(dirname(history_file(mod)))
        write(history_file(mod), "not a serialized history")
        history = @test_logs (:warn, r"Failed to load test history") ParallelTestRunner.load_test_history(mod)
        @test history == (Dict{String, Float64}(), Set{String}())
        ParallelTestRunner.update_test_history!(mod, Dict("a" => 1.0), Set(["a"]), Set{String}())
        @test ParallelTestRunner.load_test_history(mod) == (Dict("a" => 1.0), Set{String}())
    finally
        remove_history(mod)
    end
end

@testset "save_test_history replaces the whole history" begin
    mod = history_module("save")
    remove_history(mod)
    try
        ParallelTestRunner.save_test_history(mod, (Dict("a" => 1.0), Set(["a"])))
        ParallelTestRunner.save_test_history(mod, (Dict("b" => 2.0), Set{String}()))
        @test ParallelTestRunner.load_test_history(mod) == (Dict("b" => 2.0), Set{String}())
    finally
        remove_history(mod)
    end
end

# All workers must have been stopped once `runtests` returns.
@testset "no workers running" begin
    children = _count_child_pids()
    if children >= 0
        @test children == 0
    end
end
