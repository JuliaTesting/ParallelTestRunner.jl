# Workers must not outlive the manager process. Malt spawns them detached: on Unix they get
# their own session, so the signals CI runners send to the process group of the job when
# it's cancelled don't reach them, and on Windows they break away from libuv's job which
# kills its processes when the manager exits. A worker also notices the manager is gone
# only when its event loop runs, which may never happen if it's busy running a test, and
# if the manager is SIGKILLed it has no chance to stop its workers. So we ask the OS to
# kill the workers when the manager dies, where that's possible:
#
# * on Linux and FreeBSD each worker asks for a SIGKILL when its parent process exits;
# * on Windows the manager puts its workers in a job object which kills its processes when
#   its last handle, held only by the manager, is closed, i.e. when the manager exits.
#
# On macOS there is no such facility, short of keeping a task always running in the worker
# to watch the manager, so workers there are only covered when the manager exits normally
# or on SIGTERM, by the `atexit` hook below.

"""
    arm_manager_death!(manager_pid)

Run in a worker, make the OS kill it when the manager process, with PID `manager_pid`,
exits. Returns whether this was successful.
"""
function arm_manager_death!(manager_pid::Integer)
    @static if Sys.islinux() || Sys.isfreebsd()
        # when `exename` is a wrapper, e.g. `compute-sanitizer julia`, our parent is the
        # wrapper, not the manager. If the manager is gone already we are idle, waiting for
        # the next request, so we'll exit anyway as soon as we see the socket is closed.
        (@ccall getppid()::Cint) == manager_pid || return false
        ok = @static if Sys.islinux()
            # The signal is sent when the *thread* which spawned us exits, not the process,
            # but the manager spawns workers from Julia's threads, which live until exit.
            PR_SET_PDEATHSIG = Cint(1)
            (@ccall prctl(PR_SET_PDEATHSIG::Cint; Base.SIGKILL::Culong)::Cint) == 0
        else
            P_PID = Cint(0)
            PROC_PDEATHSIG_CTL = Cint(11)
            signum = Ref(Cint(Base.SIGKILL))
            (@ccall procctl(P_PID::Cint, 0::Int64, PROC_PDEATHSIG_CTL::Cint,
                            signum::Ptr{Cint})::Cint) == 0
        end
        # the manager may have died before we asked for the signal
        (@ccall getppid()::Cint) == manager_pid || @ccall _exit(1::Cint)::Cvoid
        return ok
    else
        return false
    end
end

@static if Sys.iswindows()

# `JOBOBJECT_EXTENDED_LIMIT_INFORMATION`, 144 bytes on 64-bit Windows, 112 on 32-bit
struct JobObjectExtendedLimitInformation
    # JOBOBJECT_BASIC_LIMIT_INFORMATION
    per_process_user_time_limit::Int64
    per_job_user_time_limit::Int64
    limit_flags::UInt32
    minimum_working_set_size::UInt
    maximum_working_set_size::UInt
    active_process_limit::UInt32
    affinity::UInt
    priority_class::UInt32
    scheduling_class::UInt32
    # IO_COUNTERS
    io_counters::NTuple{6,UInt64}
    process_memory_limit::UInt
    job_memory_limit::UInt
    peak_process_memory_used::UInt
    peak_job_memory_used::UInt
end

const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = UInt32(0x2000)
const JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS = Cint(9)
const PROCESS_TERMINATE = UInt32(0x0001)
const PROCESS_SET_QUOTA = UInt32(0x0100)

# The job object of the workers. Its handle is never closed, the OS does it when the
# manager exits, killing the workers.
const WORKERS_JOB = Lockable(Ref(C_NULL))

function create_workers_job()
    sizeof(JobObjectExtendedLimitInformation) == (Sys.WORD_SIZE == 64 ? 144 : 112) ||
        return C_NULL
    job = ccall((:CreateJobObjectW, "kernel32"), stdcall, Ptr{Cvoid},
                (Ptr{Cvoid}, Ptr{Cvoid}), C_NULL, C_NULL)
    job == C_NULL && return C_NULL
    info = Ref(JobObjectExtendedLimitInformation(0, 0, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
                                                 0, 0, 0, 0, 0, 0, ntuple(_ -> 0, 6),
                                                 0, 0, 0, 0))
    ok = ccall((:SetInformationJobObject, "kernel32"), stdcall, Cint,
               (Ptr{Cvoid}, Cint, Ptr{JobObjectExtendedLimitInformation}, UInt32),
               job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION_CLASS, info,
               sizeof(JobObjectExtendedLimitInformation))
    if ok == 0
        ccall((:CloseHandle, "kernel32"), stdcall, Cint, (Ptr{Cvoid},), job)
        return C_NULL
    end
    return job
end

function assign_to_workers_job(pid::Integer)
    job = @lock WORKERS_JOB begin
        if WORKERS_JOB[][] == C_NULL
            WORKERS_JOB[][] = create_workers_job()
        end
        WORKERS_JOB[][]
    end
    job == C_NULL && return false
    process = ccall((:OpenProcess, "kernel32"), stdcall, Ptr{Cvoid}, (UInt32, Cint, UInt32),
                    PROCESS_TERMINATE | PROCESS_SET_QUOTA, false, pid)
    process == C_NULL && return false
    ok = ccall((:AssignProcessToJobObject, "kernel32"), stdcall, Cint,
               (Ptr{Cvoid}, Ptr{Cvoid}), job, process)
    ccall((:CloseHandle, "kernel32"), stdcall, Cint, (Ptr{Cvoid},), process)
    return ok != 0
end

else

assign_to_workers_job(pid::Integer) = false

end

# The workers not stopped yet, by `worker_id`
const LIVE_WORKERS = Lockable(Dict{Int,PTRWorker}())

# Stop the workers still running when the manager exits, e.g. on SIGTERM. Malt does this
# too, but one worker at a time, waiting up to 30 seconds for each one before killing it,
# while CI runners usually give a few seconds before killing the manager altogether.
function stop_live_workers()
    workers = @lock LIVE_WORKERS begin
        workers = collect(values(LIVE_WORKERS[]))
        empty!(LIVE_WORKERS[])
        workers
    end
    filter!(Malt.isrunning, workers)
    isempty(workers) && return
    @static if VERSION < v"1.11" && !Sys.iswindows()
        # On SIGTERM Julia v1.10 runs the `atexit` hooks while holding the I/O lock, so
        # anything waiting on the event loop hangs: kill the workers without waiting.
        for wrkr in workers
            @ccall kill(wrkr.w.proc_pid::Cint, Base.SIGKILL::Cint)::Cint
        end
        return
    end
    # ask nicely first, so that they can e.g. write their coverage files
    for wrkr in workers
        try
            Malt.remote_do(Base.exit, wrkr.w)
        catch
        end
    end
    timedwait(() -> !any(Malt.isrunning, workers), 2; pollint=0.05)
    for wrkr in workers
        Malt.isrunning(wrkr) && kill(wrkr.w, Base.SIGKILL)
    end
    # wait for them to be reaped, so that Malt doesn't try to stop them again
    timedwait(() -> !any(Malt.isrunning, workers), 5; pollint=0.05)
    return
end

"""
    bind_worker!(wrkr::PTRWorker)

Run in the manager, make sure `wrkr` doesn't outlive it. See also [`arm_manager_death!`](@ref).
"""
function bind_worker!(wrkr::PTRWorker)
    try
        @static if Sys.iswindows()
            assign_to_workers_job(wrkr.w.proc_pid)
        elseif Sys.islinux() || Sys.isfreebsd()
            Malt.remote_eval_wait(Main, wrkr.w,
                                  :(ParallelTestRunner.arm_manager_death!($(getpid()))))
        end
    catch err
        # this is best-effort, and must never break the test run
        @debug "Could not bind the worker to the manager" exception=(err, catch_backtrace())
    end
    @lock LIVE_WORKERS LIVE_WORKERS[][worker_id(wrkr)] = wrkr
    # `atexit` hooks run in reverse order, and Malt registers one for each new worker, which
    # would stop it slowly, so register ours again to run first.
    atexit(stop_live_workers)
    return
end

unbind_worker!(wrkr::PTRWorker) = @lock LIVE_WORKERS delete!(LIVE_WORKERS[], worker_id(wrkr))
