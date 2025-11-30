# Advanced Usage

```@meta
CurrentModule = ParallelTestRunner
DocTestSetup = quote
    using ParallelTestRunner
end
```

This page covers advanced features of `ParallelTestRunner` for customizing test execution.

## Custom Test Suites

By default, `runtests` automatically discovers all `.jl` files in your test directory. You can provide a custom test suite dictionary to have full control over which tests run:

```julia
using ParallelTestRunner

# Manually define your test suite
testsuite = Dict(
    "basic" => quote
        include("basic.jl")
    end,
    "advanced" => quote
        include("advanced.jl")
    end
)

runtests(MyPackage, ARGS; testsuite)
```

Each value in the dictionary should be an expression (use `quote...end`) that executes the test code.

## Filtering Tests

You can use `find_tests` to automatically discover tests and then filter or modify them:

```julia
using ParallelTestRunner

# Start with autodiscovered tests
testsuite = find_tests(pwd())

# Parse arguments manually
args = parse_args(ARGS)

# Filter based on arguments
if filter_tests!(testsuite, args)
    # Additional filtering is allowed
    # For example, remove platform-specific tests
    if Sys.iswindows()
        delete!(testsuite, "unix_only_test")
    end
end

runtests(MyPackage, args; testsuite)
```

The `filter_tests!` function returns `true` if no positional arguments were provided (allowing additional filtering) and `false` if the user specified specific tests (preventing further filtering).

## Initialization Code

Use the `init_code` keyword argument to provide code that runs before each test file. This is useful for:
- Importing packages
- Defining constants or helper functions
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

For tests that require specific environment variables or Julia flags, you can use the `test_worker` keyword argument to assign tests to custom workers:

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
- A worker object (from `addworker`) for tests that need special configuration
- `nothing` to use the default worker pool

## Custom Output Streams

You can redirect output to custom I/O streams:

```julia
using ParallelTestRunner

io = IOBuffer()
runtests(MyPackage, ARGS; stdout=io, stderr=io)

# Process the output
output = String(take!(io))
```

This is useful for:
- Capturing test output for analysis
- Writing to log files
- Suppressing output in certain contexts

## Custom Arguments

If your package needs to accept its own command-line arguments in addition to `ParallelTestRunner`'s options, use `parse_args` with custom flags:

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

## Manual Worker Management

For advanced use cases, you can manually create workers:

```julia
using ParallelTestRunner

# Add a single worker with custom configuration
worker = addworker(
    env = ["CUSTOM_VAR" => "value"],
    exeflags = ["--check-bounds=no"]
)

# Add multiple workers
workers = addworkers(4; env = ["THREADS" => "1"])
```

Workers created this way can be used with the `test_worker` function or for other distributed computing tasks.

## Best Practices

1. **Keep tests isolated**: Each test file runs in its own module, so avoid relying on global state between tests.

2. **Use `init_code` for common setup**: Instead of duplicating setup code in each test file, use `init_code` to share common initialization.

3. **Filter tests appropriately**: Use `filter_tests!` to respect user-specified test filters while allowing additional programmatic filtering.

4. **Handle platform differences**: Use conditional logic in your test suite setup to handle platform-specific tests:

   ```julia
   testsuite = find_tests(pwd())
   if Sys.iswindows()
       delete!(testsuite, "unix_specific_test")
   end
   ```

5. **Use custom workers sparingly**: Custom workers add overhead. Only use them when tests genuinely require different configurations.
