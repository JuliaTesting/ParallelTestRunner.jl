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

#
# terminal progress bar
#

# The protocols through which the terminal described by `env` is told about the progress of
# the run, which it typically renders in its tab or in the taskbar:
# - `:osc7501`, the program status protocol, which goes to every terminal: those that do not
#   know it ignore it, as nothing else uses that number;
# - `:osc94`, the ConEmu sequence that most terminals with a progress bar understand. Some
#   of those that do not know it show a notification for every OSC 9 they receive, so it is
#   only sent to the terminals recognized as taking it.
# `PTR_TERM_PROGRESS` forces a single protocol instead, or `none` of them.
function progress_bar_protocols(env = ENV)
    forced = lowercase(strip(get(env, "PTR_TERM_PROGRESS", "")))
    forced == "none" && return Symbol[]
    forced in ("osc94", "osc7501") && return [Symbol(forced)]
    if !isempty(forced)
        @warn "Ignoring the `PTR_TERM_PROGRESS` environment variable, which should be `osc94`, `osc7501` or `none`" value=forced
    end

    # a terminal that says it understands no sequence would show them
    get(env, "TERM", "") == "dumb" && return Symbol[]

    # which terminals take OSC 9;4 was taken from the `anstyle-progress` crate
    # (https://github.com/rust-cli/anstyle)
    version(name) = something(tryparse(Int, first(eachsplit(get(env, name, ""), '.'))), 0)
    term = get(env, "TERM_PROGRAM", "")
    return if term == "rex"
        # it ignores OSC 9;4, and one that would not could mistake it for a status of its own
        [:osc7501]
    elseif haskey(env, "WT_SESSION") ||            # Windows Terminal
           get(env, "ConEmuANSI", "") == "ON" ||
           term in ("ghostty", "WezTerm", "herdr") ||
           # unlike `TERM_PROGRAM`, this identifies Ghostty across SSH
           get(env, "TERM", "") == "xterm-ghostty" ||
           # the features that iTerm2 reports are codes made of an uppercase letter and any
           # lowercase ones, where `P` stands for progress; older versions of it, which are
           # among those that show notifications, do not report this one
           occursin(r"P(?![a-z])", get(env, "TERM_FEATURES", "")) ||
           version("PTYXIS_VERSION") >= 48 ||
           version("KONSOLE_VERSION") >= 260400       # 26.04
        [:osc7501, :osc94]
    else
        [:osc7501]
    end
end

# What each of the checks of `progress_bar_protocols` gives, to tell why they were chosen:
# OSC 7501 is sent unless something disables it, and OSC 9;4 along with it when one of the
# `osc94_` checks holds and the terminal is not Rex
function progress_bar_features(env = ENV)
    version(name) = something(tryparse(Int, first(eachsplit(get(env, name, ""), '.'))), 0)
    term = get(env, "TERM_PROGRAM", "")
    return (;
        forced = get(env, "PTR_TERM_PROGRESS", ""),
        disabled_by_dumb_term = get(env, "TERM", "") == "dumb",
        rex_without_osc94 = term == "rex",
        osc94_windows_terminal = haskey(env, "WT_SESSION"),
        osc94_conemu = get(env, "ConEmuANSI", "") == "ON",
        osc94_term_program = term in ("ghostty", "WezTerm", "herdr"),
        osc94_ghostty_term = get(env, "TERM", "") == "xterm-ghostty",
        osc94_term_features = occursin(r"P(?![a-z])", get(env, "TERM_FEATURES", "")),
        osc94_ptyxis = version("PTYXIS_VERSION") >= 48,
        osc94_konsole = version("KONSOLE_VERSION") >= 260400,
    )
end

# The sequence reporting `state` to a terminal that speaks `protocol`. During the run that is
# `:working`, or `:failing` once a test did not pass, with `completed` out of `total` tests
# done, which `msg` describes. At the end it is `:done`, `:error`, or `:clear` when
# there is no outcome to report.
function progress_bar_sequence(protocol::Symbol, state::Symbol, completed::Integer = 0, total::Integer = 0,
                               msg::AbstractString = "")
    percent = total > 0 ? clamp(100 * completed ÷ total, 0, 100) : 0
    if protocol === :osc7501
        # an error is final in this protocol, so failures only show once the run is over,
        # where the outcome is left behind for the user to find
        report = if state in (:working, :failing)
            # free text is encoded, as it could not contain the separators otherwise
            "state=working:progress=$percent:msg=$(Base64.base64encode(msg))"
        else
            "state=$state"
        end
        # the reports go to a record of our own: without an identifier they would replace
        # the status of the terminal as a whole, which is that of the Julia REPL when the
        # tests are run from there, and clearing it would remove the records of every program
        report *= ":id=ParallelTestRunner"
        # every report replaces its record entirely, so each has to name the program
        state === :clear || (report *= ":app=julia")
        return "\033]7501;$report\033\\"
    else
        # there is nowhere to leave an outcome, so the progress bar is removed at the end
        report = state === :working ? "1;$percent" : state === :failing ? "2;$percent" : "0"
        return "\033]9;4;$report\a"
    end
end

# Truncate `line` to at most `max_width` characters, appending "..." when truncated.
function truncate_line(line::AbstractString, max_width::Int)
    if length(line) > max_width
        line = first(line, max(0, max_width - 3)) * "..."
    end
    return line
end
