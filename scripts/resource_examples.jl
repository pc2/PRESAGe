#!/usr/bin/env julia
using PRESAGe
using TOML

function resource_examples_main(args)
    2 <= length(args) <= 4 || error(
        "Usage: scripts/resource_examples.jl MODEL.toml OUTPUT_DIR [--backend=ap_fixed|ac_fixed] [--include-float=true|false]",
    )
    model, destination = read_resource_model(args[1]), args[2]
    options = Dict{String, String}()
    for argument in args[3:end]
        parts = split(argument, '='; limit = 2)
        length(parts) == 2 &&
            parts[1] in ("--backend", "--include-float") &&
            !haskey(options, parts[1]) || error("invalid or duplicate example option")
        options[parts[1]] = parts[2]
    end
    backend = Symbol(
        get(options, "--backend", model.toolchain == :vitis ? "ap_fixed" : "ac_fixed"),
    )
    backend in (:ap_fixed, :ac_fixed) || error("backend must be ap_fixed or ac_fixed")
    flag = get(options, "--include-float", "false")
    flag in ("true", "false") || error("include-float must be true or false")
    include_float = flag == "true"
    include_float &&
        (backend != :ac_fixed || model.toolchain == :vitis) &&
        error("floating kernel examples require AC with generic or oneAPI emission")
    data = write_resource_examples(destination; model, backend, include_float)
    println(
        "Generated $(length(data["examples"])) certified resource examples in $destination",
    )
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(resource_examples_main(ARGS))
end
