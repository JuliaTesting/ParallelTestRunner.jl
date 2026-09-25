# Memory and job-count sizing for test workers

# Always set the max rss so that if tests add large global variables
#  (which they do) we don't make the GC's life too hard. Apple's memory
#  management makes setting this value more complicated than it should
function get_max_worker_rss()
    mb = if haskey(ENV, "JULIA_TEST_MAXRSS_MB")
        parse(Int, ENV["JULIA_TEST_MAXRSS_MB"])
    elseif Sys.WORD_SIZE == 64
        totalmem = Sys.total_memory()
        if Sys.isapple()
            if totalmem <= 8*Int64(2)^30
                2000
            elseif totalmem <= 16*Int64(2)^30
                2500
            else
                3800
            end
        elseif totalmem > 8*Int64(2)^30
            3800
        else # Low memory not on macOS
            3000
        end
    else
        # Assume that we only have 3.5GB available to a single process, and that a single
        # test can take up to 2GB of RSS.  This means that we should instruct the test
        # framework to restart any worker that comes into a test set with 1.5GB of RSS.
        1536
    end
    return mb * 2^20
end

# Assumed memory footprint of a single test worker, used to clamp the default
# number of jobs on memory-constrained machines (e.g. many cores but little
# memory). Packages whose tests are heavier can pass a larger
# `memory_per_worker` to `runtests`.
const DEFAULT_MEMORY_PER_WORKER = 2 * Int64(2)^30

"""
    default_njobs(; memory_per_worker = 2 * 2^30)

A function used to determine the default number of parallel jobs. Calculated as the
number of CPU threads, clamped such that each worker can be assumed to use `memory_per_worker`
bytes of the available system memory.
"""
function default_njobs(;
        memory_per_worker = DEFAULT_MEMORY_PER_WORKER,
        # Just use Sys.EFFECTIVE_CPU_THREADS when min VERSION >= v"1.13"
        _cpu_threads = (@static isdefined(Sys, :EFFECTIVE_CPU_THREADS) ? Sys.EFFECTIVE_CPU_THREADS : Sys.CPU_THREADS),
        _free_memory = available_memory(),
    )
    memory_jobs = Int64(_free_memory) ÷ memory_per_worker
    return max(1, min(_cpu_threads, memory_jobs))
end
