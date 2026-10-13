#!/usr/bin/env julia
using PRESAGe
using TOML

include(joinpath(@__DIR__, "generation_artifacts.jl"))

function generate_main(args)
    length(args) >= 2 || error(
        "Usage: generate.jl erf|PLAN.toml|CONTRACT.toml OUTPUT_DIR [--target=cpu|kernel] [--toolchain=generic|vitis|oneapi] [--resource-model=MODEL.toml] [--search-config=SEARCH.toml] [--backend=portable|ap_fixed|ac_fixed] [--float-backend=auto|native|ac_std_float] [--internal=fixed|single|double] [--input-format=half|single] [--output-format=half|single] [--implementation=auto|lut|polynomial] [--lut-max-bits=1048576] [--lut-max-entries=65536] [--objective=memory|arithmetic|resources|luts|ffs|dsps|rams|mlabs] [--max-table-blocks=N] [--max-luts=N] [--max-ffs=N] [--max-dsps=N] [--max-rams=N] [--max-mlabs=N] [--max-parallel=N] [--absolute-error=RATIONAL] [--degree=9] [--segments=4] [--evaluation=auto|separate|fma] [--fraction-bits=31] [--certify=true|false] [--trace=true|false]",
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
            "target",
            "toolchain",
            "trace",
            "resource-model",
            "lut-max-entries",
            "objective",
            "max-table-blocks",
            "max-luts",
            "max-ffs",
            "max-dsps",
            "max-rams",
            "max-mlabs",
            "max-parallel",
        ) || error("unknown option $key")
        haskey(options, key) && error("duplicate option $key")
        options[key] = value
    end
    backend = Symbol(get(options, "backend", "ac_fixed"))
    backend in PRESAGe._CPP_BACKENDS ||
        error("backend must be portable, ap_fixed or ac_fixed")
    target = Symbol(get(options, "target", "cpu"))
    target in (:cpu, :kernel) || error("target must be cpu or kernel")
    toolchain = Symbol(get(options, "toolchain", "generic"))
    toolchain in PRESAGe._KERNEL_TOOLCHAINS ||
        error("toolchain must be generic, vitis or oneapi")
    target == :cpu &&
        haskey(options, "toolchain") &&
        error("toolchain requires target=kernel")
    target == :kernel &&
        haskey(options, "float-backend") &&
        error("float-backend is a CPU option; kernels use encoded floating interfaces")
    float_backend = Symbol(get(options, "float-backend", "auto"))
    float_backend in PRESAGe._CPP_FLOAT_BACKENDS ||
        error("float-backend must be auto, native or ac_std_float")
    trace_flag = get(options, "trace", "false")
    trace_flag in ("true", "false") || error("trace must be true or false")
    trace = trace_flag == "true"
    resource_model =
        haskey(options, "resource-model") ? read_resource_model(options["resource-model"]) :
        nothing
    implementation = Symbol(get(options, "implementation", "auto"))
    implementation in (:auto, :lut, :polynomial) ||
        error("implementation must be auto, lut or polynomial")
    lut_max_entries =
        PRESAGe._lut_entry_limit(parse(BigInt, get(options, "lut-max-entries", "65536")))
    limits = Dict{Symbol, Union{BigInt, Rational{BigInt}}}(
        name => PRESAGe._resource_count(
            PRESAGe._resource_exact(options["max-$name"]),
            name,
        ) for name in PRESAGe._RESOURCE_NAMES if haskey(options, "max-$name")
    )
    resource_budget = ResourceBudget(; limits...)
    max_table_blocks =
        haskey(options, "max-table-blocks") ? parse(BigInt, options["max-table-blocks"]) :
        nothing
    objective = Symbol(
        get(options, "objective", resource_model === nothing ? "memory" : "resources"),
    )
    PRESAGe._validate_sweep_selection(
        max_table_blocks,
        objective,
        resource_model,
        resource_budget,
    )
    selection_options = (
        "objective",
        "max-table-blocks",
        "max-luts",
        "max-ffs",
        "max-dsps",
        "max-rams",
        "max-mlabs",
    )
    compare_implementations =
        resource_model !== nothing || any(k -> haskey(options, k), selection_options)
    compare_implementations &&
        haskey(options, "lut-max-bits") &&
        error(
            "resource/memory selection uses budgets; lut-max-bits is the standalone storage policy",
        )
    implementation_report = nothing
    flag = get(
        options,
        "certify",
        get(options, "internal", "fixed") == "fixed" ? "true" : "false",
    )
    flag in ("true", "false") || error("certify must be true or false")
    certify = flag == "true"
    proof_precision = parse(Int, get(options, "proof-precision", "256"))
    accuracy = PRESAGe._parse_rational(get(options, "norm-accuracy", "1/1024"))
    compare_implementations &&
        source == "erf" &&
        !certify &&
        any(k -> haskey(options, k), selection_options) &&
        error("implementation selection requires certification")
    haskey(options, "max-parallel") &&
        !haskey(options, "search-config") &&
        error("max-parallel requires search-config")
    result = nothing
    search = nothing
    plan = if haskey(options, "search-config")
        source == "erf" && error("search-config requires a bounded contract file")
        all(
            k -> k in (
                "search-config",
                "name",
                "backend",
                "float-backend",
                "certify",
                "target",
                "toolchain",
                "trace",
                "resource-model",
                "implementation",
                "lut-max-entries",
                "objective",
                "max-table-blocks",
                "max-luts",
                "max-ffs",
                "max-dsps",
                "max-rams",
                "max-mlabs",
                "max-parallel",
            ),
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
        haskey(options, "lut-max-entries") &&
            !compare_implementations &&
            !haskey(options, "implementation") &&
            error("lut-max-entries requires implementation selection")
        if compare_implementations || haskey(options, "implementation")
            choices = implementation == :auto ? (:lut, :polynomial) : (implementation,)
            implementation_report = sweep_implementations(
                contract.spec,
                config;
                implementations = choices,
                lut_max_entries,
                resource_model,
                resource_budget,
                max_table_blocks,
                objective,
                target = target == :kernel ? TargetProfile(toolchain; backend) : nothing,
                max_parallel = parse(Int, get(options, "max-parallel", "1")),
            )
            selection = only(implementation_report.selections)
            if selection.status != :selected
                _generation_implementation_failure(directory, implementation_report)
                error("$(selection.status): $(selection.reason)")
            end
            result =
                only(
                    r for r in implementation_report.rows if r.index == selection.row_index
                ).attempt.certificate
        else
            haskey(options, "max-parallel") &&
                error("max-parallel requires implementation selection")
            search = search_polynomial(
                contract.spec,
                config;
                target = target == :kernel ? TargetProfile(toolchain; backend) : nothing,
            )
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
        end
        result.plan
    elseif source == "erf"
        internal = get(options, "internal", "fixed")
        internal in ("fixed", "single", "double") ||
            error("internal must be fixed, single or double")
        degree = parse(Int, get(options, "degree", "9"))
        segments = parse(Int, get(options, "segments", "4"))
        evaluation = Symbol(get(options, "evaluation", certify ? "auto" : "separate"))
        evaluation in (:auto, :separate, :fma) ||
            error("evaluation must be auto, separate or fma")
        evaluation == :auto &&
            !certify &&
            error("automatic arithmetic requires certification")
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
            model = ImplementationModel(;
                lut_max_bits = parse(BigInt, get(options, "lut-max-bits", string(1 << 20))),
            )
            selected =
                compare_implementations ? :deferred :
                select_implementation(spec; implementation, model, lut_max_entries)
            if selected == :lut || implementation == :lut
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
                numerical = (;
                    spec,
                    model,
                    lut_max_entries,
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
                if compare_implementations || evaluation == :auto && selected != :lut
                    candidates = CertificationResult[]
                    if implementation != :polynomial && (
                        implementation == :lut ||
                        PRESAGe._lut_availability(spec, lut_max_entries).available
                    )
                        push!(
                            candidates,
                            certified_lut(
                                spec;
                                config = OracleConfig(
                                    initial_precision = proof_precision,
                                    max_precision = max(4096, proof_precision),
                                ),
                                max_entries = lut_max_entries,
                            ),
                        )
                    end
                    if implementation != :lut
                        evaluations =
                            evaluation == :auto ? (:separate, :fma) : (evaluation,)
                        for arithmetic in evaluations
                            push!(
                                candidates,
                                certified_erf(;
                                    numerical...,
                                    evaluation = arithmetic,
                                    implementation = :polynomial,
                                ),
                            )
                        end
                    end
                    implementation_report = select_implementation(
                        candidates;
                        resource_model,
                        resource_budget,
                        max_table_blocks,
                        objective,
                        implementation,
                    )
                    if implementation_report.selected === nothing
                        _generation_implementation_failure(directory, implementation_report)
                        if all(candidate -> candidate.status != :certified, candidates)
                            write_certificate(
                                joinpath(directory, "certificate-failure.toml"),
                                first(candidates),
                            )
                        end
                        error(
                            "$(implementation_report.status): $(implementation_report.reason)",
                        )
                    end
                    result = implementation_report.selected
                else
                    result = certified_erf(; numerical..., implementation)
                end
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
            evaluation == :auto && error(
                "automatic floating erf generation requires a bounded contract and search-config",
            )
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
                "target",
                "toolchain",
                "trace",
                "resource-model",
                "implementation",
                "lut-max-entries",
                "objective",
                "max-table-blocks",
                "max-luts",
                "max-ffs",
                "max-dsps",
                "max-rams",
                "max-mlabs",
            ),
            keys(options),
        ) || error("generation options require the erf source")
        artifact = read_plan(source)
        if artifact.program === nothing
            implementation == :lut || error(
                "contract generation requires search-config or implementation=lut",
            )
            certify || error("LUT generation requires certification")
            result = certified_lut(
                artifact.spec;
                max_entries = lut_max_entries,
                config = OracleConfig(
                    initial_precision = proof_precision,
                    max_precision = max(4096, proof_precision),
                ),
            )
            if compare_implementations
                implementation_report = select_implementation(
                    (result,);
                    resource_model,
                    resource_budget,
                    objective,
                    max_table_blocks,
                    implementation = :lut,
                )
                if implementation_report.selected === nothing
                    _generation_implementation_failure(directory, implementation_report)
                    error(
                        "$(implementation_report.status): $(implementation_report.reason)",
                    )
                end
            end
            result.plan
        else
            any(
                k -> haskey(options, k),
                ("implementation", "lut-max-entries", selection_options...),
            ) && error("implementation options require a function contract")
            artifact
        end
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
        if target == :kernel
            artifacts["evaluator.hpp"] = _generation_text(
                (io, p) ->
                    emit_kernel(io, p; name, backend, toolchain, trace, resource_model),
                plan,
            )
            artifacts["evaluate.cpp"] =
                _generation_text((io, p) -> emit_kernel_harness(io, p; name), plan.program)
        else
            artifacts["evaluator.hpp"] = _generation_text(
                (io, p) -> emit_cpp(io, p; name, backend, float_backend, trace),
                plan,
            )
            artifacts["evaluate.cpp"] =
                _generation_text((io, p) -> emit_harness(io, p; name, trace), plan.program)
        end
        artifacts["plan.toml"] = _generation_text(write_plan, plan)
        if resource_model !== nothing
            artifacts["resources.toml"] = _generation_text(
                write_resource_report,
                estimate_resources(plan; model = resource_model),
            )
            artifacts["resource-model.toml"] =
                _generation_text(write_resource_model, resource_model)
        end
        result === nothing ||
            (artifacts["certificate.toml"] = _generation_text(write_certificate, result))
        search === nothing ||
            (artifacts["search.toml"] = _generation_text(write_search_report, search))
        implementation_report === nothing || (
            artifacts["implementations.toml"] =
                _generation_text(write_implementation_report, implementation_report)
        )
    catch err
        err isa InterruptException && rethrow()
        implementation_report === nothing || _generation_implementation_failure(
            directory,
            implementation_report;
            stage = "emission",
            reason = sprint(showerror, err),
        )
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
        implementation_report === nothing || _generation_implementation_failure(
            directory,
            implementation_report;
            stage = "publication",
            reason = sprint(showerror, err),
        )
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
        costs.table_blocks,
        " modeled memory blocks (",
        costs.table_block_depth,
        "x",
        costs.table_block_word_bits,
        "), ",
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
    if resource_model !== nothing
        resources = estimate_resources(plan; model = resource_model)
        println(
            "Resource model ",
            resource_model.name,
            ": ",
            resources.status,
            " ",
            resources.totals,
        )
    end
    return plan
end
if abspath(PROGRAM_FILE) == @__FILE__
    generate_main(ARGS)
end
