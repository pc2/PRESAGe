isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
const hyperbolic_results = Dict{Tuple{Symbol, Symbol}, CertificationResult}()

function check_hyperbolic(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan = result.plan
    layout = PRESAGe._hyperbolic_audit(plan)
    sinh = layout.geometry.transformation == :sinh
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
                @test trace.bits == (
                    PRESAGe._inf(plan.spec.output_format) |
                    (sinh && x.negative ? PRESAGe._sign(plan.spec.output_format) : 0)
                )
                @test !numerical
                continue
            elseif x.kind == :zero
                @test trace.bits == (
                    sinh ? (x.negative ? PRESAGe._sign(plan.spec.output_format) : 0) :
                    round_ieee(1, plan.spec.output_format)
                )
                @test !numerical
                continue
            end
            y = decode_ieee(trace.bits, plan.spec.output_format)
            @test y.value !== nothing && y.negative == (sinh && x.negative)
            ref = reference(oracle, word)
            @test ref.status == :resolved && ref.enclosure !== nothing
            lo, hi = map(b -> b.significand * PRESAGe._pow2(b.exponent), ref.enclosure)
            @test max(abs(y.value - lo), abs(y.value - hi)) <= result.total_bound
            j = only(
                j for (j, path) in enumerate(result.paths) if
                path.domain[1] <= x.value <= path.domain[2]
            )
            path = layout.paths[j]
            @test haskey(trace.values, path.reconstructed) == (abs(x.value) > 1)
            @test haskey(trace.values, path.positive_scaled) == (abs(x.value) > 1)
            @test haskey(trace.values, path.negative_scaled) == (abs(x.value) > 1)
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

function hyperbolic_rebuild(
    baseline,
    spec = baseline.plan.spec;
    precision = baseline.plan.precision,
    evaluation = :fma,
    inverse_log2 = nothing,
)
    layout = PRESAGe._hyperbolic_audit(baseline.plan)
    path = first(layout.paths)
    return hyperbolic_polynomial_plan(
        spec,
        layout.central_coefficients,
        layout.exp_coefficients,
        path.log2,
        inverse_log2 === nothing ? path.inverse_log2 : inverse_log2;
        precision,
        evaluation,
    )
end

@testset "Certified sinh/cosh central and exponential tails" begin
    for kind in (:sinh, :cosh)
        spec = FunctionSpec(
            string(kind, "(x)");
            input_format = IEEE16,
            domain = (-23 // 2, 23 // 2),
            absolute_error = 32,
        )
        search = search_polynomial(
            spec,
            PolynomialSearchConfig(
                degrees = [9],
                internal_formats = [FixedFormat(72, 24)],
                transformation = kind,
                evaluation = :fma,
                job_timeout = 60,
                total_timeout = 90,
            ),
        )
        @test search.status == :certified
        search.status == :certified || error(last(search.attempts).reason)
        baseline = search.selected
        path = last(PRESAGe._hyperbolic_audit(baseline.plan).paths)
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
            0x49c0,
            0xc9c0,
            0x49c1,
            0xc9c1,
            0x7c00,
            0xfc00,
            0x7fff,
            0xffff,
        ]
        for k = 1:17
            word = round_ieee((PRESAGe._q(k) + 1 // 2) / path.inverse_log2, IEEE16)
            append!(
                words,
                [
                    word - 1,
                    word,
                    word + 1,
                    (word - 1) | 0x8000,
                    word | 0x8000,
                    (word + 1) | 0x8000,
                ],
            )
        end
        for mode in (:fma, :separate)
            result =
                mode == :fma ? baseline :
                certify_plan(hyperbolic_rebuild(baseline; evaluation = mode))
            hyperbolic_results[(kind, mode)] = result
            check_hyperbolic(result, words)
            @test length(result.paths) == 3
            @test 16 < result.total_bound < 17
            @test implementation_cost(result.plan).exponent_scalings == 2
            @test precision_cost(result.plan).coefficient_bits == 1440
            @test precision_cost(result.plan).stage_bits == 2160
            @test certify_plan(
                read_plan(IOBuffer(sprint(write_plan, result.plan))),
            ).total_bound == result.total_bound
            report = TOML.parse(sprint(write_certificate, result))
            @test report["transformation"]["kind"] == string(kind)
            @test length(report["transformation"]["paths"]) == 3
        end
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            @test cpu_check(
                baseline.plan,
                words;
                backend,
                float_backend,
                public_api = true,
            ) == length(words)
        end
        # exp(11.5) overflows binary16; the hyperbolic result remains finite.
        with_oracle(
            FunctionSpec("exp(x)"; input_format = IEEE16);
            backend = :mpfr,
        ) do oracle
            @test decode_ieee(reference(oracle, 0x49c0).bits, IEEE16).kind == :infinity
        end
        @test decode_ieee(evaluate_bits(baseline.plan, 0x49c0), IEEE16).value !== nothing
    end
end

@testset "Exhaustive binary16 sinh/cosh verification" begin
    words = collect(UInt64(0):UInt64(0xffff))
    for kind in (:sinh, :cosh), mode in (:fma, :separate)
        check_hyperbolic(hyperbolic_results[(kind, mode)], words)
    end
    @test cpu_check(
        hyperbolic_results[(:sinh, :fma)].plan,
        words;
        backend = :portable,
        float_backend = :native,
        public_api = true,
    ) == length(words)
    @test cpu_check(
        hyperbolic_results[(:cosh, :fma)].plan,
        words;
        backend = :ac_fixed,
        float_backend = :ac_std_float,
        public_api = true,
    ) == length(words)
end

@testset "Hyperbolic bounded branches and proof refusals" begin
    for kind in (:sinh, :cosh)
        baseline = hyperbolic_results[(kind, :fma)]
        for domain in ((0, 0), (-1, 1), (1, 1), (2, 4), (-4, -2), (-1 // 3, 1 // 3))
            spec = FunctionSpec(
                string(kind, "(x)");
                input_format = IEEE16,
                domain,
                absolute_error = 32,
            )
            result = certify_plan(hyperbolic_rebuild(baseline, spec))
            words = UInt64[
                0,
                0x8000,
                1,
                0x8001,
                0x3c00,
                0xbc00,
                round_ieee(1 // 3, IEEE16),
                round_ieee(1 // 3, IEEE16; mode = :down),
                round_ieee(-1 // 3, IEEE16; mode = :up),
                round_ieee(2, IEEE16),
                round_ieee(-2, IEEE16),
                0x7c00,
                0xfc00,
                0xffff,
            ]
            check_hyperbolic(result, words)
            if domain == (0, 0)
                @test result.total_bound == 0 && isempty(result.paths)
                exact = search_polynomial(
                    spec,
                    PolynomialSearchConfig(
                        evaluation = :separate,
                        degrees = [0],
                        internal_formats = [FixedFormat(32, 8)],
                        transformation = kind,
                        job_timeout = 60,
                        total_timeout = 90,
                    ),
                )
                @test exact.status == :certified && exact.selected.total_bound == 0
            end
        end
        for domain in ((-12, 12), (-65504, 65504))
            spec = FunctionSpec(
                string(kind, "(x)");
                input_format = IEEE16,
                domain,
                absolute_error = 32,
            )
            refused = certify_plan(hyperbolic_rebuild(baseline, spec))
            @test refused.status == :proof_failed && occursin("overflow", refused.reason)
            @test !haskey(TOML.parse(sprint(write_certificate, refused)), "coverage")
        end
        tight = FunctionSpec(
            string(kind, "(x)");
            input_format = IEEE16,
            domain = baseline.plan.spec.domain,
            absolute_error = 1 // 1024,
        )
        @test certify_plan(hyperbolic_rebuild(baseline, tight)).status ==
              :bound_exceeds_budget
        @test certify_plan(hyperbolic_rebuild(baseline; inverse_log2 = 1)).status ==
              :proof_failed
        for node_kind in (IR.Compare, IR.ScaleByExponent, IR.Select, IR.Add)
            nodes = collect(baseline.plan.program.nodes)
            i = findfirst(n -> n isa node_kind, nodes)
            n = nodes[i]
            nodes[i] =
                node_kind == IR.Compare ? IR.Compare(:ge, n.a, n.b) :
                node_kind == IR.ScaleByExponent ? IR.Convert(n.source, n.format) :
                node_kind == IR.Select ? IR.Select(n.condition, n.no, n.yes) :
                IR.Add(n.a, n.a, n.format)
            mutated = PlanArtifact(
                baseline.plan.spec;
                program = IR.Program(nodes; output = baseline.plan.program.output),
                precision = baseline.plan.precision,
                settings = baseline.plan.settings,
            )
            @test certify_plan(mutated).status == :unsupported_domain
        end
        spec = FunctionSpec(
            string(kind, "(x)");
            input_format = IEEE16,
            domain = (-2, 2),
            absolute_error = 32,
        )
        low = search_polynomial(
            spec,
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [0],
                internal_formats = [IEEE64],
                transformation = kind,
                job_timeout = 60,
                total_timeout = 90,
            ),
        )
        @test low.status == :certified
        low.status == :certified || error(last(low.attempts).reason)
        check_hyperbolic(low.selected, UInt64[1, 0x3c00, 0x4000, 0xbc00, 0xc000])
    end
    for spec in (
        FunctionSpec("sinh(x)"),
        FunctionSpec("exp(x)"; domain = (-1, 1)),
        FunctionSpec("sinh(x)"; input_format = FixedFormat(16, 8), domain = (-1, 1)),
    )
        @test_throws ArgumentError hyperbolic_polynomial_plan(spec, [1], [1], 1, 1)
    end
    @test_throws ArgumentError PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [16],
        internal_formats = [IEEE64],
        transformation = :sinh,
    )
    @test_throws ArgumentError PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [9],
        internal_formats = [IEEE64],
        transformation = :cosh,
        segments = [2],
    )
    @test_throws ArgumentError search_polynomial(
        FunctionSpec("sinh(x)"; domain = (-2, 2)),
        PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [9],
            internal_formats = [IEEE64],
            transformation = :cosh,
        ),
    )
end

@testset "Hyperbolic guard bits and custom precision" begin
    for kind in (:sinh, :cosh)
        baseline = hyperbolic_results[(kind, :fma)]
        for (input, output, internal) in (
            (FloatFormat(2, 3), IEEE32, IEEE64),
            (IEEE32, IEEE32, IEEE64),
            (FloatFormat(8, 100), FloatFormat(11, 112), FixedFormat(120, 24)),
        )
            spec = FunctionSpec(
                string(kind, "(x)");
                input_format = input,
                output_format = output,
                domain = (-2, 2),
                absolute_error = 1 // 2^19,
            )
            precision = PolynomialPrecision(
                internal;
                coefficient_formats = fill(internal, 10),
                stage_formats = fill(internal, 10),
            )
            result = certify_plan(hyperbolic_rebuild(baseline, spec; precision))
            words = [
                round_ieee(x, input) for
                x in (-2, -3 // 2, -1, -1 // 2, 0, 1 // 2, 1, 3 // 2, 2)
            ]
            append!(
                words,
                [
                    BigInt(1),
                    PRESAGe._sign(input) | 1,
                    PRESAGe._inf(input),
                    PRESAGe._inf(input) | PRESAGe._sign(input),
                    PRESAGe._nan(input),
                ],
            )
            check_hyperbolic(result, words)
            @test cpu_check(
                result.plan,
                words;
                backend = :ac_fixed,
                float_backend = :ac_std_float,
                public_api = true,
            ) == length(words)
            if input == FloatFormat(8, 100)
                layout = PRESAGe._hyperbolic_audit(result.plan)
                @test first(layout.paths).reduction_format.fraction_bits >= 112
                @test first(layout.paths).reduction_format.exponent_bits >
                      output.exponent_bits
            end
        end
        original = baseline.plan.precision
        # Extra exponent headroom matters for binary64 too: the independent
        # reduced-kernel range exceeds binary64 even though sinh/cosh is finite.
        large_spec = FunctionSpec(
            string(kind, "(x)");
            input_format = IEEE64,
            domain = (-3552 // 5, 3552 // 5),
            absolute_error = PRESAGe._pow2(986),
        )
        large = certify_plan(hyperbolic_rebuild(baseline, large_spec))
        edge = round_ieee(3552 // 5, IEEE64; mode = :down)
        large_words = [edge, edge | PRESAGe._sign(IEEE64), round_ieee(710, IEEE64)]
        check_hyperbolic(large, large_words)
        @test first(
            PRESAGe._hyperbolic_audit(large.plan).paths,
        ).reduction_format.exponent_bits == 12
        @test_throws ArgumentError emit_cpp(IOBuffer(), large.plan; float_backend = :native)
        @test cpu_check(
            large.plan,
            large_words;
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            public_api = true,
        ) == length(large_words)
        coefficients = [FixedFormat(72 - min(i, 8), 24) for i = 1:10]
        stages = [FixedFormat(72 - min(i, 6), 24) for i = 1:10]
        precision = PolynomialPrecision(
            original.coordinate_format;
            coefficient_formats = coefficients,
            stage_formats = stages,
        )
        result = certify_plan(hyperbolic_rebuild(baseline; precision))
        check_hyperbolic(
            result,
            [round_ieee(x, IEEE16) for x in (-11, -1, -1 // 2, 1 // 2, 1, 11)],
        )
        proposals = PRESAGe._precision_proposals(result, 1, 0)
        @test !isempty(proposals)
        @test cpu_check(
            result.plan,
            [round_ieee(11, IEEE16)];
            backend = :ap_fixed,
            float_backend = :native,
        ) == 1
    end
end

@testset "Hyperbolic search schema, precision search and CLI" begin
    baseline = hyperbolic_results[(:sinh, :fma)]
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
    check_hyperbolic(optimized.selected, [round_ieee(x, IEEE16) for x in (-11, -1, 1, 11)])
    @test cpu_check(
        optimized.selected.plan;
        backend = :ac_fixed,
        float_backend = :ac_std_float,
    ) > 2048
    mktempdir() do directory
        config = PolynomialSearchConfig(
            degrees = [9],
            internal_formats = [FixedFormat(72, 24)],
            transformation = :cosh,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        )
        data = PRESAGe._search_config_data(config)
        @test data["schema_version"] == 11
        @test read_search_config(
            IOBuffer(sprint(write_search_config, config)),
        ).transformation == :cosh
        data["schema_version"] = 10
        @test_throws ArgumentError PRESAGe._read_search_config(data)
        source, config_path, output =
            joinpath.(Ref(directory), ("contract.toml", "search.toml", "output"))
        write_plan(source, PlanArtifact(hyperbolic_results[(:cosh, :fma)].plan.spec))
        write_search_config(config_path, config)
        generate_main([
            source,
            output,
            "--search-config=$config_path",
            "--backend=ap_fixed",
            "--float-backend=native",
        ])
        plan = read_plan(joinpath(output, "plan.toml"))
        @test plan.settings["transformation"] == "cosh"
        @test TOML.parsefile(joinpath(output, "search.toml"))["schema_version"] == 11
        @test cpu_check(
            plan,
            [round_ieee(11, IEEE16), round_ieee(-11, IEEE16)];
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
            [round_ieee(11, IEEE16)];
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            generated_directory = replay,
        ) == 1
    end
end
