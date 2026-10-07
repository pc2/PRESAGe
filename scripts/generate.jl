#!/usr/bin/env julia
using PRESAGe
using TOML

include(joinpath(@__DIR__, "generation_artifacts.jl"))

function generate_main(args)
    length(args) >= 2 || error(
        "Usage: generate.jl erf|PLAN.toml|CONTRACT.toml OUTPUT_DIR [--search-config=SEARCH.toml] [--backend=portable|ap_fixed|ac_fixed] [--float-backend=auto|native|ac_std_float] [--internal=fixed|single|double] [--input-format=half|single] [--output-format=half|single] [--implementation=auto|lut|polynomial] [--lut-max-bits=1048576] [--absolute-error=RATIONAL] [--degree=9] [--segments=4] [--evaluation=separate|fma] [--fraction-bits=31] [--certify=true|false]",
    )
    source, directory = args[1:2]
    options = Dict{String, String}()
    for arg in args[3:end]
        arg == "--certify" && (arg = "--certify=true")
        startswith(arg, "--") && occursin('=', arg) || error("expected --option=value")
        key, value = split(arg[3:end], '='; limit = 2)
        key in (
            "degree",
            "segments",
            "internal",
            "evaluation",
            "name",
            "fraction-bits",
            "max-fraction-bits",
            "coefficient-fraction-bits",
            "generation-precision",
            "proof-precision",
            "norm-accuracy",
            "certify",
            "backend",
            "float-backend",
            "input-format",
            "output-format",
            "absolute-error",
            "implementation",
            "lut-max-bits",
            "search-config",
        ) || error("unknown option $key")
        haskey(options, key) && error("duplicate option $key")
        options[key] = value
    end
    backend = Symbol(get(options, "backend", "ac_fixed"))
    backend in PRESAGe._CPP_BACKENDS ||
        error("backend must be portable, ap_fixed or ac_fixed")
    float_backend = Symbol(get(options, "float-backend", "auto"))
    float_backend in PRESAGe._CPP_FLOAT_BACKENDS ||
        error("float-backend must be auto, native or ac_std_float")
    flag = get(
        options,
        "certify",
        get(options, "internal", "fixed") == "fixed" ? "true" : "false",
    )
    flag in ("true", "false") || error("certify must be true or false")
    certify = flag == "true"
    proof_precision = parse(Int, get(options, "proof-precision", "256"))
    accuracy = PRESAGe._parse_rational(get(options, "norm-accuracy", "1/1024"))
    result = nothing
    search = nothing
    plan = if haskey(options, "search-config")
        source == "erf" && error("search-config requires a bounded contract file")
        all(
            k -> k in ("search-config", "name", "backend", "float-backend", "certify"),
            keys(options),
        ) || error("search settings belong in the search configuration file")
        certify || error("bounded search requires certification")
        contract = read_plan(source)
        contract.program === nothing &&
            contract.status == :contract &&
            isempty(contract.segments) &&
            contract.dispatch === nothing &&
            isempty(contract.settings) || error(
            "bounded search requires a contract without candidate data or settings",
        )
        config = read_search_config(options["search-config"])
        search = search_polynomial(contract.spec, config)
        if search.status != :certified
            _generation_search_failure(directory, search)
            detail =
                isempty(search.attempts) ? "no attempts started" :
                last(search.attempts).reason
            error(
                "search_limit ($(search.stop_reason)), $(length(search.attempts)) attempts: $detail",
            )
        end
        result = search.selected
        result.plan
    elseif source == "erf"
        internal = get(options, "internal", "fixed")
        internal in ("fixed", "single", "double") ||
            error("internal must be fixed, single or double")
        degree = parse(Int, get(options, "degree", "9"))
        segments = parse(Int, get(options, "segments", "4"))
        evaluation = Symbol(get(options, "evaluation", "separate"))
        precision = parse(Int, get(options, "generation-precision", "256"))
        if internal == "fixed"
            formats = Dict("half" => IEEE16, "single" => IEEE32)
            input_name = get(options, "input-format", "single")
            output_name = get(options, "output-format", input_name)
            haskey(formats, input_name) && haskey(formats, output_name) ||
                error("fixed erf interfaces must be half or single")
            input = formats[input_name]
            output = formats[output_name]
            input == output ||
                error("fixed erf requires matching input and output formats")
            spec = erf_spec(;
                format = input,
                absolute_error = PRESAGe._parse_rational(
                    get(
                        options,
                        "absolute-error",
                        PRESAGe._rational_text(PRESAGe._pow2(-output.fraction_bits)),
                    ),
                ),
            )
            implementation = Symbol(get(options, "implementation", "auto"))
            model = ImplementationModel(;
                lut_max_bits = parse(BigInt, get(options, "lut-max-bits", string(1 << 20))),
            )
            selected = select_implementation(spec; implementation, model)
            if selected == :lut
                certify || error("LUT generation requires certification")
                any(
                    k -> k in (
                        "degree",
                        "segments",
                        "evaluation",
                        "fraction-bits",
                        "max-fraction-bits",
                        "coefficient-fraction-bits",
                        "generation-precision",
                        "norm-accuracy",
                    ),
                    keys(options),
                ) && error("polynomial options do not apply to LUT generation")
            end
            fraction = parse(
                Int,
                get(
                    options,
                    "fraction-bits",
                    string(output.fraction_bits + ndigits(16degree - 1; base = 2)),
                ),
            )
            coefficient_fraction =
                haskey(options, "coefficient-fraction-bits") ?
                parse(Int, options["coefficient-fraction-bits"]) : nothing
            if certify
                result = certified_erf(;
                    spec,
                    implementation,
                    model,
                    degree,
                    segments,
                    initial_fraction_bits = fraction,
                    max_fraction_bits = parse(
                        Int,
                        get(
                            options,
                            "max-fraction-bits",
                            string(max(output.fraction_bits + 24, fraction)),
                        ),
                    ),
                    coefficient_fraction_bits = coefficient_fraction,
                    evaluation,
                    precision,
                    proof_precision,
                    accuracy,
                )
                result.plan
            else
                haskey(options, "max-fraction-bits") &&
                    error("max-fraction-bits requires certification")
                erf_fixed_candidate(;
                    spec,
                    degree,
                    segments,
                    fraction_bits = fraction,
                    coefficient_fraction_bits = coefficient_fraction === nothing ?
                                                fraction : coefficient_fraction,
                    evaluation,
                    precision,
                )
            end
        else
            any(
                k -> k in (
                    "input-format",
                    "output-format",
                    "absolute-error",
                    "implementation",
                    "lut-max-bits",
                ),
                keys(options),
            ) && error("interface and implementation options require internal=fixed")
            any(
                k -> k in
                ("fraction-bits", "max-fraction-bits", "coefficient-fraction-bits"),
                keys(options),
            ) && error("fixed width options require internal=fixed")
            erf_candidate(;
                degree,
                segments,
                internal_format = internal == "single" ? IEEE32 : IEEE64,
                evaluation,
                precision,
            )
        end
    else
        all(
            k -> k in (
                "name",
                "certify",
                "proof-precision",
                "norm-accuracy",
                "backend",
                "float-backend",
            ),
            keys(options),
        ) || error("generation options require the erf source")
        read_plan(source)
    end
    if !haskey(options, "certify") && source != "erf"
        certify = PRESAGe._has_supported_certificate(plan)
    end
    if !certify && any(k -> k in ("proof-precision", "norm-accuracy"), keys(options))
        error("proof options require certification")
    end
    certify &&
        result === nothing &&
        (result = certify_plan(plan; precision = proof_precision, accuracy))
    if result !== nothing && result.status != :certified
        mkpath(directory)
        write_certificate(joinpath(directory, "certificate-failure.toml"), result)
        error("$(result.status): $(result.reason)")
    end
    plan.program === nothing && error("plan contains no arithmetic program")
    name = get(options, "name", "evaluator")
    artifacts = Dict{String, String}()
    try
        artifacts["evaluator.hpp"] =
            _generation_text((io, p) -> emit_cpp(io, p; name, backend, float_backend), plan)
        artifacts["evaluate.cpp"] =
            _generation_text((io, program) -> emit_harness(io, program; name), plan.program)
        artifacts["plan.toml"] = _generation_text(write_plan, plan)
        result === nothing ||
            (artifacts["certificate.toml"] = _generation_text(write_certificate, result))
        search === nothing ||
            (artifacts["search.toml"] = _generation_text(write_search_report, search))
    catch err
        err isa InterruptException && rethrow()
        search === nothing || _generation_search_failure(
            directory,
            search;
            stage = "emission",
            reason = sprint(showerror, err),
        )
        rethrow()
    end
    try
        _publish_generation(directory, artifacts)
    catch err
        err isa InterruptException && rethrow()
        search === nothing || _generation_search_failure(
            directory,
            search;
            stage = "publication",
            reason = sprint(showerror, err),
        )
        rethrow()
    end
    if result !== nothing
        println(
            "Generated certified evaluator in ",
            directory,
            "; uniform bound ",
            Float64(result.total_bound),
        )
    else
        println("Generated candidate in ", directory)
    end
    costs = implementation_cost(plan)
    println(
        "Implementation ",
        get(plan.settings, "kernel", "floating_horner"),
        ": ",
        costs.table_bits,
        " table bits, ",
        costs.table_reads,
        " table reads, ",
        costs.multiplications,
        " multiplications, ",
        costs.additions,
        " additions, ",
        costs.fmas,
        " FMAs, ",
        costs.divisions,
        " divisions, ",
        costs.normalizations,
        " normalizations, ",
        costs.exponent_scalings,
        " exponent scalings, ",
        costs.exponent_extractions,
        " exponent extractions, ",
        costs.sign_copies,
        " sign copies (static IR counts)",
    )
    return plan
end
if abspath(PROGRAM_FILE) == @__FILE__
    generate_main(ARGS)
end
