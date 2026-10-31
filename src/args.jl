# Test discovery, command-line argument parsing and test selection

"""
    find_tests(dir::String) -> Dict{String, Expr}

Discover test files in a directory and return a test suite dictionary.

Walks through `dir` and finds all `.jl` files (excluding `runtests.jl`), returning a
dictionary mapping test names to expression that include each test file.
"""
function find_tests(dir::String)
    tests = Dict{String, Expr}()
    for (rootpath, _dirs, files) in walkdir(dir)
        # find Julia files
        filter!(files) do file
            endswith(file, ".jl") && file !== "runtests.jl"
        end
        isempty(files) && continue

        # strip extension
        files = map(files) do file
            file[1:(end - 3)]
        end

        # prepend subdir
        subdir = relpath(rootpath, dir)
        if subdir != "."
            files = map(files) do file
                joinpath(subdir, file)
            end
        end

        # unify path separators
        files = map(files) do file
            replace(file, path_separator => '/')
        end

        for file in files
            path = joinpath(rootpath, basename(file * ".jl"))
            tests[file] = :(include($path))
        end
    end
    return tests
end

"""
    ParsedArgs

Struct representing parsed command line arguments, to be passed to [`runtests`](@ref).
`ParsedArgs` objects are typically obtained by using [`parse_args`](@ref).

Fields are

* `jobs::Union{Some{Int}, Nothing}`: the number of jobs
* `verbose::Union{Some{Nothing}, Nothing}`: whether verbose printing was enabled
* `quickfail::Union{Some{Nothing}, Nothing}`: whether quick fail was enabled
* `list::Union{Some{Nothing}, Nothing}`: whether tests should be listed
* `custom::Dict{String,Any}`: a dictionary of custom arguments
* `positionals::Vector{String}`: the list of positional arguments passed on the command line, i.e. the explicit list of test files (to be matches with `startswith`)
"""
struct ParsedArgs
    jobs::Union{Some{Int}, Nothing}
    verbose::Union{Some{Nothing}, Nothing}
    quickfail::Union{Some{Nothing}, Nothing}
    list::Union{Some{Nothing}, Nothing}

    custom::Dict{String,Any}

    positionals::Vector{String}
end

# parse some command-line arguments
#
# `flag` is the long form (`--flag` or `--flag=value`). If `short` is given, the short
# form is also accepted: `-f` for boolean flags, and `-f value` or `-fvalue` for flags
# that take a value. If the flag is passed multiple times, the first occurrence wins.
function extract_flag!(args, flag; short = nothing, typ = Nothing)
    # only accept the exact flag or `--flag=value`, so that flags sharing a
    # prefix (e.g. `--list` and `--listing`) don't capture each other
    is_long(f) = f == flag || startswith(f, flag * "=")
    is_short(f) = short !== nothing && (f == short || (typ !== Nothing && startswith(f, short)))

    i = findfirst(f -> is_long(f) || is_short(f), args)
    i === nothing && return nothing
    f = popat!(args, i)

    val = if f == flag || f == short
        # just `--flag` or `-f`, which for typed flags means `-f value`
        if typ === Nothing
            nothing
        elseif f == short && i <= length(args)
            popat!(args, i)
        else
            hint = short === nothing ? "`$flag=<value>`" : "`$flag=<value>` or `$short <value>`"
            error("Option `$f` requires a value (use $hint)")
        end
    elseif is_long(f)
        # `--flag=foo`
        last(split(f, '='; limit = 2))
    else
        # `-ffoo`
        f[(length(short) + 1):end]
    end

    if !(val === nothing || typ === Nothing || typ <: AbstractString)
        parsed = tryparse(typ, val)
        parsed === nothing &&
            error("Invalid value `$val` for option `$(is_long(f) ? flag : short)` (expected a value of type $typ)")
        val = parsed
    end

    # drop any further occurrences of this flag
    extract_flag!(args, flag; short, typ)

    return Some(val)
end

"""
    parse_args(args; [custom::Array{String}]) -> ParsedArgs

Parse command-line arguments for `runtests`. Typically invoked by passing `Base.ARGS`.

Fields of this structure represent command-line options, containing `nothing` when the
option was not specified, or `Some(optional_value=nothing)` when it was.

Custom arguments can be specified via the `custom` keyword argument, which should be
an array of strings representing custom flag names (without the `--` prefix). Presence
of these flags will be recorded in the `custom` field of the returned [`ParsedArgs`](@ref) object.
"""
function parse_args(args; custom::Array{String} = String[])
    args = copy(args)

    help = extract_flag!(args, "--help"; short = "-h")
    if help !== nothing
        usage =
            """
            Usage: runtests.jl [--help] [--list] [--jobs=N] [TESTS...]

               -h, --help         Show this text.
               -l, --list         List available tests alphabetically.
               -V, --verbose      Print more information during testing.
               -q, --quickfail    Fail the entire run as soon as a single test errored.
               -j N, --jobs=N     Launch `N` processes to perform tests. Can also be set
                                  with the PTR_NUM_JOBS environment
                                  variable, with `--jobs=N` taking precedence."""

        if !isempty(custom)
            usage *= "\n\nCustom arguments:"
            for flag in custom
                usage *= "\n   --$flag"
            end
        end
        usage *= "\n\nRemaining arguments filter the tests that will be executed."
        usage *= "\nPrefix your argument with '!' to instead exclude those tests"
        println(usage)
        exit(0)
    end

    jobs = extract_flag!(args, "--jobs"; short = "-j", typ = Int)
    verbose = extract_flag!(args, "--verbose"; short = "-V")
    quickfail = extract_flag!(args, "--quickfail"; short = "-q")
    list = extract_flag!(args, "--list"; short = "-l")

    # boolean flags don't take values
    for (flag, val) in (("--verbose", verbose), ("--quickfail", quickfail), ("--list", list))
        if val isa Some && something(val) !== nothing
            error("Option `$flag` does not take a value")
        end
    end

    custom_args = Dict{String,Any}()
    for flag in custom
        custom_args[flag] = extract_flag!(args, "--$flag")
    end

    ## no options should remain
    optlike_args = filter(startswith("-"), args)
    if !isempty(optlike_args)
        error("Unknown test options `$(join(optlike_args, " "))` (try `--help` for usage instructions)")
    end

    return ParsedArgs(jobs, verbose, quickfail, list, custom_args, args)
end

"""
    filter_tests!(testsuite, args::ParsedArgs) -> Bool

Filter tests in `testsuite` based on command-line arguments in `args`.

Returns `true` if additional filtering may be done by the caller, `false` otherwise.

When `--list` is requested, the full `testsuite` is preserved and `false` is
returned so that callers skip any conditional filtering of their own: listing
should show every available test, not just the ones that would run by default.
"""
function filter_tests!(testsuite::Dict{<:AbstractString, <:Any}, args::ParsedArgs)
    # when only listing tests, keep the full catalog and let the caller skip its
    # own filtering, so that every available test is shown
    args.list !== nothing && return false

    # the user did not request specific tests, so let the caller do its own filtering
    isempty(args.positionals) && return true

    exclude_idxs = startswith.(args.positionals, "!")
    exclude_args = lstrip.(args.positionals[exclude_idxs], Ref(['!']))
    include_args = args.positionals[.!exclude_idxs]

    # only select tests matching positional arguments
    tests = collect(keys(testsuite))
    if !isempty(include_args)
        for test in tests
            if !any(arg -> startswith(test, arg), include_args)
                delete!(testsuite, test)
            end
        end
    end

    # remove explicitly excluded tests
    included_tests = collect(keys(testsuite))
    if !isempty(exclude_args)
        for test in included_tests
            if any(arg -> startswith(test, arg), exclude_args)
                delete!(testsuite, test)
            end
        end
    end

    # the user requested specific tests, so don't allow further filtering
    return false
end

"""
    partition_tests(tests::Vector{String}, serial::Vector{String}) -> (serial_tests, parallel_tests)

Split `tests` into two ordered vectors: tests named in `serial` (preserving their
order in `tests`) and the remaining parallel tests. Throws `ArgumentError` if any
name in `serial` is not present in `tests`.
"""
function partition_tests(tests::Vector{String}, serial::Vector{String})
    serial_set = Set(serial)
    unknown = setdiff(serial_set, Set(tests))
    if !isempty(unknown)
        throw(ArgumentError("serial test(s) not found in testsuite: $(join(sort!(collect(unknown)), ", "))"))
    end
    serial_tests = filter(t -> t in serial_set, tests)
    parallel_tests = filter(t -> !(t in serial_set), tests)
    return serial_tests, parallel_tests
end
