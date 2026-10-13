using PRESAGe

function variable_fma_cubic()
    format = FloatFormat(8, 17)
    width = 1 + format.exponent_bits + format.fraction_bits
    input = FixedFormat(5width, 5width; signed = false)
    nodes = IR.Node[IR.Input(input), IR.BitCast(1, IR.UIntFormat(input.width))]
    operands = Int[]
    for index = 0:4
        push!(nodes, IR.ExtractBits(2, index * width, width))
        push!(nodes, IR.BitCast(length(nodes), format))
        push!(operands, length(nodes))
    end
    output = PRESAGe._horner!(nodes, first(operands), operands[2:end], format, :fma)
    spec = FunctionSpec("0"; input_format = input, output_format = format, domain = (0, 1))
    return PlanArtifact(
        spec;
        program = IR.Program(nodes; output),
        settings = Dict("validation" => "variable_coefficients"),
    )
end

function fma_validation_main(args)
    length(args) == 2 || error("Usage: fma_validation.jl MODEL.toml OUTPUT_DIRECTORY")
    model = read_resource_model(args[1])
    model.toolchain in (:oneapi, :vitis) || error("FMA validation requires a vendor target")
    formats =
        model.toolchain == :oneapi ?
        [FloatFormat(e, m) for (e, m) in (PRESAGe._INTEL_FLOAT_FORMATS..., (8, 22))] :
        [IEEE16, FloatFormat(8, 17), IEEE32, IEEE64]
    plans = resource_probe_plans(; formats, operations = (:fma,))
    probes = joinpath(args[2], "probes")
    write_resource_examples(probes; model, plans, certify = false)

    spec = FunctionSpec(
        "1/3+2/7*x-3/11*x^2+4/13*x^3";
        input_format = FixedFormat(10, 3),
        output_format = IEEE32,
        domain = (-1, 1),
        absolute_error = 1 // 256,
    )
    precision = PolynomialPrecision(
        IEEE32;
        coefficient_formats = [FloatFormat(8, m) for m in (12, 18, 20, 22)],
        stage_formats = [FloatFormat(8, m) for m in (17, 22, 26, 23)],
    )
    plan = polynomial_plan(
        spec,
        [1 // 3, 2 // 7, -3 // 11, 4 // 13];
        internal_format = IEEE32,
        evaluation = :fma,
        precision,
    )
    holdout = joinpath(args[2], "holdout")
    write_resource_examples(holdout; model, plans = ["mixed-stage-cubic" => plan])
    composition = joinpath(args[2], "composition")
    write_resource_examples(
        composition;
        model,
        plans = ["variable-cubic" => variable_fma_cubic()],
        certify = false,
    )
    flow = model.toolchain == :vitis ? :hls : :oneapi_hls
    for directory in (probes, holdout, composition)
        println(prepare_synthesis(joinpath(directory, "examples.toml"); flow))
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(fma_validation_main(ARGS))
end
