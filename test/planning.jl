# Check the mathematical function and the certified ranges, including lazy guards.
function check_generated_polynomial(result, words)
    @test result.status == :certified
    plan, path = result.plan, only(result.paths)
    bounds = Dict(bound.node => bound.range for bound in path.ranges)
    accepted = BigInt[]
    backend = plan.spec.expression in ("erf(x)", "exp(x)") ? :mpfr : :sollya
    with_oracle(plan.spec; backend) do oracle
        for word in words
            input = PRESAGe._decode_input(word, plan.spec.input_format)
            if input.value === nothing || !(path.domain[1] <= input.value <= path.domain[2])
                if plan.spec.output_format isa FixedFormat
                    @test_throws DomainError evaluate_bits(plan, word)
                else
                    trace = interpret_trace(plan, word)
                    @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                    @test !any(keys(trace.values)) do node
                        plan.program.nodes[node] isa Union{IR.Mul, IR.Add, IR.FMA}
                    end
                end
                continue
            end
            push!(accepted, word)
            trace = interpret_trace(plan, word)
            actual = PRESAGe._decode_input(trace.bits, plan.spec.output_format).value
            ref = reference(oracle, word)
            @test ref.status in (:resolved, :special)
            lower, upper = if ref.enclosure !== nothing
                map(ref.enclosure) do endpoint
                    endpoint.significand * PRESAGe._pow2(endpoint.exponent)
                end
            else
                @test input.value == 0
                value = PRESAGe._q(plan.spec.expression == "exp(x)" ? 1 : 0)
                value, value
            end
            @test max(abs(actual - lower), abs(actual - upper)) <= result.total_bound
            @test all(trace.values) do (node, value)
                format = IR.format(plan.program, node)
                format isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(value.bits, format).value
                haskey(bounds, node) &&
                    q !== nothing &&
                    bounds[node][1] <= q <= bounds[node][2]
            end
        end
    end
    return accepted
end

@testset "Generated bounded polynomial certificates" begin
    fixed_backends = Symbol[:portable]
    for backend in (:ac_fixed, :ap_fixed)
        try
            vendor_include(backend)
            push!(fixed_backends, backend)
        catch
            get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" && rethrow()
        end
    end
    for mode in (:separate, :fma)
        for (internal_format, output_format, degree) in
            ((FixedFormat(32, 6), FixedFormat(24, 4), 9), (FloatFormat(8, 27), IEEE32, 13))
            for expression in ("erf(x)", "exp(x)", "exp(x)+0.1*x")
                spec = FunctionSpec(
                    expression;
                    input_format = FixedFormat(9, 3),
                    output_format,
                    domain = (-1, 1),
                    absolute_error = 1 // (1 << 18),
                )
                result =
                    certified_polynomial(spec; degree, internal_format, evaluation = mode)
                @test result.total_bound <= spec.absolute_error
                @test only(result.paths).domain == (-1, 1)
                @test result.plan.settings["degree"] == string(degree)
                @test result.plan.settings["generation_precision"] == "256"
                @test result.settings["precision"] == "256"
                coefficients = PRESAGe._polynomial_audit(result.plan).coefficients
                @test length(coefficients) <= degree + 1
                words = check_generated_polynomial(result, 0:511)
                @test length(words) == 129
                if expression == "exp(x)+0.1*x"
                    backends =
                        internal_format isa FixedFormat ? fixed_backends : [:portable]
                    for backend in backends
                        @test cpu_check(result.plan, words; backend) == length(words)
                    end
                end
                # The selected artifact is sufficient for replay and fresh proof.
                io = IOBuffer()
                write_plan(io, result.plan)
                seekstart(io)
                restored = read_plan(io)
                @test PRESAGe._program_data(restored.program) ==
                      PRESAGe._program_data(result.plan.program)
                proof = certify_plan(restored)
                @test proof.status == :certified
                @test proof.total_bound == result.total_bound
            end
        end
    end
    # Small floating input words cover signed zeros, nonfinites and inward guards.
    for (output_format, internal_format) in
        ((FixedFormat(24, 4), FixedFormat(32, 6)), (IEEE16, FloatFormat(8, 14)))
        spec = FunctionSpec(
            "exp(x)+0.1*x";
            input_format = FloatFormat(3, 4),
            output_format,
            domain = (-1, 1),
            absolute_error = 1 // (1 << 9),
        )
        result = certified_polynomial(spec; degree = 9, internal_format, evaluation = :fma)
        words = check_generated_polynomial(result, 0:255)
        @test cpu_check(result.plan, words) == length(words)
    end
end

@testset "Bounded generation contracts and numerical failures" begin
    spec = FunctionSpec(
        "x/2+0.25";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(12, 4),
        domain = (-1, 1),
    )
    for mode in (:separate, :fma)
        result = certified_polynomial(
            spec;
            degree = 1,
            internal_format = FixedFormat(24, 6),
            evaluation = mode,
            generation_precision = 128,
            proof_precision = 256,
            accuracy = 1 // 4096,
            max_refinements = 0,
        )
        @test result.status == :certified
        @test result.total_bound == 0
        @test result.plan.settings["generation_precision"] == "128"
        @test result.settings["precision"] == "256"
        @test result.settings["norm_accuracy"] == "1/4096"
        for value in (-1, -1 // 2, 0, 1 // 2, 1)
            word = round_fixed(value, spec.input_format)
            @test decode_fixed(evaluate_bits(result.plan, word), spec.output_format) ==
                  value / 2 + 1 // 4
        end
    end
    for expression in ("0", "1", "0.25", "1/3")
        constant =
            FunctionSpec(expression; domain = (-1, 1), absolute_error = 1 // (1 << 20))
        result =
            certified_polynomial(constant; degree = 0, internal_format = FixedFormat(32, 6))
        @test result.status == :certified
        @test isempty(PRESAGe._polynomial_audit(result.plan).stages)
        @test expression == "1/3" ? result.total_bound > 0 : result.total_bound == 0
    end
    # Rationalized decimal/scientific literals must generate the same polynomial.
    results = map(("0.1*x+1e-4", "(1/10)*x+1/10000")) do expression
        contract = FunctionSpec(
            expression;
            input_format = FixedFormat(9, 3),
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
            absolute_error = 1 // (1 << 18),
        )
        certified_polynomial(contract; degree = 1, internal_format = FixedFormat(32, 6))
    end
    @test all(result -> result.status == :certified, results)
    @test PRESAGe._program_data(results[1].plan.program) ==
          PRESAGe._program_data(results[2].plan.program)
    @test results[1].total_bound == results[2].total_bound
    @test results[1].plan.spec.expression == "0.1*x+1e-4"
    @test results[2].plan.spec.expression == "(1/10)*x+1/10000"

    # Singletons, including intervals reduced to one input word, avoid Remez.
    for (input_format, domain, degree) in
        ((IEEE32, (1, 1), 0), (FixedFormat(8, 3), (63 // 64, 65 // 64), 32))
        contract = FunctionSpec(
            "exp(x)";
            input_format,
            output_format = IEEE32,
            domain,
            absolute_error = 1 // (1 << 21),
        )
        result =
            certified_polynomial(contract; degree, internal_format = FloatFormat(8, 27))
        @test result.status == :certified
        @test only(result.paths).domain == (1, 1)
        @test isempty(PRESAGe._polynomial_audit(result.plan).stages)
        check_generated_polynomial(result, [PRESAGe._polynomial_round(1, input_format)])
    end
    # Clipping to the finite input range is shared by generation and the guard.
    clipped = FunctionSpec("x"; input_format = FloatFormat(3, 4), domain = (-100, 100))
    result = certified_polynomial(clipped; degree = 1)
    @test result.status == :certified && result.total_bound == 0
    @test only(result.paths).domain == (-31 // 2, 31 // 2)
    @test evaluate_bits(result.plan, PRESAGe._inf(clipped.input_format) - 1) ==
          round_ieee(31 // 2, clipped.output_format)
    for word = 0:255
        input = decode_ieee(word, clipped.input_format)
        expected =
            input.value === nothing ? PRESAGe._nan(clipped.output_format) :
            round_ieee(input.value, clipped.output_format)
        @test evaluate_bits(result.plan, word) == expected
    end
    @test cpu_check(result.plan, 0:255) == 256
    # A compact bounded domain does not require materializing extreme exponents.
    extreme = FunctionSpec("x"; input_format = FloatFormat(62, 8), domain = (-1, 1))
    result = certified_polynomial(extreme; degree = 1)
    @test result.status == :certified && result.total_bound == 0
    @test only(result.paths).domain == (-1, 1)
    # Preserve the signed-zero endpoint word in the canonical guard.
    zero_domain =
        FunctionSpec("0"; input_format = FloatFormat(3, 4), domain = (-1 // 128, 1 // 128))
    result = certified_polynomial(zero_domain; degree = 0)
    @test result.status == :certified
    @test only(result.paths).domain == (0, 0)
    @test any(result.plan.program.nodes) do node
        node isa IR.Const &&
            node.format == zero_domain.input_format &&
            node.bits == PRESAGe._sign(zero_domain.input_format)
    end

    for degree in (-1, 33, big(typemax(Int)) + 1)
        @test_throws ArgumentError certified_polynomial(spec; degree)
    end
    @test_throws ArgumentError certified_polynomial(FunctionSpec("x"); degree = 1)
    @test_throws ArgumentError certified_polynomial(spec; degree = 1, evaluation = :other)
    @test_throws ArgumentError certified_polynomial(
        spec;
        degree = 1,
        internal_format = FloatFormat(2, big(typemax(Cint)) + 1),
    )
    for precision in (11, big(typemax(Cint)) + 1)
        @test_throws ArgumentError certified_polynomial(
            spec;
            degree = 1,
            generation_precision = precision,
        )
    end
    for precision in (63, big(typemax(Cint)) + 1)
        @test_throws ArgumentError certified_polynomial(
            spec;
            degree = 1,
            proof_precision = precision,
        )
    end
    for accuracy in (0, 1, -1 // 4)
        @test_throws ArgumentError certified_polynomial(spec; degree = 1, accuracy)
    end
    for max_refinements in (-1, 9)
        @test_throws ArgumentError certified_polynomial(spec; degree = 1, max_refinements)
    end
    for format in
        (FixedFormat(16, 4; rounding = :down), FixedFormat(16, 4; overflow = :wrap))
        @test_throws ArgumentError certified_polynomial(
            spec;
            degree = 1,
            internal_format = format,
        )
        contract = FunctionSpec("x"; input_format = format, domain = (-1, 1))
        @test_throws ArgumentError certified_polynomial(contract; degree = 1)
        contract = FunctionSpec("x"; output_format = format, domain = (-1, 1))
        @test_throws ArgumentError certified_polynomial(contract; degree = 1)
    end
    for (input_format, domain) in (
        (FixedFormat(8, 3), (1 // 1000, 1 // 500)),
        (FloatFormat(3, 4), (101 // 100, 102 // 100)),
        (FixedFormat(8, 3), (4, 5)),
        (FloatFormat(3, 4), (16, 17)),
    )
        contract = FunctionSpec("x"; input_format, domain)
        @test_throws ArgumentError certified_polynomial(contract; degree = 1)
    end
    for (expression, internal_format, detail) in (
        ("3", FixedFormat(8, 2), "exceeds"),
        ("16", FloatFormat(2, 4), "exceeds"),
        ("1b-12", FloatFormat(3, 4), "not exactly representable"),
        ("-1", FixedFormat(12, 4; signed = false), "exceeds"),
    )
        contract = FunctionSpec(expression; domain = (-1, 1))
        result = certified_polynomial(contract; degree = 0, internal_format)
        @test result.status == :generation_failed
        @test occursin(detail, result.reason)
        @test result.plan.program === nothing && result.plan.status == :contract
        @test result.total_bound === nothing && isempty(result.paths)
    end
    subnormal = FunctionSpec("1b-4"; input_format = FloatFormat(3, 4), domain = (-1, 1))
    result = certified_polynomial(subnormal; degree = 0)
    @test result.status == :certified && result.total_bound == 0
    @test evaluate_bits(result.plan, 0) == 4
    for expression in ("1/x", "sqrt(x)", "[0;1]", "exp(")
        contract = FunctionSpec(expression; domain = (-1, 1))
        result = certified_polynomial(contract; degree = 2)
        @test result.status == :generation_failed
        @test !isempty(result.reason) && result.plan.program === nothing
    end

    # A stored candidate is retained when arithmetic/output overflow prevents proof.
    for (contract, internal_format) in (
        (FunctionSpec("3*x"; domain = (1, 2)), FloatFormat(2, 4)),
        (FunctionSpec("x"; domain = (4, 6)), FloatFormat(2, 4)),
        (
            FunctionSpec("3"; output_format = FixedFormat(8, 2), domain = (-1, 1)),
            FixedFormat(16, 4),
        ),
    )
        result = certified_polynomial(contract; degree = 1, internal_format)
        @test result.status == :proof_failed
        @test occursin("overflow", result.reason)
        @test result.plan.program !== nothing && result.total_bound === nothing
    end
    contract = FunctionSpec("exp(x)"; domain = (-1, 1), absolute_error = 1 // (1 << 40))
    result =
        certified_polynomial(contract; degree = 1, internal_format = FixedFormat(32, 6))
    @test result.status == :bound_exceeds_budget
    @test result.plan.program !== nothing
    @test result.total_bound > contract.absolute_error
    @test !isempty(result.paths)

    # Numerical working precision is independent of both format and ambient settings.
    narrow_domain = FunctionSpec(
        "x";
        input_format = FixedFormat(80, 2),
        domain = (1 + big(1) // (big(1) << 60), 1 + big(1) // (big(1) << 59)),
    )
    result = certified_polynomial(
        narrow_domain;
        degree = 1,
        internal_format = FixedFormat(84, 4),
        generation_precision = 12,
    )
    @test result.status == :certified && result.total_bound == 0
    @test result.plan.settings["generation_precision"] == "12"
    result = certified_polynomial(
        narrow_domain;
        degree = 1,
        internal_format = FixedFormat(84, 4),
        generation_precision = 128,
    )
    @test result.status == :certified && result.total_bound == 0
    before = (precision(BigFloat), rounding(BigFloat), Sollya.working_precision())
    setprecision(BigFloat, 24) do
        setrounding(BigFloat, RoundUp) do
            result =
                certified_polynomial(spec; degree = 1, internal_format = FixedFormat(24, 6))
            @test result.status == :certified && result.total_bound == 0
            @test result.plan.settings["generation_precision"] == "256"
            @test precision(BigFloat) == 24 && rounding(BigFloat) == RoundUp
        end
    end
    @test (precision(BigFloat), rounding(BigFloat), Sollya.working_precision()) == before
end
