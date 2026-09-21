# Command-line argument parsing and test selection

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
function extract_flag!(args, flag; typ = Nothing)
    for f in args
        # only accept the exact flag or `--flag=value`, so that flags sharing a
        # prefix (e.g. `--list` and `--listing`) don't capture each other
        if f == flag || startswith(f, flag * "=")
            # Check if it's just `--flag` or if it's `--flag=foo`
            val = if f == flag
                typ === Nothing ||
                    error("Option `$flag` requires a value (use `$flag=<value>`)")
                nothing
            else
                _, value = split(f, '='; limit = 2)
                if typ === Nothing || typ <: AbstractString
                    value
                else
                    parsed = tryparse(typ, value)
                    parsed === nothing &&
                        error("Invalid value `$value` for option `$flag` (expected a value of type $typ)")
                    parsed
                end
            end

            # Drop this value from our args
            filter!(x -> x != f, args)
            return Some(val)
        end
    end
    return nothing
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

    help = extract_flag!(args, "--help")
    if help !== nothing
        usage =
            """
            Usage: runtests.jl [--help] [--list] [--jobs=N] [TESTS...]

               --help             Show this text.
               --list             List available tests alphabetically.
               --verbose          Print more information during testing.
               --quickfail        Fail the entire run as soon as a single test errored.
               --jobs=N           Launch `N` processes to perform tests. Can also be set
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

    jobs = extract_flag!(args, "--jobs"; typ = Int)
    verbose = extract_flag!(args, "--verbose")
    quickfail = extract_flag!(args, "--quickfail")
    list = extract_flag!(args, "--list")

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
