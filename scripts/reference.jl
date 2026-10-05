#!/usr/bin/env julia
using PRESAGe

function main(args)
    length(args) >= 3 || error("Usage: reference.jl EXPRESSION INPUT.bin OUTPUT.bin [--format=single] " *
        "[--byteorder=little] [--chunk-elements=4096] [--backend=sollya] [--max-precision=4096]")
    expression, input, output = args[1:3]
    options = Dict{String,String}()
    allowed = ("format", "byteorder", "chunk-elements", "backend", "initial-precision", "max-precision")
    for arg in args[4:end]
        startswith(arg, "--") && occursin('=', arg) || error("Expected --option=value: $arg")
        key, value = split(arg[3:end], '='; limit=2)
        key in allowed || error("Unknown option: $key")
        haskey(options, key) && error("Duplicate option: $key")
        options[key] = value
    end
    formats = Dict("half" => IEEE16, "single" => IEEE32, "double" => IEEE64)
    format = get(formats, get(options, "format", "single"), nothing)
    format === nothing && error("Format must be half, single or double")
    aliases = Dict("recip" => "1/x", "rsqrt" => "1/sqrt(x)",
                   "asinpi" => "asin(x)/pi", "acospi" => "acos(x)/pi", "atanpi" => "atan(x)/pi")
    expression = get(aliases, expression, expression)
    if occursin(r"^[A-Za-z_][A-Za-z_0-9]*$", expression) && expression ∉ ("x", "pi")
        expression *= "(x)"
    end
    config = OracleConfig(; initial_precision=parse(Int, get(options, "initial-precision", "256")),
                           max_precision=parse(Int, get(options, "max-precision", "4096")))
    result = generate_references(FunctionSpec(expression; input_format=format), input, output;
        config, byteorder=Symbol(get(options, "byteorder", "little")),
        chunk_elements=parse(Int, get(options, "chunk-elements", "4096")),
        backend=Symbol(get(options, "backend", "sollya")))
    println("Wrote ", result["outputs_written"], " references to ", output)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
