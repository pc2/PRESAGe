# Check mathematical error and every visited numeric range. Small formats are
# exhausted; wider formats use boundaries plus deterministic random payloads.
function check_floating_certificate(result; words = nothing, exact = nothing)
    @test result.status == :certified
    plan, path = result.plan, only(result.paths)
    words === nothing && (words = verification_inputs(plan; random_count = 128))
    bounds = Dict(b.node => b.range for b in path.ranges)
    maximum_error = PRESAGe._q(0)
    function check_word(word, oracle)
        input = PRESAGe._decode_input(word, plan.spec.input_format)
        if input.value === nothing || !(path.domain[1] <= input.value <= path.domain[2])
            # Omitted domains make no claim about infinities. Bounded floating
            # outputs return NaN without executing polynomial arithmetic.
            if plan.spec.domain !== nothing
                if plan.spec.output_format isa FloatFormat
                    trace = interpret_trace(plan, word)
                    @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                    @test !any(
                        i -> plan.program.nodes[i] isa Union{IR.Mul, IR.Add, IR.FMA},
                        keys(trace.values),
                    )
                else
                    @test_throws DomainError evaluate_bits(plan, word)
                end
            end
            return
        end
        trace = interpret_trace(plan, word)
        actual = PRESAGe._decode_input(trace.bits, plan.spec.output_format)
        @test actual.value !== nothing
        lo, hi = if exact !== nothing
            q = PRESAGe._q(exact(input.value))
            q, q
        else
            ref = reference(oracle, word)
            @test ref.status in (:resolved, :special)
            if ref.enclosure === nothing
                @test input.value == 0
                q = PRESAGe._q(plan.spec.expression == "exp(x)" ? 1 : 0)
                q, q
            else
                a, b = ref.enclosure
                a.significand * PRESAGe._pow2(a.exponent),
                b.significand * PRESAGe._pow2(b.exponent)
            end
        end
        error = max(abs(actual.value - lo), abs(actual.value - hi))
        maximum_error = max(maximum_error, error)
        @test error <= result.total_bound
        @test all(trace.values) do (node, value)
            format = IR.format(plan.program, node)
            format isa Union{FloatFormat, FixedFormat} || return true
            q = PRESAGe._decode_input(value.bits, format).value
            haskey(bounds, node) && q !== nothing && bounds[node][1] <= q <= bounds[node][2]
        end
    end
    if exact === nothing
        with_oracle(plan.spec; backend = :mpfr) do oracle
            foreach(word -> check_word(word, oracle), words)
        end
    else
        foreach(word -> check_word(word, nothing), words)
    end
    return maximum_error
end

function floating_coefficients(expression)
    Sollya.with_session(Sollya.Session(; precision = 256)) do
        f, domain = Sollya.sollya(expression), Sollya.interval(-1, 1)
        try
            p = Sollya.fpminimax(
                f,
                13,
                32,
                domain;
                error = :absolute,
                arithmetic = :floating,
            )
            try
                Sollya.coefficients(p)
            finally
                close(p)
            end
        finally
            close(f)
            close(domain)
        end
    end
end

@testset "Uniform floating polynomial certificates" begin
    ac_available = try
        vendor_include(:ac_fixed)
        true
    catch
        get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" && rethrow()
        false
    end
    small = FloatFormat(3, 4)
    all_small = UInt64.(0:255)
    # Conversion error, separate versus fused rounding, amplification above
    # one, cancellation, subnormal ties, and exponent/significand changes.
    cases = (
        (
            "x^2+x/4",
            [0, 1 // 4, 1],
            (-1, 1),
            FloatFormat(3, 2),
            small,
            x -> x^2 + x / 4,
            3 // 4,
        ),
        (
            "x^3/8+x/4",
            [0, 1 // 4, 0, 1 // 8],
            (-2, 2),
            FloatFormat(4, 5),
            small,
            x -> x^3 / 8 + x / 4,
            1 // 2,
        ),
        ("1/4+x/2", [1 // 4, 1 // 2], (-1, 1), small, small, x -> 1 // 4 + x / 2, 1 // 8),
        ("x/2", [0, 1 // 2], (-1 // 32, 1 // 32), small, small, x -> x / 2, 1 // 128),
        (
            "x+x^2",
            [0, 1, 1],
            (-1, 0),
            FloatFormat(4, 8),
            FloatFormat(2, 2),
            x -> x + x^2,
            1 // 4,
        ),
        ("x/3", [0, 1 // 3], (-1, 1), FloatFormat(4, 8), small, x -> x / 3, 1 // 8),
    )
    for (expression, coefficients, domain, internal, output, exact, budget) in cases,
        mode in (:separate, :fma)

        spec = FunctionSpec(
            expression;
            input_format = small,
            output_format = output,
            domain,
            absolute_error = budget,
        )
        plan = polynomial_plan(
            spec,
            coefficients;
            internal_format = internal,
            evaluation = mode,
        )
        result = certify_polynomial(plan)
        check_floating_certificate(result; words = all_small, exact)
        @test result.total_bound <= budget
        @test any(b -> b isa FloatNodeBound, only(result.paths).ranges)
        if internal == FloatFormat(3, 2)
            @test only(result.paths).coordinate_error > 0
        end
        if ac_available
            @test cpu_check(plan, all_small; float_backend = :ac_std_float) == 256
        end
    end

    # Fixed/float interfaces share the same proof, with explicit quantizers.
    for (input, internal, output) in (
            (FixedFormat(8, 3), FloatFormat(4, 5), FixedFormat(10, 3)),
            (small, FixedFormat(12, 4), FloatFormat(4, 6)),
            (FixedFormat(8, 3), FloatFormat(4, 5), small),
            (small, FloatFormat(4, 8), FixedFormat(12, 4)),
        ),
        mode in (:separate, :fma)

        plan = polynomial_plan(
            FunctionSpec(
                "1/4+x/2+x^2/4";
                input_format = input,
                output_format = output,
                domain = (-1, 1),
                absolute_error = 1 // 8,
            ),
            [1 // 4, 1 // 2, 1 // 4];
            internal_format = internal,
            evaluation = mode,
        )
        result = certify_polynomial(plan)
        words = UInt64.(0:255)
        check_floating_certificate(result; words, exact = x -> 1 // 4 + x / 2 + x^2 / 4)
        if ac_available
            accepted = if output isa FixedFormat
                filter(words) do word
                    x = PRESAGe._decode_input(word, input).value
                    x !== nothing && -1 <= x <= 1
                end
            else
                words
            end
            @test cpu_check(plan, accepted; float_backend = :ac_std_float) ==
                  length(accepted)
        end
    end

    # Real erf/exp polynomials: more fraction bits reduce evaluator error while
    # leaving output rounding as a separate, unchanged allowance.
    for expression in ("erf(x)", "exp(x)")
        coefficients = floating_coefficients(expression)
        spec = FunctionSpec(expression; domain = (-1, 1), absolute_error = 1 // (1 << 21))
        for mode in (:separate, :fma)
            arithmetic = Rational{BigInt}[]
            for guard_bits in (0, 4, 8)
                plan = polynomial_plan(
                    spec,
                    coefficients;
                    internal_format = FloatFormat(8, 23 + guard_bits),
                    evaluation = mode,
                )
                result = certify_polynomial(plan)
                @test result.status in (:certified, :bound_exceeds_budget)
                push!(arithmetic, only(result.paths).arithmetic_error)
                if guard_bits > 0
                    check_floating_certificate(result)
                    if ac_available
                        @test cpu_check(plan; float_backend = :ac_std_float) > 128
                    end
                end
                @test only(result.paths).coordinate_error == 0
                @test only(result.paths).output_rounding == (
                    guard_bits == 0 ? 0 :
                    expression == "erf(x)" ? 1 // (1 << 24) : 1 // (1 << 23)
                )
                println(
                    "Floating $expression ($mode, $guard_bits guard bits): ",
                    result.status,
                    ", uniform bound ",
                    Float64(result.total_bound),
                )
            end
            @test arithmetic[3] < arithmetic[2] < arithmetic[1]
        end
        # Exhaust every binary16 encoding, including lazy exceptional paths.
        plan = polynomial_plan(
            FunctionSpec(
                expression;
                input_format = IEEE16,
                domain = (-1, 1),
                absolute_error = 1 // (1 << 9),
            ),
            coefficients;
            internal_format = FloatFormat(5, 14),
            evaluation = :fma,
        )
        result = certify_polynomial(plan)
        check_floating_certificate(result; words = UInt64.(0:65535))
        if ac_available
            @test cpu_check(plan; float_backend = :ac_std_float) == 65536
        end
    end

    # Custom/wide formats are proved uniformly, rather than by enumeration.
    for format in (small, IEEE32, IEEE64, IEEE128, IEEE256, FloatFormat(8, 160))
        identityplan = polynomial_plan(FunctionSpec("x"; input_format = format), [0, 1])
        result = certify_polynomial(identityplan)
        @test result.total_bound == 0
        check_floating_certificate(result; exact = identity)
        if ac_available && format in (IEEE128, FloatFormat(8, 160))
            @test cpu_check(identityplan) > 128
        end
    end
    for input in (IEEE64, IEEE128, IEEE256, FloatFormat(8, 160)), mode in (:separate, :fma)
        internal = FloatFormat(input.exponent_bits, input.fraction_bits + 4)
        plan = polynomial_plan(
            FunctionSpec(
                "1/4+x/2-x^2/4";
                input_format = input,
                domain = (-1, 1),
                absolute_error = PRESAGe._pow2(-input.fraction_bits),
            ),
            [1 // 4, 1 // 2, -1 // 4];
            internal_format = internal,
            evaluation = mode,
        )
        result = certify_polynomial(plan)
        check_floating_certificate(result; exact = x -> 1 // 4 + x / 2 - x^2 / 4)
        if ac_available
            @test cpu_check(plan) > 128
        end
    end

    # Tight subnormal error and final conversion, including underflow to zero.
    for internal in (small, FloatFormat(3, 8)), mode in (:separate, :fma)
        plan = polynomial_plan(
            FunctionSpec(
                "x/2";
                input_format = small,
                domain = (-1 // 32, 1 // 32),
                absolute_error = 1 // 128,
            ),
            [0, 1 // 2];
            internal_format = internal,
            evaluation = mode,
        )
        result = certify_polynomial(plan)
        @test result.total_bound == 1 // 128
        check_floating_certificate(result; words = all_small, exact = x -> x / 2)
    end

    # Inward nonrepresentable endpoints, singleton and constant polynomials.
    for (domain, expected) in (
        ((-1 // 3, 1 // 3), (-21 // 64, 21 // 64)),
        ((-100, 100), (-31 // 2, 31 // 2)),
        ((1 // 4, 1 // 4), (1 // 4, 1 // 4)),
    )
        plan = polynomial_plan(FunctionSpec("x"; input_format = small, domain), [0, 1])
        result = certify_polynomial(plan)
        @test only(result.paths).domain == expected
        check_floating_certificate(result; words = all_small, exact = identity)
    end
    constant = polynomial_plan(
        FunctionSpec("1/3"; input_format = small, absolute_error = 1 // 8),
        [1 // 3];
        internal_format = FloatFormat(2, 2),
    )
    result = certify_polynomial(constant)
    @test result.total_bound == 1 // 12
    check_floating_certificate(result; words = all_small, exact = x -> 1 // 3)
    singleton = polynomial_plan(
        FunctionSpec(
            "exp(x)";
            input_format = small,
            domain = (1 // 4, 1 // 4),
            absolute_error = 1,
        ),
        [1],
    )
    check_floating_certificate(certify_polynomial(singleton); words = all_small)

    # Endpoint rounding permits finite results just above maxfinite, and refuses
    # the overflow midpoint. Constant paths give their exact rounding error.
    maximum = PRESAGe._polynomial_value(PRESAGe._inf(small) - 1, small)
    for (offset, status) in ((1 // 8, :certified), (1 // 4, :proof_failed))
        value = maximum + offset
        plan = polynomial_plan(
            FunctionSpec(
                PRESAGe._rational_text(value);
                input_format = small,
                absolute_error = 1,
            ),
            [value];
            internal_format = FloatFormat(4, 8),
        )
        result = certify_polynomial(plan)
        @test result.status == status
        if status == :certified
            @test result.total_bound == offset
            check_floating_certificate(result; words = all_small, exact = x -> value)
        end
    end
    for (input, internal, output, expression, coefficients) in (
        (small, small, small, "x^2", [0, 0, 1]),
        (FloatFormat(4, 4), small, FloatFormat(4, 4), "x", [0, 1]),
        (FloatFormat(4, 4), FloatFormat(4, 4), small, "x", [0, 1]),
    )
        plan = polynomial_plan(
            FunctionSpec(expression; input_format = input, output_format = output),
            coefficients;
            internal_format = internal,
        )
        result = certify_polynomial(plan)
        @test result.status == :proof_failed
        @test occursin("node", result.reason) && occursin("overflow", result.reason)
    end

    # Audits reject changes to rounding order, arithmetic, and invalid branches.
    base =
        polynomial_plan(FunctionSpec("x"; input_format = small, domain = (-1, 1)), [0, 1])
    for mutation in (:rounding, :coordinate, :guard, :nan)
        nodes = collect(base.program.nodes)
        if mutation in (:rounding, :coordinate)
            i = findfirst(n -> n isa IR.Mul, nodes)
            n = nodes[i]
            nodes[i] =
                mutation == :rounding ? IR.Mul(n.a, n.b, n.format; rounding = :up) :
                IR.Mul(n.a, 2, n.format)
        elseif mutation == :guard
            n = nodes[end]
            nodes[end] = IR.Select(n.condition, n.no, n.yes)
        else
            nodes[end - 1] = IR.constant(0, small)
        end
        changed =
            PlanArtifact(base.spec; program = IR.Program(nodes), settings = base.settings)
        @test certify_polynomial(changed).status == :unsupported_domain
    end
    changed = polynomial_plan(base.spec, [1 // 4, 1])
    @test certify_polynomial(changed).status == :bound_exceeds_budget
    nodes = collect(base.program.nodes)
    nodes[2] = IR.Const(small, PRESAGe._sign(small))
    negativezero =
        PlanArtifact(base.spec; program = IR.Program(nodes), settings = base.settings)
    @test certify_polynomial(negativezero).total_bound == 0
    for expression in ("log(x)", "1/x", "log(x)-log(x)")
        plan = polynomial_plan(
            FunctionSpec(expression; input_format = small, domain = (-1, 1)),
            [0],
        )
        @test certify_polynomial(plan).status == :proof_failed
    end
    highdegree = polynomial_plan(
        FunctionSpec("x^33"; input_format = small, domain = (-1, 1)),
        [zeros(Int, 33); 1],
    )
    @test certify_polynomial(highdegree).status == :unsupported_domain
    @test certify_polynomial(erf_candidate()).status == :unsupported_domain
    @test certify_plan(base).total_bound == 0
    io = IOBuffer()
    write_certificate(io, certify_plan(base))
    data = TOML.parse(String(take!(io)))
    @test data["schema_version"] == 2
    @test data["settings"]["method"] == "floating_polynomial_horner"
    @test data["coverage"]["inputs"] ==
          "all representable finite floating inputs in the interval"
    @test data["coverage"]["outside_domain"] ==
          "canonical quiet NaN before polynomial evaluation"
    @test any(b -> b["format"] == PRESAGe._type_data(small), data["paths"][1]["ranges"])
    @test all(b -> haskey(b, "format"), data["paths"][1]["ranges"])
    @test !haskey(data, "tail")
end
