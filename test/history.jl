using Test
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
        batch = 3
        names = ["parallel_$i" for i in 1:batch]
        testsuite = Dict(name => :(@test true) for name in names)
        # runs after the parallel batch and inspects the history from inside the worker:
        # the batch of `history_flush_every` tests must already be on disk
        testsuite["last"] = :(@test length(Main.ParallelTestRunner.deserialize($file)[1]) == $batch)
        io = IOBuffer()
        @show_if_error io runtests(mod, ["--jobs=2"]; testsuite, serial=["last"], serial_position=:after,
                                   history_flush_every=batch, stdout=io, stderr=io)
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
        elapsed = @elapsed @test_logs (:warn, r"attempting to remove probably stale pidfile") ParallelTestRunner.update_test_history!(mod, Dict("a" => 1.0), Set(["a"]), Set{String}())
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
        @test_logs (:warn, r"Failed to load test history") ParallelTestRunner.update_test_history!(mod, Dict("a" => 1.0), Set(["a"]), Set{String}())
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

@testset "history_key selects the history file" begin
    mod = history_module("key")
    @test ParallelTestRunner.get_history_file(mod, nothing) == history_file(mod)
    keyed = ParallelTestRunner.get_history_file(mod, "gpu")
    @test dirname(keyed) == dirname(history_file(mod))
    @test basename(keyed) == "HistoryTest_key-gpu.jls"
    sanitized = ParallelTestRunner.get_history_file(mod, "cuda/12.9 x")
    @test dirname(sanitized) == dirname(history_file(mod))
    @test basename(sanitized) == "HistoryTest_key-cuda_12.9_x.jls"
    @test_throws ArgumentError ParallelTestRunner.get_history_file(mod, "")
end

@testset "keyed and unkeyed histories are independent" begin
    mod = history_module("isolation")
    keyed_file = ParallelTestRunner.get_history_file(mod, "gpu")
    remove_history(mod)
    rm(keyed_file; force=true)
    try
        io = IOBuffer()
        runtests(mod, ["--jobs=1"]; testsuite=Dict("a" => :(@test true)), history_key="gpu", stdout=io, stderr=io)
        runtests(mod, ["--jobs=1"]; testsuite=Dict("b" => :(@test true)), stdout=io, stderr=io)
        @test collect(keys(first(ParallelTestRunner.load_test_history(mod, "gpu")))) == ["a"]
        @test collect(keys(first(ParallelTestRunner.load_test_history(mod)))) == ["b"]
    finally
        remove_history(mod)
        rm(keyed_file; force=true)
    end
end

@testset "scheduling uses the keyed history" begin
    mod = history_module("keyed_order")
    keyed_file = ParallelTestRunner.get_history_file(mod, "gpu")
    remove_history(mod)
    rm(keyed_file; force=true)
    try
        # the two histories disagree on which test is slow; the keyed one must decide
        ParallelTestRunner.save_test_history(mod, (Dict("slow" => 10.0, "fast" => 1.0), Set{String}()); history_key="gpu")
        ParallelTestRunner.save_test_history(mod, (Dict("slow" => 1.0, "fast" => 10.0), Set{String}()))
        testsuite = Dict("slow" => :(@test true), "fast" => :(@test true))
        io = IOBuffer()
        runtests(mod, ["--jobs=1", "--verbose"]; testsuite, history_key="gpu", stdout=io, stderr=io)
        str = String(take!(io))
        @test findfirst("slow", str) < findfirst("fast", str)
    finally
        remove_history(mod)
        rm(keyed_file; force=true)
    end
end

@testset "--list respects history_key" begin
    mod = history_module("keyed_list")
    keyed_file = ParallelTestRunner.get_history_file(mod, "gpu")
    remove_history(mod)
    rm(keyed_file; force=true)
    function list_output(kwargs)
        code = """
            using ParallelTestRunner
            testsuite = Dict("alpha" => :(@test true))
            runtests(Module($(repr(nameof(mod)))), ["--list"]; testsuite, $kwargs)
            """
        return readlines(`$run_history_test_process --color=no -e $code`)
    end
    try
        ParallelTestRunner.save_test_history(mod, (Dict("alpha" => 1.234), Set{String}()); history_key="gpu")
        @test list_output("history_key=\"gpu\"") == ["Available tests:", " - alpha  (1.23s)"]
        @test list_output("history_key=nothing") == ["Available tests:", " - alpha"]
    finally
        remove_history(mod)
        rm(keyed_file; force=true)
    end
end

# All workers must have been stopped once `runtests` returns.
@testset "no workers running" begin
    children = _count_child_pids()
    if children >= 0
        @test children == 0
    end
end
