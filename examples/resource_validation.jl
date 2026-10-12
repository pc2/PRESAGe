using PRESAGe

function resource_validation_plans()
    plans = Pair{String, PlanArtifact}[]
    for format in (IEEE32, IEEE64), evaluation in (:separate, :fma)
        width = 1 + format.exponent_bits + format.fraction_bits
        for degree in (3, 5)
            coefficients = [fill(1 // 3, degree); 2 // 7]
            expression = join(
                [
                    "($(numerator(c))/$(denominator(c)))*x^$(k-1)" for
                    (k, c) in enumerate(coefficients)
                ],
                "+",
            )
            spec = FunctionSpec(
                expression;
                input_format = format,
                output_format = format,
                domain = (-1, 1),
                absolute_error = 1 // 2^16,
            )
            push!(
                plans,
                "float-$width-$evaluation-constant-degree-$degree" => polynomial_plan(
                    spec,
                    coefficients;
                    internal_format = format,
                    evaluation,
                ),
            )
        end

        degree = 3
        input = FixedFormat((degree + 2) * width, (degree + 2) * width; signed = false)
        nodes = IR.Node[IR.Input(input), IR.BitCast(1, IR.UIntFormat(input.width))]
        refs = Int[]
        for index = 0:(degree + 1)
            push!(nodes, IR.ExtractBits(2, index * width, width))
            push!(nodes, IR.BitCast(length(nodes), format))
            push!(refs, length(nodes))
        end
        output = PRESAGe._horner!(nodes, refs[1], refs[2:end], format, evaluation)
        spec =
            FunctionSpec("0"; input_format = input, output_format = format, domain = (0, 1))
        plan = PlanArtifact(
            spec;
            program = IR.Program(nodes; output),
            settings = Dict("validation" => "variable_coefficients"),
        )
        push!(plans, "float-$width-$evaluation-variable-degree-$degree" => plan)
    end
    append!(plans, filter(resource_example_plans()) do (name, _)
        name in ("segments-128", "segments-512", "mixed-columns")
    end)
    return plans
end

function resource_validation_main(args)
    length(args) == 2 || error("Usage: resource_validation.jl MODEL.toml OUTPUT_DIRECTORY")
    model, destination = read_resource_model(args[1]), args[2]
    model.toolchain == :oneapi || error("This validation matrix requires oneAPI.")
    plans = resource_validation_plans()
    write_resource_examples(destination; model, plans, certify = false)
    for (name, plan) in plans
        get(plan.settings, "validation", "") == "variable_coefficients" && continue
        result = certify_plan(plan)
        result.status == :certified || error("$name: $(result.reason)")
        write_certificate(joinpath(destination, name, "certificate.toml"), result)
    end
    println(prepare_synthesis(joinpath(destination, "examples.toml")))
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(resource_validation_main(ARGS))
end
