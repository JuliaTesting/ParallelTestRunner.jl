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

These are internal types, not subject to semantic versioning contract (could be changed or removed at any point without notice), not intended for consumption by end-users.
They are documented here exclusively for `ParallelTestRunner` developers and contributors.

```@docs
ParsedArgs
WorkerTestSet
```
