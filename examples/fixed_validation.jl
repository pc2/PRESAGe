using PRESAGe

function variable_fixed_horner(width; degree = 3)
    format = FixedFormat(width, 4)
    input = FixedFormat((degree + 2) * width, (degree + 2) * width; signed = false)
    nodes = IR.Node[IR.Input(input), IR.BitCast(1, IR.UIntFormat(input.width))]
    operands = Int[]
    for index = 0:(degree + 1)
        push!(nodes, IR.ExtractBits(2, index * width, width))
        push!(nodes, IR.BitCast(length(nodes), format))
        push!(operands, length(nodes))
    end
    output = PRESAGe._horner!(nodes, first(operands), operands[2:end], format, :fma)
    spec = FunctionSpec("0"; input_format = input, output_format = format, domain = (0, 1))
    return PlanArtifact(spec; program = IR.Program(nodes; output))
end

function fixed_rom_plan(width, entries, banks)
    format = FixedFormat(width, 4)
    bits = ndigits(entries - 1; base = 2)
    input = FixedFormat(bits, bits; signed = false)
    mask = (big(1) << width) - 1
    state = big(0x123456789abcdef)
    values = BigInt[]
    for index = 1:entries
        state = (6364136223846793005state + 1442695040888963407) & ((big(1) << 128) - 1)
        push!(values, (state >> 32) & mask)
    end
    table = IR.Table(format, values; banks, unroll = true)
    program = IR.Program(
        IR.Node[IR.Input(input), IR.BitCast(1, IR.UIntFormat(bits)), IR.TableLoad(1, 2)];
        tables = [table],
    )
    spec = FunctionSpec("0"; input_format = input, output_format = format, domain = (0, 1))
    return PlanArtifact(spec; program)
end

function fixed_validation_main(args)
    length(args) == 2 || error("Usage: fixed_validation.jl MODEL.toml OUTPUT_DIRECTORY")
    model = read_resource_model(args[1])
    model.toolchain == :vitis || error("This matrix requires a Vitis target")
    extensions = fixed_extension_probes()
    probes = resource_probe_plans(;
        formats = [FixedFormat(width, 4) for width in (17, 18, 19, 24, 26, 27, 28, 48)],
        operations = (:fma,),
    )
    for (rounding, overflow, signed) in (
        (:toward_zero, :wrap, true),
        (:down, :saturate, true),
        (:nearest_even, :reject, false),
    )
        append!(
            probes,
            resource_probe_plans(;
                formats = [FixedFormat(24, 4; rounding, overflow, signed)],
                operations = (:fma,),
            ),
        )
    end
    patterns = resource_probe_plans(;
        formats = [FixedFormat(64, 4)],
        operations = (:fma,),
        constants = (4 // 13, nothing, -3 // 11),
    )
    for constant in (1 // 3, 2 // 7)
        append!(
            patterns,
            resource_probe_plans(;
                formats = [FixedFormat(64, 4)],
                operations = (:fma,),
                constants = (nothing, nothing, constant),
            ),
        )
    end
    for widths in ((32, 22, 32), (32, 19, 32), (24, 16, 20))
        append!(
            patterns,
            resource_probe_plans(;
                formats = [FixedFormat(first(widths), 4)],
                operations = (:fma,),
                operand_formats = [FixedFormat(width, 4) for width in widths],
            ),
        )
    end
    constants = Pair{String, PlanArtifact}[]
    for width in (16, 32)
        for values in (
            (4 // 13, nothing, -3 // 11),
            (nothing, nothing, 2 // 7),
            (nothing, nothing, 1 // 3),
        )
            append!(
                constants,
                resource_probe_plans(;
                    formats = [FixedFormat(width, 4)],
                    operations = (:fma,),
                    constants = values,
                ),
            )
        end
    end
    for (width, values) in
        ((20, (nothing, nothing, 2 // 7)), (24, (4 // 13, nothing, -3 // 11)))
        append!(
            constants,
            resource_probe_plans(;
                formats = [FixedFormat(width, 4)],
                operations = (:fma,),
                constants = values,
            ),
        )
    end
    holdout = resource_example_plans()
    for width in (16, 32)
        original =
            only(filter(pair -> first(pair) == "fixed-$width-separate", holdout)).second
        push!(
            holdout,
            "constant-$width-fma" => polynomial_plan(
                original.spec,
                [1 // 3, 2 // 7, -3 // 11, 4 // 13];
                evaluation = :fma,
            ),
        )
    end
    spec = first(holdout).second.spec
    precision = PolynomialPrecision(
        FixedFormat(24, 4);
        coefficient_formats = [FixedFormat(width, 4) for width in (16, 20, 24, 28)],
        stage_formats = [FixedFormat(width, 4) for width in (16, 20, 24, 28)],
    )
    push!(
        holdout,
        "mixed-stage-cubic" => polynomial_plan(
            spec,
            [1 // 3, 2 // 7, -3 // 11, 4 // 13];
            precision,
            evaluation = :fma,
        ),
    )
    composition =
        ["variable-$width-cubic" => variable_fixed_horner(width) for width in (16, 32, 64)]
    roms = [
        "rom-$width-$entries-$banks" => fixed_rom_plan(width, entries, banks) for
        (width, entries, banks) in ((17, 128, 1), (33, 513, 2), (65, 512, 4))
    ]
    for (kind, plans, certify) in (
        ("probes", probes, false),
        ("patterns", patterns, false),
        ("constants", constants, false),
        ("extensions", extensions, false),
        ("holdout", holdout, true),
        ("composition", composition, false),
        ("rom", roms, false),
    )
        directory = joinpath(args[2], kind)
        write_resource_examples(directory; model, plans, certify)
        println(prepare_synthesis(joinpath(directory, "examples.toml"); flow = :hls))
    end
    return 0
end

function fixed_extension_probes()
    plans = Pair{String, PlanArtifact}[]
    for width in (16, 32, 64, 20, 24)
        format = FixedFormat(width, 4)
        patterns =
            width == 20 ? ((nothing, nothing, 2 // 7),) :
            width == 24 ? ((4 // 13, nothing, -3 // 11),) :
            (
                (4 // 13, nothing, -3 // 11),
                (nothing, nothing, 2 // 7),
                (nothing, nothing, 1 // 3),
            )
        for constants in patterns
            append!(
                plans,
                resource_probe_plans(;
                    formats = [format],
                    operations = (:fma,),
                    constants,
                    input_formats = [format, FixedFormat(10, 3), format],
                ),
            )
        end
    end
    return plans
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(fixed_validation_main(ARGS))
end
