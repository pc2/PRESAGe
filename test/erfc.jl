isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
const erfc_results = Dict{Symbol, CertificationResult}()

function check_erfc(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan = result.plan
    layout = PRESAGe._erfc_audit(plan)
    ranges = [Dict(b.node => b.range for b in path.ranges) for path in result.paths]
    with_oracle(plan.spec; backend = :mpfr) do oracle
        for word in words
            x = decode_ieee(word, plan.spec.input_format)
            trace = interpret_trace(plan, word)
            numerical = any(
                i ->
                    plan.program.nodes[i] isa
                    Union{IR.Mul, IR.Add, IR.FMA, IR.ScaleByExponent},
                keys(trace.values),
            )
            outside =
                x.value !== nothing &&
                !(plan.spec.domain[1] <= x.value <= plan.spec.domain[2])
            if x.kind == :nan || outside
                @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                @test !numerical
                continue
            elseif x.kind == :infinity
                @test trace.bits == round_ieee(x.negative ? 2 : 0, plan.spec.output_format)
                @test !numerical
                continue
            elseif x.kind == :zero
                @test trace.bits == round_ieee(1, plan.spec.output_format)
                @test !numerical
                continue
            end
            y = decode_ieee(trace.bits, plan.spec.output_format)
            @test y.value !== nothing && !y.negative && 0 <= y.value <= 2
            ref = reference(oracle, word)
            @test ref.status == :resolved && ref.enclosure !== nothing
            lo, hi = map(b -> b.significand * PRESAGe._pow2(b.exponent), ref.enclosure)
            @test max(abs(y.value - lo), abs(y.value - hi)) <= result.total_bound
            j = only(
                j for (j, path) in enumerate(result.paths) if
                path.domain[1] <= x.value <= path.domain[2]
            )
            path = layout.paths[j]
            @test haskey(trace.values, path.square) == (abs(x.value) > 1)
            @test haskey(trace.values, path.tail_value) == (abs(x.value) > 1)
            @test haskey(trace.values, path.reflected) == x.negative
            @test all(trace.values) do (i, value)
                f = IR.format(plan.program, i)
                f isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(value.bits, f).value
                haskey(ranges[j], i) &&
                    q !== nothing &&
                    ranges[j][i][1] <= q <= ranges[j][i][2]
            end
        end
    end
end

function erfc_rebuild(
    baseline,
    spec = baseline.plan.spec;
    precision = baseline.plan.precision,
    evaluation = :fma,
    inverse_log2 = nothing,
)
    layout = PRESAGe._erfc_audit(baseline.plan)
    path = first(layout.paths)
    return erfc_polynomial_plan(
        spec,
        layout.central_coefficients,
        layout.scaled_coefficients,
        layout.exp_coefficients,
        path.log2,
        inverse_log2 === nothing ? path.inverse_log2 : inverse_log2;
        precision,
        evaluation,
    )
end

@testset "Certified erfc scaled tails and reflection" begin
    spec = FunctionSpec(
        "erfc(x)";
        input_format = IEEE16,
        domain = (-8, 8),
        absolute_error = 1 // 512,
    )
    search = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [13],
            internal_formats = [FixedFormat(72, 24)],
            transformation = :erfc,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        ),
    )
    @test search.status == :certified
    search.status == :certified || error(last(search.attempts).reason)
    baseline = search.selected
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
        0x4800,
        0xc800,
        0x4801,
        0xc801,
        0x7c00,
        0xfc00,
        0x7fff,
        0xffff,
    ]
    # Square/exponent transitions and normal/subnormal/zero output transitions.
    path = last(PRESAGe._erfc_audit(baseline.plan).paths)
    setprecision(BigFloat, 256) do
        for k = 2:92
            threshold = sqrt(BigFloat((PRESAGe._q(k) - 1 // 2) / path.inverse_log2))
            word = round_ieee(Rational{BigInt}(threshold), IEEE16)
            append!(words, [word - 1, word, word + 1])
        end
    end
    for x in (11 // 4, 23 // 8, 3, 15 // 4, 4, 17 // 4)
        word = round_ieee(x, IEEE16)
        append!(words, [word - 1, word, word + 1, word | 0x8000])
    end
    for mode in (:fma, :separate)
        result =
            mode == :fma ? baseline :
            certify_plan(erfc_rebuild(baseline; evaluation = mode))
        erfc_results[mode] = result
        check_erfc(result, words)
        @test length(result.paths) == 4
        @test 1 // 1024 < result.total_bound < 1 // 512
        @test implementation_cost(result.plan).exponent_scalings == 1
        @test precision_cost(result.plan).coefficient_bits == 3024
        @test precision_cost(result.plan).stage_bits == 3024
        @test certify_plan(
            read_plan(IOBuffer(sprint(write_plan, result.plan))),
        ).total_bound == result.total_bound
        report = TOML.parse(sprint(write_certificate, result))
        @test report["transformation"]["kind"] == "erfc"
        @test report["transformation"]["scaled_function"] == "exp(x*x)*erfc(x)"
        @test length(report["transformation"]["paths"]) == 4
        @test 0 < evaluate_bits(result.plan, round_ieee(23 // 8, IEEE16)) < 1 << 10
        @test evaluate_bits(result.plan, round_ieee(4, IEEE16)) == 0
    end
    for backend in (:portable, :ac_fixed, :ap_fixed),
        float_backend in (:native, :ac_std_float)

        @test cpu_check(baseline.plan, words; backend, float_backend, public_api = true) ==
              length(words)
    end
end

@testset "Exhaustive binary16 erfc scaled-tail verification" begin
    words = collect(UInt64(0):UInt64(0xffff))
    for mode in (:fma, :separate)
        check_erfc(erfc_results[mode], words)
    end
    @test cpu_check(
        erfc_results[:fma].plan,
        words;
        backend = :portable,
        float_backend = :native,
        public_api = true,
    ) == length(words)
    @test cpu_check(
        erfc_results[:fma].plan,
        words;
        backend = :ap_fixed,
        float_backend = :ac_std_float,
        public_api = true,
    ) == length(words)
end

@testset "Erfc bounded branches, underflow and proof refusals" begin
    baseline = erfc_results[:fma]
    for domain in
        ((0, 0), (-1, 1), (1, 1), (-1, -1), (2, 8), (-8, -2), (8, 8), (-1 // 3, 1 // 3))
        spec = FunctionSpec(
            "erfc(x)";
            input_format = IEEE16,
            domain,
            absolute_error = 1 // 512,
        )
        result = certify_plan(erfc_rebuild(baseline, spec))
        words =
            [round_ieee(x, IEEE16) for x in (-8, -2, -1, -1 // 3, 0, 1 // 3, 1, 2, 4, 8)]
        append!(
            words,
            [
                UInt64(1),
                UInt64(0x8001),
                UInt64(0x7c00),
                UInt64(0xfc00),
                UInt64(0xffff),
                round_ieee(1 // 3, IEEE16; mode = :down),
            ],
        )
        check_erfc(result, words)
        if domain == (0, 0)
            @test result.total_bound == 0 && isempty(result.paths)
            exact = search_polynomial(
                spec,
                PolynomialSearchConfig(
                    degrees = [0],
                    internal_formats = [FixedFormat(32, 8)],
                    transformation = :erfc,
                    job_timeout = 60,
                    total_timeout = 90,
                ),
            )
            @test exact.status == :certified && exact.selected.total_bound == 0
        end
    end
    # Deep positive underflow has a tiny certified absolute bound, with no
    # power of two allocated at the very negative exponent endpoint.
    spec = FunctionSpec(
        "erfc(x)";
        input_format = IEEE64,
        domain = (30, 32),
        absolute_error = PRESAGe._pow2(-1073),
    )
    tiny = certify_plan(erfc_rebuild(baseline, spec))
    words = [round_ieee(x, IEEE64) for x in (30, 31, 32)]
    check_erfc(tiny, words)
    @test tiny.total_bound < PRESAGe._pow2(-1074)
    @test all(w -> evaluate_bits(tiny.plan, w) == 0, words)
    @test cpu_check(
        tiny.plan,
        words;
        backend = :ac_fixed,
        float_backend = :ac_std_float,
        public_api = true,
    ) == length(words)
    tight = FunctionSpec(
        "erfc(x)";
        input_format = IEEE16,
        domain = (-8, 8),
        absolute_error = 1 // 2^24,
    )
    @test certify_plan(erfc_rebuild(baseline, tight)).status == :bound_exceeds_budget
    bad = certify_plan(erfc_rebuild(baseline; inverse_log2 = 1))
    @test bad.status == :proof_failed && occursin("reduced domain", bad.reason)
    path = first(PRESAGe._erfc_audit(baseline.plan).paths)
    overflow = certify_plan(
        erfc_polynomial_plan(
            baseline.plan.spec,
            [1, 0],
            [100, 100],
            [1, 1],
            path.log2,
            path.inverse_log2;
            internal_format = FixedFormat(8, 8),
            evaluation = :fma,
        ),
    )
    @test overflow.status == :proof_failed && occursin("overflow", overflow.reason)
    huge_spec = FunctionSpec(
        "erfc(x)";
        input_format = IEEE64,
        domain = (BigInt(1) << 100, BigInt(1) << 100),
        absolute_error = 1 // 512,
    )
    huge = certify_plan(erfc_rebuild(baseline, huge_spec))
    @test huge.status == :proof_failed && occursin("reduced domain", huge.reason)
    for node_kind in (IR.Compare, IR.ScalePow2, IR.ScaleByExponent, IR.Select, IR.Mul)
        nodes = collect(baseline.plan.program.nodes)
        i = findfirst(n -> n isa node_kind, nodes)
        n = nodes[i]
        nodes[i] =
            node_kind == IR.Compare ? IR.Compare(:ge, n.a, n.b) :
            node_kind == IR.ScalePow2 ? IR.ScalePow2(n.source, n.exponent + 1, n.format) :
            node_kind == IR.ScaleByExponent ? IR.Convert(n.source, n.format) :
            node_kind == IR.Select ? IR.Select(n.condition, n.no, n.yes) :
            IR.Add(n.a, n.b, n.format)
        mutated = PlanArtifact(
            baseline.plan.spec;
            program = IR.Program(nodes; output = baseline.plan.program.output),
            precision = baseline.plan.precision,
            settings = baseline.plan.settings,
        )
        result = certify_plan(mutated)
        @test result.status == :unsupported_domain
        @test !haskey(TOML.parse(sprint(write_certificate, result)), "coverage")
    end
    for spec in (
        FunctionSpec("erfc(x)"),
        FunctionSpec("erf(x)"; domain = (-1, 1)),
        FunctionSpec("erfc(x)"; input_format = FixedFormat(16, 8), domain = (-1, 1)),
        FunctionSpec("erfc(x)"; output_format = FixedFormat(16, 8), domain = (-1, 1)),
    )
        @test_throws ArgumentError erfc_polynomial_plan(spec, [1], [1], [1], 1, 1)
    end
    @test_throws ArgumentError PolynomialSearchConfig(
        degrees = [13],
        internal_formats = [IEEE64],
        transformation = :erfc,
        segments = [2],
    )
    coarse = search_polynomial(
        FunctionSpec(
            "erfc(x)";
            input_format = IEEE16,
            domain = (-2, 2),
            absolute_error = 1,
        ),
        PolynomialSearchConfig(
            degrees = [0],
            internal_formats = [IEEE64],
            transformation = :erfc,
            job_timeout = 60,
            total_timeout = 90,
        ),
    )
    @test coarse.status == :certified
    coarse.status == :certified || error(last(coarse.attempts).reason)
    check_erfc(coarse.selected, [round_ieee(x, IEEE16) for x in (-2, -1, 1 // 2, 1, 2)])
end

@testset "Erfc binary32, guard bits and individual precision" begin
    spec = FunctionSpec(
        "erfc(x)";
        input_format = IEEE32,
        domain = (-8, 8),
        absolute_error = 1 // 2^20,
    )
    search = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [9, 13],
            internal_formats = [FixedFormat(72, 24)],
            transformation = :erfc,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 150,
        ),
    )
    @test search.status == :certified
    search.status == :certified || error(last(search.attempts).reason)
    @test first(search.attempts).status == :bound_exceeds_budget
    @test last(search.attempts).degree == 13
    result = search.selected
    words = [round_ieee(x, IEEE32) for x in (-8, -4, -1, -1 // 3, 0, 1 // 3, 1, 3, 4, 8)]
    append!(
        words,
        [UInt64(1), PRESAGe._sign(IEEE32) | 1, PRESAGe._inf(IEEE32), PRESAGe._nan(IEEE32)],
    )
    check_erfc(result, words)
    @test cpu_check(
        result.plan,
        words;
        backend = :ac_fixed,
        float_backend = :native,
        public_api = true,
    ) == length(words)
    baseline = erfc_results[:fma]
    for (input, output, internal) in (
        (FloatFormat(2, 3), IEEE32, IEEE64),
        (IEEE64, IEEE64, IEEE64),
        (FloatFormat(8, 100), FloatFormat(11, 112), FixedFormat(120, 24)),
    )
        spec = FunctionSpec(
            "erfc(x)";
            input_format = input,
            output_format = output,
            domain = (-8, 8),
            absolute_error = 1 // 2^18,
        )
        precision = PolynomialPrecision(
            internal;
            coefficient_formats = fill(internal, 14),
            stage_formats = fill(internal, 14),
        )
        result = if input == FloatFormat(2, 3)
            fresh = search_polynomial(
                spec,
                PolynomialSearchConfig(
                    degrees = [13],
                    internal_formats = [internal],
                    transformation = :erfc,
                    evaluation = :fma,
                    job_timeout = 60,
                    total_timeout = 90,
                ),
            )
            @test fresh.status == :certified
            fresh.status == :certified || error(last(fresh.attempts).reason)
            fresh.selected
        else
            certify_plan(erfc_rebuild(baseline, spec; precision))
        end
        words = [round_ieee(x, input) for x in (-3, -1, -1 // 3, 0, 1 // 3, 1, 3)]
        append!(
            words,
            [BigInt(1), PRESAGe._sign(input) | 1, PRESAGe._inf(input), PRESAGe._nan(input)],
        )
        check_erfc(result, words)
        @test cpu_check(
            result.plan,
            words;
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            public_api = true,
        ) == length(words)
        if input == IEEE64
            @test any(p -> p.coordinate_error > 0, result.paths)
        end
    end
    coefficients = [FixedFormat(72 - min(i, 5), 24) for i = 1:14]
    stages = [FixedFormat(72 - min(i, 4), 24) for i = 1:14]
    precision = PolynomialPrecision(
        FixedFormat(72, 24);
        coefficient_formats = coefficients,
        stage_formats = stages,
    )
    result = certify_plan(erfc_rebuild(baseline; precision))
    check_erfc(result, [round_ieee(x, IEEE16) for x in (-8, -1, 1, 3, 8)])
    @test !isempty(PRESAGe._precision_proposals(result, 1, 0))
    @test cpu_check(
        result.plan,
        [round_ieee(3, IEEE16)];
        backend = :ap_fixed,
        float_backend = :native,
    ) == 1
end

@testset "Erfc precision search, artifacts and CLI" begin
    baseline = erfc_results[:fma]
    optimized = optimize_precision(
        baseline;
        max_attempts = 3,
        job_timeout = 60,
        total_timeout = 150,
    )
    @test optimized.status == :certified &&
          any(a -> a.kind != :baseline && a.accepted, optimized.attempts)
    @test precision_cost(optimized.selected.plan).coefficient_bits <
          precision_cost(baseline.plan).coefficient_bits ||
          precision_cost(optimized.selected.plan).stage_bits <
          precision_cost(baseline.plan).stage_bits
    check_erfc(optimized.selected, [round_ieee(x, IEEE16) for x in (-8, -1, 1, 3, 8)])
    @test cpu_check(
        optimized.selected.plan;
        backend = :ac_fixed,
        float_backend = :ac_std_float,
    ) > 2048
    mktempdir() do directory
        config = PolynomialSearchConfig(
            degrees = [13],
            internal_formats = [FixedFormat(72, 24)],
            transformation = :erfc,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        )
        data = PRESAGe._search_config_data(config)
        @test data["schema_version"] == 12
        @test read_search_config(
            IOBuffer(sprint(write_search_config, config)),
        ).transformation == :erfc
        data["schema_version"] = 11
        @test_throws ArgumentError PRESAGe._read_search_config(data)
        source, config_path, output =
            joinpath.(Ref(directory), ("contract.toml", "search.toml", "output"))
        write_plan(source, PlanArtifact(baseline.plan.spec))
        write_search_config(config_path, config)
        generate_main([
            source,
            output,
            "--search-config=$config_path",
            "--backend=ap_fixed",
            "--float-backend=native",
        ])
        plan = read_plan(joinpath(output, "plan.toml"))
        @test plan.settings["transformation"] == "erfc"
        @test TOML.parsefile(joinpath(output, "search.toml"))["schema_version"] == 12
        @test cpu_check(
            plan,
            [round_ieee(-8, IEEE16), round_ieee(3, IEEE16)];
            backend = :ap_fixed,
            float_backend = :native,
            generated_directory = output,
        ) == 2
        replay = joinpath(directory, "replay")
        generate_main([
            joinpath(output, "plan.toml"),
            replay,
            "--backend=ac_fixed",
            "--float-backend=ac_std_float",
        ])
        @test cpu_check(
            read_plan(joinpath(replay, "plan.toml")),
            [round_ieee(3, IEEE16)];
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            generated_directory = replay,
        ) == 1
    end
end
