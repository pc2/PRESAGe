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
    index = PRESAGe._segment_index!(nodes, magnitude, format, thresholds; domain)
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
        PRESAGe._segment_index!(nodes, 1, format, thresholds; domain)
        @test !any(n -> n isa IR.ScalePow2, nodes)
        @test any(n -> n isa IR.Compare, nodes)
    end
    nodes = IR.Node[IR.Input(format)]
    PRESAGe._segment_index!(nodes, 1, format, valid; domain = (0, 4))
    @test any(n -> n isa IR.ScalePow2, nodes)
    nodes = IR.Node[IR.Input(format)]
    PRESAGe._segment_index!(nodes, 1, format, valid)
    @test !any(n -> n isa IR.ScalePow2, nodes)
end

function aligned_float_dispatch_fixture(format, count, domain)
    spec = FunctionSpec("x"; input_format = format, domain)
    domain = PRESAGe._polynomial_domain(spec)
    width = (domain[2] - domain[1]) / count
    thresholds =
        [round_ieee(domain[1] + i * width, format; mode = :up) for i = 1:(count - 1)]
    nodes = IR.Node[IR.Input(format)]
    dispatch_ranges = Dict{Int, PRESAGe._Interval}()
    index = PRESAGe._segment_index!(nodes, 1, format, thresholds; domain, dispatch_ranges)
    table = IR.Table(format, [round_ieee(i, format) for i = 0:(count - 1)])
    result = PRESAGe._push!(nodes, IR.TableLoad(1, index))
    output = PRESAGe._polynomial_guard!(nodes, result, spec)
    program = IR.Program(nodes; output, tables = [table])
    plan = PlanArtifact(spec; program)
    return (; plan, program, index, domain, width, thresholds, dispatch_ranges)
end

function float_dispatch_neighbors(format, boundaries)
    words = BigInt[
        0,
        1,
        PRESAGe._sign(format),
        PRESAGe._sign(format) | 1,
        PRESAGe._nan(format),
        PRESAGe._inf(format),
        PRESAGe._sign(format) | PRESAGe._inf(format),
    ]
    for boundary in boundaries
        word = BigInt(round_ieee(boundary, format))
        append!(words, (word, word | PRESAGe._sign(format)))
        word > 0 && push!(words, word - 1)
        word < PRESAGe._wordmask(format) && push!(words, word + 1)
    end
    return unique(words)
end

@testset "Aligned floating intervals and exact integer offsets" begin
    fixtures = NamedTuple[]
    for format in (IEEE16, IEEE32, FloatFormat(8, 70)),
        domain in ((-1, 1), (3, 5), (-5, -3), (-2, 0), (1 // 128, 513 // 128))

        count = format == FloatFormat(8, 70) ? 4 : 512
        if format == FloatFormat(8, 70) && domain == (1 // 128, 513 // 128)
            domain = (1, 5)
        end
        fixture = aligned_float_dispatch_fixture(format, count, domain)
        boundaries = [fixture.domain[1] + i * fixture.width for i = 0:count]
        words =
            format == IEEE16 && domain == (-1, 1) ? BigInt.(0:65535) :
            float_dispatch_neighbors(format, boundaries)
        @test length(fixture.dispatch_ranges) == 4
        @test !any(n -> n isa IR.Add && n.format isa FloatFormat, fixture.program.nodes)
        scale = only(
            i for i in keys(fixture.dispatch_ranges) if
            fixture.program.nodes[i] isa IR.ScalePow2
        )
        for word in words
            x = decode_ieee(word, format).value
            trace = interpret_trace(fixture.program, word)
            if x === nothing || !(fixture.domain[1] <= x <= fixture.domain[2])
                @test trace.bits == PRESAGe._nan(format)
                @test !haskey(trace.values, fixture.index)
                @test !haskey(trace.values, scale)
                continue
            end
            expected = min(floor(Int, (x - fixture.domain[1]) / fixture.width), count - 1)
            @test trace.values[fixture.index] == expected
            @test trace.bits == round_ieee(expected, format)
            @test all(fixture.dispatch_ranges) do (node, range)
                !haskey(trace.values, node) ||
                    range[1] <=
                    decode_fixed(
                        trace.values[node].bits,
                        IR.format(fixture.program, node),
                    ) <=
                    range[2]
            end
            x == fixture.domain[2] && @test !haskey(trace.values, scale)
        end
        push!(fixtures, (; program = fixture.program, words))
        if format == IEEE32 && domain == (-1, 1)
            for backend in (:portable, :ap_fixed, :ac_fixed)
                @test cpu_check(fixture.plan, words; backend, public_api = true) ==
                      length(words)
            end
            @test cpu_check(
                fixture.plan,
                words;
                backend = :ac_fixed,
                float_backend = :ac_std_float,
                public_api = true,
            ) == length(words)
        end
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
    # A dyadic segment width alone is insufficient: the lower endpoint also
    # needs an integer row offset. Unsupported offsets retain comparisons.
    format = IEEE32
    nodes = IR.Node[IR.Input(format)]
    domain = (1 // 512, 513 // 512)
    thresholds = [round_ieee(domain[1] + i // 4, format) for i = 1:3]
    PRESAGe._segment_index!(nodes, 1, format, thresholds; domain)
    @test !any(n -> n isa IR.ScalePow2, nodes)
end

function direct_segmented_linear_plan(
    format,
    domain;
    count = 4,
    precision = nothing,
    internal = FixedFormat(32, 6),
    evaluation = :separate,
)
    spec = FunctionSpec(
        "x";
        input_format = format,
        domain,
        absolute_error = PRESAGe._pow2(1 - format.fraction_bits),
    )
    geometry = PRESAGe._segment_geometry(spec, count, internal)
    rows = [[center, PRESAGe._pow2(-geometry.exponent)] for center in geometry.centers]
    return segmented_polynomial_plan(
        spec,
        rows;
        precision,
        internal_format = internal,
        evaluation,
    )
end

@testset "General direct dispatch certificates and variable precision" begin
    fixtures = NamedTuple[]
    for internal in (FixedFormat(32, 6), FloatFormat(8, 27)),
        individual in (false, true),
        evaluation in (:separate, :fma)

        precision =
            individual ?
            PolynomialPrecision(
                internal;
                coefficient_formats = internal isa FixedFormat ?
                                      [FixedFormat(24, 6), FixedFormat(28, 6)] :
                                      [FloatFormat(8, 23), FloatFormat(8, 25)],
                stage_formats = internal isa FixedFormat ?
                                [FixedFormat(32, 6), FixedFormat(30, 6)] :
                                [FloatFormat(8, 27), FloatFormat(8, 26)],
            ) : nothing
        plan = direct_segmented_linear_plan(
            FloatFormat(4, 5),
            (-1, 1);
            internal,
            precision,
            evaluation,
        )
        result = certify_plan(plan)
        @test result.status == :certified
        layout = PRESAGe._segmented_audit(plan)
        @test length(layout.dispatch_ranges) == 4
        for path in result.paths
            bounds = Dict(b.node => b.range for b in path.ranges)
            @test all(layout.dispatch_ranges) do (node, range)
                bounds[node] == range
            end
        end
        for word = 0:1023
            x = decode_ieee(word, plan.spec.input_format).value
            trace = interpret_trace(plan, word)
            if x === nothing || !(-1 <= x <= 1)
                @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                continue
            end
            row = min(floor(Int, (x + 1) * 2), 3)
            @test trace.values[first(layout.paths).index] == row
            @test abs(decode_ieee(trace.bits, plan.spec.output_format).value - x) <=
                  result.total_bound
            bounds = Dict(b.node => b.range for b in result.paths[row + 1].ranges)
            @test all(trace.values) do (node, value)
                f = IR.format(plan.program, node)
                f isa Union{FixedFormat, FloatFormat} || return true
                q = PRESAGe._polynomial_value(value.bits, f)
                bounds[node][1] <= q <= bounds[node][2]
            end
        end
        restored = read_plan(IOBuffer(sprint(io -> write_plan(io, plan))))
        @test PRESAGe._certificate_data(certify_plan(restored)) ==
              PRESAGe._certificate_data(result)
        @test cpu_check(plan, 0:1023; backend = :portable) == 1024
        push!(fixtures, (; program = plan.program, words = 0:1023, internal))
        # Every row-selection operation is audited, including exact offset
        # constants, integer arithmetic and the inclusive-endpoint branch.
        for (node, operation) in enumerate(plan.program.nodes)
            replacement = if haskey(layout.dispatch_ranges, node)
                operation isa IR.ScalePow2 ?
                IR.ScalePow2(operation.source, operation.exponent + 1, operation.format) :
                operation isa IR.Const ?
                IR.Const(operation.format, operation.bits ⊻ 1) :
                operation isa IR.Add ?
                IR.Add(operation.b, operation.a, operation.format) :
                operation isa IR.Quantize ?
                IR.Quantize(
                    operation.source,
                    FixedFormat(
                        operation.format.width,
                        operation.format.integer_bits;
                        signed = false,
                        overflow = :wrap,
                    ),
                ) : nothing
            elseif node == first(layout.paths).index
                operation isa IR.Select ?
                IR.Select(operation.condition, operation.no, operation.yes) : nothing
            else
                nothing
            end
            replacement === nothing && continue
            nodes = collect(plan.program.nodes)
            nodes[node] = replacement
            changed = PlanArtifact(
                plan.spec;
                program = IR.Program(
                    nodes;
                    output = plan.program.output,
                    tables = plan.program.tables,
                ),
                segments = plan.segments,
                precision = plan.precision,
                settings = plan.settings,
            )
            @test certify_plan(changed).status == :unsupported_domain
        end
    end
    for backend in (:ap_fixed, :ac_fixed)
        supported =
            backend == :ap_fixed ?
            filter(fixture -> fixture.internal isa FixedFormat, fixtures) : fixtures
        kernel_trace_check(supported, backend)
    end
    # Polynomial rounding policies remain restricted after dispatch is enabled.
    plan = direct_segmented_linear_plan(
        IEEE32,
        (-1, 1);
        internal = FixedFormat(32, 6; rounding = :down),
    )
    @test certify_plan(plan).status == :unsupported_domain
end

@testset "512-row general polynomial exhaustive binary16" begin
    plan = direct_segmented_linear_plan(
        IEEE16,
        (-1, 1);
        count = 512,
        internal = FixedFormat(30, 6),
    )
    result = certify_plan(plan)
    @test result.status == :certified
    @test length(result.paths) == 512
    layout = PRESAGe._segmented_audit(plan)
    index = first(layout.paths).index
    @test IR.format(plan.program, index) == IR.UIntFormat(9)
    for word = 0:65535
        x = decode_ieee(word, IEEE16).value
        trace = interpret_trace(plan, word)
        if x === nothing || !(-1 <= x <= 1)
            @test trace.bits == PRESAGe._nan(IEEE16)
            @test !haskey(trace.values, index)
            continue
        end
        row = min(floor(Int, (x + 1) * 256), 511)
        @test trace.values[index] == row
        @test abs(decode_ieee(trace.bits, IEEE16).value - x) <= result.total_bound
        bounds = Dict(b.node => b.range for b in result.paths[row + 1].ranges)
        @test all(trace.values) do (node, value)
            format = IR.format(plan.program, node)
            format isa Union{FloatFormat, FixedFormat} || return true
            q = PRESAGe._polynomial_value(value.bits, format)
            bounds[node][1] <= q <= bounds[node][2]
        end
    end
    for backend in (:portable, :ap_fixed, :ac_fixed)
        @test cpu_check(plan, 0:65535; backend, public_api = true) == 65536
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check([(; program = plan.program, words = 0:65535)], backend)
    end
end

@testset "Fresh aligned generation and precision rebuilding" begin
    spec = FunctionSpec(
        "x/2";
        input_format = IEEE32,
        domain = (-5, -3),
        absolute_error = 1 // (1 << 18),
    )
    precision = PolynomialPrecision(
        FixedFormat(32, 6);
        coefficient_formats = [FixedFormat(24, 4), FixedFormat(22, 3)],
        stage_formats = [FixedFormat(28, 6), FixedFormat(26, 5)],
    )
    result = certified_polynomial(spec; degree = 1, segments = 4, precision)
    @test result.status == :certified
    reduced = PolynomialPrecision(
        precision.coordinate_format;
        coefficient_formats = precision.coefficient_formats,
        stage_formats = [FixedFormat(26, 6), FixedFormat(24, 5)],
    )
    rebuilt = PRESAGe._reformat_polynomial(result.plan, reduced)
    proof = certify_plan(rebuilt)
    @test proof.status == :certified
    fixtures = NamedTuple[]
    for certificate in (result, proof)
        plan = certificate.plan
        layout = PRESAGe._precision_audit(plan)
        @test length(layout.dispatch_ranges) == 4
        words = float_dispatch_neighbors(IEEE32, layout.geometry.boundaries)
        for word in words
            x = decode_ieee(word, IEEE32).value
            if x !== nothing && -5 <= x <= -3
                actual = decode_ieee(evaluate_bits(plan, word), IEEE32).value
                @test abs(actual - x / 2) <= certificate.total_bound
            end
        end
        @test cpu_check(plan, words; backend = :ac_fixed, public_api = true) ==
              length(words)
        push!(fixtures, (; program = plan.program, words))
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
end
