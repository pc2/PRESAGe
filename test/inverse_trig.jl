isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
const inverse_trig_results = Dict{Symbol, CertificationResult}()

function inverse_trig_words(f)
    words = Set{IR.Word}((
        IR._word(0, f),
        PRESAGe._sign(f),
        IR._word(1, f),
        PRESAGe._sign(f) | 1,
        PRESAGe._inf(f),
        PRESAGe._inf(f) | PRESAGe._sign(f),
        PRESAGe._nan(f),
    ))
    for x in (-2, -1, -3 // 4, -1 // 2, -1 // 3, 1 // 3, 1 // 2, 3 // 4, 1, 2)
        w = round_ieee(x, f)
        for candidate in (w - 1, w, w + 1)
            0 <= candidate <= PRESAGe._word_mask(PRESAGe._width(f)) &&
                push!(words, candidate)
        end
    end
    # Vary endpoint distance through all input fraction bits and root exponents.
    for e in unique([
        1,
        2,
        3,
        4,
        7,
        12,
        f.fraction_bits - 1,
        f.fraction_bits,
        f.fraction_bits + 1,
    ])
        e >= 1 || continue
        for sign in (-1, 1)
            push!(words, round_ieee(sign * (1 - PRESAGe._pow2(-e)), f))
        end
    end
    sort!(collect(words))
end

function check_inverse_trig(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan = result.plan
    layout = PRESAGe._inverse_trig_audit(plan)
    ranges = [Dict(b.node => b.range for b in p.ranges) for p in result.paths]
    with_oracle(plan.spec; backend = :mpfr) do oracle
        for word in words
            x = decode_ieee(word, plan.spec.input_format)
            trace = interpret_trace(plan, word)
            numerical = any(
                i ->
                    plan.program.nodes[i] isa Union{
                        IR.Mul,
                        IR.Add,
                        IR.FMA,
                        IR.RootArgument,
                        IR.ScaleByInputExponent,
                    },
                keys(trace.values),
            )
            if x.value === nothing ||
               !(plan.spec.domain[1] <= x.value <= plan.spec.domain[2]) ||
               abs(x.value) > 1
                @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                @test !numerical
                continue
            end
            j = only(
                j for (j, p) in enumerate(layout.paths) if
                p.input_domain[1] <= x.value <= p.input_domain[2]
            )
            path = layout.paths[j]
            y = decode_ieee(trace.bits, plan.spec.output_format)
            @test y.value !== nothing
            @test numerical == !path.special
            @test haskey(trace.values, path.mantissa) ==
                  (path.tail && !isempty(path.root_kernel.stages))
            if x.kind == :zero && layout.geometry.transformation == :asin
                @test trace.bits ==
                      (x.negative ? PRESAGe._sign(plan.spec.output_format) : 0)
            elseif x.value == 1 && layout.geometry.transformation == :acos
                @test trace.bits == 0
            else
                ref = reference(oracle, word)
                @test ref.status == :resolved && ref.enclosure !== nothing
                lo, hi = map(b -> b.significand * PRESAGe._pow2(b.exponent), ref.enclosure)
                @test max(abs(y.value - lo), abs(y.value - hi)) <= result.paths[j].total
            end
            if path.tail
                t =
                    PRESAGe._decode_input(
                        trace.values[path.t].bits,
                        IR.format(plan.program, path.t),
                    ).value
                @test t == (1 - abs(x.value)) / 2 && t > 0
            end
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

function inverse_trig_rebuild(
    base,
    spec = base.plan.spec;
    precision = base.plan.precision,
    evaluation = :fma,
    pi2 = nothing,
    sqrt_coefficients = nothing,
)
    layout = PRESAGe._inverse_trig_audit(base.plan)
    inverse_trig_polynomial_plan(
        spec,
        layout.asin_coefficients,
        sqrt_coefficients === nothing ? layout.sqrt_coefficients : sqrt_coefficients,
        pi2 === nothing ? layout.pi2 : pi2;
        precision,
        evaluation,
    )
end

@testset "Certified asin/acos endpoint transformations" begin
    for kind in (:asin, :acos)
        spec = FunctionSpec(
            "$kind(x)";
            input_format = IEEE16,
            domain = (-1, 1),
            absolute_error = 1 // 512,
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
        result = search.selected
        inverse_trig_results[kind] = result
        @test length(result.paths) == 7
        @test result.total_bound <= spec.absolute_error
        check_inverse_trig(result, inverse_trig_words(IEEE16))
        @test precision_cost(result.plan).coefficient_bits == 2 * 10 * 72
        @test precision_cost(result.plan).stage_bits == 2 * 10 * 72
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            @test cpu_check(
                result.plan,
                inverse_trig_words(IEEE16);
                backend,
                float_backend,
                public_api = true,
            ) == length(inverse_trig_words(IEEE16))
        end
        separate = certify_plan(inverse_trig_rebuild(result; evaluation = :separate))
        check_inverse_trig(separate, inverse_trig_words(IEEE16))
        @test cpu_check(
            separate.plan,
            inverse_trig_words(IEEE16);
            backend = :ap_fixed,
            float_backend = :ac_std_float,
        ) == length(inverse_trig_words(IEEE16))
    end
end

@testset "Exhaustive binary16 inverse trig verification" begin
    for kind in (:asin, :acos)
        result = inverse_trig_results[kind]
        for evaluation in (:fma, :separate)
            candidate =
                evaluation == :fma ? result :
                certify_plan(inverse_trig_rebuild(result; evaluation))
            check_inverse_trig(candidate, UInt64(0):UInt64(65535))
        end
        @test cpu_check(
            result.plan,
            UInt64(0):UInt64(65535);
            backend = :ac_fixed,
            float_backend = :ac_std_float,
        ) == 65536
    end
end

@testset "Inverse trig custom formats and individual precision" begin
    for kind in (:asin, :acos)
        for (input, output, internal, degree, budget) in (
            (IEEE32, IEEE32, FixedFormat(96, 32), 13, 1 // 2^20),
            (IEEE64, IEEE64, IEEE64, 13, 1 // 2^20),
            (FloatFormat(2, 3), IEEE16, FixedFormat(72, 24), 9, 1 // 512),
            (FloatFormat(11, 80), FloatFormat(11, 80), FixedFormat(128, 32), 17, 1 // 2^32),
        )
            spec = FunctionSpec(
                "$kind(x)";
                input_format = input,
                output_format = output,
                domain = (-1, 1),
                absolute_error = budget,
            )
            search = search_polynomial(
                spec,
                PolynomialSearchConfig(
                    degrees = [degree],
                    internal_formats = [internal],
                    transformation = kind,
                    evaluation = :fma,
                    job_timeout = 60,
                    total_timeout = 90,
                ),
            )
            @test search.status == :certified
            search.status == :certified || error(last(search.attempts).reason)
            words =
                input == FloatFormat(2, 3) ? (UInt64(0):UInt64(PRESAGe._wordmask(input))) :
                inverse_trig_words(input)
            result = search.selected
            check_inverse_trig(result, words)
            @test cpu_check(
                result.plan,
                words;
                backend = :ac_fixed,
                float_backend = :ac_std_float,
                public_api = true,
            ) == length(words)
            if input == IEEE32
                single_spec = FunctionSpec(
                    "$kind(x)";
                    input_format = IEEE32,
                    domain = (-1, 1),
                    absolute_error = 1 // 2^20,
                )
                precision = PolynomialPrecision(
                    FixedFormat(76, 24);
                    coefficient_formats = fill(FixedFormat(76, 24), 14),
                    stage_formats = fill(FixedFormat(76, 24), 14),
                )
                native = certify_plan(inverse_trig_rebuild(result, single_spec; precision))
                check_inverse_trig(native, words)
                @test cpu_check(
                    native.plan,
                    words;
                    backend = :ap_fixed,
                    float_backend = :native,
                ) == length(words)
            end
        end
        base = inverse_trig_results[kind]
        precision = PolynomialPrecision(
            FixedFormat(72, 24);
            coefficient_formats = [FixedFormat(72 - min(i, 4), 24) for i = 1:10],
            stage_formats = [FixedFormat(72 - min(i, 3), 24) for i = 1:10],
        )
        result = certify_plan(inverse_trig_rebuild(base; precision))
        check_inverse_trig(result, inverse_trig_words(IEEE16))
        @test cpu_check(result.plan, inverse_trig_words(IEEE16); backend = :ap_fixed) ==
              length(inverse_trig_words(IEEE16))
        stage = first(
            filter(p -> p.kind == :stage_range, PRESAGe._precision_proposals(base, 1, 0)),
        )
        reformatted = PRESAGe._reformat_polynomial(base.plan, stage.precision)
        @test PRESAGe._inverse_trig_audit(reformatted).sqrt_coefficients ==
              PRESAGe._inverse_trig_audit(base.plan).sqrt_coefficients
        check_inverse_trig(certify_plan(reformatted), inverse_trig_words(IEEE16))
    end
end

@testset "Inverse trig specials, small domains and proof refusals" begin
    for kind in (:asin, :acos)
        base = inverse_trig_results[kind]
        for domain in (
            (0, 0),
            (-1, -1),
            (1, 1),
            (-1 // 2, 1 // 2),
            (3 // 4, 1),
            (-1, -3 // 4),
            (1 // 3, 2 // 3),
        )
            spec = FunctionSpec(
                "$kind(x)";
                input_format = IEEE16,
                domain,
                absolute_error = 1 // 512,
            )
            result = certify_plan(inverse_trig_rebuild(base, spec))
            words =
                unique([inverse_trig_words(IEEE16); round_ieee.(domain, Ref(IEEE16))...])
            check_inverse_trig(result, words)
            @test cpu_check(
                result.plan,
                words;
                backend = :ac_fixed,
                float_backend = :ac_std_float,
            ) == length(words)
            all(p.special for p in PRESAGe._inverse_trig_audit(result.plan).paths) &&
                @test isempty(PRESAGe._precision_proposals(result, 1, 0))
        end
        for domain in (nothing, (-2, 1), (-1, 2))
            @test_throws ArgumentError certified_polynomial(
                FunctionSpec("$kind(x)"; domain);
                transformation = kind,
                degree = 9,
            )
        end
        for (input, output) in ((FixedFormat(8, 3), IEEE32), (IEEE32, FixedFormat(16, 4)))
            @test_throws ArgumentError certified_polynomial(
                FunctionSpec(
                    "$kind(x)";
                    input_format = input,
                    output_format = output,
                    domain = (-1, 1),
                );
                transformation = kind,
                degree = 9,
            )
        end
        @test_throws ArgumentError PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [9],
            internal_formats = [IEEE64],
            transformation = kind,
            segments = [2],
        )
        @test_throws ArgumentError certified_polynomial(
            FunctionSpec("sin(x)"; domain = (-1, 1));
            transformation = kind,
            degree = 9,
        )
        @test certify_plan(inverse_trig_rebuild(base; pi2 = 0)).status ==
              :bound_exceeds_budget
        @test certify_plan(
            inverse_trig_rebuild(base; sqrt_coefficients = fill(0, 10)),
        ).status != :certified
        p = base.plan
        layout = PRESAGe._inverse_trig_audit(p)
        tail = first(filter(p -> p.tail, layout.paths))
        for i in (
            tail.gap,
            tail.t,
            tail.mantissa,
            tail.root_value,
            tail.selected,
            tail.tail_subtraction.value,
        )
            nodes = collect(p.program.nodes)
            n = nodes[i]
            nodes[i] =
                n isa IR.Add ? IR.Add(n.a, n.a, n.format) :
                n isa IR.ScalePow2 ? IR.ScalePow2(n.source, n.exponent + 1, n.format) :
                n isa IR.RootArgument ? IR.RootArgument(n.source, 3) :
                n isa IR.ScaleByInputExponent ?
                IR.ScaleByInputExponent(n.source, n.input, -1, n.format; divisor = 2) :
                n isa IR.Select ? IR.Select(n.condition, n.no, n.yes) :
                IR.FMA(n.a, n.b, n.b, n.format)
            corrupt = PlanArtifact(
                p.spec;
                program = IR.Program(nodes; output = p.program.output),
                precision = p.precision,
                settings = p.settings,
            )
            @test certify_plan(corrupt).status == :unsupported_domain
            io = IOBuffer()
            write_certificate(io, certify_plan(corrupt))
            @test !haskey(TOML.parse(String(take!(io))), "coverage")
        end
        precision = PolynomialPrecision(
            FixedFormat(8, 3);
            coefficient_formats = fill(FixedFormat(8, 3), 10),
            stage_formats = fill(FixedFormat(8, 3), 10),
        )
        @test certify_plan(inverse_trig_rebuild(base; precision)).status != :certified
        spec = FunctionSpec(
            "$kind(x)";
            input_format = IEEE16,
            domain = (-1, 1),
            absolute_error = 1,
        )
        coarse = search_polynomial(
            spec,
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [0],
                internal_formats = [FixedFormat(72, 24)],
                transformation = kind,
                job_timeout = 60,
                total_timeout = 90,
            ),
        )
        @test coarse.status == :certified
        check_inverse_trig(coarse.selected, inverse_trig_words(IEEE16))
    end
end

@testset "Inverse trig precision search, artifacts and replay" begin
    for kind in (:asin, :acos)
        base = inverse_trig_results[kind]
        config = PolynomialSearchConfig(
            degrees = [9],
            internal_formats = [FixedFormat(72, 24)],
            transformation = kind,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        )
        io = IOBuffer()
        write_search_config(io, config)
        data = TOML.parse(String(take!(io)))
        @test data["schema_version"] == 14
        @test PRESAGe._read_search_config(data).transformation == kind
        data["schema_version"] = 13
        @test_throws ArgumentError PRESAGe._read_search_config(data)
        io = IOBuffer()
        write_certificate(io, base)
        report = TOML.parse(String(take!(io)))
        @test report["transformation"]["kind"] == string(kind)
        @test getindex.(report["paths"], "kind") ==
              string.(getproperty.(PRESAGe._inverse_trig_audit(base.plan).paths, :kind))
        optimization = optimize_precision(
            base;
            max_attempts = 2,
            job_timeout = 60,
            total_timeout = 120,
        )
        @test optimization.status == :certified
        @test any(a -> a.kind != :baseline && a.accepted, optimization.attempts)
        check_inverse_trig(optimization.selected, inverse_trig_words(IEEE16))
        mktempdir() do dir
            contract, settings =
                joinpath(dir, "contract.toml"), joinpath(dir, "search-config.toml")
            write_plan(contract, PlanArtifact(base.plan.spec))
            write_search_config(settings, config)
            generated, replay = joinpath(dir, "generated"), joinpath(dir, "replayed")
            generate_main([
                contract,
                generated,
                "--search-config=$settings",
                "--backend=ac_fixed",
                "--float-backend=ac_std_float",
            ])
            plan = read_plan(joinpath(generated, "plan.toml"))
            @test TOML.parsefile(joinpath(generated, "plan.toml"))["schema_version"] == 7
            @test TOML.parsefile(joinpath(generated, "search.toml"))["schema_version"] == 14
            @test cpu_check(
                plan,
                inverse_trig_words(IEEE16);
                backend = :ac_fixed,
                float_backend = :ac_std_float,
                generated_directory = generated,
            ) == length(inverse_trig_words(IEEE16))
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
                inverse_trig_words(IEEE16);
                backend = :ap_fixed,
                float_backend = :native,
                generated_directory = replay,
            ) == length(inverse_trig_words(IEEE16))
        end
    end
end
