using Documenter
using ParallelTestRunner

makedocs(;
    modules=[ParallelTestRunner],
    authors="Valentin Churavy <v.churavy@gmail.com> and contributors",
    repo="https://github.com/JuliaTesting/ParallelTestRunner.jl/blob/{commit}{path}#{line}",
    sitename="ParallelTestRunner.jl",
    format=Documenter.HTML(;
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical="https://juliatesting.github.io/ParallelTestRunner.jl",
        assets=String[],
    ),
    pages=[
        "Home" => "index.md",
        "Advanced Usage" => "advanced.md",
        "API Reference" => "api.md",
    ],
)
