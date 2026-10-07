isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
const exp_results = Dict{Symbol, CertificationResult}()

function check_exp(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan = result.plan
    path = only(PRESAGe._exp_audit(plan).paths)
    with_oracle(plan.spec; backend = :mpfr) do oracle
        for word in words
            x = decode_ieee(word, plan.spec.input_format)
            trace = interpret_trace(plan, word)
            outside =
                x.value !== nothing &&
                !(plan.spec.domain[1] <= x.value <= plan.spec.domain[2])
            numerical = any(
                i ->
                    plan.program.nodes[i] isa
                    Union{IR.Mul, IR.Add, IR.FMA, IR.ScaleByExponent},
                keys(trace.values),
            )
            if x.kind == :nan || outside
                @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                @test !numerical
                continue
            elseif x.kind == :infinity
                @test trace.bits == (x.negative ? 0 : PRESAGe._inf(plan.spec.output_format))
                @test !numerical
                continue
            elseif x.kind == :zero
                @test trace.bits == round_ieee(1, plan.spec.output_format)
                @test !numerical
                continue
            end
            ref = reference(oracle, word)
            @test ref.status == :resolved && ref.enclosure !== nothing
            y = decode_ieee(trace.bits, plan.spec.output_format)
            @test y.value !== nothing && !y.negative
            lo, hi = map(b -> b.significand * PRESAGe._pow2(b.exponent), ref.enclosure)
            @test max(abs(y.value - lo), abs(y.value - hi)) <= result.total_bound
            ranges = Dict(b.node => b.range for b in only(result.paths).ranges)
            @test all(trace.values) do (i, v)
                f = IR.format(plan.program, i)
                f isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(v.bits, f).value
                haskey(ranges, i) && q !== nothing && ranges[i][1] <= q <= ranges[i][2]
            end
            k = decode_fixed(trace.values[path.exponent_node].bits, path.exponent_format)
            selected = trace.values[path.selection_product]
            @test k == PRESAGe._rounded_integer(
                decode_ieee(selected.bits, selected.format).value,
                :nearest_even,
            )
        end
    end
end

@testset "Dynamic exponent scaling and direct output quantization" begin
    ef = FixedFormat(8, 8)
    words = collect(UInt64(0):UInt64(0xffff))
    for k in (-15, -1, 1)
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = IEEE16);
            program = IR.Program([
                IR.Input(IEEE16),
                IR.constant(k, ef),
                IR.ScaleByExponent(1, 2, IEEE16),
            ]),
        )
        for word in words
            x = decode_ieee(word, IEEE16)
            expected =
                x.kind == :nan ? PRESAGe._nan(IEEE16) :
                x.kind == :infinity ? word :
                round_ieee(x.value * PRESAGe._pow2(k), IEEE16; zero_sign = x.negative)
            @test evaluate_bits(plan, word) == expected
        end
        cpu_check(plan, words; float_backend = :native, public_api = true)
        cpu_check(
            plan,
            words;
            float_backend = :ac_std_float,
            backend = :ac_fixed,
            public_api = true,
        )
        data = PRESAGe._plan_data(plan)
        @test data["schema_version"] == 11
        @test PRESAGe._program_data(
            read_plan(IOBuffer(sprint(write_plan, plan))).program,
        ) == PRESAGe._program_data(plan.program)
        data["schema_version"] = 10
        @test_throws ArgumentError PRESAGe._read_plan(data)
    end
    for source in (FixedFormat(24, 4), IEEE64)
        value = 3 // 4 + 1 // 1024 + 1 // 2^20
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = IEEE32, output_format = IEEE16);
            program = IR.Program([
                IR.Input(IEEE32),
                IR.constant(value, source),
                IR.constant(-15, ef),
                IR.ScaleByExponent(2, 3, IEEE16),
            ]),
        )
        @test evaluate_bits(plan, 0) == 385
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            cpu_check(
                plan,
                UInt64[0, 0x80000000, 0x7f800000];
                backend,
                float_backend,
                public_api = true,
            )
        end
    end
    for (source, k, value) in (
        (FixedFormat(320, 300), -128, 3PRESAGe._pow2(292)),
        (FixedFormat(320, 8), 127, 3PRESAGe._pow2(-312)),
    )
        plan = PlanArtifact(
            FunctionSpec("x"; output_format = IEEE64);
            program = IR.Program([
                IR.Input(IEEE32),
                IR.constant(value, source),
                IR.constant(k, ef),
                IR.ScaleByExponent(2, 3, IEEE64),
            ]),
        )
        @test evaluate_bits(plan, 0) == round_ieee(value * PRESAGe._pow2(k), IEEE64)
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            cpu_check(plan, UInt64[0]; backend, float_backend, public_api = true)
        end
    end
    p = IR.Program([
        IR.Input(FloatFormat(30, 3)),
        IR.constant(1, ef),
        IR.ScaleByExponent(1, 2, IEEE32),
    ])
    @test_throws ArgumentError emit_cpp(IOBuffer(), p; float_backend = :ac_std_float)
    input, output = FloatFormat(8, 100), FloatFormat(11, 112)
    plan = PlanArtifact(
        FunctionSpec("x"; input_format = input, output_format = output);
        program = IR.Program([
            IR.Input(input),
            IR.constant(-15, ef),
            IR.ScaleByExponent(1, 2, output),
        ]),
    )
    wide_words = [round_ieee(x, input) for x in (0, 1, -3, 1 // 3)]
    for backend in (:portable, :ac_fixed, :ap_fixed)
        cpu_check(
            plan,
            wide_words;
            backend,
            float_backend = :ac_std_float,
            public_api = true,
        )
    end
    for k in (big(10)^50, -big(10)^50)
        huge = FixedFormat(172, 172)
        p = IR.Program([
            IR.Input(IEEE16),
            IR.constant(k, huge),
            IR.ScaleByExponent(1, 2, IEEE16),
        ])
        @test evaluate_bits(p, round_ieee(1, IEEE16)) == (k > 0 ? PRESAGe._inf(IEEE16) : 0)
        @test_throws ArgumentError emit_cpp(IOBuffer(), p; float_backend = :native)
        @test_throws ArgumentError emit_cpp(IOBuffer(), p; float_backend = :ac_std_float)
    end
    for exponent in (FixedFormat(8, 4), FixedFormat(8, 8; signed = false), IEEE32)
        @test_throws ArgumentError IR.Program([
            IR.Input(IEEE32),
            IR.constant(1, exponent),
            IR.ScaleByExponent(1, 2, IEEE32),
        ])
    end
    @test_throws ArgumentError IR.ScaleByExponent(1, 2, IEEE32; rounding = :down)
    p = PlanArtifact(
        FunctionSpec("x");
        program = IR.Program([
            IR.Input(IEEE32),
            IR.constant(-1, ef),
            IR.ScaleByExponent(1, 2, IEEE32),
        ]),
    )
    cpu_check(
        p,
        [round_ieee(1, IEEE32)];
        public_api = true,
        host_rounding = :down,
        expected_error = "PRESAGe requires FE_TONEAREST",
    )
    # Integer exponent selection itself has explicit positive/negative even ties.
    f = FixedFormat(8, 8)
    p = IR.Program([IR.Input(IEEE64), IR.Convert(1, f), IR.Convert(2, IEEE64)])
    for x in (-5 // 2, -3 // 2, -1 // 2, 1 // 2, 3 // 2, 5 // 2)
        @test evaluate_bits(p, round_ieee(x, IEEE64)) ==
              round_ieee(PRESAGe._rounded_integer(PRESAGe._q(x), :nearest_even), IEEE64)
    end
end

@testset "Certified exp reduction and reconstruction" begin
    spec = FunctionSpec(
        "exp(x)";
        input_format = IEEE16,
        domain = (-65504, 5),
        absolute_error = 1 // 8,
    )
    search = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [9],
            internal_formats = [FixedFormat(72, 24)],
            transformation = :exp,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        ),
    )
    @test search.status == :certified
    search.status == :certified || error(search.attempts[end].reason)
    path = only(PRESAGe._exp_audit(search.selected.plan).paths)
    words = UInt64[
        0,
        0x8000,
        1,
        0x8001,
        0x3c00,
        0xbc00,
        0x4500,
        0xfbff,
        0x7c00,
        0xfc00,
        0x7fff,
        0xffff,
    ]
    for evaluation in (:fma, :separate)
        result =
            evaluation == :fma ? search.selected :
            certify_plan(
                exp_polynomial_plan(
                    spec,
                    path.coefficients,
                    path.log2,
                    path.inverse_log2;
                    precision = search.selected.plan.precision,
                    evaluation,
                ),
            )
        exp_results[evaluation] = result
        check_exp(result, words)
        @test length(result.paths) == 1
        @test only(result.paths).output_rounding == 1 // 16
        @test PRESAGe._parse_rational(result.settings["ideal_residual_radius"]) <= 1 // 2
        @test PRESAGe._parse_rational(result.settings["residual_error_bound"]) > 0
        @test result.settings["maximum_exponent"] == "7"
        @test implementation_cost(result.plan).exponent_scalings == 1
        @test implementation_cost(result.plan).fmas == (evaluation == :fma ? 10 : 0)
        report = PRESAGe._certificate_data(result)
        @test report["transformation"]["kind"] == "exp"
        @test report["transformation"]["reduction_format"] == "binary64"
        @test certify_plan(
            read_plan(IOBuffer(sprint(write_plan, result.plan))),
        ).total_bound == result.total_bound
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            cpu_check(result.plan, words; backend, float_backend, public_api = true)
        end
    end
    # Actual exponent transitions follow the stored reciprocal constant and
    # rounded multiplication. Adjacent input encodings cover both sides.
    boundaries = UInt64[]
    for k = -24:7
        threshold = (PRESAGe._q(k) + 1 // 2) / path.inverse_log2
        word = round_ieee(threshold, IEEE16)
        append!(boundaries, [word - 1, word, word + 1])
    end
    for result in values(exp_results)
        check_exp(result, boundaries)
    end
end

@testset "Exhaustive binary16 exp verification" begin
    words = collect(UInt64(0):UInt64(0xffff))
    check_exp(exp_results[:fma], words)
    check_exp(exp_results[:separate], words)
    for backend in (:portable, :ac_fixed, :ap_fixed),
        float_backend in (:native, :ac_std_float)

        cpu_check(exp_results[:fma].plan, words; backend, float_backend, public_api = true)
    end
end

@testset "Exp underflow, exceptional branches and proof refusals" begin
    baseline = exp_results[:fma]
    path = only(PRESAGe._exp_audit(baseline.plan).paths)
    for domain in
        ((0, 0), (-1, 1), (1, 1), (-65504, -65500), (-32, -20), (2, 5), (-1 // 3, 1 // 3))
        spec =
            FunctionSpec("exp(x)"; input_format = IEEE16, domain, absolute_error = 1 // 8)
        result = certify_plan(
            exp_polynomial_plan(
                spec,
                path.coefficients,
                path.log2,
                path.inverse_log2;
                precision = baseline.plan.precision,
                evaluation = :fma,
            ),
        )
        words = UInt64[
            0,
            0x8000,
            1,
            0x8001,
            0x3c00,
            0xbc00,
            0x4500,
            0xfbff,
            0x7c00,
            0xfc00,
            0xffff,
        ]
        check_exp(result, words)
        if domain == (0, 0)
            @test result.total_bound == 0 && isempty(result.paths)
            @test PRESAGe._certificate_data(result)["transformation"]["zero_only"]
            exact = search_polynomial(
                spec,
                PolynomialSearchConfig(
                    degrees = [0],
                    internal_formats = [FixedFormat(32, 8)],
                    transformation = :exp,
                    evaluation = :fma,
                    job_timeout = 60,
                    total_timeout = 90,
                ),
            )
            @test exact.status == :certified && exact.selected.total_bound == 0
        elseif domain == (-65504, -65500)
            @test result.total_bound < 1 // 2^20
        end
        cpu_check(result.plan, words; backend = :ac_fixed, float_backend = :ac_std_float)
    end
    for spec in (
        FunctionSpec("exp(x)"),
        FunctionSpec("expm1(x)"; domain = (-1, 1)),
        FunctionSpec("exp(x)"; input_format = FixedFormat(16, 8), domain = (-1, 1)),
        FunctionSpec("exp(x)"; output_format = FixedFormat(16, 8), domain = (-1, 1)),
    )
        @test_throws ArgumentError exp_polynomial_plan(spec, [1], 1, 1)
    end
    @test_throws ArgumentError PolynomialSearchConfig(
        degrees = [9],
        internal_formats = [IEEE64],
        transformation = :exp,
        segments = [2],
    )
    overflow = FunctionSpec(
        "exp(x)";
        input_format = IEEE16,
        domain = (0, 20),
        absolute_error = 100,
    )
    refused = certify_plan(
        exp_polynomial_plan(
            overflow,
            path.coefficients,
            path.log2,
            path.inverse_log2;
            precision = baseline.plan.precision,
            evaluation = :fma,
        ),
    )
    @test refused.status == :proof_failed && occursin("overflow", refused.reason)
    @test TOML.parse(sprint(write_certificate, refused))["status"] == "proof_failed"
    for kind in (IR.ScaleByExponent, IR.Convert, IR.FMA, IR.Select)
        nodes = collect(baseline.plan.program.nodes)
        i = findfirst(
            n -> n isa kind && (kind != IR.Convert || n.format isa FixedFormat),
            nodes,
        )
        n = nodes[i]
        nodes[i] =
            kind == IR.ScaleByExponent ? IR.Convert(n.source, n.format) :
            kind == IR.Convert ? IR.Convert(n.source, n.format; rounding = :toward_zero) :
            kind == IR.FMA ? IR.FMA(n.a, n.b, n.a, n.format) :
            IR.Select(n.condition, n.no, n.yes)
        # Float->integer conversion policy must also match the fixed format.
        kind == IR.Convert && (
            nodes[i] = IR.Convert(
                n.source,
                FixedFormat(n.format.width, n.format.integer_bits; rounding = :toward_zero),
            )
        )
        mutated = PlanArtifact(
            baseline.plan.spec;
            program = IR.Program(nodes; output = baseline.plan.program.output),
            precision = baseline.plan.precision,
            settings = baseline.plan.settings,
        )
        r = certify_plan(mutated)
        @test r.status == :unsupported_domain
        @test !haskey(TOML.parse(sprint(write_certificate, r)), "coverage")
    end
    bad = certify_plan(
        exp_polynomial_plan(
            baseline.plan.spec,
            path.coefficients,
            path.log2,
            1;
            precision = baseline.plan.precision,
            evaluation = :fma,
        ),
    )
    @test bad.status == :proof_failed && occursin("reduced domain", bad.reason)
    tight = FunctionSpec(
        "exp(x)";
        input_format = IEEE16,
        domain = baseline.plan.spec.domain,
        absolute_error = 1 // 2^24,
    )
    @test certify_plan(
        exp_polynomial_plan(
            tight,
            path.coefficients,
            path.log2,
            path.inverse_log2;
            precision = baseline.plan.precision,
            evaluation = :fma,
        ),
    ).status == :bound_exceeds_budget
end

@testset "Exp guard bits, custom formats and individual precision" begin
    baseline = exp_results[:fma]
    path = only(PRESAGe._exp_audit(baseline.plan).paths)
    for (input, output, internal) in (
        (FloatFormat(2, 3), IEEE32, IEEE64),
        (FloatFormat(8, 100), FloatFormat(11, 112), FixedFormat(120, 24)),
        (IEEE64, IEEE64, IEEE64),
    )
        spec = FunctionSpec(
            "exp(x)";
            input_format = input,
            output_format = output,
            domain = (-3, 1),
            absolute_error = output == IEEE32 ? 1 // 2^21 : 1 // 2^24,
        )
        result = certify_plan(
            exp_polynomial_plan(
                spec,
                path.coefficients,
                path.log2,
                path.inverse_log2;
                internal_format = internal,
                evaluation = :fma,
            ),
        )
        words =
            input == FloatFormat(2, 3) ?
            collect(UInt64(0):UInt64(PRESAGe._wordmask(input))) :
            [round_ieee(x, input) for x in (-3, -1, -1 // 3, 0, 1 // 3, 1)]
        check_exp(result, words)
        for backend in (:portable, :ac_fixed, :ap_fixed)
            cpu_check(
                result.plan,
                words;
                backend,
                float_backend = :ac_std_float,
                public_api = true,
            )
        end
    end
    coordinate = FixedFormat(72, 24)
    precision = PolynomialPrecision(
        coordinate;
        coefficient_formats = [FixedFormat(72 - mod(i, 3), 24) for i = 1:10],
        stage_formats = [FixedFormat(72 - mod(i, 4), 24) for i = 1:10],
    )
    result = certify_plan(
        exp_polynomial_plan(
            baseline.plan.spec,
            path.coefficients,
            path.log2,
            path.inverse_log2;
            precision,
            evaluation = :fma,
        ),
    )
    check_exp(result, UInt64[1, 0x3c00, 0xbc00, 0x4500, 0xfbff])
    @test result.plan.precision == precision
    for backend in (:portable, :ac_fixed, :ap_fixed)
        cpu_check(
            result.plan,
            UInt64[1, 0x3c00, 0xbc00, 0x4500, 0xfbff];
            backend,
            public_api = true,
        )
    end
end

@testset "Exp precision search, CLI generation and replay" begin
    baseline = exp_results[:fma]
    optimized = optimize_precision(
        baseline;
        max_attempts = 3,
        bit_step = 4,
        job_timeout = 60,
        total_timeout = 180,
    )
    @test optimized.status == :certified
    @test any(a -> a.accepted && a.kind != :baseline, optimized.attempts)
    @test precision_cost(optimized.selected.plan).coefficient_bits +
          precision_cost(optimized.selected.plan).stage_bits <
          precision_cost(baseline.plan).coefficient_bits +
          precision_cost(baseline.plan).stage_bits
    check_exp(optimized.selected, UInt64[0, 1, 0x3c00, 0xbc00, 0x4500, 0xfbff, 0x7c00])
    config = PolynomialSearchConfig(
        degrees = [9],
        internal_formats = [FixedFormat(72, 24)],
        transformation = :exp,
        evaluation = :fma,
        job_timeout = 60,
        total_timeout = 90,
    )
    data = PRESAGe._search_config_data(config)
    @test data["schema_version"] == 10
    @test PRESAGe._read_search_config(data).transformation == :exp
    for version = 1:9
        bad = deepcopy(data)
        bad["schema_version"] = version
        @test_throws ArgumentError PRESAGe._read_search_config(bad)
    end
    mktempdir() do directory
        contract, configuration, generated, replayed =
            joinpath.(
                Ref(directory),
                ("contract.toml", "search.toml", "generated", "replayed"),
            )
        write_plan(contract, PlanArtifact(baseline.plan.spec))
        write_search_config(configuration, config)
        plan = generate_main([
            contract,
            generated,
            "--search-config=$configuration",
            "--backend=ap_fixed",
            "--float-backend=ac_std_float",
        ])
        @test TOML.parsefile(joinpath(generated, "search.toml"))["schema_version"] == 10
        @test TOML.parsefile(joinpath(generated, "plan.toml"))["schema_version"] == 11
        @test TOML.parsefile(joinpath(generated, "certificate.toml"))["transformation"]["kind"] ==
              "exp"
        replay = generate_main([
            joinpath(generated, "plan.toml"),
            replayed,
            "--backend=ap_fixed",
            "--float-backend=ac_std_float",
        ])
        @test PRESAGe._program_data(plan.program) == PRESAGe._program_data(replay.program)
        @test read(joinpath(generated, "evaluator.hpp"), String) ==
              read(joinpath(replayed, "evaluator.hpp"), String)
        cpu_check(
            plan,
            UInt64[0, 1, 0x3c00, 0xbc00, 0x4500, 0xfbff, 0x7c00, 0xfc00];
            backend = :ap_fixed,
            float_backend = :ac_std_float,
            generated_directory = generated,
        )
    end
end
