# Per-test result records

"""
    AbstractTestRecord

Abstract supertype for per-test result records. [`TestRecord`](@ref) is the
default concrete subtype, carrying the captured test set and baseline timing /
memory statistics. Custom subtypes can attach extra per-test data (e.g. GPU
statistics) by carrying a `base::TestRecord` field and dispatching
[`execute`](@ref) on the new type. See the `RecordType` argument of
[`runtests`](@ref) for how to plug a custom record type into a run.
"""
abstract type AbstractTestRecord end

"""
    TestRecord <: AbstractTestRecord

Default per-test record. Holds the captured `DefaultTestSet` alongside the
baseline timing and memory statistics that [`runtests`](@ref) prints and
persists. Custom [`AbstractTestRecord`](@ref) subtypes wrap a `TestRecord` in a
`base` field; [`parent`](@ref) returns that baseline so the default `print_*`
methods work unchanged.
"""
struct TestRecord <: AbstractTestRecord
    value::DefaultTestSet

    # stats
    time::Float64
    bytes::UInt64
    gctime::Float64
    compile_time::Float64
    rss::UInt64
    total_time::Float64
end

"""
    parent(rec::AbstractTestRecord) -> TestRecord

Return the [`TestRecord`](@ref) baseline that a custom record type wraps. By
default, subtypes of `AbstractTestRecord` are expected to carry a
`base::TestRecord` field; override `parent` for a different layout. The default
`print_*` methods read baseline fields through `parent`, so wrapped types
inherit the standard output unchanged.
"""
Base.parent(rec::AbstractTestRecord) = rec.base
Base.parent(rec::TestRecord) = rec

function memory_usage(rec::AbstractTestRecord)
    return parent(rec).rss
end

function init_time(rec::AbstractTestRecord)
    base = parent(rec)
    return base.total_time - base.time
end

function Base.getindex(rec::AbstractTestRecord)
    return parent(rec).value
end
