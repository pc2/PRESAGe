function check_odd_polynomial(result, words)
    @test result.status == :certified
    plan, path = result.plan, only(result.paths)
    layout = only(PRESAGe._odd_audit(plan).paths)
    ranges = Dict(b.node => b.range for b in path.ranges)
    accepted = BigInt[]
    with_oracle(
        plan.spec;
        backend = :mpfr,
        config = OracleConfig(initial_precision = 512, max_precision = 2048),
    ) do oracle
        for word in words
            x = PRESAGe._decode_input(word, plan.spec.input_format).value
            if x === nothing || !(path.domain[1] <= x <= path.domain[2])
                if plan.spec.output_format isa FixedFormat
                    @test_throws DomainError evaluate_bits(plan, word)
                else
                    trace = interpret_trace(plan, word)
                    @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                    @test !any(
                        i ->
                            plan.program.nodes[i] isa
                            Union{IR.Mul, IR.Add, IR.FMA, IR.Quantize},
                        keys(trace.values),
                    )
                end
                continue
            end
            push!(accepted, word)
            trace = interpret_trace(plan, word)
            actual = PRESAGe._decode_input(trace.bits, plan.spec.output_format).value
            ref = reference(oracle, word)
            @test ref.status in (:resolved, :special)
            lo, hi =
                ref.enclosure === nothing ? (PRESAGe._q(0), PRESAGe._q(0)) :
                map(b -> b.significand * PRESAGe._pow2(b.exponent), ref.enclosure)
            @test max(abs(actual - lo), abs(actual - hi)) <= result.total_bound
            @test all(trace.values) do (i, value)
                f = IR.format(plan.program, i)
                f isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(value.bits, f).value
                haskey(ranges, i) && q !== nothing && ranges[i][1] <= q <= ranges[i][2]
            end
            if iszero(x)
                @test actual == 0
                @test !haskey(trace.values, layout.coordinate)
                @test !haskey(trace.values, layout.reconstruction)
                if plan.spec.input_format isa FloatFormat &&
                   plan.spec.output_format isa FloatFormat
                    @test decode_ieee(trace.bits, plan.spec.output_format).negative ==
                          decode_ieee(word, plan.spec.input_format).negative
                end
            else
                if haskey(trace.values, layout.coordinate)
                    @test ranges[layout.coordinate][1] >= 0
                else
                    @test isempty(layout.stages)
                end
            end
        end
    end
    return accepted
end

@testset "Odd central generation and complete uniform certificates" begin
    for (expression, degree) in
        (("sin(x)", 9), ("sinh(x)", 9), ("erf(x)", 13), ("atan(x)", 17)),
        format in (FixedFormat(32, 6), FloatFormat(8, 27)),
        evaluation in (:separate, :fma)

        spec = FunctionSpec(
            expression;
            input_format = FixedFormat(9, 3),
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
            absolute_error = 1 // 2^18,
        )
        result = search_polynomial(
            spec,
            PolynomialSearchConfig(
                degrees = [degree],
                internal_formats = [format],
                transformation = :odd,
                evaluation = evaluation,
                job_timeout = 45,
                total_timeout = 60,
            ),
        )
        @test result.status == :certified
        result.selected === nothing && error(only(result.attempts).reason)
        proof = result.selected
        @test proof.settings["method"] == "odd_polynomial_horner"
        @test length(proof.plan.precision.coefficient_formats) <= (degree + 1) ÷ 2
        words = check_odd_polynomial(proof, 0:511)
        @test length(words) == 129
        # Both numerical families and arithmetic modes compile with official
        # headers. Fixed sin additionally checks the independent portable/AP paths.
        @test cpu_check(proof.plan, words; backend = :ac_fixed) == length(words)
        if expression == "sin(x)" && format isa FixedFormat
            @test cpu_check(proof.plan, words; backend = :portable) == length(words)
            @test cpu_check(proof.plan, words; backend = :ap_fixed) == length(words)
        end
        restored = PRESAGe._read_plan(PRESAGe._plan_data(proof.plan))
        @test certify_plan(restored).total_bound == proof.total_bound
        report = PRESAGe._certificate_data(proof)
        @test report["transformation"]["polynomial"] == "x*q(x*x)"
        @test report["transformation"]["norm_domain"] == ["0/1", "1/1"]
        @test occursin("odd", report["coverage"]["dispatch"])
        cost = implementation_cost(proof.plan)
        if evaluation == :separate
            @test cost.multiplications ==
                  length(proof.plan.precision.coefficient_formats) + 1
        else
            @test cost.multiplications == 2
            @test cost.fmas == length(proof.plan.precision.coefficient_formats) - 1
        end
    end
    f = FixedFormat(32, 6)
    precision = PolynomialPrecision(
        f;
        coefficient_formats = [
            FixedFormat(30, 4),
            FixedFormat(28, 3),
            FixedFormat(27, 2),
            FixedFormat(26, 2),
            FixedFormat(25, 2),
        ],
        stage_formats = [FixedFormat(w, 4) for w in (32, 31, 30, 29, 28)],
    )
    config = PolynomialSearchConfig(
        degrees = [9],
        internal_formats = [f],
        precisions = [precision],
        transformation = :odd,
        evaluation = :fma,
        job_timeout = 45,
        total_timeout = 60,
    )
    restored = PRESAGe._read_search_config(PRESAGe._search_config_data(config))
    @test restored.transformation == :odd
    @test only(restored.precisions) == precision
    spec = FunctionSpec(
        "sin(x)";
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(24, 4),
        domain = (-1, 1),
        absolute_error = 1 // 2^18,
    )
    search = search_polynomial(spec, restored)
    @test search.status == :certified
    @test search.selected.plan.precision == precision
    words = check_odd_polynomial(search.selected, 0:511)
    @test cpu_check(search.selected.plan, words; backend = :ac_fixed) == length(words)
end

@testset "Odd square, reconstruction, zeros and overflow" begin
    for input in (FixedFormat(8, 3), FloatFormat(3, 4)),
        family in (:fixed, :float),
        evaluation in (:separate, :fma)

        f = family == :fixed ? FixedFormat(12, 4) : FloatFormat(4, 3)
        coefficient = family == :fixed ? FixedFormat(18, 4) : FloatFormat(5, 12)
        stages =
            family == :fixed ? [FixedFormat(10, 3), FixedFormat(8, 3)] :
            [FloatFormat(4, 4), FloatFormat(4, 2)]
        precision = PolynomialPrecision(
            f;
            coefficient_formats = [coefficient, coefficient],
            stage_formats = stages,
        )
        spec = FunctionSpec(
            "sin(x)";
            input_format = input,
            output_format = FloatFormat(3, 4),
            domain = (-9 // 10, 7 // 10),
            absolute_error = 1 // 2,
        )
        proof = certify_plan(odd_polynomial_plan(spec, [1, -1 // 6]; precision, evaluation))
        @test only(proof.paths).coordinate_error > 0
        @test only(proof.paths).arithmetic_error > 0
        words = check_odd_polynomial(proof, 0:255)
        for backend in (:portable, :ac_fixed, :ap_fixed)
            @test cpu_check(proof.plan, words; backend, public_api = true) == length(words)
        end
    end
    # Zero-only contracts certify the actual lazy branch, even when an unused
    # seed conversion would overflow. No tiny erf return-x rule is assumed.
    f = FloatFormat(5, 10)
    precision = PolynomialPrecision(
        f;
        coefficient_formats = [f],
        stage_formats = [FloatFormat(2, 2)],
    )
    spec = FunctionSpec(
        "erf(x)";
        input_format = FloatFormat(3, 4),
        output_format = FloatFormat(3, 4),
        domain = (0, 0),
    )
    result = certify_plan(odd_polynomial_plan(spec, [16]; precision))
    @test result.status == :certified
    @test result.total_bound == 0
    words = check_odd_polynomial(result, 0:255)
    @test length(words) == 2
    @test cpu_check(result.plan, words) == 2
    optimized =
        optimize_precision(result; max_attempts = 4, job_timeout = 30, total_timeout = 60)
    @test optimized.status == :certified
    @test optimized.stop_reason == :choices_exhausted
    @test length(optimized.attempts) == 1
    # Original inputs that convert to zero still execute the ordinary error
    # proof; the shortcut tests the input, not a rounded coordinate.
    tiny = FunctionSpec(
        "erf(x)";
        input_format = FloatFormat(3, 4),
        output_format = FloatFormat(3, 4),
        domain = (-1 // 32, 1 // 32),
        absolute_error = 1 // 4,
    )
    result =
        certify_plan(odd_polynomial_plan(tiny, [1]; internal_format = FixedFormat(6, 4)))
    @test only(result.paths).coordinate_error > 0
    check_odd_polynomial(result, 0:255)
    @test interpret_trace(
        result.plan,
        round_ieee(1 // 64, tiny.input_format),
    ).values[PRESAGe._odd_audit(result.plan).paths[1].reconstruction_coordinate].bits == 0
    positive = FunctionSpec(
        "sin(x)";
        input_format = FloatFormat(3, 4),
        output_format = FloatFormat(3, 4),
        domain = (1 // 2, 1),
        absolute_error = 1 // 2,
    )
    positive_proof = certify_plan(
        odd_polynomial_plan(positive, [1, -1 // 6]; internal_format = FixedFormat(24, 6)),
    )
    check_odd_polynomial(positive_proof, 0:255)
    @test evaluate_bits(positive_proof.plan, 0) == PRESAGe._nan(positive.output_format)
    @test cpu_check(positive_proof.plan, 0:255; backend = :ac_fixed) == 256
    for (input, internal, domain) in (
        (FixedFormat(8, 5), FixedFormat(8, 3), (-2, 2)),
        (FloatFormat(4, 4), FloatFormat(2, 3), (-2, 2)),
    )
        spec = FunctionSpec(
            "sin(x)";
            input_format = input,
            output_format = input,
            domain,
            absolute_error = 1,
        )
        result = certify_plan(
            odd_polynomial_plan(spec, [1, -1 // 6]; internal_format = internal),
        )
        @test result.status == :proof_failed
        @test occursin("overflow", result.reason)
        # A degree-one evaluator does not need a square, even if the declared
        # but unreachable square node would overflow on the same domain.
        loose = FunctionSpec(
            "sin(x)";
            input_format = input,
            output_format = input,
            domain,
            absolute_error = 2,
        )
        linear = certify_plan(odd_polynomial_plan(loose, [1]; internal_format = internal))
        @test linear.status == :certified
        check_odd_polynomial(linear, 0:((big(1) << PRESAGe._width(input)) - 1))
    end
end

@testset "Odd graph audit, identity authorization and request validation" begin
    f = FixedFormat(24, 6)
    spec = FunctionSpec(
        "sin(x)";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(16, 4),
        domain = (-1, 1),
        absolute_error = 1 // 16,
    )
    plan = odd_polynomial_plan(spec, [1, -1 // 6]; internal_format = f)
    for (i, n) in enumerate(plan.program.nodes)
        nodes = collect(plan.program.nodes)
        changed = if n isa IR.Mul
            IR.Add(n.a, n.b, n.format)
        elseif n isa IR.Quantize
            IR.Convert(n.source, n.format)
        elseif n isa IR.Classify && n.kind == :zero
            IR.Classify(:finite, n.source)
        elseif n isa IR.Select && i == only(PRESAGe._odd_audit(plan).paths).zero_select
            IR.Select(n.condition, n.no, n.yes)
        else
            continue
        end
        nodes[i] = changed
        mutated = PlanArtifact(
            spec;
            program = IR.Program(nodes; output = plan.program.output),
            precision = plan.precision,
            settings = plan.settings,
        )
        @test certify_plan(mutated).status == :unsupported_domain
    end
    # Coefficient changes are supported only with a fresh mathematical norm.
    @test certify_plan(odd_polynomial_plan(spec, [0]; internal_format = f)).status ==
          :bound_exceeds_budget
    disguised = PlanArtifact(
        FunctionSpec(
            "exp(x)";
            input_format = spec.input_format,
            output_format = spec.output_format,
            domain = spec.domain,
        );
        program = plan.program,
        precision = plan.precision,
        settings = plan.settings,
    )
    @test certify_plan(disguised).status == :unsupported_domain
    floating = FloatFormat(5, 10)
    float_spec = FunctionSpec(
        "sin(x)";
        input_format = FloatFormat(3, 4),
        output_format = FloatFormat(3, 4),
        domain = (-1, 1),
        absolute_error = 2,
    )
    float_plan = odd_polynomial_plan(float_spec, [0, 1 // 4]; internal_format = floating)
    coefficient = first(PRESAGe._odd_audit(float_plan).coefficient_nodes)
    nodes = collect(float_plan.program.nodes)
    nodes[coefficient] = IR.Const(floating, PRESAGe._sign(floating))
    signed = PlanArtifact(
        float_spec;
        program = IR.Program(nodes; output = float_plan.program.output),
        precision = float_plan.precision,
        settings = float_plan.settings,
    )
    @test certify_plan(signed).status == :certified
    replay = PRESAGe._read_plan(PRESAGe._plan_data(signed))
    @test replay.program.nodes[coefficient].bits == PRESAGe._sign(floating)
    narrower = PolynomialPrecision(
        floating;
        coefficient_formats = [floating, floating],
        stage_formats = [FloatFormat(5, 8), FloatFormat(5, 8)],
    )
    reformatted = PRESAGe._reformat_polynomial(replay, narrower)
    @test reformatted.program.nodes[coefficient].bits == PRESAGe._sign(floating)
    @test certify_plan(reformatted).status == :certified
    for expression in ("exp(x)", "sin(x)+x", "x", "sin(2*x)")
        @test_throws ArgumentError certified_polynomial(
            FunctionSpec(expression; domain = (-1, 1));
            degree = 9,
            transformation = :odd,
        )
    end
    for degree in (0, 2, 32), transformation in (:odd,)
        @test_throws ArgumentError PolynomialSearchConfig(
            degrees = [degree],
            internal_formats = [f],
            transformation = transformation,
        )
    end
    @test_throws ArgumentError PolynomialSearchConfig(
        degrees = [9],
        internal_formats = [f],
        transformation = :odd,
        segments = [2],
    )
    @test_throws ArgumentError PolynomialSearchConfig(
        degrees = [9],
        internal_formats = [f],
        transformation = :unknown,
    )
    @test_throws ArgumentError certified_polynomial(
        FunctionSpec("sin(x)");
        degree = 9,
        transformation = :odd,
    )
    @test_throws ArgumentError certified_polynomial(
        spec;
        degree = 9,
        segments = 2,
        transformation = :odd,
    )
    started = Ref(false)
    @test_throws ArgumentError PRESAGe._search_polynomial(
        FunctionSpec("exp(x)"; domain = (-1, 1)),
        PolynomialSearchConfig(
            degrees = [9],
            internal_formats = [f],
            transformation = :odd,
        );
        process_started = (p, d) -> (started[] = true),
    )
    @test !started[]
end

@testset "Odd binary16 coverage, precision optimization and CLI replay" begin
    spec = FunctionSpec(
        "sin(x)";
        input_format = IEEE16,
        output_format = IEEE16,
        domain = (-1, 1),
        absolute_error = 1 // 2^9,
    )
    f = FixedFormat(32, 6)
    baseline = certified_polynomial(
        spec;
        degree = 9,
        internal_format = f,
        transformation = :odd,
        evaluation = :fma,
    )
    @test baseline.status == :certified
    words = check_odd_polynomial(baseline, 0:65535)
    @test cpu_check(baseline.plan, 0:65535; backend = :ac_fixed) == 65536
    @test cpu_check(baseline.plan, 0:65535; backend = :ap_fixed) == 65536
    optimized = optimize_precision(
        baseline;
        max_attempts = 8,
        bit_step = 2,
        job_timeout = 45,
        total_timeout = 180,
    )
    @test optimized.status == :certified
    @test all(
        a ->
            a.result.plan === nothing ||
                a.result.plan.program === nothing ||
                a.result.plan.settings["transformation"] == "odd",
        optimized.attempts,
    )
    @test precision_cost(optimized.selected.plan).coefficient_bits <
          precision_cost(baseline.plan).coefficient_bits
    @test implementation_cost(optimized.selected.plan).fmas == 4
    @test certify_plan(optimized.selected.plan).total_bound ==
          optimized.selected.total_bound
    mktempdir() do directory
        contract, configuration =
            joinpath(directory, "contract.toml"), joinpath(directory, "config.toml")
        fixed_spec = FunctionSpec(
            "sin(x)";
            input_format = FixedFormat(9, 3),
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
            absolute_error = 1 // 2^18,
        )
        write_plan(contract, PlanArtifact(fixed_spec))
        config = PolynomialSearchConfig(
            degrees = [3, 9],
            internal_formats = [f],
            transformation = :odd,
            evaluation = :fma,
            job_timeout = 45,
            total_timeout = 120,
        )
        write_search_config(configuration, config)
        @test read_search_config(configuration).transformation == :odd
        @test TOML.parsefile(configuration)["schema_version"] == 4
        output = joinpath(directory, "generated")
        generate_main([
            contract,
            output,
            "--search-config=$configuration",
            "--backend=ac_fixed",
        ])
        plan = read_plan(joinpath(output, "plan.toml"))
        report = TOML.parsefile(joinpath(output, "search.toml"))
        @test report["transformation"] == "odd"
        @test [a["status"] for a in report["attempts"]] == ["bound_exceeds_budget", "certified"]
        accepted = check_odd_polynomial(certify_plan(plan), 0:511)
        @test cpu_check(
            plan,
            accepted;
            backend = :ac_fixed,
            generated_directory = output,
        ) == length(accepted)
        replay = joinpath(directory, "replayed")
        generate_main([joinpath(output, "plan.toml"), replay, "--backend=ap_fixed"])
        @test read_plan(joinpath(replay, "plan.toml")).settings["transformation"] == "odd"
        @test cpu_check(
            plan,
            accepted;
            backend = :ap_fixed,
            generated_directory = replay,
        ) == length(accepted)
        invalid = PRESAGe._search_config_data(config)
        invalid["schema_version"] = 3
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
        for transformation in (nothing, "none", "unknown", 1)
            invalid = PRESAGe._search_config_data(config)
            if transformation === nothing
                delete!(invalid, "transformation")
            else
                invalid["transformation"] = transformation
            end
            @test_throws ArgumentError PRESAGe._read_search_config(invalid)
        end
    end
end
