#!/usr/bin/env julia
# Bootstrap the sibling checkout without registry or network resolution.
using Pkg
Pkg.offline(true)
root = dirname(@__DIR__)
sollya = abspath(get(ENV, "PRESAGE_SOLLYA_PATH", joinpath(dirname(root), "Sollya.jl")))
isfile(joinpath(sollya, "Project.toml")) || error("Set PRESAGE_SOLLYA_PATH to a local Sollya.jl checkout")
Pkg.activate(root)
cd(root) do
    Pkg.develop(; path=relpath(sollya, root))
end
Pkg.instantiate(; allow_autoprecomp=false)
