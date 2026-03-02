# Count direct child processes of current process (for default-worker test).
# Returns -1 if unsupported so the test can be skipped.
function _count_child_pids(pid = getpid())
    if Sys.isunix() && !isnothing(Sys.which("ps"))
        pids = Int[]
        out = try
            # Suggested in <https://askubuntu.com/a/512872>.
            readchomp(`ps -o ppid= -o pid= -A`)
        catch
            return -1
        end
        lines = split(out, '\n')
        # The output of `ps` for the current process always contains `ps` itself
        # because it's spawned by the current process, in that case we subtract
        # one to always exclude it, otherwise if we're getting the number of
        # children of another process we start from 0.
        count = pid == getpid() : -1 : 0
        for line in lines
            m = match(r" *(\d+) +(\d+)", line)
            if !isnothing(m)
                if parse(Int, m[1]) == pid
                    count += 1
                end
            end
        end
        return count
    else
        return -1
    end
end
