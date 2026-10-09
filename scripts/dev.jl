#!/usr/bin/env julia
# Instantiate the pinned Git dependency, or explicitly develop a local checkout.
using Pkg
root = realpath(dirname(@__DIR__))
local_sollya = get(ENV, "PRESAGE_SOLLYA_PATH", "")
if !isempty(local_sollya)
    local_sollya = abspath(local_sollya)
    isfile(joinpath(local_sollya, "Project.toml")) ||
        error("PRESAGE_SOLLYA_PATH must point to a local Sollya.jl checkout")
    local_sollya = realpath(local_sollya)
end
Pkg.activate(root)
if !isempty(local_sollya)
    Pkg.offline(true)
    cd(root) do
        Pkg.develop(; path = relpath(local_sollya, root))
    end
else
    # Resolve changes to [sources], including an existing path-based Manifest.
    Pkg.resolve()
end
Pkg.instantiate(; allow_autoprecomp = false)
