# A dispatch-only graph exposes the selected row as a floating table value.
# Its comparisons are checked against the original representable partition;
# this fixture makes no function-approximation accuracy claim.
function float_dispatch_fixture(format, count; upper = 4)
    domain = (PRESAGe._q(0), PRESAGe._q(upper))
    width = domain[2] / count
    thresholds = [round_ieee(i * width, format; mode = :up) for i = 1:(count - 1)]
    nodes = IR.Node[IR.Input(format)]
    raw_format = IR.UIntFormat(PRESAGe._width(format))
    raw = PRESAGe._push!(nodes, IR.BitCast(1, raw_format))
    mask = PRESAGe._push!(
        nodes,
        IR.Const(raw_format, PRESAGe._wordmask(format) ⊻ PRESAGe._sign(format)),
    )
    bits = PRESAGe._push!(nodes, IR.BitOp(:bitand, raw, mask))
    magnitude = PRESAGe._push!(nodes, IR.BitCast(bits, format))
    index = PRESAGe._segment_index!(
        nodes,
        magnitude,
        format,
        thresholds;
        domain,
        float_direct = true,
    )
    output = PRESAGe._push!(nodes, IR.TableLoad(1, index))
    tables = [IR.Table(format, [round_ieee(i, format) for i = 0:(count - 1)])]
    program = IR.Program(nodes; output, tables)
    plan = PlanArtifact(FunctionSpec("x"; input_format = format); program)
    return (; plan, program, index, thresholds, width)
end

@testset "Exact floating row selection" begin
    fixtures = NamedTuple[]
    cpu_fixtures = NamedTuple[]
    for format in (IEEE16, IEEE32), count in (1, 2, 4, 16, 512)
        fixture = float_dispatch_fixture(format, count)
        endpoint = round_ieee(4, format)
        positive = if format == IEEE16 && count == 512
            BigInt.(0:endpoint)
        else
            words = BigInt[0, 1, endpoint - 1, endpoint]
            for threshold in fixture.thresholds
                append!(words, (threshold - 1, threshold, threshold + 1))
            end
            append!(words, [fld(BigInt(endpoint) * i, 257) for i = 0:257])
            unique(words)
        end
        words = unique([positive; positive .| PRESAGe._sign(format)])
        scales = findall(n -> n isa IR.ScalePow2, fixture.program.nodes)
        @test length(scales) == (count == 1 ? 0 : 1)
        @test IR.format(fixture.program, fixture.index) ==
              PRESAGe._segment_index_format(count)
        for word in words
            magnitude = abs(decode_ieee(word, format).value)
            expected = min(floor(Int, magnitude / fixture.width), count - 1)
            trace = interpret_trace(fixture.program, word)
            @test trace.values[fixture.index] == expected
            @test trace.bits == round_ieee(expected, format)
        end
        if count > 1
            scale = only(scales)
            @test fixture.program.nodes[scale].rounding == :down
            @test !haskey(interpret_trace(fixture.program, endpoint).values, scale)
            @test !haskey(
                interpret_trace(fixture.program, endpoint | PRESAGe._sign(format)).values,
                scale,
            )
            @test haskey(interpret_trace(fixture.program, endpoint - 1).values, scale)
        end
        push!(fixtures, (; program = fixture.program, words))
        count == 512 && push!(cpu_fixtures, (; fixture.plan, words))
    end
    # Upward-rounded thresholds can coincide in a coarse float format. The
    # direct mapping still skips exactly the unrepresentable comparison rows.
    format = FloatFormat(3, 2)
    fixture = float_dispatch_fixture(format, 16)
    words = 0:round_ieee(4, format)
    for word in words
        x = decode_ieee(word, format).value
        comparison_row = count(t -> word >= t, fixture.thresholds)
        @test interpret_trace(fixture.program, word).values[fixture.index] == comparison_row
        @test comparison_row == min(floor(Int, x / fixture.width), 15)
    end
    push!(fixtures, (; program = fixture.program, words))
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
    for fixture in cpu_fixtures
        for backend in (:portable, :ap_fixed, :ac_fixed)
            @test cpu_check(fixture.plan, fixture.words; backend, public_api = true) ==
                  length(fixture.words)
        end
        @test cpu_check(
            fixture.plan,
            fixture.words;
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            public_api = true,
            trace = false,
        ) == length(fixture.words)
    end
end

@testset "Floating row selection fallback" begin
    format = IEEE32
    valid = [round_ieee(i, format) for i = 1:3]
    for (thresholds, domain) in (
        (valid, (-1, 3)),
        ([round_ieee(i * 3 // 4, format) for i = 1:3], (0, 3)),
        ([round_ieee(i * 5 // 12, format; mode = :up) for i = 1:3], (0, 5 // 3)),
        (valid[1:2], (0, 4)),
        ([valid[1] + 1; valid[2:end]], (0, 4)),
    )
        nodes = IR.Node[IR.Input(format)]
        @test PRESAGe._float_segment_index!(nodes, 1, format, thresholds, domain) ===
              nothing
        @test length(nodes) == 1
        PRESAGe._segment_index!(nodes, 1, format, thresholds; domain, float_direct = true)
        @test !any(n -> n isa IR.ScalePow2, nodes)
        @test any(n -> n isa IR.Compare, nodes)
    end
    nodes = IR.Node[IR.Input(format)]
    PRESAGe._segment_index!(nodes, 1, format, valid; domain = (0, 4))
    @test !any(n -> n isa IR.ScalePow2, nodes)
end
