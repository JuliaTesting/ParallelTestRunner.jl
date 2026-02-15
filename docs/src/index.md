# ParallelTestRunner.jl

```@meta
CurrentModule = ParallelTestRunner
DocTestSetup = quote
    using ParallelTestRunner
end
```

```@setup mypackage
using ParallelTestRunner
using MyPackage
test_dir = joinpath(pkgdir(ParallelTestRunner), "docs", "MyPackage", "test")
```

[ParallelTestRunner.jl](https://github.com/JuliaTesting/ParallelTestRunner.jl) is a simple parallel test runner for Julia tests with automatic test discovery.
It runs each test file concurrently in isolated worker processes, providing real-time progress output and efficient resource management.

## Quick Start

### Basic Setup

1. **Remove existing `include` statements** from your test files.
   `ParallelTestRunner` will automatically discover and run all test files.

2. **Update your `test/runtests.jl`**:

   ```@example mypackage
   using MyPackage
   using ParallelTestRunner

   cd(test_dir) do # hide
   runtests(MyPackage, ARGS)
   end # hide
   ```

That's it! `ParallelTestRunner` will automatically:
- Discover all `.jl` files in your `test/` directory (excluding `runtests.jl`)
- Run them in parallel across multiple worker processes
- Display real-time progress with timing and memory statistics

### Running Tests

Run tests using the standard Julia package testing interface:

```bash
julia --project -e 'using Pkg; Pkg.test("MyPackage")'
```

Or from within Julia:

```julia
using Pkg
Pkg.test("MyPackage")
```

## Command Line Options

You can pass various options to the `runtests.jl` script to control test execution:

```bash
julia --project test/runtests.jl [OPTIONS] [TESTS...]
```

### Available Options

- `--help`: Show usage information and exit
- `--list`: List all available test files and exit
- `--verbose`: Print more detailed information during test execution (including start times for each test)
- `--quickfail`: Stop the entire test run as soon as any test fails
- `--jobs=N`: Use `N` worker processes (default: based on CPU threads and available memory)
- `TESTS...`: Filter test files by name, matched using `startswith`

### Examples

```bash
# List all available tests
julia --project test/runtests.jl --list

# Run only tests matching "integration"
julia --project test/runtests.jl integration

# Run with verbose output and 4 workers
julia --project test/runtests.jl --verbose --jobs=4

# Run with quick-fail enabled
julia --project test/runtests.jl --quickfail
```

### Using with Pkg.test

You can also pass arguments through [`Pkg.test`](https://pkgdocs.julialang.org/v1/api/#Pkg.test):

```julia
using Pkg
Pkg.test("MyPackage"; test_args=`--verbose --jobs=4 integration`)
```

## Features

### Automatic Test Files Discovery

`ParallelTestRunner` automatically discovers all `.jl` files in your `test/` directory and subdirectories, excluding `runtests.jl`.

### Parallel Execution

Tests run concurrently in isolated worker processes, each inside own module.
`ParallelTestRunner` records historical tests duration for each package, so that in subsequent runs long-running tests are executed first, to improve load balancing.

### Real-time Progress

The test runner provides real-time output showing:
- Test name and worker assignment
- Execution time
- GC time and percentage
- Memory allocation
- RSS (Resident Set Size) memory usage

### Graceful Interruption

Press `Ctrl+C` to interrupt the test run. The framework will:
- Clean up running tests
- Display a summary of completed tests
- Exit gracefully

## Test File Structure

Your test files should be standard Julia test files using the `Test` standard library:

```julia
using Test
using MyPackage

@testset "MyPackage tests" begin
    @test 1 + 1 == 2
    @test MyPackage.my_function(42) == 84
end
```

Each test file runs in its own isolated module, so you don't need to worry about test pollution between files.

## Packages using ParallelTestRunner.jl

There are a few packages already [using `ParallelTestRunner.jl`](https://github.com/search?q=%2Fusing.*+ParallelTestRunner%2F+language%3AJulia++NOT+is%3Aarchived+NOT+is%3Afork+path%3A%2F%5Etest%5C%2Fruntests.jl%2F&type=code) to parallelize their tests, you can look at their setups if you need inspiration to move your packages as well:

* [`ApproxFun.jl`](https://github.com/JuliaApproximation/ApproxFun.jl/blob/master/test/runtests.jl)
* [`BlockArrays.jl`](https://github.com/JuliaArrays/BlockArrays.jl/blob/master/test/runtests.jl)
* [`CuNESSie.jl`](https://github.com/tkemmer/CuNESSie.jl/blob/master/test/runtests.jl)
* [`Enzyme.jl`](https://github.com/EnzymeAD/Enzyme.jl/blob/main/test/runtests.jl)
* [`GPUArrays.jl`](https://github.com/JuliaGPU/GPUArrays.jl/blob/master/test/runtests.jl)
* [`GPUCompiler.jl`](https://github.com/JuliaGPU/GPUCompiler.jl/blob/master/test/runtests.jl)
* [`HyperHessians.jl`](https://github.com/KristofferC/HyperHessians.jl/blob/master/test/runtests.jl)
* [`Metal.jl`](https://github.com/JuliaGPU/Metal.jl/blob/main/test/runtests.jl)
* [`WCS.jl`](https://github.com/JuliaAstro/WCS.jl/blob/master/test/runtests.jl)

## Inspiration
Based on [@maleadt](https://github.com/maleadt) test infrastructure for [CUDA.jl](https://github.com/JuliaGPU/CUDA.jl).
