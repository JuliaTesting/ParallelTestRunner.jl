# API Reference

```@meta
CurrentModule = ParallelTestRunner
DocTestSetup = quote
    using ParallelTestRunner
end
```

## Main Functions

```@docs
runtests
```

## Test Discovery

```@docs
find_tests
```

## Argument Parsing

```@docs
parse_args
filter_tests!
```

## Worker Management

```@docs
addworker
addworkers
```

## Configuration

```@docs
default_njobs
```

## Internal Types

```@docs
WorkerTestSet
```
