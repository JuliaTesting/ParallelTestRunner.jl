# Advanced Usage

```@meta
CurrentModule = ParallelTestRunner
DocTestSetup = quote
    using ParallelTestRunner
end
```

This page covers advanced features of `ParallelTestRunner` for customizing test execution.

## Customizing the test suite

By default, [`runtests`](@ref) automatically discovers all `.jl` files in your `test/` directory (excluding `runtests.jl` itself) using the `find_tests` function.
You can customize which tests to run by providing a custom `testsuite` dictionary:

```julia
# Manually define your test suite
testsuite = Dict(
    "basic" => quote
        include("basic.jl")
    end,
    "advanced" => quote
        include("advanced.jl")
    end
)

runtests(MyModule, ARGS; testsuite)
```

## Filtering Test Files

You can also use [`find_tests`](@ref) to automatically discover test files and then filter or modify them.
This requires manually parsing arguments so that filtering is only applied when the user did not request specific tests to run:

```julia
# Start with autodiscovered tests
testsuite = find_tests(pwd())

# Parse arguments
args = parse_args(ARGS)

if filter_tests!(testsuite, args)
    # Remove tests that shouldn't run on Windows
    if Sys.iswindows()
        delete!(testsuite, "ext/specialfunctions")
    end
end

runtests(MyModule, args; testsuite)
```

The [`filter_tests!`](@ref) function returns `true` if no positional arguments were provided (allowing additional filtering) and `false` if the user specified specific tests (preventing further filtering).

## Initialization Code

Use the `init_code` keyword argument to [`runtests`](@ref) to provide code that runs before each test file.
This is useful for:
- Importing packages
- Defining constants, defaults or helper functions
- Setting up test infrastructure

```julia
using ParallelTestRunner

const init_code = quote
    using Test
    using MyPackage

    # Define a helper function available to all tests
    function test_helper(x)
        return x * 2
    end
end

runtests(MyPackage, ARGS; init_code)
```

The `init_code` is evaluated in each test's sandbox module, so all definitions are available to your test files.

## Custom Workers

For tests that require specific environment variables or Julia flags, you can use the `test_worker` keyword argument to [`runtests`](@ref) to assign tests to custom workers:

```julia
using ParallelTestRunner

function test_worker(name)
    if name == "needs_env_var"
        # Create a worker with a specific environment variable
        return addworker(; env = ["SPECIAL_ENV_VAR" => "42"])
    elseif name == "needs_threads"
        # Create a worker with multiple threads
        return addworker(; exeflags = ["--threads=4"])
    end
    # Return nothing to use the default worker
    return nothing
end

testsuite = Dict(
    "needs_env_var" => quote
        @test ENV["SPECIAL_ENV_VAR"] == "42"
    end,
    "needs_threads" => quote
        @test Base.Threads.nthreads() == 4
    end,
    "normal_test" => quote
        @test 1 + 1 == 2
    end
)

runtests(MyPackage, ARGS; test_worker, testsuite)
```

The `test_worker` function receives the test name and should return either:
- A worker object (from [`addworker`](@ref) for tests that need special configuration
- `nothing` to use the default worker pool

## Custom Arguments

If your package needs to accept its own command-line arguments in addition to `ParallelTestRunner`'s options, use [`parse_args`](@ref) with custom flags:

```julia
using ParallelTestRunner

# Parse arguments with custom flags
args = parse_args(ARGS; custom=["myflag", "another-flag"])

# Access custom flags
if args.custom["myflag"] !== nothing
    println("Custom flag was set!")
end

# Pass parsed args to runtests
runtests(MyPackage, args)
```

Custom flags are stored in the `custom` field of the `ParsedArgs` object, with values of `nothing` (not set) or `Some(value)` (set, with optional value).

## Interactive use

Arguments can also be passed via the standard `Pkg.test` interface for interactive control. For example, here is how we could run the subset of tests that start with the testset name "MyTestsetA" in i) verbose mode, and ii) with default threading enabled:

```julia-repl
# In an environment where `MyPackage.jl` is available
julia --proj

julia> using Pkg

# No need to start a fresh session to change threading
julia> Pkg.test("MyModule"; test_args=`--verbose MyTestsetA`, julia_args=`--threads=auto`);
```
Alternatively, arguments can be passed directly from the command line with a shell alias like the one below:

```julia-repl
jltest --threads=auto -- --verbose MyTestsetA
```

Shell alias:

```shell
function jltest {
    julia=(julia)

    # certain arguments (like those beginnning with a +) need to come first
    if [[ $# -gt 0 && "$1" = +* ]]; then
        julia+=("$1")
        shift
    fi

    "${julia[@]}" --startup-file=no --project -e "using Pkg; Pkg.API.test(; test_args=ARGS)" "$@"
}
```

## Best Practices

1. **Keep tests isolated**: Each test file runs in its own module, so avoid relying on global state between tests.

1. **Use `init_code` for common setup**: Instead of duplicating setup code in each test file, use `init_code` to share common initialization.

1. **Filter tests appropriately**: Use [`filter_tests!`](@ref) to respect user-specified test filters while allowing additional programmatic filtering.

1. **Handle platform differences**: Use conditional logic in your test suite setup to handle platform-specific tests:

   ```julia
   testsuite = find_tests(pwd())
   if Sys.iswindows()
       delete!(testsuite, "unix_specific_test")
   end
   ```

1. **Load balance the test files**: `ParallelTestRunner` runs the tests files in parallel, ideally all test files should run for _roughly_ the same time for better performance.
   Having few long-running test files and other short-running ones hinders scalability.

1. **Use custom workers sparingly**: Custom workers add overhead. Only use them when tests genuinely require different configurations.
