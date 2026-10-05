#!/usr/bin/env julia
include("offline_pkg.jl")
with_offline_pkg() do
    Pkg.activate(dirname(@__DIR__))
    Pkg.test(; allow_reresolve=false)
end
