isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))

function check_root(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan, bound = result.plan, result.total_bound
    kind = Symbol(plan.settings["transformation"])
    ranges =
        isempty(result.paths) ? Dict() :
        Dict(b.node => b.range for b in only(result.paths).ranges)
    for word in words
        input = decode_ieee(word, plan.spec.input_format)
        trace = interpret_trace(plan, word)
        x = input.value
        expected = if input.kind == :infinity && !input.negative
            kind == :sqrt ? PRESAGe._inf(plan.spec.output_format) : UInt64(0)
        elseif input.kind == :zero && plan.spec.domain[1] <= 0 <= plan.spec.domain[2]
            (kind == :sqrt ? UInt64(0) : PRESAGe._inf(plan.spec.output_format)) |
            (input.negative ? PRESAGe._sign(plan.spec.output_format) : UInt64(0))
        elseif x === nothing || x <= 0 || !(plan.spec.domain[1] <= x <= plan.spec.domain[2])
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
        y = decode_ieee(trace.bits, plan.spec.output_format).value
        @test y !== nothing && y >= 0
        y === nothing && error("nonfinite root output")
        # Independent exact rational inequalities, without an approximate oracle:
        # sqrt(x) lies in [max(y-B,0),y+B]; rsqrt(x) lies there iff its
        # reciprocated squared endpoints enclose x.
        lower, upper = max(y - bound, 0), y + bound
        if kind == :sqrt
            @test lower^2 <= x <= upper^2
        else
            @test x * lower^2 <= 1 <= x * upper^2
        end
        @test all(trace.values) do (i, value)
            f = IR.format(plan.program, i)
            f isa Union{FloatFormat, FixedFormat} || return true
            q = PRESAGe._decode_input(value.bits, f).value
            haskey(ranges, i) && q !== nothing && ranges[i][1] <= q <= ranges[i][2]
        end
    end
end

@testset "Exact root argument and floor exponent splitting" begin
    for divisor in (1, 2, 3),
        e in (
            typemin(Int),
            -129,
            -24,
            -3,
            -2,
            -1,
            0,
            1,
            2,
            3,
            127,
            typemax(Int),
            big(2)^100,
            -big(2)^100 - 1,
        )

        q, r = split_exponent(e, divisor)
        @test big(e) == divisor * big(q) + r
        @test 0 <= r < divisor
    end
    @test split_exponent(-3) == (-2, 1)
    @test_throws ArgumentError split_exponent(0, 0)
    for f in (IEEE16, FloatFormat(2, 3))
        for word = UInt64(0):UInt64(PRESAGe._wordmask(f))
            x = decode_ieee(word, f)
            if x.kind != :finite
                @test_throws DomainError PRESAGe._root_argument(word, f)
                continue
            end
            _, e = normalize_float(word, f)
            q, r = split_exponent(e)
            t = decode_ieee(PRESAGe._root_argument(word, f), f)
            @test 1 <= t.value < 4
            @test !t.negative
            @test t.value * PRESAGe._pow2(2q) == abs(x.value)
        end
    end
    f = FloatFormat(8, 4096)
    for word in (big(1), (big(1) << f.fraction_bits) - 1, big(PRESAGe._inf(f)) - 1)
        _, e = normalize_float(word, f)
        q, r = split_exponent(e)
        @test decode_ieee(PRESAGe._root_argument(word, f), f).value * PRESAGe._pow2(2q) ==
              decode_ieee(word, f).value
    end
end

@testset "Root reconstruction IR and single output quantizer" begin
    f = FloatFormat(4, 4)
    finite = [
        w for
        w = UInt64(1):UInt64(PRESAGe._wordmask(f)) if decode_ieee(w, f).kind == :finite
    ]
    argument = PlanArtifact(
        FunctionSpec("x"; input_format = f);
        program = IR.Program([IR.Input(f), IR.RootArgument(1)]),
    )
    @test all(w -> evaluate_bits(argument, w) == PRESAGe._root_argument(w, f), finite)
    cpu_check(argument, finite; float_backend = :ac_std_float)
    for multiplier in (-1, 1)
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = f, output_format = IEEE32);
            program = IR.Program([
                IR.Input(f),
                IR.constant(1, IEEE32),
                IR.ScaleByInputExponent(2, 1, multiplier, IEEE32; divisor = 2),
            ]),
        )
        @test all(finite) do word
            _, e = normalize_float(word, f)
            evaluate_bits(plan, word) ==
            round_ieee(PRESAGe._pow2(multiplier * fld(e, 2)), IEEE32)
        end
        cpu_check(plan, finite; float_backend = :ac_std_float)
    end
    source = FixedFormat(24, 4)
    value = 3 // 4 + 1 // 1024 + 1 // 2^20
    plan = PlanArtifact(
        FunctionSpec("1/sqrt(x)"; input_format = IEEE32, output_format = IEEE16);
        program = IR.Program([
            IR.Input(IEEE32),
            IR.constant(value, source),
            IR.ScaleByInputExponent(2, 1, -1, IEEE16; divisor = 2),
        ]),
    )
    words = [round_ieee(PRESAGe._pow2(e), IEEE32) for e in (-3, -2, -1, 0, 1, 2, 30, 31)]
    @test evaluate_bits(plan, last(words)) == 385
    for backend in (:portable, :ac_fixed, :ap_fixed),
        float_backend in (:native, :ac_std_float)

        cpu_check(plan, words; backend, float_backend, public_api = true)
    end
    @test_throws ArgumentError IR.ScaleByInputExponent(1, 1, 1, IEEE16; divisor = 4)
    @test_throws ArgumentError IR.Program([IR.Input(FixedFormat(8, 4)), IR.RootArgument(1)])
    io = IOBuffer()
    write_plan(io, plan)
    data = TOML.parse(String(take!(io)))
    @test data["schema_version"] == 7
    @test PRESAGe._program_data(read_plan(IOBuffer(sprint(TOML.print, data))).program) ==
          PRESAGe._program_data(plan.program)
    data["schema_version"] = 6
    @test_throws ArgumentError PRESAGe._read_plan(data)
end

root_results = Dict{Tuple{Symbol, Symbol}, CertificationResult}()
@testset "Certified sqrt and rsqrt reduced kernels" begin
    for kind in (:sqrt, :rsqrt)
        spec = FunctionSpec(
            kind == :sqrt ? "sqrt(x)" : "1 / sqrt(x)";
            input_format = IEEE16,
            domain = (0, 65504),
            absolute_error = kind == :sqrt ? 1 // 4 : 4,
        )
        search = search_polynomial(
            spec,
            PolynomialSearchConfig(
                degrees = [11],
                internal_formats = [FixedFormat(80, 24)],
                transformation = kind,
                evaluation = :fma,
                job_timeout = 60,
                total_timeout = 90,
            ),
        )
        @test search.status == :certified
        search.selected === nothing && error(only(search.attempts).reason)
        root_results[(kind, :fma)] = search.selected
        layout = PRESAGe._root_audit(search.selected.plan)
        for evaluation in (:fma, :separate)
            result =
                evaluation == :fma ? search.selected :
                certify_plan(
                    root_polynomial_plan(
                        spec,
                        only(layout.paths).coefficients;
                        precision = layout.precision,
                        evaluation,
                    ),
                )
            root_results[(kind, evaluation)] = result
            words = vcat(
                [
                    UInt64(0),
                    UInt64(0x8000),
                    UInt64(1),
                    UInt64(2),
                    UInt64(1023),
                    UInt64(1024),
                    UInt64(0x7bff),
                    UInt64(0x7c00),
                    UInt64(0xfc00),
                    UInt64(0x7c01),
                    UInt64(0x7fff),
                    UInt64(0xffff),
                ],
                [
                    round_ieee(PRESAGe._pow2(e), IEEE16) for
                    e in (-14, -3, -2, -1, 0, 1, 2, 3, 14)
                ],
            )
            check_root(result, words)
            path = only(result.paths)
            @test path.coordinate_error == 0
            @test path.arithmetic_error > 0 && path.output_rounding > 0
            @test path.approximation[1] == 0
            cost = implementation_cost(result.plan)
            @test cost.normalizations == cost.exponent_scalings == 1
            @test cost.fmas == (evaluation == :fma ? 11 : 0)
            report = PRESAGe._certificate_data(result)
            @test report["transformation"]["kind"] == string(kind)
            @test report["transformation"]["input_exponents"] == [-24, 15]
            @test report["transformation"]["maximum_error_scale"] ==
                  (kind == :sqrt ? "128/1" : "4096/1")
            io = IOBuffer()
            write_plan(io, result.plan)
            replay = read_plan(IOBuffer(String(take!(io))))
            @test certify_plan(replay).status == :certified
            for backend in (:portable, :ac_fixed, :ap_fixed),
                float_backend in (:native, :ac_std_float)

                cpu_check(result.plan, words; backend, float_backend, public_api = true)
            end
        end
    end
end

@testset "Exhaustive binary16 sqrt and rsqrt verification" begin
    words = collect(UInt64(0):UInt64(0xffff))
    for kind in (:sqrt, :rsqrt)
        result = root_results[(kind, :fma)]
        check_root(result, words)
        cpu_check(result.plan, words; backend = :portable, float_backend = :native)
        cpu_check(result.plan, words; backend = :ac_fixed, float_backend = :ac_std_float)
        cpu_check(result.plan, words; backend = :ap_fixed, float_backend = :ac_std_float)
    end
end

@testset "Root zero branches and graph proof refusal" begin
    for kind in (:sqrt, :rsqrt)
        expression = kind == :sqrt ? "sqrt(x)" : "1/sqrt(x)"
        spec = FunctionSpec(expression; input_format = IEEE16, domain = (0, 0))
        plan = root_polynomial_plan(spec, [0]; internal_format = FixedFormat(2, 1))
        result = certify_plan(plan)
        @test result.status == :certified &&
              result.total_bound == 0 &&
              isempty(result.paths)
        words = [
            UInt64(0),
            UInt64(0x8000),
            UInt64(1),
            UInt64(0x7c00),
            UInt64(0xfc00),
            UInt64(0x7fff),
        ]
        check_root(result, words)
        cpu_check(plan, words; backend = :ac_fixed, float_backend = :ac_std_float)
        @test PRESAGe._certificate_data(result)["transformation"]["zero_only"]
        bounded = FunctionSpec(
            expression;
            input_format = IEEE16,
            domain = (1, 16),
            absolute_error = 8,
        )
        p = root_polynomial_plan(bounded, [1]; internal_format = FixedFormat(3, 2))
        check_root(
            certify_plan(p),
            [
                UInt64(0),
                UInt64(0x8000),
                round_ieee(1, IEEE16),
                round_ieee(16, IEEE16),
                UInt64(0x7c00),
            ],
        )
        for domain in (nothing, (-1, 1), (-1, 0))
            bad = FunctionSpec(expression; input_format = IEEE16, domain)
            @test_throws ArgumentError certified_polynomial(
                bad;
                degree = 3,
                transformation = kind,
            )
        end
        @test_throws ArgumentError root_polynomial_plan(
            FunctionSpec(expression; input_format = FixedFormat(16, 8), domain = (1, 2)),
            [1],
        )
        @test_throws ArgumentError root_polynomial_plan(
            FunctionSpec(expression; output_format = FixedFormat(16, 8), domain = (1, 2)),
            [1],
        )
    end
    plan = root_results[(:sqrt, :fma)].plan
    for expression in ("1/sqrt(x)", "sqrt(x)+1", "sin(x)")
        spec = FunctionSpec(
            expression;
            input_format = IEEE16,
            domain = (0, 65504),
            absolute_error = 1,
        )
        @test_throws ArgumentError root_polynomial_plan(spec, [1]; transformation = :sqrt)
        @test certify_plan(
            PlanArtifact(
                spec;
                program = plan.program,
                precision = plan.precision,
                settings = plan.settings,
            ),
        ).status == :unsupported_domain
    end
    for kind in (IR.RootArgument, IR.ScaleByInputExponent, IR.CopySign, IR.FMA, IR.Select)
        nodes = collect(plan.program.nodes)
        i = findfirst(n -> n isa kind, nodes)
        n = nodes[i]
        nodes[i] =
            kind == IR.RootArgument ? IR.FloatMantissa(n.source) :
            kind == IR.ScaleByInputExponent ?
            IR.ScaleByInputExponent(n.source, n.input, n.multiplier, n.format) :
            kind == IR.CopySign ? IR.CopySign(n.source, 1) :
            kind == IR.FMA ? IR.FMA(n.a, n.b, n.a, n.format) :
            IR.Select(n.condition, n.no, n.yes)
        @test certify_plan(
            PlanArtifact(
                plan.spec;
                program = IR.Program(nodes; output = plan.program.output),
                precision = plan.precision,
                settings = plan.settings,
            ),
        ).status == :unsupported_domain
    end
    narrow = FunctionSpec(
        "sqrt(x)";
        input_format = IEEE16,
        output_format = FloatFormat(3, 3),
        domain = (0, 65504),
        absolute_error = 1,
    )
    overflowing = root_polynomial_plan(
        narrow,
        only(PRESAGe._root_audit(plan).paths).coefficients;
        precision = plan.precision,
        evaluation = :fma,
    )
    @test certify_plan(overflowing).status == :proof_failed
    strict = FunctionSpec(
        "sqrt(x)";
        input_format = IEEE16,
        domain = (0, 65504),
        absolute_error = 1 // 2^30,
    )
    @test certify_plan(
        PlanArtifact(
            strict;
            program = plan.program,
            precision = plan.precision,
            settings = plan.settings,
        ),
    ).status == :bound_exceeds_budget
    @test_throws ArgumentError PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [3],
        internal_formats = [IEEE32],
        transformation = :sqrt,
        segments = [2],
    )
end

@testset "Root precision search and configuration replay" begin
    for kind in (:sqrt, :rsqrt)
        config = PolynomialSearchConfig(
            degrees = [11],
            internal_formats = [FixedFormat(80, 24)],
            transformation = kind,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        )
        io = IOBuffer()
        write_search_config(io, config)
        data = TOML.parse(String(take!(io)))
        @test data["schema_version"] == 6
        @test read_search_config(IOBuffer(sprint(TOML.print, data))).transformation == kind
        data["schema_version"] = 5
        @test_throws ArgumentError PRESAGe._read_search_config(data)
        optimized = optimize_precision(
            root_results[(kind, :fma)];
            max_attempts = 3,
            job_timeout = 60,
            total_timeout = 180,
        )
        @test optimized.status == :certified
        @test any(a -> a.accepted, optimized.attempts)
        check_root(
            optimized.selected,
            [
                UInt64(1),
                UInt64(1023),
                round_ieee(1, IEEE16),
                round_ieee(2, IEEE16),
                UInt64(0x7bff),
            ],
        )
        cpu_check(
            optimized.selected.plan,
            [UInt64(1), round_ieee(1, IEEE16), UInt64(0x7bff)];
            backend = :ac_fixed,
            float_backend = :ac_std_float,
        )
    end
end

@testset "Root floating and wide mixed precision" begin
    for (kind, input, output, domain, internal, target) in (
        (:sqrt, FloatFormat(4, 4), IEEE32, (1 // 1024, 16), FloatFormat(11, 40), 1 // 2048),
        (
            :rsqrt,
            FloatFormat(4, 4),
            IEEE32,
            (1 // 1024, 16),
            FloatFormat(11, 40),
            1 // 2048,
        ),
        (
            :sqrt,
            FloatFormat(8, 100),
            FloatFormat(11, 112),
            (1 // 4, 16),
            FixedFormat(96, 24),
            1 // 2^20,
        ),
        (
            :rsqrt,
            FloatFormat(8, 100),
            FloatFormat(11, 112),
            (1 // 4, 16),
            FixedFormat(96, 24),
            1 // 2^20,
        ),
    )
        spec = FunctionSpec(
            kind == :sqrt ? "sqrt(x)" : "1/sqrt(x)";
            input_format = input,
            output_format = output,
            domain,
            absolute_error = target,
        )
        search = search_polynomial(
            spec,
            PolynomialSearchConfig(
                degrees = [input == FloatFormat(4, 4) ? 11 : 13],
                internal_formats = [internal],
                transformation = kind,
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
            [
                round_ieee(x, input) for
                x in (1 // 4, 1 // 2, 3 // 4, 1, 3 // 2, 2, 3, 4, 8, 16)
            ]
        check_root(result, words)
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
    for kind in (:sqrt, :rsqrt)
        baseline = root_results[(kind, :fma)]
        p = baseline.plan.precision
        stages = collect(p.stage_formats)
        stages[1], stages[2] = FixedFormat(76, 20), FixedFormat(78, 22)
        precision = PolynomialPrecision(
            p.coordinate_format;
            coefficient_formats = p.coefficient_formats,
            stage_formats = stages,
        )
        result = certify_plan(PRESAGe._reformat_polynomial(baseline.plan, precision))
        check_root(result, [UInt64(1), round_ieee(3 // 2, IEEE16), UInt64(0x7bff)])
        for backend in (:portable, :ac_fixed, :ap_fixed)
            cpu_check(
                result.plan,
                [UInt64(1), round_ieee(3 // 2, IEEE16), UInt64(0x7bff)];
                backend,
                float_backend = :ac_std_float,
            )
        end
    end
    # Coefficient payloads and initial/stage casts survive the graph audit.
    spec = FunctionSpec(
        "sqrt(x)";
        input_format = IEEE16,
        output_format = IEEE32,
        domain = (1, 4),
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
    cpu_check(plan, [round_ieee(3 // 2, IEEE16)]; float_backend = :ac_std_float)
end

@testset "Root CLI generation and stored replay" begin
    mktempdir() do directory
        contract, config, artifact =
            joinpath.(Ref(directory), ("contract.toml", "search.toml", "result"))
        spec = root_results[(:sqrt, :fma)].plan.spec
        write_plan(contract, PlanArtifact(spec))
        write_search_config(
            config,
            PolynomialSearchConfig(
                degrees = [11],
                internal_formats = [FixedFormat(80, 24)],
                transformation = :sqrt,
                evaluation = :fma,
                job_timeout = 60,
                total_timeout = 90,
            ),
        )
        generated = generate_main([
            contract,
            artifact,
            "--search-config=$config",
            "--backend=ap_fixed",
            "--float-backend=ac_std_float",
        ])
        @test generated.program !== nothing
        stored = read_plan(joinpath(artifact, "plan.toml"))
        @test stored.settings["transformation"] == "sqrt"
        @test TOML.parsefile(joinpath(artifact, "plan.toml"))["schema_version"] == 7
        @test TOML.parsefile(joinpath(artifact, "search.toml"))["schema_version"] == 6
        @test TOML.parsefile(joinpath(artifact, "certificate.toml"))["transformation"]["kind"] ==
              "sqrt"
        cpu_check(
            stored,
            [
                UInt64(0),
                UInt64(0x8000),
                UInt64(1),
                round_ieee(2, IEEE16),
                UInt64(0x7bff),
                UInt64(0x7c00),
                UInt64(0xfc00),
            ];
            backend = :ap_fixed,
            float_backend = :ac_std_float,
            generated_directory = artifact,
        )
        rsqrt = joinpath(directory, "rsqrt.toml")
        write_plan(rsqrt, root_results[(:rsqrt, :fma)].plan)
        replay = joinpath(directory, "replay")
        generated = generate_main([
            rsqrt,
            replay,
            "--backend=ac_fixed",
            "--float-backend=ac_std_float",
            "--certify=true",
        ])
        @test generated.program !== nothing
        stored = read_plan(joinpath(replay, "plan.toml"))
        @test stored.settings["transformation"] == "rsqrt"
        cpu_check(
            stored,
            [
                UInt64(0),
                UInt64(0x8000),
                UInt64(1),
                round_ieee(2, IEEE16),
                UInt64(0x7bff),
                UInt64(0x7c00),
                UInt64(0xfc00),
            ];
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            generated_directory = replay,
        )
    end
end
