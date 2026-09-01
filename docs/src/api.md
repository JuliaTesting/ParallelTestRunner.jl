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

## Memory Pressure Monitoring

On macOS, the kernel's virtual memory counters can be sampled on a timer to tell whether
a test run is merely using a lot of memory or actively thrashing (compressor churn, swap
traffic). Reports are delivered through a `Channel`, so callers decide how to react.
See [Diagnosing memory pressure](@ref) for a worked example.

```@docs
start_memory_pressure_monitor
stop_memory_pressure_monitor
MemoryPressureMonitor
MemoryPressureReport
MemoryPressureThresholds
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

## Internal Functionalities

These are internal types or functions, not subject to semantic versioning contract (could be changed or removed at any point without notice), not intended for consumption by end-users.
They are documented here exclusively for `ParallelTestRunner` developers and contributors.

```@docs
ParsedArgs
WorkerTestSet
partition_tests
```
