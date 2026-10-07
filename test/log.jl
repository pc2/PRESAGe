isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
const log_results = Dict{Symbol, CertificationResult}()

function check_log(result, words)
    @test result.status == :certified
    result.status == :certified || error(result.reason)
    plan, bound = result.plan, result.total_bound
    ranges =
        isempty(result.paths) ? Dict() :
        Dict(b.node => b.range for b in only(result.paths).ranges)
    with_oracle(plan.spec; backend = :mpfr) do oracle
        for word in words
            input = decode_ieee(word, plan.spec.input_format)
            trace = interpret_trace(plan, word)
            expected = if input.kind == :infinity && !input.negative
                PRESAGe._inf(plan.spec.output_format)
            elseif input.value === nothing ||
                   input.value < 0 ||
                   !(plan.spec.domain[1] <= input.value <= plan.spec.domain[2])
                PRESAGe._nan(plan.spec.output_format)
            elseif input.kind == :zero
                PRESAGe._inf(plan.spec.output_format) | PRESAGe._sign(plan.spec.output_format)
            elseif input.value == 1
                UInt64(0)
            else
                nothing
            end
            if expected !== nothing
                @test trace.bits == expected
                @test !any(keys(trace.values)) do i
                    plan.program.nodes[i] isa Union{
                        IR.FloatMantissa,
                        IR.FloatExponent,
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
            output.value === nothing && error("nonfinite log output")
            ref = reference(oracle, word)
            @test ref.status == :resolved
            @test ref.enclosure !== nothing
            lo, hi = map(ref.enclosure) do b
                b.significand * PRESAGe._pow2(b.exponent)
            end
            # Directed MPFR endpoints are independent of Sollya's norm proof.
            @test max(abs(output.value - lo), abs(output.value - hi)) <= bound
            @test all(trace.values) do (i, value)
                f = IR.format(plan.program, i)
                f isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(value.bits, f).value
                haskey(ranges, i) && q !== nothing && ranges[i][1] <= q <= ranges[i][2]
            end
        end
    end
end

@testset "Exact exponent IR and C++" begin
    for f in (IEEE16, FloatFormat(2, 3))
        p = IR.Program([IR.Input(f), IR.FloatExponent(1)])
        ef = IR.format(p, 2)
        @test ef == PRESAGe._float_exponent_format(f)
        @test ef.signed && ef.integer_bits == ef.width
        valid = UInt64[]
        for word = UInt64(0):UInt64(PRESAGe._wordmask(f))
            x = decode_ieee(word, f)
            if x.kind != :finite
                @test_throws DomainError evaluate_bits(p, word)
                continue
            end
            m, e = normalize_float(word, f)
            @test decode_fixed(evaluate_bits(p, word), ef) == e
            @test decode_ieee(m, f).value * PRESAGe._pow2(e) == abs(x.value)
            push!(valid, word)
        end
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = f, output_format = ef);
            program = p,
        )
        data = PRESAGe._plan_data(plan)
        @test data["schema_version"] == 9
        @test PRESAGe._program_data(
            read_plan(IOBuffer(sprint(write_plan, plan))).program,
        ) == PRESAGe._program_data(p)
        for version in (6, 7, 8)
            invalid = deepcopy(data)
            invalid["schema_version"] = version
            @test_throws ArgumentError PRESAGe._read_plan(invalid)
        end
        words = f == IEEE16 ? valid[1:97:end] : valid
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (f == IEEE16 ? (:native, :ac_std_float) : (:ac_std_float,))

            cpu_check(plan, words; backend, float_backend, public_api = true)
        end
    end
    @test PRESAGe._float_exponent_format(FloatFormat(62, 10)).width == 63
    @test PRESAGe._float_exponent_format(FloatFormat(2, typemax(Int) - 4)).width == 64
    @test_throws ArgumentError IR.Program([
        IR.Input(FixedFormat(8, 8)),
        IR.FloatExponent(1),
    ])
end

@testset "Certified log reconstruction" begin
    spec = FunctionSpec(
        "log(x)";
        input_format = IEEE16,
        domain = (0, 65504),
        absolute_error = 1 // 64,
    )
    search = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [9],
            internal_formats = [FixedFormat(80, 24)],
            transformation = :log,
            evaluation = :fma,
            job_timeout = 60,
            total_timeout = 90,
        ),
    )
    @test search.status == :certified
    search.status == :certified || error(search.attempts[end].reason)
    layout = PRESAGe._log_audit(search.selected.plan)
    path = only(layout.paths)
    words = vcat(
        UInt64[
            0,
            0x8000,
            1,
            2,
            1023,
            1024,
            0x3bff,
            0x3c00,
            0x3c01,
            0x7bff,
            0x7c00,
            0xfc00,
            0x7c01,
            0xffff,
        ],
        [round_ieee(PRESAGe._pow2(e), IEEE16) for e in (-24, -14, -3, -1, 0, 1, 3, 15)],
    )
    for evaluation in (:fma, :separate)
        result =
            evaluation == :fma ? search.selected :
            certify_plan(
                log_polynomial_plan(
                    spec,
                    path.coefficients,
                    path.log2;
                    precision = layout.precision,
                    evaluation,
                ),
            )
        log_results[evaluation] = result
        check_log(result, words)
        bound = only(result.paths)
        @test bound.coordinate_error == 0
        @test bound.arithmetic_error > 0
        @test bound.output_rounding == 1 // 128
        report = PRESAGe._certificate_data(result)
        @test report["transformation"]["kind"] == "log"
        @test report["transformation"]["input_exponents"] == [-24, 15]
        @test PRESAGe._parse_rational(report["transformation"]["log2_error_bound"]) > 0
        @test implementation_cost(result.plan).exponent_extractions == 1
        @test implementation_cost(result.plan).fmas == (evaluation == :fma ? 10 : 0)
        replay = read_plan(IOBuffer(sprint(write_plan, result.plan)))
        @test certify_plan(replay).total_bound == result.total_bound
        for backend in (:portable, :ac_fixed, :ap_fixed),
            float_backend in (:native, :ac_std_float)

            cpu_check(result.plan, words; backend, float_backend, public_api = true)
        end
    end
end

@testset "Exhaustive binary16 log verification" begin
    result = log_results[:fma]
    words = collect(UInt64(0):UInt64(0xffff))
    check_log(result, words)
    for backend in (:portable, :ac_fixed, :ap_fixed),
        float_backend in (:native, :ac_std_float)

        cpu_check(result.plan, words; backend, float_backend, public_api = true)
    end
    # Separate reconstruction has its own certificate and independent checks.
    check_log(log_results[:separate], UInt64(1):UInt64(0x7bff))
end

@testset "Log domains, exact branches and proof refusals" begin
    baseline = log_results[:fma]
    path = only(PRESAGe._log_audit(baseline.plan).paths)
    for domain in ((0, 0), (1, 1), (0, 1), (1, 65504), (1 // 8, 1 // 2))
        spec =
            FunctionSpec("log(x)"; input_format = IEEE16, domain, absolute_error = 1 // 64)
        plan = log_polynomial_plan(
            spec,
            path.coefficients,
            path.log2;
            precision = baseline.plan.precision,
            evaluation = :fma,
        )
        result = certify_plan(plan)
        check_log(
            result,
            UInt64[
                0,
                0x8000,
                1,
                0x3000,
                0x3800,
                0x3bff,
                0x3c00,
                0x3c01,
                0x7bff,
                0x7c00,
                0xfc00,
                0xffff,
            ],
        )
        if domain in ((0, 0), (1, 1))
            @test result.total_bound == 0 && isempty(result.paths)
            @test PRESAGe._certificate_data(result)["transformation"]["exceptional_only"]
        end
        cpu_check(
            plan,
            UInt64[0, 1, 0x3800, 0x3c00, 0x7bff, 0x7c00, 0xfc00];
            backend = :ac_fixed,
        )
    end
    for value in (0, 1)
        exact = certified_polynomial(
            FunctionSpec("log(x)"; input_format = IEEE16, domain = (value, value));
            degree = 0,
            internal_format = FixedFormat(32, 8),
            transformation = :log,
        )
        @test exact.status == :certified && exact.total_bound == 0
        @test isempty(exact.paths)
    end
    for spec in (
        FunctionSpec("log1p(x)"; domain = (0, 1)),
        FunctionSpec("log(x)"),
        FunctionSpec("log(x)"; domain = (-1, 1)),
        FunctionSpec("log(x)"; input_format = FixedFormat(16, 8), domain = (1, 2)),
        FunctionSpec("log(x)"; output_format = FixedFormat(16, 8), domain = (1, 2)),
    )
        @test_throws ArgumentError log_polynomial_plan(spec, [0], 1)
    end
    @test_throws ArgumentError PolynomialSearchConfig(
        degrees = [2],
        internal_formats = [IEEE32],
        transformation = :log,
        segments = [2],
    )
    nodes = collect(baseline.plan.program.nodes)
    nodes[path.log2_node] = IR.constant(0, baseline.plan.precision.coordinate_format)
    wrong_constant = PlanArtifact(
        baseline.plan.spec;
        program = IR.Program(nodes; output = baseline.plan.program.output),
        precision = baseline.plan.precision,
        settings = baseline.plan.settings,
    )
    @test certify_plan(wrong_constant).status == :bound_exceeds_budget
    for kind in (IR.FloatExponent, IR.FloatMantissa, IR.FMA, IR.Select)
        nodes = collect(baseline.plan.program.nodes)
        i = findfirst(n -> n isa kind, nodes)
        n = nodes[i]
        nodes[i] =
            kind == IR.FloatExponent ? IR.constant(0, IR.format(baseline.plan.program, i)) :
            kind == IR.FloatMantissa ?
            IR.Convert(n.source, IR.format(baseline.plan.program, i)) :
            kind == IR.FMA ? IR.FMA(n.a, n.a, n.c, n.format) :
            IR.Select(n.condition, n.no, n.yes)
        mutated = PlanArtifact(
            baseline.plan.spec;
            program = IR.Program(nodes; output = baseline.plan.program.output),
            precision = baseline.plan.precision,
            settings = baseline.plan.settings,
        )
        @test certify_plan(mutated).status == :unsupported_domain
    end
    tight = FunctionSpec(
        "log(x)";
        input_format = IEEE16,
        domain = baseline.plan.spec.domain,
        absolute_error = 1 // 2^30,
    )
    @test certify_plan(
        log_polynomial_plan(
            tight,
            path.coefficients,
            path.log2;
            precision = baseline.plan.precision,
        ),
    ).status == :bound_exceeds_budget
    narrow = PolynomialPrecision(
        FixedFormat(64, 4);
        coefficient_formats = baseline.plan.precision.coefficient_formats,
        stage_formats = baseline.plan.precision.stage_formats,
    )
    @test certify_plan(
        log_polynomial_plan(
            baseline.plan.spec,
            path.coefficients,
            path.log2;
            precision = narrow,
        ),
    ).status == :proof_failed
end

@testset "Log custom floating and individual precision" begin
    baseline = log_results[:fma]
    path = only(PRESAGe._log_audit(baseline.plan).paths)
    for (input, output, domain, internal) in (
        (FloatFormat(2, 3), IEEE32, (0, 3), IEEE64),
        (
            FloatFormat(8, 100),
            FloatFormat(11, 112),
            (1 // (big(1) << 100), big(1) << 100),
            FixedFormat(80, 24),
        ),
    )
        spec = FunctionSpec(
            "log(x)";
            input_format = input,
            output_format = output,
            domain,
            absolute_error = 1 // 2^20,
        )
        precision = PolynomialPrecision(
            internal;
            coefficient_formats = fill(internal, 10),
            stage_formats = internal isa FixedFormat ?
                            [FixedFormat(72 + i, 24) for i = 1:10] : fill(internal, 10),
        )
        result = certify_plan(
            log_polynomial_plan(
                spec,
                path.coefficients,
                path.log2;
                precision,
                evaluation = :fma,
            ),
        )
        words =
            input == FloatFormat(2, 3) ? collect(UInt64(0):UInt64(63)) :
            [
                round_ieee(q, input) for
                q in (domain[1], 1 // 2, 1, 1 + 1 // (big(1) << 100), 2, 3, domain[2])
            ]
        check_log(result, words)
        @test precision_cost(result.plan).stage_widths ==
              collect(PRESAGe._width.(precision.stage_formats))
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

@testset "Log precision search, CLI and replay" begin
    baseline = log_results[:fma]
    optimized = optimize_precision(
        baseline;
        max_attempts = 3,
        job_timeout = 60,
        total_timeout = 180,
    )
    @test optimized.selected !== nothing
    @test optimized.selected.status == :certified
    @test any(a -> a.accepted, optimized.attempts)
    @test precision_cost(optimized.selected.plan).coefficient_bits +
          precision_cost(optimized.selected.plan).stage_bits <
          precision_cost(baseline.plan).coefficient_bits +
          precision_cost(baseline.plan).stage_bits
    check_log(optimized.selected, UInt64[1, 1024, 0x3bff, 0x3c00, 0x3c01, 0x7bff])
    config = PolynomialSearchConfig(
        degrees = [9],
        internal_formats = [baseline.plan.precision.coordinate_format],
        transformation = :log,
        evaluation = :fma,
        job_timeout = 60,
        total_timeout = 90,
    )
    data = PRESAGe._search_config_data(config)
    @test data["schema_version"] == 8
    @test PRESAGe._read_search_config(data).transformation == :log
    for version = 1:7
        invalid = deepcopy(data)
        invalid["schema_version"] = version
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
    end
    mktempdir() do directory
        contract, configuration, generated, replayed =
            joinpath.(
                Ref(directory),
                ("contract.toml", "search.toml", "generated", "replayed"),
            )
        write_plan(contract, PlanArtifact(baseline.plan.spec))
        write_search_config(configuration, config)
        generated_plan =
            generate_main([contract, generated, "--search-config=$configuration"])
        @test TOML.parsefile(joinpath(generated, "certificate.toml"))["status"] ==
              "certified"
        report = TOML.parsefile(joinpath(generated, "search.toml"))
        @test report["schema_version"] == 8 && report["transformation"] == "log"
        replay_plan = generate_main([joinpath(generated, "plan.toml"), replayed])
        @test PRESAGe._program_data(replay_plan.program) ==
              PRESAGe._program_data(generated_plan.program)
        @test read(joinpath(generated, "evaluator.hpp"), String) ==
              read(joinpath(replayed, "evaluator.hpp"), String)
        cpu_check(
            generated_plan,
            UInt64[0, 1, 0x3bff, 0x3c00, 0x3c01, 0x7bff, 0x7c00];
            backend = :ac_fixed,
            generated_directory = generated,
        )
    end
end

@testset "Log exponent conversion and stored constant error" begin
    input = round_ieee(big(1) << 25, IEEE32)
    spec = FunctionSpec(
        "log(x)";
        input_format = IEEE32,
        domain = (big(1) << 25, big(1) << 25),
        absolute_error = 3,
    )
    coordinate = FloatFormat(8, 3)
    precision = PolynomialPrecision(
        coordinate;
        coefficient_formats = [IEEE64],
        stage_formats = [IEEE64],
    )
    plan = log_polynomial_plan(spec, [0], 11 // 16; precision, evaluation = :fma)
    config = PolynomialSearchConfig(
        degrees = [0],
        internal_formats = [coordinate],
        precisions = [precision],
        transformation = :log,
        evaluation = :fma,
        job_timeout = 60,
        total_timeout = 90,
    )
    request = (;
        spec,
        config,
        domain = PRESAGe._polynomial_domain(spec),
        degree = 0,
        internal_format = coordinate,
        segments = 1,
        precision,
        stored_plan = PRESAGe._plan_data(plan),
    )
    attempt, deadline = PRESAGe._run_polynomial_job(
        request,
        time_ns();
        worker_command = PRESAGe._polynomial_worker_command,
        process_started = (_, _) -> nothing,
    )
    @test !deadline && attempt.status == :certified
    result = attempt.certificate
    check_log(result, [input])
    path = only(PRESAGe._log_audit(plan).paths)
    trace = interpret_trace(plan, input)
    @test decode_fixed(
        trace.values[path.exponent_node].bits,
        IR.format(plan.program, path.exponent_node),
    ) == 25
    @test decode_ieee(trace.values[path.exponent_value].bits, coordinate).value == 24
    @test decode_ieee(trace.bits, IEEE32).value == 16
    ranges, rho = PRESAGe._polynomial_ranges(plan.program, path)
    @test rho[path.exponent_value] == 1
    @test rho[path.reconstruction] == 1 // 2
    constant_error = PRESAGe._parse_rational(result.settings["log2_error_bound"])
    @test constant_error > 0
    @test only(result.paths).arithmetic_error == constant_error + 11 // 16 + 1 // 2
    @test_throws ArgumentError emit_cpp(IOBuffer(), plan; float_backend = :native)
    for backend in (:portable, :ac_fixed, :ap_fixed)
        cpu_check(plan, [input]; backend, float_backend = :ac_std_float, public_api = true)
    end
end
