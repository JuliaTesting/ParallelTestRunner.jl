# A miscellaneous collection of utilities used by PTR
#  Many of these are to handle differences between julia
#  versions or operating systems

# Thin compatibility shim for using `anynonpass` before Julia 1.13
function anynonpass(ts::Test.AbstractTestSet)
    @static if VERSION >= v"1.13.0-DEV.1037"
        return Test.anynonpass(ts)
    else
        Test.get_test_counts(ts)
        return ts.anynonpass
    end
end

# Thin compatibility shim for using `Lockable` also in Julia v1.10
if VERSION >= v"1.11.0-DEV.1568"
    const Lockable = Base.Lockable
else
    # Adapted from <https://github.com/JuliaLang/julia/pull/52898>.
    struct Lockable{T, L <: Base.AbstractLock}
        value::T
        lock::L
    end

    Lockable(value) = Lockable(value, ReentrantLock())
    Base.getindex(l::Lockable) = (Base.assert_havelock(l.lock); l.value)

    Base.lock(l::Lockable) = Base.lock(l.lock)
    Base.trylock(l::Lockable) = Base.trylock(l.lock)
    Base.unlock(l::Lockable) = Base.unlock(l.lock)
end

# Needed to support both pre and post 1.13 Test
function with_testset(f, testset)
    @static if VERSION >= v"1.13.0-DEV.1044"
        Test.@with_testset testset f()
    else
        Test.push_testset(testset)
        try
            f()
        finally
            Test.pop_testset()
        end
    end
    return nothing
end

# libUV's available memory count was a bit conservative with it's reporting
# on macOS so use a more meaningful value.
@static if Sys.isapple()
    mutable struct VmStatistics64
    	free_count::UInt32
    	active_count::UInt32
    	inactive_count::UInt32
    	wire_count::UInt32
    	zero_fill_count::UInt64
    	reactivations::UInt64
    	pageins::UInt64
    	pageouts::UInt64
    	faults::UInt64
    	cow_faults::UInt64
    	lookups::UInt64
    	hits::UInt64
    	purges::UInt64
    	purgeable_count::UInt32

    	speculative_count::UInt32

    	decompressions::UInt64
    	compressions::UInt64
    	swapins::UInt64
    	swapouts::UInt64
    	compressor_page_count::UInt32
    	throttled_count::UInt32
    	external_page_count::UInt32
    	internal_page_count::UInt32
    	total_uncompressed_pages_in_compressor::UInt64

    	VmStatistics64() = new(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    end

    function available_memory()
    	vms = Ref{VmStatistics64}(VmStatistics64())
    	mach_host_self = @ccall mach_host_self()::UInt32
    	count = UInt32(sizeof(VmStatistics64) ÷ sizeof(Int32))
    	ref_count = Ref(count)
    	@ccall host_statistics64(mach_host_self::UInt32, 4::Int64, pointer_from_objref(vms[])::Ptr{Int64}, ref_count::Ref{UInt32})::Int64

    	page_size = Int(@ccall sysconf(29::UInt32)::UInt32)

    	return (Int(vms[].free_count) + Int(vms[].inactive_count) + Int(vms[].purgeable_count) + Int(vms[].compressor_page_count)) * page_size
    end
else
    available_memory() = Sys.free_memory()
end
