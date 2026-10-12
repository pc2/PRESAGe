isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))

function check_reciprocal(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan, path = result.plan, only(result.paths)
    ranges = Dict(b.node => b.range for b in path.ranges)
    largest = PRESAGe._q(0)
    for word in words
        x = decode_ieee(word, plan.spec.input_format).value
        trace = interpret_trace(plan, word)
        if x === nothing || !(path.domain[1] <= x <= path.domain[2])
            @test trace.bits == PRESAGe._nan(plan.spec.output_format)
            @test !any(keys(trace.values)) do i
                plan.program.nodes[i] isa Union{
                    IR.FloatMantissa,
                    IR.ScaleByInputExponent,
                    IR.Mul,
                    IR.Add,
                    IR.FMA,
                    IR.Convert,
                    IR.Quantize,
                }
            end
            continue
        end
        actual = decode_ieee(trace.bits, plan.spec.output_format).value
        @test actual !== nothing
        actual === nothing && error("nonfinite reciprocal result")
        difference = abs(actual - 1 / x)
        largest = max(largest, difference)
        @test difference <= result.total_bound
        @test all(trace.values) do (i, value)
            f = IR.format(plan.program, i)
            f isa Union{FloatFormat, FixedFormat} || return true
            q = PRESAGe._decode_input(value.bits, f).value
            haskey(ranges, i) && q !== nothing && ranges[i][1] <= q <= ranges[i][2]
        end
    end
    return largest
end

@testset "Exact floating magnitude normalization" begin
    for f in (IEEE16, FloatFormat(3, 3))
        for word = UInt64(0):UInt64(PRESAGe._wordmask(f))
            x = decode_ieee(word, f)
            if x.kind != :finite
                @test_throws DomainError normalize_float(word, f)
                continue
            end
            m, e = normalize_float(word, f)
            decoded = decode_ieee(m, f)
            @test 1 <= decoded.value < 2
            @test !decoded.negative
            @test decoded.value * PRESAGe._pow2(e) == abs(x.value)
        end
    end
    for f in (IEEE128, IEEE256, FloatFormat(8, 300), FloatFormat(8, 4096))
        for word in (
                BigInt(1),
                (BigInt(1) << f.fraction_bits) - 1,
                BigInt(1) << f.fraction_bits,
                BigInt(PRESAGe._inf(f)) - 1,
            ),
            negative in (false, true)

            word |= negative ? BigInt(PRESAGe._sign(f)) : 0
            m, e = normalize_float(word, f)
            @test m isa BigInt
            @test decode_ieee(m, f).value * PRESAGe._pow2(e) ==
                  abs(decode_ieee(word, f).value)
        end
    end
    huge = FloatFormat(62, 1)
    @test normalize_float(1, huge) == (round_ieee(1, huge), PRESAGe._emin(huge) - 1)
    @test normalize_float(round_ieee(1, huge), huge) == (round_ieee(1, huge), 0)
    @test_throws ArgumentError normalize_float(-1, IEEE16)
    @test_throws ArgumentError normalize_float(1 << 16, IEEE16)
end

@testset "Exponent reconstruction IR and official CPU headers" begin
    for f in (FloatFormat(4, 4), IEEE16, FloatFormat(8, 100))
        nodes = IR.Node[
            IR.Input(f),
            IR.FloatMantissa(1),
            IR.ScaleByInputExponent(2, 1, 1, f),
            IR.CopySign(3, 1),
        ]
        plan =
            PlanArtifact(FunctionSpec("x"; input_format = f); program = IR.Program(nodes))
        words = if f == IEEE16
            [w for w = UInt64(0):UInt64(0xffff) if decode_ieee(w, f).kind == :finite]
        elseif f == FloatFormat(4, 4)
            [
                w for w = UInt64(0):UInt64(PRESAGe._wordmask(f)) if
                decode_ieee(w, f).kind == :finite
            ]
        else
            [
                BigInt(w) | (negative ? BigInt(PRESAGe._sign(f)) : 0) for w in (
                    1,
                    (BigInt(1) << f.fraction_bits) - 1,
                    BigInt(1) << f.fraction_bits,
                    BigInt(PRESAGe._inf(f)) - 1,
                ) for negative in (false, true)
            ]
        end
        @test all(w -> evaluate_bits(plan, w) == w, words)
        cpu_check(
            plan,
            words;
            float_backend = f == IEEE16 ? :native : :ac_std_float,
            public_api = true,
        )
        f == IEEE16 && cpu_check(plan, words; float_backend = :ac_std_float)
        for word in (0, PRESAGe._sign(f), PRESAGe._inf(f), PRESAGe._nan(f))
            @test_throws DomainError evaluate_bits(plan, word)
        end
        io = IOBuffer()
        write_plan(io, plan)
        @test TOML.parse(String(take!(io)))["schema_version"] == 6
    end
    f = IEEE16
    source = FixedFormat(24, 4)
    value = 3 // 4 + 1 // 1024 + 1 // 2^20
    program = IR.Program(
        IR.Node[
            IR.Input(f),
            IR.constant(value, source),
            IR.ScaleByInputExponent(2, 1, -1, f),
            IR.CopySign(3, 1),
        ],
    )
    plan = PlanArtifact(FunctionSpec("1/x"; input_format = f); program)
    words = [
        w | (negative ? PRESAGe._sign(f) : 0) for w in (
            UInt64(1),
            UInt64(2),
            UInt64(3),
            UInt64(1023),
            UInt64(1024),
            round_ieee(1, f),
            round_ieee(8192, f),
            round_ieee(65504, f),
        ) for negative in (false, true)
    ]
    for word in words
        _, e = normalize_float(word, f)
        @test evaluate_bits(plan, word) ==
              round_dyadic(
            numerator(value),
            -20 - e,
            f;
            zero_sign = decode_ieee(word, f).negative,
        ) | (decode_ieee(word, f).negative ? PRESAGe._sign(f) : 0)
    end
    # An intermediate half conversion would round to a subnormal midpoint and
    # choose 384; direct reconstruction must choose 385.
    @test evaluate_bits(plan, round_ieee(65504, f)) == 385
    for backend in (:portable, :ac_fixed, :ap_fixed),
        float_backend in (:native, :ac_std_float)

        cpu_check(plan, words; backend, float_backend, public_api = true)
    end
    cpu_check(
        plan,
        [round_ieee(1, f)];
        expected_error = "FE_TONEAREST",
        host_rounding = :down,
        public_api = true,
    )
    @test_throws ArgumentError IR.Program([
        IR.Input(FixedFormat(8, 4)),
        IR.FloatMantissa(1),
    ])
    @test_throws ArgumentError IR.ScaleByInputExponent(1, 1, 0, f)
    @test_throws ArgumentError IR.Program([IR.Input(f), IR.CopySign(1, 2)])
    wide_exponent = FloatFormat(30, 4)
    p = IR.Program([
        IR.Input(wide_exponent),
        IR.ScaleByInputExponent(1, 1, -1, wide_exponent),
    ])
    @test_throws ArgumentError emit_cpp(IOBuffer(), p; float_backend = :ac_std_float)
end

reciprocal_results = Dict{Tuple{Symbol, Symbol}, CertificationResult}()
@testset "Certified reciprocal mantissa kernels and complete error bounds" begin
    for evaluation in (:separate, :fma), side in (:positive, :negative)
        domain = side == :positive ? (1 // 16, 16) : (-16, -1 // 16)
        spec =
            FunctionSpec("1 / x"; input_format = IEEE16, domain, absolute_error = 1 // 64)
        search = search_polynomial(
            spec,
            PolynomialSearchConfig(
                degrees = [7],
                internal_formats = [FixedFormat(40, 12)],
                transformation = :reciprocal,
                evaluation = evaluation,
                job_timeout = 60,
                total_timeout = 90,
            ),
        )
        @test search.status == :certified
        search.selected === nothing && error(only(search.attempts).reason)
        result = search.selected
        reciprocal_results[(evaluation, side)] = result
        words = [
            round_ieee(x, IEEE16) for
            x in (domain[1], domain[2], side == :positive ? 3 // 2 : -3 // 2)
        ]
        check_reciprocal(result, words)
        @test only(result.paths).coordinate_error == 0
        @test only(result.paths).arithmetic_error > 0
        @test only(result.paths).output_rounding > 0
        cost = implementation_cost(result.plan)
        @test cost.normalizations == cost.exponent_scalings == cost.sign_copies == 1
        @test cost.fmas == (evaluation == :fma ? 7 : 0)
        @test cost.multiplications == (evaluation == :separate ? 7 : 0)
        report = PRESAGe._certificate_data(result)
        @test report["transformation"]["input_exponents"] == [-4, 4]
        @test report["transformation"]["maximum_error_scale"] == "16/1"
        @test occursin("mantissa", report["coverage"]["dispatch"])
        io = IOBuffer()
        write_plan(io, result.plan)
        replay = read_plan(IOBuffer(String(take!(io))))
        @test PRESAGe._program_data(replay.program) ==
              PRESAGe._program_data(result.plan.program)
        @test certify_plan(replay).status == :certified
        for backend in (:portable, :ac_fixed, :ap_fixed)
            cpu_check(result.plan, words; backend, float_backend = :ac_std_float)
        end
    end
    for (input, output, domain, internal, degree, target) in (
        (FloatFormat(4, 4), IEEE32, (1 // 1024, 1 // 64), FloatFormat(8, 30), 9, 1 // 512),
        (
            FloatFormat(8, 100),
            FloatFormat(11, 112),
            (1 // 4, 4),
            FixedFormat(96, 24),
            9,
            1 // 2^20,
        ),
    )
        spec = FunctionSpec(
            "1/x";
            input_format = input,
            output_format = output,
            domain,
            absolute_error = target,
        )
        search = search_polynomial(
            spec,
            PolynomialSearchConfig(
                degrees = [degree],
                internal_formats = [internal],
                transformation = :reciprocal,
                evaluation = :fma,
                generation_precision = 384,
                proof_precision = 384,
                job_timeout = 60,
                total_timeout = 90,
            ),
        )
        @test search.status == :certified
        search.selected === nothing && error(only(search.attempts).reason)
        result = search.selected
        words =
            input == FloatFormat(4, 4) ?
            collect(UInt64(0):UInt64(PRESAGe._wordmask(input))) :
            [round_ieee(x, input) for x in (1 // 4, 1 // 2, 3 // 4, 1, 3 // 2, 2, 3, 4)]
        check_reciprocal(result, words)
        @test (
            internal isa FixedFormat ? only(result.paths).coordinate_error > 0 :
            only(result.paths).coordinate_error == 0
        )
        for backend in (:portable, :ac_fixed, :ap_fixed)
            cpu_check(result.plan, words; backend, public_api = true)
        end
    end
end

@testset "Exhaustive binary16 reciprocal verification" begin
    words = collect(UInt64(0):UInt64(0xffff))
    for side in (:positive, :negative)
        result = reciprocal_results[(:fma, side)]
        largest = check_reciprocal(result, words)
        @test largest <= result.total_bound <= result.plan.spec.absolute_error
        cpu_check(result.plan, words; float_backend = :native)
        if side == :positive
            cpu_check(
                result.plan,
                words;
                backend = :ac_fixed,
                float_backend = :ac_std_float,
            )
            cpu_check(
                result.plan,
                words;
                backend = :ap_fixed,
                float_backend = :ac_std_float,
            )
        end
    end
end

@testset "Reciprocal proof refusal and exact graph authorization" begin
    plan = reciprocal_results[(:fma, :positive)].plan
    for expression in ("sqrt(x)", "2/x", "sin(x)")
        spec = FunctionSpec(
            expression;
            input_format = IEEE16,
            domain = (1 // 16, 16),
            absolute_error = 1 // 64,
        )
        @test_throws ArgumentError reciprocal_polynomial_plan(spec, [1])
        @test certify_plan(
            PlanArtifact(
                spec;
                program = plan.program,
                precision = plan.precision,
                settings = plan.settings,
            ),
        ).status == :unsupported_domain
    end
    for domain in (nothing, (0, 1), (-1, 1), (-1, 0))
        spec = FunctionSpec("1/x"; input_format = IEEE16, domain)
        @test_throws ArgumentError certified_polynomial(
            spec;
            degree = 3,
            transformation = :reciprocal,
        )
    end
    @test_throws ArgumentError reciprocal_polynomial_plan(
        FunctionSpec("1/x"; input_format = FixedFormat(16, 8), domain = (1, 2)),
        [1],
    )
    @test_throws ArgumentError reciprocal_polynomial_plan(
        FunctionSpec("1/x"; output_format = FixedFormat(16, 8), domain = (1, 2)),
        [1],
    )
    @test_throws ArgumentError PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [3],
        internal_formats = [IEEE32],
        segments = [2],
        transformation = :reciprocal,
    )
    for kind in (IR.FloatMantissa, IR.ScaleByInputExponent, IR.CopySign, IR.FMA)
        nodes = collect(plan.program.nodes)
        i = findfirst(n -> n isa kind, nodes)
        n = nodes[i]
        nodes[i] =
            kind == IR.FloatMantissa ? IR.Convert(n.source, IEEE16) :
            kind == IR.ScaleByInputExponent ?
            IR.ScaleByInputExponent(n.source, n.input, 1, n.format) :
            kind == IR.CopySign ? IR.Convert(n.source, IEEE16) :
            IR.FMA(n.a, n.b, n.a, n.format)
        mutated = PlanArtifact(
            plan.spec;
            program = IR.Program(nodes; output = plan.program.output),
            precision = plan.precision,
            settings = plan.settings,
        )
        @test certify_plan(mutated).status == :unsupported_domain
    end
    data = PRESAGe._plan_data(plan)
    data["schema_version"] = 5
    @test_throws ArgumentError PRESAGe._read_plan(data)
    too_small = FunctionSpec(
        "1/x";
        input_format = IEEE16,
        domain = (1 // 16, 16),
        absolute_error = 1 // 2^30,
    )
    @test certify_plan(
        PlanArtifact(
            too_small;
            program = plan.program,
            precision = plan.precision,
            settings = plan.settings,
        ),
    ).status == :bound_exceeds_budget
    overflowing = FunctionSpec(
        "1/x";
        input_format = IEEE16,
        domain = (1 // 2^24, 1 // 1024),
        absolute_error = 1,
    )
    p = reciprocal_polynomial_plan(
        overflowing,
        only(PRESAGe._reciprocal_audit(plan).paths).coefficients;
        precision = plan.precision,
        evaluation = :fma,
    )
    @test certify_plan(p).status == :proof_failed
    @test occursin("overflow", certify_plan(p).reason)
    # Constant kernels need no mantissa conversion; unused narrow coordinates
    # must not prevent proving their executed exponent reconstruction.
    broad = FunctionSpec("1/x"; input_format = IEEE16, domain = (1, 2), absolute_error = 1)
    p = reciprocal_polynomial_plan(broad, [1 // 2]; internal_format = FixedFormat(2, 1))
    @test certify_plan(p).status == :certified
    @test !haskey(interpret_trace(p, round_ieee(1, IEEE16)).values, 2)
    singleton =
        FunctionSpec("1/x"; input_format = IEEE16, domain = (1, 1), absolute_error = 1)
    result =
        certify_plan(reciprocal_polynomial_plan(singleton, [1]; internal_format = IEEE32))
    @test result.status == :certified
    @test only(result.paths).approximation[1] == 0
    @test evaluate_bits(result.plan, round_ieee(1, IEEE16)) == round_ieee(1, IEEE16)
end

@testset "Reciprocal precision optimization and configuration replay" begin
    baseline = reciprocal_results[(:fma, :positive)]
    precision = baseline.plan.precision
    stages = collect(precision.stage_formats)
    stages[1] = FixedFormat(38, 11)
    stages[2] = FixedFormat(39, 11)
    layout = PolynomialPrecision(
        precision.coordinate_format;
        coefficient_formats = precision.coefficient_formats,
        stage_formats = stages,
    )
    reformatted = PRESAGe._reformat_polynomial(baseline.plan, layout)
    result = certify_plan(reformatted)
    check_reciprocal(result, [round_ieee(x, IEEE16) for x in (1 // 16, 3 // 2, 16)])
    @test result.total_bound > baseline.total_bound
    for backend in (:portable, :ac_fixed, :ap_fixed)
        cpu_check(reformatted, [round_ieee(3 // 2, IEEE16)]; backend)
    end
    # Raw negative-zero coefficient words survive canonical audit and stage
    # reformatting, including the floating coefficient-load conversion.
    spec = FunctionSpec(
        "1/x";
        input_format = IEEE16,
        output_format = IEEE32,
        domain = (1, 2),
        absolute_error = 1,
    )
    p = reciprocal_polynomial_plan(
        spec,
        [3 // 4, 0];
        internal_format = IEEE32,
        evaluation = :fma,
    )
    audit = PRESAGe._reciprocal_audit(p)
    nodes = collect(p.program.nodes)
    zero_coefficient = last(audit.coefficient_nodes)
    nodes[zero_coefficient] = IR.Const(IEEE32, PRESAGe._sign(IEEE32))
    p = PlanArtifact(
        spec;
        program = IR.Program(nodes; output = p.program.output),
        precision = p.precision,
        settings = p.settings,
    )
    layout = PolynomialPrecision(
        IEEE32;
        coefficient_formats = p.precision.coefficient_formats,
        stage_formats = fill(FloatFormat(8, 26), 2),
    )
    p = PRESAGe._reformat_polynomial(p, layout)
    @test p.program.nodes[last(PRESAGe._reciprocal_audit(p).coefficient_nodes)].bits ==
          PRESAGe._sign(IEEE32)
    @test certify_plan(PRESAGe._read_plan(PRESAGe._plan_data(p))).status == :certified
    cpu_check(p, [round_ieee(3 // 2, IEEE16)]; float_backend = :ac_std_float)
    optimized = optimize_precision(
        baseline;
        max_attempts = 3,
        job_timeout = 60,
        total_timeout = 180,
    )
    @test optimized.status == :certified
    @test optimized.selected !== nothing
    @test optimized.selected.plan.settings["transformation"] == "reciprocal"
    @test precision_cost(optimized.selected.plan).coefficient_bits <
          precision_cost(baseline.plan).coefficient_bits
    check_reciprocal(
        optimized.selected,
        [round_ieee(x, IEEE16) for x in (1 // 16, 3 // 2, 16)],
    )
    mktempdir() do directory
        contract, config, artifact =
            joinpath.(Ref(directory), ("contract.toml", "search.toml", "result"))
        write_plan(contract, PlanArtifact(baseline.plan.spec))
        search = PolynomialSearchConfig(
            degrees = [7],
            internal_formats = [baseline.plan.precision.coordinate_format],
            transformation = :reciprocal,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        )
        write_search_config(config, search)
        data = TOML.parsefile(config)
        @test data["schema_version"] == 5
        @test read_search_config(config).transformation == :reciprocal
        generated = generate_main([
            contract,
            artifact,
            "--search-config=$config",
            "--backend=ap_fixed",
            "--float-backend=ac_std_float",
        ])
        @test generated.program !== nothing
        stored = read_plan(joinpath(artifact, "plan.toml"))
        @test stored.settings["transformation"] == "reciprocal"
        @test TOML.parsefile(joinpath(artifact, "search.toml"))["schema_version"] == 5
        cpu_check(
            stored,
            [round_ieee(x, IEEE16) for x in (1 // 16, 3 // 2, 16)];
            backend = :ap_fixed,
            float_backend = :ac_std_float,
            generated_directory = artifact,
        )
        replay = joinpath(directory, "replay")
        generated = generate_main([
            joinpath(artifact, "plan.toml"),
            replay,
            "--backend=ac_fixed",
            "--float-backend=ac_std_float",
            "--certify=true",
        ])
        @test generated.program !== nothing
        cpu_check(
            read_plan(joinpath(replay, "plan.toml")),
            [round_ieee(3 // 2, IEEE16)];
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            generated_directory = replay,
        )
        data["schema_version"] = 4
        @test_throws ArgumentError PRESAGe._read_search_config(data)
    end
end
