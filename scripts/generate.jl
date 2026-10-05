#!/usr/bin/env julia
using PRESAGe

function generate_main(args)
    length(args) >= 2 || error("Usage: generate.jl erf|PLAN.toml OUTPUT_DIR [--degree=9] [--segments=4] [--internal=double] [--evaluation=separate] [--name=evaluator]")
    source,directory = args[1:2]
    options = Dict{String,String}()
    for arg in args[3:end]
        startswith(arg,"--") && occursin('=',arg) || error("expected --option=value")
        key,value = split(arg[3:end],'=';limit=2)
        key in ("degree","segments","internal","evaluation","name") || error("unknown option $key")
        haskey(options,key) && error("duplicate option $key")
        options[key] = value
    end
    plan = if source == "erf"
        internal = get(options,"internal","double")
        internal in ("single","double") || error("internal must be single or double")
        erf_candidate(;degree=parse(Int,get(options,"degree","9")),segments=parse(Int,get(options,"segments","4")),
            internal_format=internal == "single" ? IEEE32 : IEEE64,
            evaluation=Symbol(get(options,"evaluation","separate")))
    else
        all(k -> k == "name",keys(options)) || error("generation options require the erf source")
        read_plan(source)
    end
    plan.program === nothing && error("plan contains no arithmetic program")
    name = get(options,"name","evaluator")
    # Validate emission before creating output files.
    header = IOBuffer()
    emit_cpp(header,plan;name)
    harness = IOBuffer()
    emit_harness(harness,plan.program;name)
    mkpath(directory)
    write(joinpath(directory,"evaluator.hpp"),take!(header))
    write(joinpath(directory,"evaluate.cpp"),take!(harness))
    write_plan(joinpath(directory,"plan.toml"),plan)
    println("Generated candidate in ",directory)
end
if abspath(PROGRAM_FILE) == @__FILE__
    generate_main(ARGS)
end
