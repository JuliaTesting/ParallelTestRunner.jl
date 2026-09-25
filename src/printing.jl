#
# overridable I/O context for pretty-printing
#

struct TestIOContext
    stdout::IO
    stderr::IO
    color::Bool
    verbose::Bool
    lock::ReentrantLock
    name_align::Int
    elapsed_align::Int
    compile_align::Int
    gc_align::Int
    percent_align::Int
    alloc_align::Int
    rss_align::Int
    max_worker_rss::Int
    recycled::Ref{Bool}
    nonpass_face::Ref{Symbol}
end

function test_IOContext(::Type{<:AbstractTestRecord}, stdout::IO, stderr::IO, lock::ReentrantLock, name_align::Int, verbose::Bool, max_worker_rss::Int)
    elapsed_align = textwidth("time (s)")
    compile_align = textwidth("Compile")
    gc_align = textwidth("GC (s)")
    percent_align = textwidth("GC %")
    alloc_align = textwidth("Alloc (MB)")
    rss_align = textwidth("RSS (MB)")

    color = get(stdout, :color, false)

    return TestIOContext(
        stdout, stderr, color, verbose, lock, name_align, elapsed_align, compile_align, gc_align, percent_align,
        alloc_align, rss_align, max_worker_rss, Ref(false), Ref(:ptr_error)
    )
end


function print_header(::Type{<:AbstractTestRecord}, ctx::TestIOContext, testgroupheader, workerheader)
    lock(ctx.lock)
    try
        # header top
        name_pad_str = " "^(ctx.name_align + textwidth(testgroupheader) - 3) * " │ "
        init_str = ctx.verbose ? "   Init   │" : ""
        compile_str = VERSION >= v"1.11" && ctx.verbose ? " Compile │" : ""
        header_top_str = "$name_pad_str  Test   │$init_str$compile_str ──────────────── CPU ──────────────── │\n"
        print(ctx.stdout, header_top_str)

        # header bottom
        workerheaderstr = lpad(workerheader, ctx.name_align - textwidth(testgroupheader) + 1)
        init_time_str = ctx.verbose ? " time (s) │" : ""
        comp_time_str = VERSION >= v"1.11" && ctx.verbose ? "   (%)   │" : ""
        bottom_header_str = "$testgroupheader$workerheaderstr │ time (s) │$init_time_str$comp_time_str GC (s) │ GC % │ Alloc (MB) │ RSS (MB) │\n"
        print(ctx.stdout, bottom_header_str)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_started(::Type{<:AbstractTestRecord}, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")
        # StyledStrings 1.0.3 (used on Julia 1.10) cannot print a styled string whose leading
        # unstyled text ends in a multi-byte character (e.g. `│`), so style it explicitly
        out_str = styled"{default:$(test)$padded_wrkr │}{ptr_light:$(\" \"^ctx.elapsed_align) started at $(now())}\n"
        print(ctx.stdout, out_str)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_finished(record::AbstractTestRecord, wrkr, test, ctx::TestIOContext)
    base = parent(record)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")
        wrkr_face = ctx.recycled[] ? :ptr_warn : :default

        time_str = @sprintf("%7.2f", base.time)
        padded_time = lpad(time_str, ctx.elapsed_align, " ")

        padded_init_time, padded_comp_time = if ctx.verbose
            # pre-testset time
            init_time_str = @sprintf("%7.2f", base.total_time - base.time)
            init_time = lpad(init_time_str, ctx.elapsed_align, " ") * " │ "

            # compilation time
            comp_time = if VERSION >= v"1.11"
                comp_time_str = @sprintf("%7.2f", Float64(100*base.compile_time/base.time))
                lpad(comp_time_str, ctx.compile_align, " ") * " │ "
            else
                ""
            end
            init_time, comp_time
        else
            "", ""
        end

        gc_str = @sprintf("%5.2f", base.gctime)
        padded_gc = lpad(gc_str, ctx.gc_align, " ")

        percent_str = @sprintf("%4.1f", 100 * base.gctime / base.time)
        padded_percent = lpad(percent_str, ctx.percent_align, " ")

        alloc_str = @sprintf("%5.2f", base.bytes / 2^20)
        padded_alloc = lpad(alloc_str, ctx.alloc_align, " ")

        mem_use = memory_usage(record)
        mem_face = mem_use > ctx.max_worker_rss ? :ptr_warn : :default
        rss_str = @sprintf("%5.2f", mem_use / 2^20)
        padded_rss = lpad(rss_str, ctx.rss_align, " ")

        # see `print_test_started` for why `test` is styled explicitly
        out_str = styled"{default:$test}{$wrkr_face:$padded_wrkr} │ $padded_time │ $padded_init_time$padded_comp_time$padded_gc │ $padded_percent │ $padded_alloc │ {$mem_face:$padded_rss} │\n"
        print(ctx.stdout, out_str)
        flush(ctx.stdout)
    finally
        unlock(ctx.lock)
    end
end

function print_test_failed(record::AbstractTestRecord, wrkr, test, ctx::TestIOContext)
    base = parent(record)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")

        time_str = @sprintf("%7.2f", base.time)
        padded_time = lpad(time_str, ctx.elapsed_align + 1, " ")

        padded_init_time = if ctx.verbose
            init_time_str = @sprintf("%7.2f", base.total_time - base.time)
            lpad(init_time_str, ctx.elapsed_align + 1, " ") * " │ "
        else
            ""
        end

        failed_str = "failed at $(now())"
        # 11 -> 3 from " │ " 3x and 2 for each " " on either side
        fail_align = (11 + ctx.gc_align + ctx.percent_align + ctx.alloc_align + ctx.rss_align - textwidth(failed_str)) ÷ 2 + textwidth(failed_str)
        failed_str = lpad(failed_str, fail_align, " ")

        # TODO: print other stats?

        out_str = styled"{$(ctx.nonpass_face[]):$test$padded_wrkr │$padded_time │$padded_init_time$failed_str}\n"
        print(ctx.stderr, out_str)
        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end

function print_test_crashed(::Type{<:AbstractTestRecord}, wrkr, test, ctx::TestIOContext)
    lock(ctx.lock)
    try
        padded_wrkr = lpad("($wrkr)", ctx.name_align - textwidth(test) + 1, " ")
        out_str = styled"{$(ctx.nonpass_face[]):$(test)$padded_wrkr │$(\" \"^ctx.elapsed_align) crashed at $(now())}\n"
        print(ctx.stderr, out_str)
        flush(ctx.stderr)
    finally
        unlock(ctx.lock)
    end
end

# Truncate `line` to at most `max_width` characters, appending "..." when truncated.
function truncate_line(line::AbstractString, max_width::Int)
    if length(line) > max_width
        line = first(line, max(0, max_width - 3)) * "..."
    end
    return line
end
