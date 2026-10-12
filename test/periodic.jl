isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
const periodic_results = Dict{Symbol, CertificationResult}()

function check_periodic(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan = result.plan
    layout = PRESAGe._periodic_audit(plan)
    ranges = [Dict(b.node => b.range for b in path.ranges) for path in result.paths]
    quadrants = Set{Int}()
    with_oracle(plan.spec; backend = :mpfr) do oracle
        for word in words
            x = decode_ieee(word, plan.spec.input_format)
            trace = interpret_trace(plan, word)
            numerical = any(
                i -> plan.program.nodes[i] isa Union{IR.Mul, IR.Add, IR.FMA},
                keys(trace.values),
            )
            if x.value === nothing ||
               !(plan.spec.domain[1] <= x.value <= plan.spec.domain[2])
                @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                @test !numerical
                continue
            elseif x.kind == :zero
                expected =
                    layout.geometry.transformation == :sin ?
                    (x.negative ? PRESAGe._sign(plan.spec.output_format) : 0) :
                    round_ieee(1, plan.spec.output_format)
                @test trace.bits == expected
                @test !numerical
                continue
            end
            quadrant = Int(trace.values[first(layout.paths).quadrant_bits])
            push!(quadrants, quadrant)
            path = layout.paths[quadrant + 1]
            @test haskey(trace.values, path.reconstruction) == path.sin_kernel
            @test haskey(trace.values, path.negated) == path.negative_sign
            y = decode_ieee(trace.bits, plan.spec.output_format)
            @test y.value !== nothing
            ref = reference(oracle, word)
            @test ref.status == :resolved && ref.enclosure !== nothing
            lo, hi = map(b -> b.significand * PRESAGe._pow2(b.exponent), ref.enclosure)
            @test max(abs(y.value - lo), abs(y.value - hi)) <=
                  result.paths[quadrant + 1].total
            @test all(trace.values) do (i, value)
                f = IR.format(plan.program, i)
                f isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(value.bits, f).value
                haskey(ranges[quadrant + 1], i) &&
                    q !== nothing &&
                    ranges[quadrant + 1][i][1] <= q <= ranges[quadrant + 1][i][2]
            end
        end
    end
    return quadrants
end

function periodic_rebuild(
    baseline,
    spec = baseline.plan.spec;
    precision = baseline.plan.precision,
    evaluation = :fma,
    pi2 = nothing,
    inverse_pi2 = nothing,
)
    layout = PRESAGe._periodic_audit(baseline.plan)
    p = first(layout.paths)
    periodic_polynomial_plan(
        spec,
        layout.sin_coefficients,
        layout.cos_coefficients,
        pi2 === nothing ? p.pi2 : pi2,
        inverse_pi2 === nothing ? p.inverse_pi2 : inverse_pi2;
        precision,
        evaluation,
    )
end

function periodic_neighbours(f; radius = 32)
    words = Set{IR.Word}((
        IR._word(0, f),
        PRESAGe._sign(f),
        IR._word(1, f),
        PRESAGe._sign(f) | 1,
        PRESAGe._inf(f),
        PRESAGe._inf(f) | PRESAGe._sign(f),
        PRESAGe._nan(f),
    ))
    setprecision(BigFloat, 256) do
        for k = -20:20
            for x in
                (BigFloat(k) * big(pi) / 2, (BigFloat(k) + BigFloat(0.5)) * big(pi) / 2)
                abs(x) <= radius || continue
                word = round_ieee(Rational{BigInt}(x), f)
                for w in (word - 1, word, word + 1)
                    0 <= w <= PRESAGe._word_mask(PRESAGe._width(f)) || continue
                    push!(words, w)
                end
            end
        end
    end
    for x in (-radius, radius, -radius - 1, radius + 1)
        push!(words, round_ieee(x, f))
    end
    return sort!(collect(words))
end

@testset "Periodic kernels and exact quadrant restoration" begin
    for kind in (:sin, :cos)
        spec = FunctionSpec(
            "$kind(x)";
            input_format = IEEE16,
            domain = (-32, 32),
            absolute_error = 1 // 512,
        )
        search = search_polynomial(
            spec,
            PolynomialSearchConfig(
                degrees = [3, 5],
                internal_formats = [FixedFormat(56, 8)],
                transformation = kind,
                evaluation = :fma,
                job_timeout = 60,
                total_timeout = 150,
            ),
        )
        @test search.status == :certified
        search.status == :certified || error(last(search.attempts).reason)
        result = search.selected
        periodic_results[kind] = result
        @test result.total_bound < 1 // 512
        @test length(result.paths) == 4
        @test check_periodic(result, periodic_neighbours(IEEE16)) == Set(0:3)
        p = result.plan
        layout = PRESAGe._periodic_audit(p)
        @test precision_cost(p).coefficient_bits ==
              2sum(f.width for f in p.precision.coefficient_formats)
        @test precision_cost(p).stage_bits ==
              2sum(f.width for f in p.precision.stage_formats)
        @test PRESAGe._parse_rational(result.settings["ideal_residual_radius"]) < 1
        for backend in (:portable, :ap_fixed, :ac_fixed)
            @test cpu_check(p, periodic_neighbours(IEEE16); backend, public_api = true) ==
                  length(periodic_neighbours(IEEE16))
        end
        @test cpu_check(
            p,
            periodic_neighbours(IEEE16);
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            public_api = true,
        ) == length(periodic_neighbours(IEEE16))
        separate = certify_plan(periodic_rebuild(result; evaluation = :separate))
        check_periodic(separate, periodic_neighbours(IEEE16))
        @test cpu_check(
            separate.plan,
            periodic_neighbours(IEEE16);
            backend = :ap_fixed,
            float_backend = :ac_std_float,
        ) == length(periodic_neighbours(IEEE16))
    end
end

@testset "Exhaustive binary16 periodic verification" begin
    for kind in (:sin, :cos)
        result = periodic_results[kind]
        @test check_periodic(result, UInt64(0):UInt64(65535)) == Set(0:3)
        @test cpu_check(
            result.plan,
            UInt64(0):UInt64(65535);
            backend = :ac_fixed,
            float_backend = :ac_std_float,
        ) == 65536
    end
end

@testset "Periodic binary32, custom floats and individual precision" begin
    for kind in (:sin, :cos)
        for (input, output, internal, budget) in (
            (IEEE32, IEEE32, FixedFormat(60, 8), 1 // 2^20),
            (IEEE64, IEEE64, IEEE64, 1 // 2^32),
            (FloatFormat(5, 8), FloatFormat(8, 23), FixedFormat(56, 8), 1 // 2^20),
            (FloatFormat(11, 80), FloatFormat(11, 80), FixedFormat(112, 8), 1 // big(2)^60),
        )
            spec = FunctionSpec(
                "$kind(x)";
                input_format = input,
                output_format = output,
                domain = (-32, 32),
                absolute_error = budget,
            )
            search = search_polynomial(
                spec,
                PolynomialSearchConfig(
                    degrees = [9],
                    internal_formats = [internal],
                    transformation = kind,
                    evaluation = :fma,
                    job_timeout = 60,
                    total_timeout = 90,
                ),
            )
            @test search.status == :certified
            search.status == :certified || error(last(search.attempts).reason)
            result = search.selected
            words = periodic_neighbours(input)
            check_periodic(result, words)
            @test cpu_check(
                result.plan,
                words;
                backend = :ac_fixed,
                float_backend = :ac_std_float,
                public_api = true,
            ) == length(words)
            if input == IEEE32
                @test cpu_check(
                    result.plan,
                    words;
                    backend = :ap_fixed,
                    float_backend = :native,
                ) == length(words)
            end
        end
        baseline = periodic_results[kind]
        n = length(baseline.plan.precision.coefficient_formats)
        precision = PolynomialPrecision(
            FixedFormat(56, 8);
            coefficient_formats = [FixedFormat(56 - min(i, 4), 8) for i = 1:n],
            stage_formats = [FixedFormat(56 - min(i, 3), 8) for i = 1:n],
        )
        result = certify_plan(periodic_rebuild(baseline; precision))
        check_periodic(result, periodic_neighbours(IEEE16))
        @test !isempty(PRESAGe._precision_proposals(result, 1, 0))
        @test cpu_check(result.plan, periodic_neighbours(IEEE16); backend = :ap_fixed) ==
              length(periodic_neighbours(IEEE16))
        proposals = PRESAGe._precision_proposals(baseline, 1, 0)
        stage = first(filter(p -> p.kind == :stage_range, proposals))
        reformatted = PRESAGe._reformat_polynomial(baseline.plan, stage.precision)
        @test PRESAGe._periodic_audit(reformatted).sin_coefficients ==
              PRESAGe._periodic_audit(baseline.plan).sin_coefficients
        check_periodic(certify_plan(reformatted), periodic_neighbours(IEEE16))
    end
end

@testset "Periodic proof refusals and lazy exceptional inputs" begin
    base = periodic_results[:sin]
    for (pi2, inverse) in ((0, nothing), (nothing, 0), (nothing, 9 // 10), (10, nothing))
        result = certify_plan(periodic_rebuild(base; pi2, inverse_pi2 = inverse))
        @test result.status == :proof_failed
        @test result.total_bound === nothing
    end
    for kind in (:sin, :cos)
        baseline = periodic_results[kind]
        spec = FunctionSpec(
            "$kind(x)";
            input_format = IEEE16,
            domain = (0, 0),
            absolute_error = 1 // 512,
        )
        zero = certify_plan(periodic_rebuild(baseline, spec))
        @test zero.status == :certified && zero.total_bound == 0 && isempty(zero.paths)
        check_periodic(zero, UInt64[0, 0x8000, 1, 0x8001, 0x7c00, 0xfc00, 0x7e00])
        @test cpu_check(
            zero.plan,
            UInt64[0, 0x8000, 1, 0x7c00];
            backend = :ac_fixed,
            float_backend = :ac_std_float,
        ) == 4
        positive = FunctionSpec(
            "$kind(x)";
            input_format = IEEE16,
            domain = (1, 32),
            absolute_error = 1 // 512,
        )
        check_periodic(
            certify_plan(periodic_rebuild(baseline, positive)),
            UInt64[0, 0x8000, 0x3bff, 0x3c00, 0x4000],
        )
        @test_throws ArgumentError certified_polynomial(
            FunctionSpec("$kind(x)"; domain = nothing);
            transformation = kind,
            degree = 3,
        )
        @test certified_polynomial(
            FunctionSpec(
                "$kind(x)";
                input_format = IEEE64,
                domain = (-big(2)^70, big(2)^70),
            );
            transformation = kind,
            degree = 3,
        ).status == :proof_failed
        @test_throws ArgumentError PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [16],
            internal_formats = [IEEE64],
            transformation = kind,
        )
        @test_throws ArgumentError PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [3],
            segments = [2],
            internal_formats = [IEEE64],
            transformation = kind,
        )
        @test_throws ArgumentError certified_polynomial(
            FunctionSpec("exp(x)"; domain = (-1, 1));
            transformation = kind,
            degree = 3,
        )
        p = baseline.plan
        layout = PRESAGe._periodic_audit(p)
        for i in (
            first(layout.paths).selection_product,
            first(layout.paths).residual,
            first(layout.paths).quadrant_bits,
            first(layout.paths).selected,
            first(layout.paths).signed,
        )
            nodes = collect(p.program.nodes)
            node = nodes[i]
            nodes[i] =
                node isa IR.Mul ? IR.Add(node.a, node.b, node.format) :
                node isa IR.FMA ? IR.FMA(node.a, node.b, node.b, node.format) :
                node isa IR.ExtractBits ? IR.ExtractBits(node.source, 1, node.width) :
                IR.Select(node.condition, node.no, node.yes)
            corrupt = PlanArtifact(
                p.spec;
                program = IR.Program(nodes; output = p.program.output),
                precision = p.precision,
                settings = p.settings,
            )
            @test certify_plan(corrupt).status == :unsupported_domain
        end
        narrow = PolynomialPrecision(
            FixedFormat(4, 2);
            coefficient_formats = fill(
                FixedFormat(4, 2),
                length(p.precision.coefficient_formats),
            ),
            stage_formats = fill(FixedFormat(4, 2), length(p.precision.stage_formats)),
        )
        @test certify_plan(periodic_rebuild(baseline; precision = narrow)).status !=
              :certified
    end
    wide_domain = FunctionSpec(
        "sin(x)";
        input_format = IEEE64,
        domain = (-big(2)^58, big(2)^58),
        absolute_error = 1 // 512,
    )
    @test certify_plan(periodic_rebuild(base, wide_domain)).status == :proof_failed
end

@testset "Fixed payload bitcast and periodic artifacts" begin
    for format in
        (FixedFormat(8, 8), FixedFormat(9, 6; signed = false), FixedFormat(130, 130))
        raw = IR.UIntFormat(format.width)
        program = IR.Program(
            [
                IR.Input(format),
                IR.BitCast(1, raw),
                IR.ExtractBits(2, 0, 2),
                IR.TableLoad(1, 3),
            ];
            tables = [IR.Table(IEEE32, round_ieee.(0:3, Ref(IEEE32)))],
        )
        spec = FunctionSpec(
            "sin(x)";
            input_format = format,
            output_format = IEEE32,
            domain = (-1, 1),
        )
        plan = PlanArtifact(spec; program)
        words = [BigInt(0), BigInt(1), BigInt(2), BigInt(3), (big(1) << format.width) - 1]
        for word in words
            @test evaluate_bits(plan, word) == round_ieee(word & 3, IEEE32)
        end
        @test cpu_check(plan, words; backend = :ac_fixed, float_backend = :ac_std_float) ==
              length(words)
        @test cpu_check(plan, words; backend = :portable, float_backend = :ac_std_float) ==
              length(words)
        io = IOBuffer()
        write_plan(io, plan)
        data = TOML.parse(String(take!(io)))
        @test data["schema_version"] == 12
        @test PRESAGe._program_data(PRESAGe._read_plan(data).program) ==
              PRESAGe._program_data(program)
        data["schema_version"] = 11
        @test_throws ArgumentError PRESAGe._read_plan(data)
    end
    for kind in (:sin, :cos)
        baseline = periodic_results[kind]
        config = PolynomialSearchConfig(
            degrees = [3],
            internal_formats = [FixedFormat(56, 8)],
            transformation = kind,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        )
        io = IOBuffer()
        write_search_config(io, config)
        data = TOML.parse(String(take!(io)))
        @test data["schema_version"] == 13
        @test PRESAGe._read_search_config(data).transformation == kind
        data["schema_version"] = 12
        @test_throws ArgumentError PRESAGe._read_search_config(data)
        io = IOBuffer()
        write_certificate(io, baseline)
        report = TOML.parse(String(take!(io)))
        @test report["transformation"]["kind"] == string(kind)
        @test getindex.(report["paths"], "quadrant") == collect(0:3)
        @test length(report["transformation"]["paths"]) == 4
        optimization = optimize_precision(
            baseline;
            max_attempts = 2,
            job_timeout = 60,
            total_timeout = 120,
        )
        @test optimization.status == :certified
        @test any(a -> a.kind != :baseline && a.accepted, optimization.attempts)
        @test optimization.selected.status == :certified
        check_periodic(optimization.selected, periodic_neighbours(IEEE16))
        mktempdir() do dir
            contract, settings =
                joinpath(dir, "contract.toml"), joinpath(dir, "search-config.toml")
            write_plan(contract, PlanArtifact(baseline.plan.spec))
            write_search_config(settings, config)
            generated = joinpath(dir, "generated")
            generate_main([
                contract,
                generated,
                "--search-config=$settings",
                "--backend=ac_fixed",
                "--float-backend=ac_std_float",
            ])
            plan = read_plan(joinpath(generated, "plan.toml"))
            @test TOML.parsefile(joinpath(generated, "search.toml"))["schema_version"] == 13
            @test cpu_check(
                plan,
                periodic_neighbours(IEEE16);
                backend = :ac_fixed,
                float_backend = :ac_std_float,
                generated_directory = generated,
            ) == length(periodic_neighbours(IEEE16))
            replay = joinpath(dir, "replayed")
            generate_main([
                joinpath(generated, "plan.toml"),
                replay,
                "--backend=ap_fixed",
                "--float-backend=native",
            ])
            @test PRESAGe._program_data(read_plan(joinpath(replay, "plan.toml")).program) ==
                  PRESAGe._program_data(plan.program)
            @test cpu_check(
                plan,
                periodic_neighbours(IEEE16);
                backend = :ap_fixed,
                float_backend = :native,
                generated_directory = replay,
            ) == length(periodic_neighbours(IEEE16))
        end
    end
end

@testset "Periodic wide quadrants and small contracts" begin
    for kind in (:sin, :cos)
        baseline = periodic_results[kind]
        for domain in ((3, 3), (-3, -3), (-1 // 3, 1 // 3), (1 // 3, 2 // 3))
            spec = FunctionSpec(
                "$kind(x)";
                input_format = IEEE16,
                domain,
                absolute_error = 1 // 512,
            )
            result = certify_plan(periodic_rebuild(baseline, spec))
            words = [round_ieee(x, IEEE16) for x in (domain..., 0, 1 // 2)]
            check_periodic(result, words)
            @test cpu_check(
                result.plan,
                words;
                backend = :ac_fixed,
                float_backend = :ac_std_float,
            ) == length(words)
        end
        spec = FunctionSpec(
            "$kind(x)";
            input_format = IEEE16,
            domain = (-32, 32),
            absolute_error = 1,
        )
        result = certified_polynomial(
            spec;
            transformation = kind,
            degree = 0,
            internal_format = FixedFormat(56, 8),
            evaluation = :separate,
        )
        check_periodic(result, periodic_neighbours(IEEE16))
        @test cpu_check(result.plan, periodic_neighbours(IEEE16); backend = :ap_fixed) ==
              length(periodic_neighbours(IEEE16))
        for (input, output) in ((FixedFormat(8, 3), IEEE32), (IEEE32, FixedFormat(16, 4)))
            spec = FunctionSpec(
                "$kind(x)";
                input_format = input,
                output_format = output,
                domain = (-1, 1),
            )
            @test_throws ArgumentError certified_polynomial(
                spec;
                transformation = kind,
                degree = 3,
            )
        end
        radius = big(2)^70
        spec = FunctionSpec(
            "$kind(x)";
            input_format = IEEE64,
            output_format = IEEE32,
            domain = (-radius, radius),
            absolute_error = 1 // 2^20,
        )
        result = certified_polynomial(
            spec;
            transformation = kind,
            degree = 9,
            internal_format = FixedFormat(112, 8),
            evaluation = :fma,
        )
        @test result.status == :certified
        result.status == :certified || error(result.reason)
        @test first(PRESAGe._periodic_audit(result.plan).paths).quadrant_format.width > 64
        words = periodic_neighbours(IEEE64)
        for x in (-radius, -radius // 3, radius // 3, radius)
            word = round_ieee(x, IEEE64)
            append!(words, (word - 1, word, word + 1))
        end
        check_periodic(result, words)
        @test cpu_check(
            result.plan,
            words;
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            public_api = true,
        ) == length(words)
        @test cpu_check(
            result.plan,
            words;
            backend = :ap_fixed,
            float_backend = :ac_std_float,
        ) == length(words)
        @test cpu_check(
            result.plan,
            words;
            backend = :portable,
            float_backend = :ac_std_float,
        ) == length(words)
    end
end
