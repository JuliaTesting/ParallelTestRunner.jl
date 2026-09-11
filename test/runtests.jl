using ParallelTestRunner
using Test

include(joinpath(@__DIR__, "utils.jl"))

# Every test file exercises `runtests` itself, so each one is run in its own worker by
# ParallelTestRunner: the nested runs spawn their own workers from there.
testsuite = find_tests(@__DIR__)
filter!(testsuite) do (name, _)
    # `utils.jl` is a helper, and `sample_tests/` holds test files used by the tests themselves.
    name != "utils" && !startswith(name, "sample_tests/")
end

init_code = quote
    using ParallelTestRunner
    using Test
    include($(joinpath(@__DIR__, "utils.jl")))
end

push!(ARGS, "--verbose")

runtests(ParallelTestRunner, ARGS; testsuite, init_code)

# All workers must have been stopped once `runtests` returns.
@testset "no workers running" begin
    children = _count_child_pids()
    if children >= 0
        @test children == 0
    end
end
