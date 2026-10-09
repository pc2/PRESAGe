@testset "Uniform fixed erf certificates" begin
    result = certified_erf()
    @test result.status == :certified
    @test result.total_bound <= result.plan.spec.absolute_error
    @test length(result.paths) == 4
    @test result.tail_bound < 1 // (1 << 25)
    @test first(result.paths).domain[1] == 0
    @test last(result.paths).domain[2] == 4
    for path in result.paths
        @test path.approximation[1] <= path.approximation[2]
        @test path.total ==
              path.approximation[2] +
              path.coordinate_error +
              path.arithmetic_error +
              path.output_rounding
        for bound in path.ranges
            lower, upper = PRESAGe._fixed_limits(bound.format)
            quantum = PRESAGe._pow2(-PRESAGe._fraction(bound.format))
            @test lower * quantum <= bound.range[1] <= bound.range[2] <= upper * quantum
        end
    end
    plan = result.plan
    words = verification_inputs(plan)
    @test cpu_check(plan, words) == length(words)
    with_oracle(plan.spec; backend = :mpfr) do oracle
        for word in words
            x = decode_ieee(word, IEEE32)
            x.kind in (:finite, :zero) || continue
            ref = reference(oracle, word)
            actual = decode_ieee(evaluate_bits(plan, word), IEEE32).value
            if ref.enclosure === nothing
                @test evaluate_bits(plan, word) == ref.bits
            else
                lo, hi = ref.enclosure
                error = max(
                    abs(actual - lo.significand * PRESAGe._pow2(lo.exponent)),
                    abs(actual - hi.significand * PRESAGe._pow2(hi.exponent)),
                )
                @test error <= result.total_bound
            end
        end
    end
    for (bits, expected) in (
        (0, 0),
        (0x80000000, 0x80000000),
        (0x7f800000, 0x3f800000),
        (0xff800000, 0xbf800000),
        (0xffa12345, 0x7fc00000),
    )
        @test evaluate_bits(plan, bits) == expected
    end
    @test evaluate_bits(plan, 0x3f800000) == 0x3f57bb3d
    @test evaluate_bits(plan, 0xc0800001) == 0xbf800000
    index = only(unique(n.index for n in plan.program.nodes if n isa IR.TableLoad))
    for (bits, row) in (
        (0x3f7fffff, 0),
        (0x3f800000, 1),
        (0x3fffffff, 1),
        (0x40000000, 2),
        (0x403fffff, 2),
        (0x40400000, 3),
        (0x40800000, 3),
    )
        @test interpret_trace(plan, bits).values[index] == row
    end
    io = IOBuffer()
    write_certificate(io, result)
    data = TOML.parse(String(take!(io)))
    @test data["status"] == "certified"
    @test PRESAGe._parse_rational(data["total_bound"]) == result.total_bound
    @test data["coverage"]["overflow"] == "all fixed nodes and output conversions bounded"
    @test !any(
        k -> occursin("hash", k) || occursin("version", k) && k != "schema_version",
        keys(data),
    )
    # Changed arithmetic, coefficient tables, metadata or row selection need
    # a new proof. None can inherit the supported graph's certificate.
    scaled = only(findall(n -> n isa IR.ScalePow2, plan.program.nodes))
    scale = plan.program.nodes[scaled]
    @test all(
        path -> any(
            bound ->
                bound.node == scaled &&
                    bound.range == (0, 3) &&
                    bound.format.rounding == :down,
            path.ranges,
        ),
        result.paths,
    )
    endpoint = plan.program.nodes[index].condition
    comparison = plan.program.nodes[endpoint]
    mutations = [
        (scaled, IR.ScalePow2(scale.source, scale.exponent + 1, scale.format)),
        (
            scaled,
            IR.ScalePow2(
                scale.source,
                scale.exponent,
                FixedFormat(scale.format.width, scale.format.integer_bits; signed = false),
            ),
        ),
        (endpoint, IR.Compare(:lt, comparison.a, comparison.b)),
        (index, IR.BitCast(scaled, IR.format(plan.program, index))),
    ]
    for (node, replacement) in mutations
        nodes = collect(plan.program.nodes)
        nodes[node] = replacement
        changed = PlanArtifact(
            plan.spec;
            program = IR.Program(nodes; tables = plan.program.tables),
            segments = plan.segments,
            dispatch = plan.dispatch,
            settings = plan.settings,
        )
        @test certify_erf(changed).status == :unsupported_domain
    end
    ss = [Segment(s.lower, s.upper, copy(s.coefficients)) for s in plan.segments]
    ss[1].coefficients[1] += 1 // (1 << 31)
    changed = PlanArtifact(
        plan.spec;
        program = plan.program,
        segments = ss,
        dispatch = plan.dispatch,
        settings = plan.settings,
    )
    @test certify_erf(changed).status == :unsupported_domain
    @test certify_erf(erf_candidate()).status == :unsupported_domain
    low = erf_fixed_candidate(; degree = 1, fraction_bits = 12)
    @test certify_erf(low).status == :bound_exceeds_budget
    @test certified_erf(;
        degree = 1,
        initial_fraction_bits = 12,
        max_fraction_bits = 12,
    ).status == :search_limit
    for mode in (:separate, :fma)
        wide = erf_fixed_candidate(; fraction_bits = 80, evaluation = mode)
        @test certify_erf(wide).status == :certified
        @test cpu_check(wide, verification_inputs(wide; random_count = 256)) > 256
    end
    @test_throws ArgumentError certify_erf(plan; accuracy = 0)
    @test_throws ArgumentError certify_erf(plan; precision = 32)
    @test_throws ArgumentError certified_erf(;
        initial_fraction_bits = 31,
        max_fraction_bits = 30,
    )
    println(
        "Uniform fixed erf bound: ",
        Float64(result.total_bound),
        "; tail: ",
        Float64(result.tail_bound),
    )
end
