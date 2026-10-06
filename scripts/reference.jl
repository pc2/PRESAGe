#!/usr/bin/env julia
using PRESAGe

function reference_format(text; rounding = :nearest_even, overflow = :reject)
    float = get(
        Dict(
            "half" => IEEE16,
            "single" => IEEE32,
            "double" => IEEE64,
            "quad" => IEEE128,
            "octuple" => IEEE256,
        ),
        text,
        nothing,
    )
    float === nothing || return float
    (startswith(text, "float(") || startswith(text, "binary")) &&
        return PRESAGe._read_format(text)
    parts = match(r"^(u?fixed)\((\d+),(\d+)\)$", text)
    parts === nothing && error(
        "format must be half, single, double, quad, octuple, float(E,M), fixed(W,I) or ufixed(W,I)",
    )
    return FixedFormat(
        parse(Int, parts[2]),
        parse(Int, parts[3]);
        signed = parts[1] == "fixed",
        rounding,
        overflow,
    )
end

function main(args)
    length(args) >= 3 || error(
        "Usage: reference.jl EXPRESSION INPUT.bin OUTPUT.bin [--input-format=single|fixed(W,I)|ufixed(W,I)] [--output-format=...] " *
        "[--byteorder=little] [--chunk-elements=4096] [--backend=sollya] [--max-precision=4096]",
    )
    expression, input, output = args[1:3]
    options = Dict{String, String}()
    allowed = (
        "format",
        "input-format",
        "output-format",
        "rounding",
        "overflow",
        "byteorder",
        "chunk-elements",
        "backend",
        "initial-precision",
        "max-precision",
    )
    for arg in args[4:end]
        startswith(arg, "--") && occursin('=', arg) ||
            error("Expected --option=value: $arg")
        key, value = split(arg[3:end], '='; limit = 2)
        key in allowed || error("Unknown option: $key")
        haskey(options, key) && error("Duplicate option: $key")
        options[key] = value
    end
    haskey(options, "format") &&
        haskey(options, "input-format") &&
        error("use format or input-format, not both")
    inputname = get(options, "input-format", get(options, "format", "single"))
    inputformat = reference_format(inputname)
    outputformat = reference_format(
        get(options, "output-format", inputname);
        rounding = Symbol(get(options, "rounding", "nearest_even")),
        overflow = Symbol(get(options, "overflow", "reject")),
    )
    outputformat isa FixedFormat ||
        !any(k -> haskey(options, k), ("rounding", "overflow")) ||
        error("rounding and overflow options require fixed output")
    aliases = Dict(
        "recip" => "1/x",
        "rsqrt" => "1/sqrt(x)",
        "asinpi" => "asin(x)/pi",
        "acospi" => "acos(x)/pi",
        "atanpi" => "atan(x)/pi",
    )
    expression = get(aliases, expression, expression)
    if occursin(r"^[A-Za-z_][A-Za-z_0-9]*$", expression) && expression ∉ ("x", "pi")
        expression *= "(x)"
    end
    config = OracleConfig(;
        initial_precision = parse(Int, get(options, "initial-precision", "256")),
        max_precision = parse(Int, get(options, "max-precision", "4096")),
    )
    result = generate_references(
        FunctionSpec(expression; input_format = inputformat, output_format = outputformat),
        input,
        output;
        config,
        byteorder = Symbol(get(options, "byteorder", "little")),
        chunk_elements = parse(Int, get(options, "chunk-elements", "4096")),
        backend = Symbol(get(options, "backend", "sollya")),
    )
    println("Wrote ", result["outputs_written"], " references to ", output)
end

if abspath(PROGRAM_FILE) == @__FILE__
    main(ARGS)
end
