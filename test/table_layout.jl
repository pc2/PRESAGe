function table_layout_fixture(format, entries; banks = 1, unroll = false)
    input = FixedFormat(11, 11; signed = false)
    width = kernel_width(format)
    mask = (BigInt(1) << width) - 1
    values = [
        ((BigInt(i) * 0x9e3779b97f4a7c15) ⊻ (BigInt(i ÷ 2) << (width - 1))) & mask for
        i = 0:(entries - 1)
    ]
    nodes = IR.Node[IR.Input(input), IR.BitCast(1, IR.UIntFormat(11)), IR.TableLoad(1, 2)]
    if format isa IR.UIntFormat && width == 1
        push!(nodes, IR.Const(format, 1), IR.Compare(:eq, 3, 4))
        push!(nodes, IR.constant(17, input), IR.constant(31, input))
        push!(nodes, IR.Select(5, 6, 7))
    elseif format isa IR.UIntFormat
        push!(nodes, IR.BitCast(3, FloatFormat(3, width - 4)))
    end
    program = IR.Program(nodes; tables = [IR.Table(format, values; banks, unroll)])
    return (; program, words = 0:1023)
end

@testset "Independent memory depth and width" begin
    for (entries, width, banks, blocks) in (
        (512, 32, 1, 1),
        (513, 32, 1, 2),
        (512, 64, 1, 2),
        (512, 33, 1, 2),
        (512, 17, 2, 2),
        (513, 129, 4, 20),
    )
        fixture = table_layout_fixture(IR.UIntFormat(width), entries; banks)
        cost = table_memory_cost(fixture.program)
        @test cost.blocks == blocks
        @test cost.logical_bits == entries * width
        @test cost.allocated_bits == blocks * 512 * 32
        table = only(cost.tables)
        @test table.rows == cld(entries, banks)
        @test table.depth_blocks == cld(table.rows, 512)
        @test table.width_blocks == cld(width, 32)
    end
    p = table_layout_fixture(IR.UIntFormat(33), 512).program
    @test table_memory_cost(p; model = BlockMemoryModel(word_bits = 36)).blocks == 1
    @test table_memory_cost(p; model = BlockMemoryModel(depth = 256)).blocks == 4
    dead = IR.Program([IR.Input(IEEE32)]; tables = [IR.Table(IR.UIntFormat(32), [0])])
    @test isempty(table_memory_cost(dead).tables)
    @test table_memory_cost(dead).blocks == 0
    @test table_memory_cost(dead).allocated_bits == 0
    for value in (0, -1, true, BigInt(typemax(Int)) + 1)
        @test_throws ArgumentError BlockMemoryModel(depth = value)
        @test_throws ArgumentError BlockMemoryModel(word_bits = value)
    end
    @test_throws ArgumentError table_memory_cost(PlanArtifact(FunctionSpec("x")))
end

@testset "Direct fixed segment indexing" begin
    fixtures = NamedTuple[]
    for (format, domain, count, direct) in (
        (FixedFormat(10, 4), (-1, 1), 64, true),
        (FixedFormat(10, 4), (0, 4), 64, true),
        (FixedFormat(10, 4; signed = false), (0, 4), 64, true),
        (FixedFormat(10, 4), (-3, -1), 64, true),
        (FixedFormat(10, 4), (1 // 2, 3 // 2), 32, true),
        (FixedFormat(10, 4), (1 // 4, 5 // 4), 32, true),
        (FixedFormat(10, 4), (-1, 1 // 2), 32, false),
    )
        spec = FunctionSpec("x"; input_format = format, domain)
        geometry = PRESAGe._segmented_domains(spec, count)
        nodes = IR.Node[IR.Input(format)]
        index = PRESAGe._segment_index!(
            nodes,
            1,
            format,
            geometry.thresholds;
            domain = (first(geometry.boundaries), last(geometry.boundaries)),
        )
        selected = PRESAGe._push!(nodes, IR.TableLoad(1, index))
        output = PRESAGe._polynomial_guard!(nodes, selected, spec)
        # Distinct raw table payloads make every selected row observable.
        program = IR.Program(nodes; output, tables = [IR.Table(format, 0:(count - 1))])
        @test any(n -> n isa IR.ExtractBits, program.nodes) == direct
        for word = 0:1023
            x = decode_fixed(word, format)
            if !(domain[1] <= x <= domain[2])
                @test_throws DomainError evaluate_bits(program, word)
                continue
            end
            trace = interpret_trace(program, word)
            expected = clamp(
                floor(Int, (x - domain[1]) * count / (domain[2] - domain[1])),
                0,
                count - 1,
            )
            @test trace.values[index] == expected
        end
        push!(fixtures, (; program, words = 0:1023))
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
end

@testset "512-segment coverage and coefficient banks" begin
    input, format = FixedFormat(12, 2), FixedFormat(32, 4)
    spec = FunctionSpec("x"; input_format = input, output_format = format, domain = (-1, 1))
    geometry = PRESAGe._segment_geometry(spec, 512, format)
    precision = PolynomialPrecision(
        format;
        coefficient_formats = [FixedFormat(w, 4) for w in (17, 33, 65, 9)],
        stage_formats = fill(format, 4),
    )
    rows = [[center, 1 // 512, 0, 0] for center in geometry.centers]
    fixtures = NamedTuple[]
    for evaluation in (:separate, :fma)
        plan = segmented_polynomial_plan(spec, rows; precision, evaluation)
        result = certify_polynomial(plan)
        @test result.status == :certified
        @test result.total_bound == 0
        @test length(result.paths) == 512
        layout = PRESAGe._segmented_audit(plan)
        index = first(layout.paths).index
        @test IR.format(plan.program, index) == IR.UIntFormat(9)
        @test layout.paths[end].row == 512
        nodes = collect(plan.program.nodes)
        last_row = findfirst(nodes) do node
            node isa IR.Const && node.format == IR.UIntFormat(9) && node.bits == 511
        end
        nodes[last_row] = IR.Const(IR.UIntFormat(9), 510)
        changed = PlanArtifact(
            spec;
            program = IR.Program(
                nodes;
                output = plan.program.output,
                tables = plan.program.tables,
            ),
            segments = plan.segments,
            settings = plan.settings,
            precision,
        )
        @test certify_polynomial(changed).status == :unsupported_domain
        for word = 0:4095
            x = decode_fixed(word, input)
            if !(-1 <= x <= 1)
                @test_throws DomainError evaluate_bits(plan, word)
                continue
            end
            trace = interpret_trace(plan, word)
            row = min(floor(Int, (x + 1) * 256), 511)
            @test trace.values[index] == row
            @test trace.bits == round_fixed(x, format)
            # Bit extraction, one endpoint check and two domain guard comparisons.
            @test count(i -> plan.program.nodes[i] isa IR.Compare, keys(trace.values)) == 3
        end
        memory = table_memory_cost(plan)
        @test [t.word_bits for t in memory.tables] == [32, 17, 33, 65, 9]
        @test all(t -> t.rows == 512 && t.depth_blocks == 1, memory.tables)
        @test [t.width_blocks for t in memory.tables] == [1, 1, 2, 3, 1]
        @test memory.blocks == 8 # Includes the center table.
        @test implementation_cost(plan).table_blocks == 8
        @test implementation_cost(plan).table_block_depth == 512
        @test implementation_cost(
            plan;
            memory_model = BlockMemoryModel(word_bits = 36),
        ).table_blocks == 6
        push!(fixtures, (; program = plan.program, words = 0:4095))
        mktempdir() do directory
            path = joinpath(directory, "plan.toml")
            write_plan(path, plan)
            replay = read_plan(path)
            @test PRESAGe._program_data(replay.program) ==
                  PRESAGe._program_data(plan.program)
            @test certify_polynomial(replay).status == :certified
        end
    end
    # Exercise fresh Sollya coefficient generation at the new upper count.
    generated =
        certified_polynomial(spec; degree = 1, segments = 512, internal_format = format)
    @test generated.status == :certified
    @test generated.total_bound == 0
    @test table_memory_cost(generated.plan).blocks == 3
    @test evaluate_bits(generated.plan, round_fixed(1, input)) == round_fixed(1, format)
    for count in (1, 2, 64, 128, 256, 512)
        @test PRESAGe._segment_index_format(count).width ==
              max(1, ndigits(count - 1; base = 2))
    end
    config = PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [1],
        internal_formats = [format],
        segments = [128, 256, 512],
    )
    @test config.segments == (128, 256, 512)
    io = IOBuffer()
    write_search_config(io, config)
    @test PRESAGe._read_search_config(TOML.parse(String(take!(io)))).segments ==
          config.segments
    coarse = FunctionSpec("x"; input_format = FixedFormat(8, 4), domain = (-1, 1))
    @test_throws ArgumentError PRESAGe._segment_geometry(coarse, 512, format)
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
end

@testset "512-row erf dispatch with floating inputs" begin
    rows = [Segment(i // 128, (i + 1) // 128, [0, 0]) for i = 0:511]
    fixtures = NamedTuple[]
    for format in (IEEE16, IEEE32)
        spec = erf_spec(; format)
        layout = PRESAGe._fixed_erf_layout(rows, 16, 16, :separate; spec)
        plan = layout.plan
        @test PRESAGe._erf_audit(plan).index == layout.index
        @test IR.format(plan.program, layout.index) == IR.UIntFormat(9)
        words = BigInt[0, PRESAGe._sign(format), PRESAGe._inf(format), PRESAGe._nan(format)]
        for i = 1:511
            threshold = round_ieee(i // 128, format)
            for word in (threshold - 1, threshold, threshold + 1)
                trace = interpret_trace(plan, word)
                x = decode_ieee(word, format).value
                @test trace.values[layout.index] == min(floor(Int, 128x), 511)
                @test count(
                    j -> plan.program.nodes[j] isa IR.Compare,
                    keys(trace.values),
                ) == 2
                push!(words, word, word | PRESAGe._sign(format))
            end
        end
        for word in (round_ieee(4, format) - 1, round_ieee(4, format))
            @test interpret_trace(plan, word).values[layout.index] == 511
            push!(words, word)
        end
        @test !haskey(interpret_trace(plan, 0).values, layout.index)
        @test !haskey(interpret_trace(plan, round_ieee(5, format)).values, layout.index)
        push!(words, round_ieee(5, format))
        push!(fixtures, (; program = plan.program, words = unique(words)))
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
end

@testset "Exact-width ROM payloads and cyclic padding" begin
    fixtures = [
        table_layout_fixture(IR.UIntFormat(17), 512),
        table_layout_fixture(IR.UIntFormat(32), 513; unroll = true),
        table_layout_fixture(IR.UIntFormat(64), 512; banks = 2),
        table_layout_fixture(IR.UIntFormat(129), 513; banks = 4, unroll = true),
        table_layout_fixture(FixedFormat(33, 4), 512),
        table_layout_fixture(IEEE16, 512),
        table_layout_fixture(IR.UIntFormat(1), 513; banks = 2),
    ]
    # The same ROM emitter serves the complete binary16 lookup backend.
    push!(
        fixtures,
        (;
            program = IR.Program(
                [IR.Input(IEEE16), IR.BitCast(1, IR.UIntFormat(16)), IR.TableLoad(1, 2)];
                tables = [IR.Table(IEEE16, 0:65535; banks = 4)],
            ),
            words = 0:65535,
        ),
    )
    for backend in (:ap_fixed, :ac_fixed)
        for fixture in fixtures
            table = only(fixture.program.tables)
            width = kernel_width(table.format)
            text = sprint(io -> emit_kernel(io, fixture.program; backend))
            @test occursin(
                "static const UInt$width table[$(table.banks)][$(cld(length(table.values), table.banks))]",
                text,
            )
            @test !occursin("static const unsigned long long table", text)
            @test !occursin("dim=3", text)
        end
        kernel_trace_check(fixtures, backend)
    end
end
