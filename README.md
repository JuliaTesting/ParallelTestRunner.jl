# ParallelTestRunner.jl

[![Stable Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliatesting.github.io/ParallelTestRunner.jl/)
[![Latest Documentation](https://img.shields.io/badge/docs-latest-blue.svg)](https://juliatesting.github.io/ParallelTestRunner.jl/dev)

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

## Documentation

For more details about the use of this package, read the [documentation](https://juliatesting.github.io/ParallelTestRunner.jl/).

## Inspiration
Based on [@maleadt](https://github.com/maleadt) test infrastructure for [CUDA.jl](https://github.com/JuliaGPU/CUDA.jl).
