isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
const atan_results = Dict{Symbol, CertificationResult}()

function check_atan(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan, bound = result.plan, result.total_bound
    layout = PRESAGe._atan_audit(plan)
    with_oracle(plan.spec; backend = :mpfr) do oracle
        for word in words
            x = decode_ieee(word, plan.spec.input_format)
            trace = interpret_trace(plan, word)
            outside =
                x.value !== nothing &&
                !(plan.spec.domain[1] <= x.value <= plan.spec.domain[2])
            if x.kind == :nan || outside
                @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                @test !any(
                    i ->
                        plan.program.nodes[i] isa
                        Union{IR.FloatReciprocal, IR.Mul, IR.Add, IR.FMA},
                    keys(trace.values),
                )
                continue
            elseif x.kind == :zero
                @test trace.bits ==
                      (x.negative ? PRESAGe._sign(plan.spec.output_format) : 0)
                @test !any(
                    i ->
                        plan.program.nodes[i] isa
                        Union{IR.FloatReciprocal, IR.Mul, IR.Add, IR.FMA},
                    keys(trace.values),
                )
                continue
            end
            y = decode_ieee(trace.bits, plan.spec.output_format)
            @test y.value !== nothing && y.negative == x.negative
            ref = reference(oracle, word)
            @test ref.status == :resolved && ref.enclosure !== nothing
            lo, hi = map(ref.enclosure) do b
                b.significand * PRESAGe._pow2(b.exponent)
            end
            @test max(abs(y.value - lo), abs(y.value - hi)) <= bound
            if x.kind == :infinity
                @test !any(
                    i ->
                        plan.program.nodes[i] isa
                        Union{IR.FloatReciprocal, IR.Mul, IR.Add, IR.FMA},
                    keys(trace.values),
                )
                continue
            end
            index = only(
                i for (i, path) in enumerate(result.paths) if
                path.domain[1] <= x.value <= path.domain[2]
            )
            ranges = Dict(b.node => b.range for b in result.paths[index].ranges)
            path = only(
                p for p in layout.paths if p.input_domain == result.paths[index].domain
            )
            @test haskey(trace.values, path.reciprocal) == (abs(x.value) > 1)
            @test haskey(trace.values, path.tail_value) == (abs(x.value) > 1)
            @test all(trace.values) do (i, value)
                f = IR.format(plan.program, i)
                f isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(value.bits, f).value
                haskey(ranges, i) && q !== nothing && ranges[i][1] <= q <= ranges[i][2]
            end
        end
    end
end

@testset "Rounded floating reciprocal IR and official headers" begin
    for f in (IEEE16, FloatFormat(2, 3))
        program = IR.Program([IR.Input(f), IR.FloatReciprocal(1)])
        words = collect(UInt64(0):UInt64(PRESAGe._wordmask(f)))
        for word in words
            x = decode_ieee(word, f)
            expected =
                x.kind == :nan ? PRESAGe._nan(f) :
                x.kind == :infinity ? (x.negative ? PRESAGe._sign(f) : 0) :
                x.kind == :zero ? (PRESAGe._inf(f) | (x.negative ? PRESAGe._sign(f) : 0)) :
                round_ieee(inv(x.value), f)
            @test evaluate_bits(program, word) == expected
        end
        plan = PlanArtifact(FunctionSpec("1/x"; input_format = f); program)
        @test PRESAGe._plan_data(plan)["schema_version"] == 10
        data = PRESAGe._plan_data(plan)
        data["schema_version"] = 9
        @test_throws ArgumentError PRESAGe._read_plan(data)
        cpu_check(plan, words; float_backend = :ac_std_float, public_api = true)
    end
    for f in (IEEE32, IEEE64, FloatFormat(8, 100))
        plan = PlanArtifact(
            FunctionSpec("1/x"; input_format = f);
            program = IR.Program([IR.Input(f), IR.FloatReciprocal(1)]),
        )
        one = round_ieee(1, f)
        words = [
            one - 1,
            one,
            one + 1,
            round_ieee(3, f),
            PRESAGe._inf(f) - 1,
            UInt64(1),
            PRESAGe._inf(f),
            PRESAGe._nan(f),
            PRESAGe._sign(f),
        ]
        for word in words
            x = decode_ieee(word, f)
            x.kind == :finite &&
                @test evaluate_bits(plan, word) == round_ieee(inv(x.value), f)
        end
        cpu_check(plan, words; float_backend = :ac_std_float, public_api = true)
        f in (IEEE32, IEEE64) &&
            cpu_check(plan, words; float_backend = :native, public_api = true)
        f == IEEE32 && cpu_check(
            plan,
            [round_ieee(3, f)];
            float_backend = :native,
            public_api = true,
            host_rounding = :down,
            expected_error = "PRESAGe requires FE_TONEAREST",
        )
    end
    @test_throws ArgumentError IR.Program([
        IR.Input(FixedFormat(8, 4)),
        IR.FloatReciprocal(1),
    ])
    negative_magnitude = IR.Program([
        IR.Input(IEEE32),
        IR.Const(IEEE32, PRESAGe._sign(IEEE32)),
        IR.CopySign(1, 2),
        IR.Convert(3, IEEE64),
    ])
    ranges, _ = PRESAGe._polynomial_ranges(
        negative_magnitude,
        (; domain = (PRESAGe._q(1), PRESAGe._q(2)), result = 3, negative = false),
    )
    @test ranges[3] == (-2, -1)
end

@testset "Certified atan central and reciprocal tails" begin
    spec = FunctionSpec(
        "atan(x)";
        input_format = IEEE16,
        domain = (-65504, 65504),
        absolute_error = 1 // 1024,
    )
    search = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [15],
            internal_formats = [FixedFormat(72, 24)],
            transformation = :atan,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        ),
    )
    @test search.status == :certified
    search.status == :certified || error(search.attempts[end].reason)
    layout = PRESAGe._atan_audit(search.selected.plan)
    words = UInt64[
        0,
        0x8000,
        1,
        0x8001,
        0x3bff,
        0x3c00,
        0x3c01,
        0xbbff,
        0xbc00,
        0xbc01,
        0x7bff,
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
                atan_polynomial_plan(
                    spec,
                    first(layout.paths).coefficients,
                    layout.pi2;
                    precision = layout.precision,
                    evaluation,
                ),
            )
        atan_results[evaluation] = result
        check_atan(result, words)
        @test length(result.paths) == 3
        @test result.paths[1].domain[2] == -decode_ieee(0x3c01, IEEE16).value
        @test result.paths[2].domain == (-1, 1)
        @test result.paths[3].domain[1] == decode_ieee(0x3c01, IEEE16).value
        @test all(p -> p.approximation[1] == 0, result.paths)
        @test result.paths[1].output_rounding ==
              result.paths[3].output_rounding ==
              1 // 2048
        @test result.paths[2].output_rounding == 1 // 4096
        @test PRESAGe._parse_rational(result.settings["pi2_error_bound"]) > 0
        @test implementation_cost(result.plan).divisions == 1
        @test implementation_cost(result.plan).fmas == (evaluation == :fma ? 8 : 0)
        report = PRESAGe._certificate_data(result)
        @test report["transformation"]["kind"] == "atan"
        @test report["transformation"]["reciprocal_format"] == "binary64"
        @test PRESAGe._program_data(
            read_plan(IOBuffer(sprint(write_plan, result.plan))).program,
        ) == PRESAGe._program_data(result.plan.program)
        @test certify_plan(
            read_plan(IOBuffer(sprint(write_plan, result.plan))),
        ).total_bound == result.total_bound
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            cpu_check(result.plan, words; backend, float_backend, public_api = true)
        end
    end
end

@testset "Exhaustive binary16 atan verification" begin
    words = collect(UInt64(0):UInt64(0xffff))
    check_atan(atan_results[:fma], words)
    check_atan(atan_results[:separate], words)
    for backend in (:portable, :ac_fixed, :ap_fixed),
        float_backend in (:native, :ac_std_float)

        cpu_check(atan_results[:fma].plan, words; backend, float_backend, public_api = true)
    end
end

@testset "Atan domains, exceptional limits and proof refusals" begin
    baseline = atan_results[:fma]
    layout = PRESAGe._atan_audit(baseline.plan)
    for domain in ((0, 0), (-1, 1), (1, 1), (-3, -2), (2, 65504), (-65504, 0), (-2, 2))
        spec = FunctionSpec(
            "atan(x)";
            input_format = IEEE16,
            domain,
            absolute_error = 1 // 1024,
        )
        result = certify_plan(
            atan_polynomial_plan(
                spec,
                first(layout.paths).coefficients,
                layout.pi2;
                precision = layout.precision,
                evaluation = :fma,
            ),
        )
        check_atan(
            result,
            UInt64[
                0,
                0x8000,
                1,
                0x3bff,
                0x3c00,
                0x3c01,
                0x4000,
                0x4200,
                0xbc00,
                0xbc01,
                0xc000,
                0xc200,
                0x7bff,
                0xfbff,
                0x7c00,
                0xfc00,
                0x7fff,
            ],
        )
        @test length(result.paths) == (
            domain == (0, 0) ? 0 : domain in ((-65504, 0),) ? 2 : domain == (-2, 2) ? 3 : 1
        )
        if domain == (0, 0)
            @test result.total_bound ==
                  PRESAGe._parse_rational(result.settings["infinity_error_bound"])
            exact = certified_polynomial(
                spec;
                degree = 1,
                internal_format = FixedFormat(72, 24),
                transformation = :atan,
            )
            @test exact.status == :certified && isempty(exact.paths)
        end
        cpu_check(
            result.plan,
            UInt64[0, 1, 0x3c00, 0x3c01, 0x4000, 0xbc00, 0xbc01, 0x7c00, 0xfc00];
            backend = :ac_fixed,
        )
    end
    for spec in (
        FunctionSpec("atan(x)"),
        FunctionSpec("atanpi(x)"; domain = (-1, 1)),
        FunctionSpec("atan(x)"; input_format = FixedFormat(16, 8), domain = (-1, 1)),
        FunctionSpec("atan(x)"; output_format = FixedFormat(16, 8), domain = (-1, 1)),
    )
        @test_throws ArgumentError atan_polynomial_plan(spec, [1], 3 // 2)
    end
    for degree in (0, 2, 32)
        @test_throws ArgumentError PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [degree],
            internal_formats = [IEEE64],
            transformation = :atan,
        )
    end
    @test_throws ArgumentError PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [15],
        internal_formats = [IEEE64],
        transformation = :atan,
        segments = [2],
    )
    for kind in (IR.FloatReciprocal, IR.Compare, IR.CopySign, IR.Select)
        nodes = collect(baseline.plan.program.nodes)
        i = findfirst(n -> n isa kind, nodes)
        n = nodes[i]
        nodes[i] =
            kind == IR.FloatReciprocal ?
            IR.Convert(n.source, IR.format(baseline.plan.program, i)) :
            kind == IR.Compare ? IR.Compare(:ge, n.a, n.b) :
            kind == IR.CopySign ? IR.CopySign(n.source, n.source) :
            IR.Select(n.condition, n.no, n.yes)
        mutated = PlanArtifact(
            baseline.plan.spec;
            program = IR.Program(nodes; output = baseline.plan.program.output),
            precision = layout.precision,
            settings = baseline.plan.settings,
        )
        refused = certify_plan(mutated)
        @test refused.status == :unsupported_domain
        report = TOML.parse(sprint(write_certificate, refused))
        @test report["status"] == "unsupported_domain" && !haskey(report, "coverage")
    end
    wrong_constant = atan_polynomial_plan(
        baseline.plan.spec,
        first(layout.paths).coefficients,
        0;
        precision = layout.precision,
        evaluation = :fma,
    )
    @test certify_plan(wrong_constant).status == :bound_exceeds_budget
    tight = FunctionSpec(
        "atan(x)";
        input_format = IEEE16,
        domain = baseline.plan.spec.domain,
        absolute_error = 1 // 2^30,
    )
    @test certify_plan(
        atan_polynomial_plan(
            tight,
            first(layout.paths).coefficients,
            layout.pi2;
            precision = layout.precision,
        ),
    ).status == :bound_exceeds_budget
end

@testset "Atan custom floating, guard bits and individual precision" begin
    baseline = atan_results[:fma]
    layout = PRESAGe._atan_audit(baseline.plan)
    for (input, output, domain, internal) in (
        (FloatFormat(2, 3), IEEE32, (-3, 3), IEEE64),
        (
            FloatFormat(8, 100),
            FloatFormat(11, 112),
            (-(big(1) << 100), big(1) << 100),
            FixedFormat(120, 24),
        ),
        (
            IEEE64,
            IEEE64,
            (
                -decode_ieee(PRESAGe._inf(IEEE64) - 1, IEEE64).value,
                decode_ieee(PRESAGe._inf(IEEE64) - 1, IEEE64).value,
            ),
            FixedFormat(128, 16),
        ),
    )
        spec = FunctionSpec(
            "atan(x)";
            input_format = input,
            output_format = output,
            domain,
            absolute_error = 1 // 2^20,
        )
        precision = PolynomialPrecision(
            internal;
            coefficient_formats = fill(internal, 8),
            stage_formats = internal isa FixedFormat ?
                            [
                FixedFormat(internal.width - 8 + i, internal.integer_bits) for i = 1:8
            ] : fill(internal, 8),
        )
        result = certify_plan(
            atan_polynomial_plan(
                spec,
                first(layout.paths).coefficients,
                layout.pi2;
                precision,
                evaluation = :fma,
            ),
        )
        words =
            input == FloatFormat(2, 3) ? collect(UInt64(0):UInt64(63)) :
            [
                round_ieee(q, input) for
                q in (domain[1], -2, -1, -1 // 2, 0, 1 // 2, 1, 2, domain[2])
            ]
        append!(
            words,
            [
                round_ieee(1, input) - 1,
                round_ieee(1, input) + 1,
                PRESAGe._inf(input),
                PRESAGe._inf(input) | PRESAGe._sign(input),
            ],
        )
        check_atan(result, words)
        reduction = PRESAGe._atan_audit(result.plan).reduction_format
        @test reduction.fraction_bits >= max(input.fraction_bits, output.fraction_bits)
        @test reduction.fraction_bits >= (
            internal isa FixedFormat ? PRESAGe._fraction(internal) : internal.fraction_bits
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
end

@testset "Atan precision search, generation and replay" begin
    baseline = atan_results[:fma]
    optimized = optimize_precision(
        baseline;
        max_attempts = 3,
        job_timeout = 60,
        total_timeout = 180,
    )
    @test optimized.status == :certified
    @test any(a -> a.accepted && a.kind != :baseline, optimized.attempts)
    @test precision_cost(optimized.selected.plan).coefficient_bits +
          precision_cost(optimized.selected.plan).stage_bits <
          precision_cost(baseline.plan).coefficient_bits +
          precision_cost(baseline.plan).stage_bits
    check_atan(
        optimized.selected,
        UInt64[1, 0x3bff, 0x3c00, 0x3c01, 0xbc01, 0x7bff, 0x7c00],
    )
    cpu_check(
        optimized.selected.plan,
        UInt64[1, 0x3bff, 0x3c01, 0xbc01, 0x7bff];
        backend = :ac_fixed,
    )
    config = PolynomialSearchConfig(
        degrees = [15],
        internal_formats = [FixedFormat(72, 24)],
        transformation = :atan,
        evaluation = :fma,
        job_timeout = 60,
        total_timeout = 90,
    )
    data = PRESAGe._search_config_data(config)
    @test data["schema_version"] == 9
    @test PRESAGe._read_search_config(data).transformation == :atan
    for version = 1:8
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
        @test TOML.parsefile(joinpath(generated, "search.toml"))["schema_version"] == 9
        @test TOML.parsefile(joinpath(generated, "plan.toml"))["schema_version"] == 10
        @test TOML.parsefile(joinpath(generated, "certificate.toml"))["transformation"]["kind"] ==
              "atan"
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
            UInt64[0, 1, 0x3c00, 0x3c01, 0xbc01, 0x7bff, 0x7c00];
            backend = :ap_fixed,
            float_backend = :ac_std_float,
            generated_directory = generated,
        )
    end
end

@testset "Atan directed infinity reference limits" begin
    for output in (IEEE16, IEEE32, IEEE64, FloatFormat(11, 112), FixedFormat(24, 4))
        spec = FunctionSpec("atan(x)"; output_format = output, domain = (-1, 1))
        for word in (UInt64(0x7f800000), UInt64(0xff800000))
            a = reference(spec, word; backend = :sollya)
            b = reference(spec, word; backend = :mpfr)
            @test a.status == b.status == :resolved
            @test a.bits == b.bits
            @test a.enclosure !== nothing && b.enclosure !== nothing
            aa, bb = map((a.enclosure, b.enclosure)) do bounds
                map(q -> q.significand * PRESAGe._pow2(q.exponent), bounds)
            end
            @test aa[1] <= bb[2] && bb[1] <= aa[2]
            @test (word == 0x7f800000 ? aa[1] > 0 : aa[2] < 0)
        end
    end
    @test reference(FunctionSpec("atan(x)"), 0x7f800000).bits == 0x3fc90fdb
    @test reference(FunctionSpec("atan(x)"), 0xff800000).bits == 0xbfc90fdb
    low = reference(
        FunctionSpec("atan(x)"; input_format = IEEE16, output_format = IEEE64),
        0x7c00;
        backend = :mpfr,
        config = OracleConfig(initial_precision = 12, max_precision = 12),
    )
    @test low.status == :unresolved && low.enclosure !== nothing
    @test reference(
        FunctionSpec("atan(x)"; output_format = FixedFormat(2, 1)),
        0x7f800000;
        backend = :mpfr,
    ).status == :overflow
end
