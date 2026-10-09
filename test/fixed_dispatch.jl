function uint_add_fixture(width)
    input = FixedFormat(width, width; signed = false)
    output = FixedFormat(8, 4)
    word = IR.UIntFormat(width)
    mask = BigInt(IR.mask(word))
    nodes = IR.Node[
        IR.Input(input),
        IR.BitCast(1, word),
        IR.Const(word, mod(mask - 2, mask + 1)),
        IR.UIntAdd(2, 3),
        IR.Const(word, 0),
        IR.Compare(:eq, 4, 5),
        IR.constant(1, output),
        IR.constant(-1, output),
        IR.Select(6, 7, 8),
    ]
    program = IR.Program(nodes)
    words = if width <= 9
        collect(0:Int(mask))
    else
        unique(BigInt[0, 1, 2, 3, mask - 2, mask - 1, mask, mask ÷ 2, mask ÷ 2 + 1])
    end
    plan = PlanArtifact(
        FunctionSpec("x"; input_format = input, output_format = output);
        program,
    )
    return (; plan, program, words)
end

@testset "Modular unsigned addition semantics and replay" begin
    fixtures = uint_add_fixture.((1, 5, 9, 64, 65, 129))
    for fixture in fixtures
        p = fixture.program
        mask = BigInt(IR.mask(IR.format(p, 4)))
        offset = BigInt(p.nodes[3].bits)
        for word in fixture.words
            trace = interpret_trace(p, word)
            expected = mod(BigInt(word) + offset, mask + 1)
            @test trace.values[4] == expected
            @test trace.bits == round_fixed(iszero(expected) ? 1 : -1, IR.format(p))
        end
        io = IOBuffer()
        write_plan(io, fixture.plan)
        data = TOML.parse(String(take!(io)))
        @test data["schema_version"] == 13
        @test PRESAGe._program_data(PRESAGe._read_plan(data).program) ==
              PRESAGe._program_data(p)
        data["schema_version"] = 12
        @test_throws ArgumentError PRESAGe._read_plan(data)
    end
    for (a, b) in (
        (IR.Const(IR.UIntFormat(5), 0), IR.Const(IR.UIntFormat(6), 0)),
        (IR.Const(IR.UIntFormat(5), 0), IR.constant(0, IEEE32)),
        (IR.Const(Bool, 0), IR.Const(Bool, 0)),
    )
        @test_throws ArgumentError IR.Program(
            [IR.Input(IEEE32), a, b, IR.UIntAdd(2, 3)];
            output = 1,
        )
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
    for backend in (:portable, :ap_fixed, :ac_fixed), fixture in fixtures
        cpu_check(fixture.plan, fixture.words; backend, public_api = true)
    end
    # Exercise AC floating CPU emission even when every word fits a native integer.
    cpu_check(first(fixtures).plan, first(fixtures).words; float_backend = :ac_std_float)
end

function fixed_dispatch_fixture(format, domain, count)
    spec = FunctionSpec("x"; input_format = format, domain)
    geometry = PRESAGe._segmented_domains(spec, count)
    nodes = IR.Node[IR.Input(format)]
    index = PRESAGe._segment_index!(nodes, 1, format, geometry.thresholds; domain)
    selected = PRESAGe._push!(nodes, IR.TableLoad(1, index))
    output = PRESAGe._polynomial_guard!(nodes, selected, spec)
    program = IR.Program(nodes; output, tables = [IR.Table(format, 0:(count - 1))])
    return (; program, index)
end

@testset "Every aligned fixed lower-row offset" begin
    fixtures = NamedTuple[]
    for signed in (true, false), negative in (true, false)
        !signed && negative && continue
        format = FixedFormat(10, 4; signed)
        for phase = 0:31
            lower = (phase - (negative ? 32 : 0)) // 32
            domain = (lower, lower + 1)
            fixture = fixed_dispatch_fixture(format, domain, 32)
            p, index = fixture.program, fixture.index
            @test count(n -> n isa IR.ExtractBits, p.nodes) == 1
            @test count(n -> n isa IR.UIntAdd, p.nodes) == (phase ∉ (0, 16))
            @test count(n -> n isa IR.Compare, p.nodes) == 3
            for word = 0:1023
                x = decode_fixed(word, format)
                if !(domain[1] <= x <= domain[2])
                    @test_throws DomainError evaluate_bits(p, word)
                else
                    trace = interpret_trace(p, word)
                    expected = min(floor(Int, (x - lower) * 32), 31)
                    @test trace.values[index] == expected
                    @test trace.bits == expected
                end
            end
            # Representative negative, positive, signed and unsigned wrap points.
            phase in (1, 8, 31) && push!(fixtures, (; program = p, words = 0:1023))
        end
    end
    # All supported index widths, including one-bit rows and the 512-row limit.
    for row_count in (2, 4, 8, 16, 64, 128, 256, 512)
        format = FixedFormat(12, 2)
        lower = (1 - row_count ÷ 2) // row_count
        domain = (lower, lower + 1)
        fixture = fixed_dispatch_fixture(format, domain, row_count)
        @test count(n -> n isa IR.ExtractBits, fixture.program.nodes) == 1
        @test IR.format(fixture.program, fixture.index) ==
              PRESAGe._segment_index_format(row_count)
        for word = 0:4095
            x = decode_fixed(word, format)
            if !(domain[1] <= x <= domain[2])
                @test_throws DomainError evaluate_bits(fixture.program, word)
            else
                trace = interpret_trace(fixture.program, word)
                @test trace.values[fixture.index] ==
                      min(floor(Int, (x - lower) * row_count), row_count - 1)
            end
        end
        push!(fixtures, (; program = fixture.program, words = 0:4095))
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
end

@testset "Wide fixed dispatch and incompatible partitions" begin
    fixtures = NamedTuple[]
    for width in (65, 129), signed in (true, false)
        format = FixedFormat(width, 4; signed)
        domain = signed ? (-3 // 4, 1 // 4) : (1 // 4, 5 // 4)
        fixture = fixed_dispatch_fixture(format, domain, 32)
        @test count(n -> n isa IR.UIntAdd, fixture.program.nodes) == 1
        words = BigInt[0, PRESAGe._fixed_mask(format)]
        for row = 0:32
            word = round_fixed(domain[1] + row // 32, format)
            append!(words, [word - 1, word, word + 1])
        end
        filter!(word -> 0 <= word <= PRESAGe._fixed_mask(format), words)
        unique!(words)
        for word in words
            x = decode_fixed(word, format)
            if !(domain[1] <= x <= domain[2])
                @test_throws DomainError evaluate_bits(fixture.program, word)
            else
                trace = interpret_trace(fixture.program, word)
                @test trace.values[fixture.index] ==
                      min(floor(Int, (x - domain[1]) * 32), 31)
            end
        end
        push!(fixtures, (; program = fixture.program, words))
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = format, domain);
            program = fixture.program,
        )
        accepted =
            filter(word -> domain[1] <= decode_fixed(word, format) <= domain[2], words)
        for backend in (:portable, :ap_fixed, :ac_fixed)
            cpu_check(plan, accepted; backend, public_api = true)
        end
    end
    for domain in ((1 // 64, 65 // 64), (-1, 1 // 2))
        format = FixedFormat(10, 4)
        fixture = fixed_dispatch_fixture(format, domain, 32)
        @test !any(n -> n isa IR.ExtractBits, fixture.program.nodes)
        for word = 0:1023
            x = decode_fixed(word, format)
            if domain[1] <= x <= domain[2]
                trace = interpret_trace(fixture.program, word)
                @test trace.values[fixture.index] ==
                      min(floor(Int, (x - domain[1]) * 32 / (domain[2] - domain[1])), 31)
            else
                @test_throws DomainError evaluate_bits(fixture.program, word)
            end
        end
        push!(fixtures, (; program = fixture.program, words = 0:1023))
    end
    format = FixedFormat(10, 4)
    geometry = PRESAGe._segmented_domains(
        FunctionSpec("x"; input_format = format, domain = (1 // 4, 5 // 4)),
        32,
    )
    thresholds = copy(geometry.thresholds)
    thresholds[16] += 1
    nodes = IR.Node[IR.Input(format)]
    @test PRESAGe._fixed_segment_index!(nodes, 1, format, thresholds, (1 // 4, 5 // 4)) ===
          nothing
    @test length(nodes) == 1
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
end

@testset "Fixed integer offsets in certified polynomial evaluators" begin
    fixtures = NamedTuple[]
    internal = FixedFormat(32, 6)
    precision = PolynomialPrecision(
        internal;
        coefficient_formats = [FixedFormat(w, 4) for w in (17, 33, 65, 9)],
        stage_formats = fill(internal, 4),
    )
    for (input, domain) in (
            (FixedFormat(10, 4), (1 // 4, 5 // 4)),
            (FixedFormat(10, 4), (-5 // 4, -1 // 4)),
            (FixedFormat(10, 4), (-3 // 4, 1 // 4)),
            (FixedFormat(10, 4; signed = false), (1 // 4, 5 // 4)),
        ),
        evaluation in (:separate, :fma),
        individual in (false, true)

        spec = FunctionSpec("x"; input_format = input, output_format = internal, domain)
        geometry = PRESAGe._segment_geometry(spec, 32, internal)
        rows = [
            [center, PRESAGe._pow2(-geometry.exponent), 0, 0] for center in geometry.centers
        ]
        plan =
            individual ? segmented_polynomial_plan(spec, rows; precision, evaluation) :
            segmented_polynomial_plan(spec, rows; internal_format = internal, evaluation)
        result = certify_polynomial(plan)
        @test result.status == :certified
        @test result.total_bound == 0
        index = first(PRESAGe._segmented_audit(plan).paths).index
        @test count(n -> n isa IR.UIntAdd, plan.program.nodes) == 1
        @test implementation_cost(plan).additions ==
              count(n -> n isa Union{IR.Add, IR.UIntAdd}, plan.program.nodes)
        cost = precision_cost(plan)
        @test cost.arithmetic_result_bits == sum(
            PRESAGe._cost_width(IR.format(plan.program, i)) for
            (i, n) in enumerate(plan.program.nodes) if
            n isa Union{IR.Add, IR.UIntAdd, IR.Mul, IR.FMA}
        )
        accepted = Int[]
        for word = 0:1023
            x = decode_fixed(word, input)
            if !(domain[1] <= x <= domain[2])
                @test_throws DomainError evaluate_bits(plan, word)
            else
                push!(accepted, word)
                trace = interpret_trace(plan, word)
                @test trace.values[index] == min(floor(Int, (x - domain[1]) * 32), 31)
                @test trace.bits == round_fixed(x, internal)
            end
        end
        io = IOBuffer()
        write_plan(io, plan)
        replay = read_plan(IOBuffer(String(take!(io))))
        @test certify_polynomial(replay).status == :certified
        @test PRESAGe._program_data(replay.program) == PRESAGe._program_data(plan.program)
        nodes = collect(plan.program.nodes)
        add = only(n for n in nodes if n isa IR.UIntAdd)
        offset = nodes[add.b]
        nodes[add.b] = IR.Const(offset.format, (offset.bits + 1) & IR.mask(offset.format))
        changed = PlanArtifact(
            spec;
            program = IR.Program(
                nodes;
                output = plan.program.output,
                tables = plan.program.tables,
            ),
            segments = plan.segments,
            settings = plan.settings,
            precision = plan.precision,
        )
        @test certify_polynomial(changed).status == :unsupported_domain
        push!(fixtures, (; program = plan.program, words = 0:1023))
        # C++ CPU public APIs cover both Horner modes and both precision layouts.
        domain == (1 // 4, 5 // 4) &&
            input.signed &&
            foreach(
                backend -> cpu_check(replay, accepted; backend, public_api = true),
                (:portable, :ap_fixed, :ac_fixed),
            )
    end
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
    spec = FunctionSpec(
        "x/2";
        input_format = FixedFormat(10, 4),
        output_format = internal,
        domain = (1 // 4, 5 // 4),
    )
    generated =
        certified_polynomial(spec; degree = 1, segments = 32, internal_format = internal)
    @test generated.status == :certified
    @test generated.total_bound == 0
    @test count(n -> n isa IR.UIntAdd, generated.plan.program.nodes) == 1
    for word = round_fixed(1 // 4, spec.input_format):round_fixed(5 // 4, spec.input_format)
        @test evaluate_bits(generated.plan, word) ==
              round_fixed(decode_fixed(word, spec.input_format) / 2, internal)
    end
end
