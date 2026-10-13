function resource_example_plans(; include_float = false, float_evaluation = :fma)
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
        geometry = _segment_geometry(spec, count, format)
        scale = _pow2(-geometry.exponent)
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
    geometry = _segment_geometry(spec, 512, format)
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
    argument_scale = 256_pow2(-geometry.exponent)
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
                "float-$(1 + format.exponent_bits + format.fraction_bits)-$float_evaluation" =>
                    polynomial_plan(
                        spec,
                        [1 // 3, 2 // 7];
                        internal_format = format,
                        evaluation = float_evaluation,
                    ),
            )
        end
    end
    return plans
end


"""Write certified calibration kernels and their exact plans and resource estimates."""
function write_resource_examples(
    destination::AbstractString;
    model::ResourceModel,
    backend::Symbol = model.toolchain == :vitis ? :ap_fixed : :ac_fixed,
    include_float::Bool = false,
    plans = resource_example_plans(;
        include_float,
        float_evaluation = model.toolchain == :oneapi ? :separate : :fma,
    ),
    certify::Bool = true,
)
    TargetProfile(model.toolchain; backend)
    plans = collect(plans)
    names = first.(plans)
    length(unique(names)) == length(names) ||
        throw(ArgumentError("resource example names must be unique"))
    entries = Dict{String, Any}[]
    for (name, plan) in plans
        certificate = certify ? certify_plan(plan) : nothing
        certificate === nothing ||
            certificate.status == :certified ||
            error("$name: $(certificate.reason)")
        estimate = estimate_resources(plan; model)
        directory = joinpath(destination, name)
        mkpath(directory)
        write_plan(joinpath(directory, "plan.toml"), plan)
        certificate === nothing ||
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
    return data
end

"""Build isolated arithmetic probes with independently supplied operand bits."""
function resource_probe_plans(;
    formats = [FixedFormat(width, 4) for width in (16, 24, 32, 48, 64)],
    operations = (:add, :mul),
    constants = nothing,
    operand_formats = nothing,
    input_formats = nothing,
)
    plans = Pair{String, PlanArtifact}[]
    for format in formats, operation in operations
        operation in (:add, :mul, :fma) ||
            throw(ArgumentError("unsupported primitive operation"))
        width = _kernel_width(format)
        count = operation == :fma ? 3 : 2
        shapes = operand_formats === nothing ? fill(format, count) : operand_formats
        length(shapes) == count ||
            throw(ArgumentError("one format is required per operand"))
        all(f -> f isa typeof(format), shapes) ||
            throw(ArgumentError("probe operands must share the output format family"))
        format isa FloatFormat &&
            any(!=(format), shapes) &&
            throw(ArgumentError("floating probes require identical operand formats"))
        values = constants === nothing ? fill(nothing, count) : constants
        length(values) == count ||
            throw(ArgumentError("one constant choice is required per operand"))
        inputs = input_formats === nothing ? shapes : input_formats
        length(inputs) == count ||
            throw(ArgumentError("one input format is required per operand"))
        for (input, shape, value) in zip(inputs, shapes, values)
            input == shape && continue
            value === nothing &&
                input isa FixedFormat &&
                shape isa FixedFormat &&
                input.signed == shape.signed &&
                input.integer_bits <= shape.integer_bits &&
                _fraction(input) <= _fraction(shape) || throw(
                ArgumentError("probe input conversions must be exact fixed extensions"),
            )
        end
        variables = Base.count(isnothing, values)
        variables > 0 || throw(ArgumentError("a resource probe needs a variable operand"))
        input_width =
            sum(_kernel_width(f) for (f, value) in zip(inputs, values) if value === nothing)
        input = FixedFormat(input_width, input_width; signed = false)
        nodes = IR.Node[IR.Input(input), IR.BitCast(1, IR.UIntFormat(input_width))]
        operands = Int[]
        index = 0
        for (shape, source, value) in zip(shapes, inputs, values)
            if value === nothing
                bits = _kernel_width(source)
                push!(nodes, IR.ExtractBits(2, index, bits))
                push!(nodes, IR.BitCast(length(nodes), source))
                source == shape || push!(nodes, IR.Quantize(length(nodes), shape))
                index += bits
            else
                push!(nodes, IR.constant(value, shape))
            end
            push!(operands, length(nodes))
        end
        node =
            operation == :add ? IR.Add(operands..., format) :
            operation == :mul ? IR.Mul(operands..., format) : IR.FMA(operands..., format)
        push!(nodes, node)
        program = IR.Program(nodes)
        spec =
            FunctionSpec("0"; input_format = input, output_format = format, domain = (0, 1))
        family =
            format isa FloatFormat ?
            "float-$(format.exponent_bits)-$(format.fraction_bits)" : "fixed-$width"
        if format isa FixedFormat && (
            format.integer_bits != 4 ||
            !format.signed ||
            format.rounding != :nearest_even ||
            format.overflow != :reject
        )
            family *= "-i$(format.integer_bits)-$(format.signed ? "signed" : "unsigned")-$(format.rounding)-$(format.overflow)"
        end
        suffix =
            constants === nothing ? "" :
            "-" * bytes2hex(sha256(join(string.(values), ",")))[1:12]
        operand_formats === nothing ||
            (suffix *= "-" * bytes2hex(sha256(join(string.(shapes), ",")))[1:12])
        input_formats === nothing ||
            (suffix *= "-" * bytes2hex(sha256(join(string.(inputs), ",")))[1:12])
        push!(
            plans,
            "$family-$operation$suffix" => PlanArtifact(
                spec;
                program,
                settings = Dict("resource_probe" => "independent_operands"),
            ),
        )
    end
    return plans
end

"""Write arithmetic probes for synthesis and interpreter conformance without claiming approximation certificates."""
function write_resource_probes(destination::AbstractString; model::ResourceModel, kwargs...)
    return write_resource_examples(
        destination;
        model,
        plans = resource_probe_plans(; kwargs...),
        certify = false,
    )
end
