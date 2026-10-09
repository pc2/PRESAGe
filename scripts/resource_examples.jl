#!/usr/bin/env julia
using PRESAGe
using TOML

function resource_example_plans(; include_float = false)
    plans = Pair{String, PlanArtifact}[]
    for (width, evaluation) in ((16, :separate), (32, :separate), (64, :fma))
        format = FixedFormat(width, 4)
        spec = FunctionSpec(
            "1/3 + 2/7*x - 3/11*x^2 + 4/13*x^3";
            input_format = FixedFormat(10, 3),
            output_format = format,
            domain = (-1, 1),
            absolute_error = 1 // 2^8,
        )
        push!(
            plans,
            "fixed-$width-$evaluation" => polynomial_plan(
                spec,
                [1 // 3, 2 // 7, -3 // 11, 4 // 13];
                internal_format = format,
                evaluation,
            ),
        )
    end
    for count in (128, 512)
        format = FixedFormat(32, 4)
        spec = FunctionSpec(
            "1/(2-x)";
            input_format = FixedFormat(12, 3),
            output_format = format,
            domain = (-1, 1),
            absolute_error = 1 // 2^10,
        )
        geometry = PRESAGe._segment_geometry(spec, count, format)
        scale = PRESAGe._pow2(-geometry.exponent)
        rows = [[1 / (2 - center), scale / (2 - center)^2] for center in geometry.centers]
        push!(
            plans,
            "segments-$count" =>
                segmented_polynomial_plan(spec, rows; internal_format = format),
        )
    end
    format = FixedFormat(32, 4)
    spec = FunctionSpec(
        "sin(256*x)";
        input_format = FixedFormat(12, 3),
        output_format = format,
        domain = (-1, 1),
        absolute_error = 1 // 2^6,
    )
    geometry = PRESAGe._segment_geometry(spec, 512, format)
    precision = PolynomialPrecision(
        format;
        coefficient_formats = [
            FixedFormat(17, 4),
            FixedFormat(33, 4),
            FixedFormat(65, 4),
            FixedFormat(9, 1),
        ],
        stage_formats = fill(format, 4),
    )
    # Local Taylor coefficients stay nontrivial across all four storage columns.
    argument_scale = 256PRESAGe._pow2(-geometry.exponent)
    rows = setprecision(BigFloat, 256) do
        map(geometry.centers) do center
            argument = 256BigFloat(center)
            sine, cosine =
                Rational{BigInt}(sin(argument)), Rational{BigInt}(cos(argument))
            [
                sine,
                cosine * argument_scale,
                -sine * argument_scale^2 / 2,
                -cosine * argument_scale^3 / 6,
            ]
        end
    end
    push!(
        plans,
        "mixed-columns" =>
            segmented_polynomial_plan(spec, rows; internal_format = format, precision),
    )
    if include_float
        for format in (IEEE32, IEEE64)
            spec = FunctionSpec(
                "1/3 + 2/7*x";
                input_format = format,
                output_format = format,
                domain = (-1, 1),
                absolute_error = 1 // 2^20,
            )
            push!(
                plans,
                "float-$(1 + format.exponent_bits + format.fraction_bits)-fma" =>
                    polynomial_plan(
                        spec,
                        [1 // 3, 2 // 7];
                        internal_format = format,
                        evaluation = :fma,
                    ),
            )
        end
    end
    return plans
end

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
    entries = Dict{String, Any}[]
    for (name, plan) in resource_example_plans(; include_float)
        certificate = certify_plan(plan)
        certificate.status == :certified || error("$name: $(certificate.reason)")
        estimate = estimate_resources(plan; model)
        directory = joinpath(destination, name)
        mkpath(directory)
        write_plan(joinpath(directory, "plan.toml"), plan)
        write_certificate(joinpath(directory, "certificate.toml"), certificate)
        write_resource_model(joinpath(directory, "resource-model.toml"), model)
        write_resource_report(joinpath(directory, "resources.toml"), estimate)
        emit_kernel(
            joinpath(directory, "evaluator.hpp"),
            plan;
            backend,
            toolchain = model.toolchain,
            resource_model = model,
        )
        emit_kernel_harness(joinpath(directory, "evaluate.cpp"), plan.program)
        write(
            joinpath(directory, "kernel.cpp"),
            """
#include "evaluator.hpp"
extern "C" void presage_resource_kernel(presage_evaluator::InputBits input,
    presage_evaluator::OutputBits& output, unsigned& status) {
#if defined(__SYNTHESIS__)
#pragma HLS pipeline II=1
#endif
    auto result = presage_evaluator::evaluate_bits(input);
    output = result.bits;
    status = static_cast<unsigned>(result.status);
}
""",
        )
        push!(
            entries,
            Dict(
                "name" => name,
                "plan" => "$name/plan.toml",
                "resources" => "$name/resources.toml",
                "header" => "$name/evaluator.hpp",
                "kernel" => "$name/kernel.cpp",
                "model" => "$name/resource-model.toml",
            ),
        )
    end
    data = Dict(
        "schema" => "presage-resource-examples",
        "schema_version" => 1,
        "model" => model.name,
        "backend" => string(backend),
        "toolchain" => string(model.toolchain),
        "examples" => entries,
    )
    open(
        io -> TOML.print(io, data; sorted = true),
        joinpath(destination, "examples.toml"),
        "w",
    )
    println("Generated $(length(entries)) certified resource examples in $destination")
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(resource_examples_main(ARGS))
end
