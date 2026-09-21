const ID_COUNTER = Threads.Atomic{Int}(1)

# Thin wrapper around Malt.Worker, to handle the stdio loop differently.
struct PTRWorker <: Malt.AbstractWorker
    w::Malt.Worker
    io::Lockable{IOBuffer, ReentrantLock}
    id::Int
end

function PTRWorker(; exename=Base.julia_cmd()[1], exeflags=String[], env=String[])
    io = Lockable(IOBuffer())
    wrkr = Malt.Worker(; exename, exeflags, env, monitor_stdout=false, monitor_stderr=false)
    stdio_loop(wrkr, io)
    id = Threads.atomic_add!(ID_COUNTER, 1)
    return PTRWorker(wrkr, io, id)
end


# Adapted from `Malt._stdio_loop`, used by PTRWorker
function stdio_loop(worker::Malt.Worker, io::Lockable)
    Threads.@spawn while !eof(worker.stdout) && Malt.isrunning(worker)
        try
            bytes = readavailable(worker.stdout)
            @lock io write(io[], bytes)
        catch
            break
        end
    end
    Threads.@spawn while !eof(worker.stderr) && Malt.isrunning(worker)
        try
            bytes = readavailable(worker.stderr)
            @lock io write(io[], bytes)
        catch
            break
        end
    end
end

worker_id(wrkr::PTRWorker) = wrkr.id
Malt.isrunning(wrkr::PTRWorker) = Malt.isrunning(wrkr.w)
Malt.stop(wrkr::PTRWorker) = Malt.stop(wrkr.w)


function test_exe(color::Bool=false)
    test_exeflags = Base.julia_cmd()
    push!(test_exeflags.exec, "--project=$(Base.active_project())")
    push!(test_exeflags.exec, "--color=$(color ? "yes" : "no")")
    return test_exeflags
end

"""
    addworkers(; env=Vector{Pair{String, String}}(), init_worker_code = :(), exename=nothing, exeflags=nothing, color::Bool=false)

Add `X` worker processes.
To add a single worker, use [`addworker`](@ref).

## Arguments
- `env`: Vector of environment variable pairs to set for the worker process.
- `init_worker_code`: Code use to initialize each worker. This is run only once per worker instead of once per test.
- `exename`: Custom executable to use for the worker process.
- `exeflags`: Custom flags to pass to the worker process.
- `color`: Boolean flag to decide whether to start `julia` with `--color=yes` (if `true`) or `--color=no` (if `false`).
"""
addworkers(X; kwargs...) = [addworker(; kwargs...) for _ in 1:X]

"""
    addworker(; env=Vector{Pair{String, String}}(), init_worker_code = :(), exename=nothing, exeflags=nothing; color::Bool=false)

Add a single worker process.
To add multiple workers, use [`addworkers`](@ref).

## Arguments
- `env`: Vector of environment variable pairs to set for the worker process.
- `init_worker_code`: Code use to initialize each worker. This is run only once per worker instead of once per test.
- `exename`: Custom executable to use for the worker process.
- `exeflags`: Custom flags to pass to the worker process.
- `color`: Boolean flag to decide whether to start `julia` with `--color=yes` (if `true`) or `--color=no` (if `false`).
"""
function addworker(;
        env = Vector{Pair{String, String}}(),
        init_worker_code = :(),
        exename = nothing,
        exeflags = nothing,
        color::Bool = false,
    )
    exe = test_exe(color)
    if exename === nothing
        exename = exe[1]
    end
    if exeflags !== nothing
        exeflags = vcat(exe[2:end], exeflags)
    else
        exeflags = exe[2:end]
    end

    # don't mutate the caller's vector; multiple workers may share a default
    worker_env = copy(env)
    push!(worker_env, "JULIA_NUM_THREADS" => "1")
    # Malt already sets OPENBLAS_NUM_THREADS to 1
    push!(worker_env, "OPENBLAS_NUM_THREADS" => "1")
    wrkr = PTRWorker(; exename, exeflags, env = worker_env)
    # make ParallelTestRunner available to `init_worker_code`; users commonly
    # need it to reference `AbstractTestRecord`, `execute`, etc. when defining
    # custom record types.
    Malt.remote_eval_wait(Main, wrkr.w, :(import ParallelTestRunner))
    if init_worker_code != :()
        Malt.remote_eval_wait(Main, wrkr.w, init_worker_code)
    end
    return wrkr
end
