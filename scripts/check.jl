#!/usr/bin/env julia
using Pkg
Pkg.offline(true)
Pkg.activate(dirname(@__DIR__))
Pkg.test(; allow_reresolve=false)
