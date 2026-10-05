#!/usr/bin/env julia
using PRESAGe

function certify_main(args)
    length(args) >= 2 || error("Usage: certify.jl PLAN.toml REPORT.toml [--precision=256] [--accuracy=1/1024]")
    options = Dict{String,String}()
    for arg in args[3:end]
        startswith(arg,"--") && occursin('=',arg) || error("expected --option=value")
        key,value = split(arg[3:end],'=';limit=2)
        key in ("precision","accuracy") || error("unknown option $key")
        haskey(options,key) && error("duplicate option $key")
        options[key] = value
    end
    result = certify_erf(read_plan(args[1]);precision=parse(Int,get(options,"precision","256")),
        accuracy=PRESAGe._parse_rational(get(options,"accuracy","1/1024")))
    write_certificate(args[2],result)
    result.status == :certified || error("$(result.status): $(result.reason)")
    println("Certified uniform absolute error: ",Float64(result.total_bound))
    return result
end
if abspath(PROGRAM_FILE) == @__FILE__
    certify_main(ARGS)
end
