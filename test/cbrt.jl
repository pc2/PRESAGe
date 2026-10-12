isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))

function check_cbrt(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan, bound = result.plan, result.total_bound
    ranges =
        isempty(result.paths) ? Dict() :
        Dict(b.node => b.range for b in only(result.paths).ranges)
    for word in words
        input = decode_ieee(word, plan.spec.input_format)
        trace = interpret_trace(plan, word)
        expected = if input.kind == :infinity
            PRESAGe._inf(plan.spec.output_format) |
            (input.negative ? PRESAGe._sign(plan.spec.output_format) : 0)
        elseif input.kind == :zero && plan.spec.domain[1] <= 0 <= plan.spec.domain[2]
            input.negative ? PRESAGe._sign(plan.spec.output_format) : UInt64(0)
        elseif input.value === nothing ||
               !(plan.spec.domain[1] <= input.value <= plan.spec.domain[2])
            PRESAGe._nan(plan.spec.output_format)
        else
            nothing
        end
        if expected !== nothing
            @test trace.bits == expected
            @test !any(keys(trace.values)) do i
                plan.program.nodes[i] isa Union{
                    IR.RootArgument,
                    IR.ScaleByInputExponent,
                    IR.Mul,
                    IR.Add,
                    IR.FMA,
                    IR.Quantize,
                }
            end
            continue
        end
        output = decode_ieee(trace.bits, plan.spec.output_format)
        @test output.value !== nothing
        output.value === nothing && error("nonfinite cbrt output")
        @test output.negative == input.negative
        # Cubing is strictly increasing over the reals: these exact rational
        # inequalities independently prove |output-cbrt(input)| ≤ B.
        @test (output.value - bound)^3 <= input.value <= (output.value + bound)^3
        @test all(trace.values) do (i, value)
            f = IR.format(plan.program, i)
            f isa Union{FloatFormat, FixedFormat} || return true
            q = PRESAGe._decode_input(value.bits, f).value
            haskey(ranges, i) && q !== nothing && ranges[i][1] <= q <= ranges[i][2]
        end
    end
end

@testset "Exact cube root argument and exponent splitting" begin
    @test split_exponent(-1, 3) == (-1, 2)
    @test split_exponent(-4, 3) == (-2, 2)
    for f in (IEEE16, FloatFormat(2, 3))
        out = PRESAGe._root_argument_format(f, 3)
        @test out.fraction_bits == f.fraction_bits
        @test out.exponent_bits >= 3
        for word = UInt64(0):UInt64(PRESAGe._wordmask(f))
            x = decode_ieee(word, f)
            if x.kind != :finite
                @test_throws DomainError PRESAGe._root_argument(word, f, 3)
                continue
            end
            _, e = normalize_float(word, f)
            q, r = split_exponent(e, 3)
            t = decode_ieee(PRESAGe._root_argument(word, f, 3), out)
            @test 1 <= t.value < 8
            @test !t.negative
            @test t.value * PRESAGe._pow2(3q) == abs(x.value)
        end
    end
    for f in (FloatFormat(2, 100), FloatFormat(8, 4096))
        out = PRESAGe._root_argument_format(f, 3)
        for word in (big(1), (big(1) << f.fraction_bits) - 1, big(PRESAGe._inf(f)) - 1)
            _, e = normalize_float(word, f)
            q, r = split_exponent(e, 3)
            @test decode_ieee(PRESAGe._root_argument(word, f, 3), out).value *
                  PRESAGe._pow2(3q) == decode_ieee(word, f).value
        end
    end
end

@testset "Cube root IR reconstruction and official CPU headers" begin
    for f in (IEEE16, FloatFormat(2, 3), FloatFormat(8, 100))
        out = PRESAGe._root_argument_format(f, 3)
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = f, output_format = out);
            program = IR.Program([IR.Input(f), IR.RootArgument(1, 3)]),
        )
        words =
            f == IEEE16 || f == FloatFormat(2, 3) ?
            [
                w for w = UInt64(0):UInt64(PRESAGe._wordmask(f)) if
                decode_ieee(w, f).kind == :finite
            ] :
            [
                big(1),
                (big(1) << f.fraction_bits) - 1,
                big(1) << f.fraction_bits,
                big(PRESAGe._inf(f)) - 1,
            ]
        @test all(w -> evaluate_bits(plan, w) == PRESAGe._root_argument(w, f, 3), words)
        cpu_check(plan, words; float_backend = :ac_std_float, public_api = true)
        f == IEEE16 && cpu_check(plan, words; float_backend = :native)
        @test IR.format(plan.program, 2) == out
    end
    value = 3 // 4 + 1 // 1024 + 1 // 2^20
    plan = PlanArtifact(
        FunctionSpec("cbrt(x)"; input_format = IEEE32, output_format = IEEE16);
        program = IR.Program([
            IR.Input(IEEE32),
            IR.constant(value, FixedFormat(24, 4)),
            IR.ScaleByInputExponent(2, 1, 1, IEEE16; divisor = 3),
        ]),
    )
    words = [
        round_ieee(PRESAGe._pow2(e), IEEE32) for
        e in (-46, -45, -44, -4, -3, -2, -1, 0, 1, 2, 3, 4, 30)
    ]
    @test evaluate_bits(plan, round_ieee(PRESAGe._pow2(-45), IEEE32)) == 385
    for word in words
        _, e = normalize_float(word, IEEE32)
        @test evaluate_bits(plan, word) ==
              round_ieee(value * PRESAGe._pow2(fld(e, 3)), IEEE16)
    end
    for backend in (:portable, :ac_fixed, :ap_fixed),
        float_backend in (:native, :ac_std_float)

        cpu_check(plan, words; backend, float_backend, public_api = true)
    end
    @test_throws ArgumentError IR.RootArgument(1, 1)
    @test_throws ArgumentError IR.RootArgument(1, 4)
    @test_throws ArgumentError IR.ScaleByInputExponent(1, 1, 1, IEEE16; divisor = 4)
    @test_throws ArgumentError PRESAGe._root_argument(1, IEEE16, 4)
end

cbrt_results = Dict{Symbol, CertificationResult}()
@testset "Certified signed cbrt mantissa kernel" begin
    spec = FunctionSpec(
        "cbrt( x )";
        input_format = IEEE16,
        domain = (-65504, 65504),
        absolute_error = 1 // 16,
    )
    search = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [13],
            internal_formats = [FixedFormat(96, 24)],
            transformation = :cbrt,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        ),
    )
    @test search.status == :certified
    search.selected === nothing && error(only(search.attempts).reason)
    audit = PRESAGe._root_audit(search.selected.plan)
    for evaluation in (:fma, :separate)
        result =
            evaluation == :fma ? search.selected :
            certify_plan(
                root_polynomial_plan(
                    spec,
                    only(audit.paths).coefficients;
                    precision = audit.precision,
                    evaluation,
                ),
            )
        cbrt_results[evaluation] = result
        words = [
            UInt64(0),
            UInt64(0x8000),
            UInt64(1),
            UInt64(0x8001),
            UInt64(0x7bff),
            UInt64(0xfbff),
            UInt64(0x7c00),
            UInt64(0xfc00),
            UInt64(0x7c01),
            UInt64(0xffff),
        ]
        for e in (-24, -14, -7, -6, -5, -4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 6, 14, 15),
            sign in (-1, 1)

            push!(words, round_ieee(sign * PRESAGe._pow2(e), IEEE16))
        end
        check_cbrt(result, words)
        path = only(result.paths)
        @test path.domain == spec.domain
        @test path.coordinate_error == 0 &&
              path.arithmetic_error > 0 &&
              path.output_rounding > 0
        @test path.approximation[1] == 0
        report = PRESAGe._certificate_data(result)
        @test report["transformation"]["kind"] == "cbrt"
        @test report["transformation"]["exponent_divisor"] == 3
        @test report["transformation"]["input_exponents"] == [-24, 15]
        @test report["transformation"]["maximum_error_scale"] == "32/1"
        @test report["transformation"]["norm_domain"] == ["1/1", "8/1"]
        @test report["coverage"]["infinities"] == "both signed infinities preserved"
        @test implementation_cost(result.plan).normalizations ==
              implementation_cost(result.plan).exponent_scalings ==
              1
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            cpu_check(result.plan, words; backend, float_backend, public_api = true)
        end
        replay = PRESAGe._read_plan(PRESAGe._plan_data(result.plan))
        @test PRESAGe._program_data(replay.program) ==
              PRESAGe._program_data(result.plan.program)
        @test certify_plan(replay).status == :certified
    end
end

@testset "Exhaustive binary16 cbrt verification" begin
    result = cbrt_results[:fma]
    words = collect(UInt64(0):UInt64(0xffff))
    check_cbrt(result, words)
    cpu_check(result.plan, words; float_backend = :native)
    cpu_check(result.plan, words; backend = :ac_fixed, float_backend = :ac_std_float)
    cpu_check(result.plan, words; backend = :ap_fixed, float_backend = :ac_std_float)
end

@testset "Cbrt signed domains, zeros and proof refusal" begin
    baseline = cbrt_results[:fma]
    coefficients = only(PRESAGe._root_audit(baseline.plan).paths).coefficients
    for domain in ((-16, -1 // 8), (1 // 8, 16), (-16, 0), (0, 16), (-3 // 2, 1 // 4))
        spec =
            FunctionSpec("cbrt(x)"; input_format = IEEE16, domain, absolute_error = 1 // 16)
        result = certify_plan(
            root_polynomial_plan(
                spec,
                coefficients;
                precision = baseline.plan.precision,
                evaluation = :fma,
            ),
        )
        words = vcat(
            [
                UInt64(0),
                UInt64(0x8000),
                UInt64(1),
                UInt64(0x8001),
                UInt64(0x7c00),
                UInt64(0xfc00),
                UInt64(0x7fff),
            ],
            [round_ieee(x, IEEE16) for x in (domain[1], domain[2], -1, 1)],
        )
        check_cbrt(result, words)
        cpu_check(result.plan, words; backend = :ac_fixed, float_backend = :ac_std_float)
    end
    zero = FunctionSpec(
        "cbrt(x)";
        input_format = IEEE32,
        output_format = IEEE16,
        domain = (0, 0),
    )
    result = certified_polynomial(
        zero;
        degree = 13,
        internal_format = FixedFormat(2, 1),
        transformation = :cbrt,
    )
    @test result.status == :certified && result.total_bound == 0 && isempty(result.paths)
    @test isempty(PRESAGe._precision_proposals(result, 1, 0))
    @test PRESAGe._certificate_data(result)["transformation"]["zero_only"]
    words = [
        UInt64(0),
        PRESAGe._sign(IEEE32),
        UInt64(1),
        PRESAGe._inf(IEEE32),
        PRESAGe._inf(IEEE32) | PRESAGe._sign(IEEE32),
        PRESAGe._nan(IEEE32),
    ]
    check_cbrt(result, words)
    cpu_check(result.plan, words; float_backend = :ac_std_float)
    for expression in ("sqrt(x)", "x^(1/3)", "cbrt(x)+1")
        spec = FunctionSpec(
            expression;
            input_format = IEEE16,
            domain = baseline.plan.spec.domain,
            absolute_error = 1,
        )
        @test_throws ArgumentError root_polynomial_plan(spec, [1]; transformation = :cbrt)
        @test certify_plan(
            PlanArtifact(
                spec;
                program = baseline.plan.program,
                precision = baseline.plan.precision,
                settings = baseline.plan.settings,
            ),
        ).status == :unsupported_domain
    end
    @test_throws ArgumentError root_polynomial_plan(FunctionSpec("cbrt(x)"), [1])
    @test_throws ArgumentError root_polynomial_plan(
        FunctionSpec("cbrt(x)"; input_format = FixedFormat(16, 8), domain = (-1, 1)),
        [1],
    )
    @test_throws ArgumentError root_polynomial_plan(
        FunctionSpec("cbrt(x)"; output_format = FixedFormat(16, 8), domain = (-1, 1)),
        [1],
    )
    @test_throws ArgumentError PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [3],
        internal_formats = [IEEE32],
        transformation = :cbrt,
        segments = [2],
    )
    for kind in (IR.RootArgument, IR.ScaleByInputExponent, IR.CopySign, IR.Select)
        nodes = collect(baseline.plan.program.nodes)
        i = findfirst(n -> n isa kind, nodes)
        n = nodes[i]
        nodes[i] =
            kind == IR.RootArgument ? IR.RootArgument(n.source, 2) :
            kind == IR.ScaleByInputExponent ?
            IR.ScaleByInputExponent(
                n.source,
                n.input,
                n.multiplier,
                n.format;
                divisor = 2,
            ) :
            kind == IR.CopySign ?
            IR.Convert(n.source, IR.format(baseline.plan.program, i)) :
            IR.Select(n.condition, n.no, n.yes)
        @test certify_plan(
            PlanArtifact(
                baseline.plan.spec;
                program = IR.Program(nodes; output = baseline.plan.program.output),
                precision = baseline.plan.precision,
                settings = baseline.plan.settings,
            ),
        ).status == :unsupported_domain
    end
    strict = FunctionSpec(
        "cbrt(x)";
        input_format = IEEE16,
        domain = baseline.plan.spec.domain,
        absolute_error = 1 // 2^30,
    )
    @test certify_plan(
        PlanArtifact(
            strict;
            program = baseline.plan.program,
            precision = baseline.plan.precision,
            settings = baseline.plan.settings,
        ),
    ).status == :bound_exceeds_budget
    narrow = FunctionSpec(
        "cbrt(x)";
        input_format = IEEE16,
        output_format = FloatFormat(2, 3),
        domain = baseline.plan.spec.domain,
        absolute_error = 1,
    )
    @test certify_plan(
        root_polynomial_plan(
            narrow,
            coefficients;
            precision = baseline.plan.precision,
            evaluation = :fma,
        ),
    ).status == :proof_failed
end

@testset "Cbrt custom floating and individual precision" begin
    for (input, output, domain, internal, degree, target) in (
        (FloatFormat(2, 3), IEEE32, (-3, 3), FloatFormat(11, 48), 13, 1 // 4096),
        (
            FloatFormat(8, 100),
            FloatFormat(11, 112),
            (-8, 8),
            FixedFormat(136, 48),
            19,
            1 // 2^20,
        ),
    )
        spec = FunctionSpec(
            "cbrt(x)";
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
                transformation = :cbrt,
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
            input == FloatFormat(2, 3) ?
            collect(UInt64(0):UInt64(PRESAGe._wordmask(input))) :
            [round_ieee(x, input) for x in (-8, -4, -2, -1, -1 // 4, 0, 1 // 4, 1, 2, 4, 8)]
        check_cbrt(result, words)
        @test (
            internal isa FixedFormat ? only(result.paths).coordinate_error > 0 :
            only(result.paths).coordinate_error == 0
        )
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
    baseline = cbrt_results[:fma]
    p = baseline.plan.precision
    stages = collect(p.stage_formats)
    stages[1], stages[2] = FixedFormat(92, 20), FixedFormat(94, 22)
    precision = PolynomialPrecision(
        p.coordinate_format;
        coefficient_formats = p.coefficient_formats,
        stage_formats = stages,
    )
    result = certify_plan(PRESAGe._reformat_polynomial(baseline.plan, precision))
    words = [
        UInt64(1),
        UInt64(0x8001),
        round_ieee(-3, IEEE16),
        round_ieee(3, IEEE16),
        UInt64(0x7bff),
        UInt64(0xfbff),
    ]
    check_cbrt(result, words)
    for backend in (:portable, :ac_fixed, :ap_fixed)
        cpu_check(result.plan, words; backend, float_backend = :ac_std_float)
    end
    spec = FunctionSpec(
        "cbrt(x)";
        input_format = IEEE16,
        output_format = IEEE32,
        domain = (-8, 8),
        absolute_error = 4,
    )
    plan = root_polynomial_plan(spec, [1, 0]; internal_format = IEEE32, evaluation = :fma)
    coefficient = last(PRESAGe._root_audit(plan).coefficient_nodes)
    nodes = collect(plan.program.nodes)
    nodes[coefficient] = IR.Const(IEEE32, PRESAGe._sign(IEEE32))
    plan = PlanArtifact(
        spec;
        program = IR.Program(nodes; output = plan.program.output),
        precision = plan.precision,
        settings = plan.settings,
    )
    precision = PolynomialPrecision(
        IEEE32;
        coefficient_formats = plan.precision.coefficient_formats,
        stage_formats = fill(FloatFormat(8, 26), 2),
    )
    plan = PRESAGe._reformat_polynomial(plan, precision)
    @test plan.program.nodes[last(PRESAGe._root_audit(plan).coefficient_nodes)].bits ==
          PRESAGe._sign(IEEE32)
    @test certify_plan(PRESAGe._read_plan(PRESAGe._plan_data(plan))).status == :certified
    cpu_check(
        plan,
        [round_ieee(-3 // 2, IEEE16), round_ieee(3 // 2, IEEE16)];
        float_backend = :ac_std_float,
    )
end

@testset "Cbrt precision search, CLI generation and replay" begin
    baseline = cbrt_results[:fma]
    optimized = optimize_precision(
        baseline;
        max_attempts = 3,
        job_timeout = 60,
        total_timeout = 180,
    )
    @test optimized.status == :certified && any(a -> a.accepted, optimized.attempts)
    @test optimized.selected.plan.settings["transformation"] == "cbrt"
    words = [
        UInt64(1),
        UInt64(0x8001),
        round_ieee(-1, IEEE16),
        round_ieee(1, IEEE16),
        UInt64(0x7bff),
        UInt64(0xfbff),
    ]
    check_cbrt(optimized.selected, words)
    cpu_check(
        optimized.selected.plan,
        words;
        backend = :ac_fixed,
        float_backend = :ac_std_float,
    )
    data = PRESAGe._plan_data(baseline.plan)
    @test data["schema_version"] == 8
    data["schema_version"] = 7
    @test_throws ArgumentError PRESAGe._read_plan(data)
    config = PolynomialSearchConfig(
        degrees = [13],
        internal_formats = [FixedFormat(96, 24)],
        transformation = :cbrt,
        evaluation = :fma,
        job_timeout = 60,
        total_timeout = 90,
    )
    io = IOBuffer()
    write_search_config(io, config)
    data = TOML.parse(String(take!(io)))
    @test data["schema_version"] == 7
    @test read_search_config(IOBuffer(sprint(TOML.print, data))).transformation == :cbrt
    data["schema_version"] = 6
    @test_throws ArgumentError PRESAGe._read_search_config(data)
    mktempdir() do directory
        contract, config_path, artifact =
            joinpath.(Ref(directory), ("contract.toml", "search.toml", "result"))
        write_plan(contract, PlanArtifact(baseline.plan.spec))
        write_search_config(config_path, config)
        generated = generate_main([
            contract,
            artifact,
            "--search-config=$config_path",
            "--backend=ap_fixed",
            "--float-backend=ac_std_float",
        ])
        @test generated.program !== nothing
        @test TOML.parsefile(joinpath(artifact, "plan.toml"))["schema_version"] == 8
        @test TOML.parsefile(joinpath(artifact, "search.toml"))["schema_version"] == 7
        @test TOML.parsefile(joinpath(artifact, "certificate.toml"))["transformation"]["kind"] ==
              "cbrt"
        cpu_check(
            read_plan(joinpath(artifact, "plan.toml")),
            words;
            backend = :ap_fixed,
            float_backend = :ac_std_float,
            generated_directory = artifact,
        )
        replay = joinpath(directory, "replay")
        generated = generate_main([
            joinpath(artifact, "plan.toml"),
            replay,
            "--certify=true",
            "--backend=ac_fixed",
            "--float-backend=ac_std_float",
        ])
        @test generated.program !== nothing
        cpu_check(
            read_plan(joinpath(replay, "plan.toml")),
            words;
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            generated_directory = replay,
        )
    end
end

@testset "Cbrt inferred coordinate format" begin
    input, argument = FloatFormat(2, 3), FloatFormat(3, 3)
    spec = FunctionSpec(
        "cbrt(x)";
        input_format = input,
        output_format = IEEE32,
        domain = (-3, 3),
        absolute_error = 2,
    )
    plan = root_polynomial_plan(spec, [1, 0]; internal_format = argument, evaluation = :fma)
    audit = PRESAGe._root_audit(plan)
    @test IR.format(plan.program, 2) == argument
    @test only(audit.paths).coordinate == 2
    @test audit.coefficient_nodes == [3, 4]
    @test PRESAGe._program_data(PRESAGe._read_plan(PRESAGe._plan_data(plan)).program) ==
          PRESAGe._program_data(plan.program)
    result = certify_plan(plan)
    words = collect(UInt64(0):UInt64(PRESAGe._wordmask(input)))
    check_cbrt(result, words)
    cpu_check(plan, words; float_backend = :ac_std_float, public_api = true)
end

@testset "Cbrt Sollya and MPFR references" begin
    spec = FunctionSpec("cbrt(x)"; input_format = IEEE32, output_format = IEEE64)
    for x in (-27, -8, -2, -1, -1 // 8, -1 // 1024, 1 // 1024, 1 // 8, 1, 2, 8, 27)
        word = round_ieee(x, IEEE32)
        sollya = reference(spec, word; backend = :sollya)
        mpfr = reference(spec, word; backend = :mpfr)
        @test sollya.status == mpfr.status == :resolved
        @test sollya.bits == mpfr.bits
        if abs(x) in (1 // 8, 1, 8, 27)
            expected = abs(x) == 1 // 8 ? 1 // 2 : abs(x) == 1 ? 1 : abs(x) == 8 ? 2 : 3
            @test sollya.bits == round_ieee(sign(x) * expected, IEEE64)
        end
    end
    for backend in (:sollya, :mpfr),
        (word, expected) in (
            (UInt64(0), UInt64(0)),
            (PRESAGe._sign(IEEE32), PRESAGe._sign(IEEE64)),
            (PRESAGe._inf(IEEE32), PRESAGe._inf(IEEE64)),
            (
                PRESAGe._inf(IEEE32) | PRESAGe._sign(IEEE32),
                PRESAGe._inf(IEEE64) | PRESAGe._sign(IEEE64),
            ),
            (PRESAGe._nan(IEEE32), PRESAGe._nan(IEEE64)),
        )

        @test reference(spec, word; backend).bits == expected
    end
end

@testset "Cbrt expression parsing and ordinary polynomial proof" begin
    @test PRESAGe._exact_expression("cbrt( x )") == "x^(1/3)"
    @test_throws ArgumentError PRESAGe._exact_expression("cbrt(x)+x")
    @test_throws ArgumentError ReferenceOracle(FunctionSpec("cbrt(x)+x"))
    positive =
        FunctionSpec("cbrt(x)"; input_format = IEEE16, domain = (1, 8), absolute_error = 2)
    result = certify_plan(polynomial_plan(positive, [1]; internal_format = IEEE32))
    @test result.status == :certified
    # An unsupported native cbrt call can recover as x. It must not certify
    # the identity evaluator on a signed cbrt contract.
    negative = FunctionSpec(
        "cbrt(x)";
        input_format = IEEE16,
        domain = (-8, -1),
        absolute_error = 1 // 1024,
    )
    @test certify_plan(
        polynomial_plan(negative, [0, 1]; internal_format = IEEE32),
    ).status == :unsupported_domain
    search = search_polynomial(
        negative,
        PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1],
            internal_formats = [IEEE32],
            job_timeout = 60,
            total_timeout = 90,
        ),
    )
    @test search.status != :certified
    @test only(search.attempts).status == :generation_failed
    @test occursin("transformation=:cbrt", only(search.attempts).reason)
end
