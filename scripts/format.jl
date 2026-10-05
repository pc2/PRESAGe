#!/usr/bin/env julia
using JuliaFormatter

function format_main(args)
    args in (String[], ["--check"]) || error("Usage: scripts/format.jl [--check]")
    check = !isempty(args)
    root = dirname(@__DIR__)
    files = String[]
    for directory in ("src", "scripts", "test", "examples")
        for (path, _, names) in walkdir(joinpath(root, directory))
            append!(
                files,
                [joinpath(path, name) for name in names if endswith(name, ".jl")],
            )
        end
    end
    changed = String[]
    for file in sort!(files)
        JuliaFormatter.format(file; overwrite = !check) ||
            push!(changed, relpath(file, root))
    end
    if check && !isempty(changed)
        println(stderr, "Julia formatting required:")
        foreach(file -> println(stderr, "  ", file), changed)
        return 1
    end
    println(
        check ? "Julia formatting is clean." : "Formatted $(length(changed)) Julia files.",
    )
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(format_main(ARGS))
end
