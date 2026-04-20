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

## Custom Records

Per-test data is captured in an [`AbstractTestRecord`](@ref). The default
[`TestRecord`](@ref) stores timing and memory statistics; subtypes can wrap it
to collect additional data (e.g. GPU metrics) by dispatching [`execute`](@ref)
on the new type and reading the baseline through [`parent`](@ref).

```@docs
AbstractTestRecord
TestRecord
execute
parent(::ParallelTestRunner.AbstractTestRecord)
```

## Internal Types

These are internal types, not subject to semantic versioning contract (could be changed or removed at any point without notice), not intended for consumption by end-users.
They are documented here exclusively for `ParallelTestRunner` developers and contributors.

```@docs
ParsedArgs
WorkerTestSet
```
