# ParallelTestRunner.jl

Simple parallel test runner for Julia tests with autodiscovery.

## Usage

The main entry point of `ParallelTestRunner` is the exported function `runtests`, which takes two mandatory arguments:

* the module for which you want to run the tests
* the list of arguments passed to the test script, as a `Vector{String}`, this will typically be [`Base.ARGS`](https://docs.julialang.org/en/v1/base/constants/#Base.ARGS).

With the `--help` flag you can print a help message:

```julia
julia> using ParallelTestRunner

julia> ParallelTestRunner.runtests(ParallelTestRunner, ["--help"])
Usage: runtests.jl [--help] [--list] [--jobs=N] [TESTS...]

   --help             Show this text.
   --list             List all available tests.
   --verbose          Print more information during testing.
   --quickfail        Fail the entire run as soon as a single test errored.
   --jobs=N           Launch `N` processes to perform tests.

   Remaining arguments filter the tests that will be executed.
```

## Setup

`ParallelTestRunner` runs each file inside your `test/` concurrently and isolated.
First you should remove all `include` statements that you added.

Then in your `test/runtests.jl` add:

```julia
using MyModule
using ParallelTestRunner

runtests(MyModule, ARGS)
```

### Customizing the test suite

By default, `runtests` automatically discovers all `.jl` files in your `test/` directory (excluding `runtests.jl` itself) using the `find_tests` function. You can customize which tests to run by providing a custom `testsuite` dictionary:

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

You can also use `find_tests` to automatically discover tests and then filter or modify them. This requires manually parsing arguments so that filtering is only applied when the user did not request specific tests to run:

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

### Provide defaults

`runtests` takes a keyword argument that one can use to provide default definitions to be loaded before each testfile.
As an example one could always load `Test` and the package under test.

```julia
const init_code = quote
   using Test
   using MyPackage
end

runtests(MyModule, ARGS; init_code)
```

## Packages using ParallelTestRunner.jl

There are a few packages already using `ParallelTestRunner.jl` to parallelize their tests, you can look at their setups if you need inspiration to move your packages as well:

* [`Enzyme.jl`](https://github.com/EnzymeAD/Enzyme.jl/blob/main/test/runtests.jl)
* [`GPUArrays.jl`](https://github.com/JuliaGPU/GPUArrays.jl/blob/master/test/runtests.jl)
* [`GPUCompiler.jl`](https://github.com/JuliaGPU/GPUCompiler.jl/blob/master/test/runtests.jl)
* [`Metal.jl`](https://github.com/JuliaGPU/Metal.jl/blob/main/test/runtests.jl)

## Inspiration
Based on [@maleadt](https://github.com/maleadt) test infrastructure for [CUDA.jl](https://github.com/JuliaGPU/CUDA.jl).
