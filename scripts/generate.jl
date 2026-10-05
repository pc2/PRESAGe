#!/usr/bin/env julia
using PRESAGe

function generate_main(args)
    length(args) >= 2 || error("Usage: generate.jl erf|PLAN.toml OUTPUT_DIR [--backend=portable|ap_fixed|ac_fixed] [--internal=fixed|single|double] [--degree=9] [--segments=4] [--evaluation=separate|fma] [--fraction-bits=31] [--certify=true|false]")
    source,directory = args[1:2]
    options = Dict{String,String}()
    for arg in args[3:end]
        arg == "--certify" && (arg = "--certify=true")
        startswith(arg,"--") && occursin('=',arg) || error("expected --option=value")
        key,value = split(arg[3:end],'=';limit=2)
        key in ("degree","segments","internal","evaluation","name","fraction-bits","max-fraction-bits",
            "coefficient-fraction-bits","generation-precision","proof-precision","norm-accuracy","certify","backend") || error("unknown option $key")
        haskey(options,key) && error("duplicate option $key")
        options[key] = value
    end
    backend = Symbol(get(options,"backend","ac_fixed"))
    backend in PRESAGe._CPP_BACKENDS || error("backend must be portable, ap_fixed or ac_fixed")
    flag = get(options,"certify",get(options,"internal","fixed") == "fixed" ? "true" : "false")
    flag in ("true","false") || error("certify must be true or false")
    certify = flag == "true"
    proof_precision = parse(Int,get(options,"proof-precision","256"))
    accuracy = PRESAGe._parse_rational(get(options,"norm-accuracy","1/1024"))
    result = nothing
    plan = if source == "erf"
        internal = get(options,"internal","fixed")
        internal in ("fixed","single","double") || error("internal must be fixed, single or double")
        degree = parse(Int,get(options,"degree","9"))
        segments = parse(Int,get(options,"segments","4"))
        evaluation = Symbol(get(options,"evaluation","separate"))
        precision = parse(Int,get(options,"generation-precision","256"))
        if internal == "fixed"
            fraction = parse(Int,get(options,"fraction-bits",string(23+ndigits(16degree-1;base=2))))
            coefficient_fraction = haskey(options,"coefficient-fraction-bits") ? parse(Int,options["coefficient-fraction-bits"]) : nothing
            if certify
                result = certified_erf(;degree,segments,initial_fraction_bits=fraction,
                    max_fraction_bits=parse(Int,get(options,"max-fraction-bits",string(max(47,fraction)))),
                    coefficient_fraction_bits=coefficient_fraction,evaluation,precision,proof_precision,accuracy)
                result.plan
            else
                haskey(options,"max-fraction-bits") && error("max-fraction-bits requires certification")
                erf_fixed_candidate(;degree,segments,fraction_bits=fraction,
                    coefficient_fraction_bits=coefficient_fraction === nothing ? fraction : coefficient_fraction,
                    evaluation,precision)
            end
        else
            any(k -> k in ("fraction-bits","max-fraction-bits","coefficient-fraction-bits"),keys(options)) &&
                error("fixed width options require internal=fixed")
            erf_candidate(;degree,segments,internal_format=internal == "single" ? IEEE32 : IEEE64,evaluation,precision)
        end
    else
        all(k -> k in ("name","certify","proof-precision","norm-accuracy","backend"),keys(options)) || error("generation options require the erf source")
        read_plan(source)
    end
    if !haskey(options,"certify") && source != "erf"
        certify = plan.program !== nothing && PRESAGe._has_fixed(plan.program)
    end
    if !certify && any(k -> k in ("proof-precision","norm-accuracy"),keys(options))
        error("proof options require certification")
    end
    certify && result === nothing && (result = certify_erf(plan;precision=proof_precision,accuracy))
    if result !== nothing && result.status != :certified
        mkpath(directory)
        write_certificate(joinpath(directory,"certificate-failure.toml"),result)
        error("$(result.status): $(result.reason)")
    end
    plan.program === nothing && error("plan contains no arithmetic program")
    name = get(options,"name","evaluator")
    # Validate emission before creating output files.
    header = IOBuffer()
    emit_cpp(header,plan;name,backend)
    harness = IOBuffer()
    emit_harness(harness,plan.program;name)
    mkpath(directory)
    certificate_path = joinpath(directory,"certificate.toml")
    isfile(certificate_path) && rm(certificate_path)
    write(joinpath(directory,"evaluator.hpp"),take!(header))
    write(joinpath(directory,"evaluate.cpp"),take!(harness))
    write_plan(joinpath(directory,"plan.toml"),plan)
    if result !== nothing
        write_certificate(certificate_path,result)
        println("Generated certified evaluator in ",directory,"; uniform bound ",Float64(result.total_bound))
    else
        println("Generated candidate in ",directory)
    end
    failure = joinpath(directory,"certificate-failure.toml")
    isfile(failure) && rm(failure)
end
if abspath(PROGRAM_FILE) == @__FILE__
    generate_main(ARGS)
end
