isdefined(Main, :verification_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "verify.jl"))
isdefined(Main, :sweep_main) || include(joinpath(@__DIR__, "..", "scripts", "sweep.jl"))

function verification_rational(text)
    occursin('@', text) || return PRESAGe._parse_rational(text)
    m, e = split(text, '@')
    return parse(BigInt, m) * PRESAGe._pow2(parse(Int, e))
end

function checker_fixture(
    directory,
    format;
    expected = 0,
    actual = expected,
    reference_bits = expected,
    lower = "0/1",
    upper = lower,
    target = "1/2",
    bound = "-",
    status = "resolved",
    byteorder = :little,
)
    mkpath(directory)
    open(joinpath(directory, "cases.tsv"), "w") do io
        println(io, "PRESAGE_VERIFICATION\t1")
        PRESAGe._verification_format_line(io, "input", format)
        PRESAGe._verification_format_line(io, "output", format)
        println(io, "byteorder\t", byteorder)
        println(io, "absolute_error\t", target)
        println(io, "count\t1")
        println(
            io,
            "index\tinput_bits\texpected_bits\treference_status\treference_bits\treference_lower\treference_upper\treference_precision\tcertificate_bound\tbranch",
        )
        println(
            io,
            join(
                (
                    1,
                    hex_bits(0, format),
                    hex_bits(expected, format),
                    status,
                    hex_bits(reference_bits, format),
                    lower,
                    upper,
                    256,
                    bound,
                    "fixture",
                ),
                '\t',
            ),
        )
    end
    for (name, value) in
        (("inputs.bin", 0), ("expected.bin", expected), ("outputs.bin", actual))
        open(joinpath(directory, name), "w") do io
            PRESAGe._write_word(io, value, PRESAGe._word_bytes(format), byteorder)
        end
    end
    return joinpath(directory, "outputs.bin")
end

function verification_compile(plan, directory; backend = :portable, float_backend = :auto)
    mkpath(directory)
    header, source, exe =
        joinpath.(Ref(directory), ("evaluator.hpp", "evaluate.cpp", "evaluate"))
    emit_cpp(header, plan; backend, float_backend)
    emit_harness(source, plan.program)
    compiler = get(
        ENV,
        "CXX",
        isfile("/opt/homebrew/opt/llvm/bin/clang++") ?
        "/opt/homebrew/opt/llvm/bin/clang++" : "c++",
    )
    options = String[]
    if PRESAGe._has_fixed(plan.program)
        prefix = get(
            ENV,
            "GMP_PREFIX",
            isdir("/opt/homebrew/opt/gmp") ? "/opt/homebrew/opt/gmp" : "",
        )
        isempty(prefix) || append!(
            options,
            ["-isystem", joinpath(prefix, "include"), "-L" * joinpath(prefix, "lib")],
        )
        append!(options, ["-lgmpxx", "-lgmp"])
    end
    if backend != :portable ||
       PRESAGe._resolved_float_backend(plan.program, float_backend) == :ac_std_float
        roots = String[]
        backend == :ap_fixed && push!(
            roots,
            get(
                ENV,
                "PRESAGE_AP_INCLUDE_DIR",
                normpath(
                    joinpath(
                        @__DIR__,
                        "..",
                        "..",
                        "HLS_arbitrary_Precision_Types",
                        "include",
                    ),
                ),
            ),
        )
        (
            backend == :ac_fixed ||
            PRESAGe._resolved_float_backend(plan.program, float_backend) == :ac_std_float
        ) && push!(
            roots,
            get(
                ENV,
                "PRESAGE_AC_INCLUDE_DIR",
                normpath(joinpath(@__DIR__, "..", "..", "ac_types", "include")),
            ),
        )
        for root in roots
            if !isdir(root)
                get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") in ("1", "true") &&
                    error("vendor headers not found: $root")
                return nothing
            end
            append!(options, ["-isystem", root])
        end
    end
    run(
        `$compiler -std=c++20 -O2 -Wall -Wextra -Werror -ffp-contract=off -fno-fast-math -frounding-math $source $options -o $exe`,
    )
    return exe
end

mktempdir() do root
    checker = build_verification_checker(joinpath(root, "presage_check"))
    @testset "C++ error decisions, rational equality and witnesses" begin
        for (name, lo, hi, target, expected) in (
            ("pass", "1/8", "1/4", "1/2", "passed"),
            ("fail", "3/4", "1/1", "1/2", "failed"),
            ("uncertain", "1/4", "3/4", "1/2", "unresolved"),
            ("equal", "1/3", "1/3", "1/3", "passed"),
            ("equal_interval", "1/3", "2/3", "2/3", "passed"),
            ("negative", "-3/4", "-1/4", "1/2", "unresolved"),
            ("zero", "0/1", "0/1", "1/2", "passed"),
        )
            bundle = joinpath(root, name)
            outputs = checker_fixture(bundle, IEEE32; lower = lo, upper = hi, target)
            report = check_outputs(bundle, outputs; checker)
            @test report["status"] == expected
            enclosure = report["maximum_error"]
            lower, upper = verification_rational(enclosure["lower"]),
            verification_rational(enclosure["upper"])
            a, b = PRESAGe._parse_rational(lo), PRESAGe._parse_rational(hi)
            @test lower <= max(0, a, -b) <= max(abs(a), abs(b)) <= upper
            @test report["maximum_upper_witness"]["input_bits"] == "0x00000000"
            @test report["maximum_upper_witness"]["output_bits"] == "0x00000000"
            @test report["counts"]["tested"] == 1
        end
        bundle = joinpath(root, "certificate_failure")
        outputs = checker_fixture(bundle, IEEE32; lower = "1/3", bound = "1/4")
        report = check_outputs(bundle, outputs; checker)
        @test report["status"] == "failed"
        @test report["counts"]["accuracy_passed"] == 1
        @test report["counts"]["certificate_failed"] == 1
        bundle = joinpath(root, "bit_failure")
        outputs =
            checker_fixture(bundle, IEEE32; actual = round_ieee(1, IEEE32), lower = "1/1")
        report = check_outputs(bundle, outputs; checker)
        @test report["counts"]["bit_mismatches"] == 1
        @test report["counts"]["accuracy_passed"] == 1
        @test report["status"] == "failed"
        bundle = joinpath(root, "nonfinite_output")
        outputs = checker_fixture(bundle, IEEE32; actual = PRESAGe._nan(IEEE32))
        report = check_outputs(bundle, outputs; checker)
        @test report["counts"]["accuracy_failed"] == 1
        @test report["maximum_error"]["lower"] == "+inf"
        bundle = joinpath(root, "missing_reference")
        outputs = checker_fixture(
            bundle,
            IEEE32;
            lower = "-",
            upper = "-",
            status = "unresolved",
            bound = "1/2",
        )
        report = check_outputs(bundle, outputs; checker)
        @test report["status"] == "unresolved"
        @test report["maximum_error"]["upper"] == "+inf"
        @test report["counts"]["certificate_unresolved"] == 1
    end

    @testset "Wide words, exact fixed decoding, custom exponents and byte order" begin
        for format in (
                FixedFormat(320, 320),
                FixedFormat(301, 7),
                FixedFormat(9, 3; signed = false),
                IEEE16,
                IEEE128,
                IEEE256,
                FloatFormat(7, 81),
            ),
            order in (:little, :big)

            value =
                format isa FixedFormat && format.integer_bits == 320 ? (big(1) << 250) + 3 :
                -3 // 8
            format isa FixedFormat && !format.signed && (value = 3 // 8)
            bits = PRESAGe._round_output(value, format)
            q = PRESAGe._decode_input(bits, format).value
            bundle = joinpath(root, "wide-$format-$order")
            outputs = checker_fixture(
                bundle,
                format;
                expected = bits,
                lower = PRESAGe._rational_text(q),
                bound = "0/1",
                byteorder = order,
            )
            report = check_outputs(bundle, outputs; checker, precision = 32)
            @test report["status"] == "passed"
            @test report["maximum_error"]["upper"] == "0@0"
            @test report["counts"]["certificate_passed"] == 1
        end
        # This exponent would make a rational expansion impractical. The checker
        # keeps it as a dyadic number and does not allocate a huge power of two.
        f = FloatFormat(42, 10)
        bundle = joinpath(root, "extreme_exponent")
        outputs = checker_fixture(
            bundle,
            f;
            expected = 1,
            lower = "1@$(PRESAGe._emin(f)-f.fraction_bits)",
            bound = "0/1",
        )
        report = check_outputs(bundle, outputs; checker)
        @test report["status"] == "passed"
        @test report["maximum_error"]["upper"] == "0@0"
    end

    @testset "Strict stream and bundle validation" begin
        function fresh(name; kwargs...)
            bundle = joinpath(root, "invalid-" * name)
            return bundle, checker_fixture(bundle, FixedFormat(9, 3); kwargs...)
        end
        bundle, outputs = fresh("truncated")
        write(outputs, UInt8[0])
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs = fresh("extra")
        open(io -> write(io, UInt8(0)), outputs, "a")
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs = fresh("padding")
        write(outputs, UInt8[0, 0x80])
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs = fresh("inputs")
        write(joinpath(bundle, "inputs.bin"), UInt8[1, 0])
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs = fresh("expected")
        write(joinpath(bundle, "expected.bin"), UInt8[1, 0])
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs = fresh("schema")
        file = joinpath(bundle, "cases.tsv")
        write(
            file,
            replace(
                read(file, String),
                "PRESAGE_VERIFICATION\t1" => "PRESAGE_VERIFICATION\t2",
            ),
        )
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs = fresh("reversed"; lower = "2/3", upper = "1/3")
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs =
            fresh("reversed-dyadic"; lower = "$(big(2)^900+1)@-900", upper = "1@0")
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs =
            fresh("reversed-mixed"; lower = "$(big(2)^900+1)/$(big(2)^900)", upper = "1@0")
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        bundle, outputs = fresh("denominator"; lower = "1/0")
        @test_throws ErrorException check_outputs(bundle, outputs; checker)
        @test_throws ArgumentError check_outputs(bundle, outputs; checker, precision = 31)
        @test_throws ArgumentError check_outputs(
            bundle,
            outputs;
            checker,
            report_path = outputs,
        )
    end

    @testset "Bundle preparation, sampling, finite scope and special branches" begin
        f = FixedFormat(9, 3)
        plan = polynomial_plan(
            FunctionSpec("x"; input_format = f, output_format = f, domain = (-1, 1)),
            [0, 1];
            internal_format = FixedFormat(24, 6),
        )
        words = sample_inputs(plan)
        @test length(words) == 129
        @test all(w -> -1 <= decode_fixed(w, f) <= 1, words)
        bundle = joinpath(root, "generated")
        initial_precision, initial_rounding = precision(BigFloat), rounding(BigFloat)
        metadata = write_verification_bundle(plan, bundle)
        @test metadata["count"] == length(words)
        @test PRESAGe._spec_data(read_plan(joinpath(bundle, "plan.toml")).spec) ==
              PRESAGe._spec_data(plan.spec)
        @test isfile(joinpath(bundle, "manifest.toml"))
        @test check_outputs(bundle, joinpath(bundle, "expected.bin"); checker)["status"] ==
              "passed"
        @test precision(BigFloat) == initial_precision &&
              rounding(BigFloat) == initial_rounding
        @test_throws ArgumentError write_verification_bundle(plan, bundle)
        @test_throws ArgumentError write_verification_bundle(
            plan,
            joinpath(root, "bad-input");
            inputs = [big(1) << 9],
        )
        @test !ispath(joinpath(root, "bad-input"))
        @test_throws DomainError write_verification_bundle(
            plan,
            joinpath(root, "failed-bundle");
            inputs = [round_fixed(2, f)],
        )
        @test !ispath(joinpath(root, "failed-bundle"))
        report = verify_samples(plan; checker, inputs = [])
        @test report["status"] == "unresolved"
        # The mathematical value is needed even when rounded fixed references overflow.
        output_format = FixedFormat(9, 1)
        for expression in ("2*x", "exp(x)")
            spec = FunctionSpec(
                expression;
                input_format = f,
                output_format,
                domain = (0, 1),
                absolute_error = 3,
            )
            p = PlanArtifact(
                spec;
                program = IR.Program([IR.Input(f), IR.constant(0, output_format)]),
            )
            input = round_fixed(expression == "2*x" ? 1 : 0, f)
            report = verify_samples(p; checker, inputs = [input])
            @test report["status"] == "passed"
            @test report["counts"]["numeric_checked"] == 1
        end

        p = polynomial_plan(FunctionSpec("x"; domain = (-1, 1)), [0, 1])
        sampling = VerificationSampling(
            exhaustive_bits = 0,
            grid_points = 17,
            exponent_points = 8,
            random_points = 20,
            seed = 123,
        )
        @test sample_inputs(p; sampling) == sample_inputs(p; sampling)
        for point in (-1, 0, 1), delta in (-1, 0, 1)
            bits = big(round_ieee(point, IEEE32)) + delta
            0 <= bits <= typemax(UInt32) && @test bits in sample_inputs(p; sampling)
        end
        @test_throws ArgumentError VerificationSampling(exhaustive_bits = 17)
        @test_throws ArgumentError VerificationSampling(random_points = -1)
        @test_throws ArgumentError VerificationSampling(seed = -1)
        @test verify_samples(p; checker, sampling)["status"] == "passed"

        p = root_polynomial_plan(
            FunctionSpec("sqrt(x)"; domain = (0, 4)),
            [1];
            internal_format = FixedFormat(24, 6),
        )
        words = [
            0,
            PRESAGe._sign(IEEE32),
            PRESAGe._inf(IEEE32),
            PRESAGe._nan(IEEE32),
            round_ieee(1, IEEE32),
        ]
        bundle = joinpath(root, "special")
        report =
            verify_samples(p; checker, inputs = words, backend = :mpfr, directory = bundle)
        @test report["status"] == "passed"
        @test report["counts"]["special_checked"] == 0
        @test report["counts"]["outside_domain"] == 2
        output = joinpath(bundle, "wrong-zero.bin")
        bytes = read(joinpath(bundle, "expected.bin"))
        bytes[8] = 0
        write(output, bytes)
        changed = check_outputs(bundle, output; checker)
        @test changed["counts"]["bit_mismatches"] == 1
        @test changed["counts"]["accuracy_failed"] == 0 # Signed zeros have equal numerical value.
    end

    @testset "Exact finite references respect the declared error allowance" begin
        for (i, format) in enumerate((IEEE32, FixedFormat(32, 6))),
            reference_value in (0, 1),
            delta in (-1 // 4, 1 // 4)

            bits(value) =
                format isa FloatFormat ? round_ieee(value, format) :
                round_fixed(value, format)
            output = bits(reference_value + delta)
            q = PRESAGe._rational_text(PRESAGe._q(reference_value))
            directory = joinpath(root, "finite-special-$i-$reference_value-$(delta > 0)")
            outputs = checker_fixture(
                directory,
                format;
                expected = output,
                reference_bits = bits(reference_value),
                lower = q,
                upper = q,
                status = "special",
                target = "1/4",
                bound = "1/4",
            )
            report = check_outputs(directory, outputs; checker)
            @test report["status"] == "passed"
            @test report["counts"]["bit_mismatches"] == 0
            @test report["counts"]["accuracy_passed"] == 1
            @test report["counts"]["certificate_passed"] == 1
            @test report["counts"]["special_checked"] == 0
        end
        outputs = checker_fixture(
            joinpath(root, "finite-special-over-budget"),
            IEEE32;
            expected = round_ieee(3 // 4, IEEE32),
            reference_bits = round_ieee(1, IEEE32),
            lower = "1/1",
            upper = "1/1",
            status = "special",
            target = "1/8",
            bound = "1/8",
        )
        report = check_outputs(dirname(outputs), outputs; checker)
        @test report["status"] == "failed"
        @test report["counts"]["accuracy_failed"] == 1
        @test report["counts"]["certificate_failed"] == 1
        for (name, output, verdict) in (
            ("pole", PRESAGe._inf(IEEE32), "passed"),
            ("wrong-pole", PRESAGe._nan(IEEE32), "failed"),
        )
            outputs = checker_fixture(
                joinpath(root, name),
                IEEE32;
                expected = output,
                reference_bits = PRESAGe._inf(IEEE32),
                lower = "-",
                upper = "-",
                status = "special",
            )
            report = check_outputs(dirname(outputs), outputs; checker)
            @test report["status"] == verdict
            @test report["counts"]["special_checked"] == 1
            @test report["counts"]["bit_mismatches"] == 0
        end
    end

    @testset "Selective reference refinement and reduction transitions" begin
        bits = round_ieee(1 // 2, IEEE16)
        high =
            reference(FunctionSpec("exp(x)"; input_format = IEEE16), bits; backend = :mpfr)
        q = high.enclosure[2].significand * PRESAGe._pow2(high.enclosure[2].exponent)
        spec = FunctionSpec(
            "exp(x)";
            input_format = IEEE16,
            domain = (1 // 2, 1 // 2),
            absolute_error = q - 1 + PRESAGe._pow2(-90),
        )
        plan = PlanArtifact(
            spec;
            program = IR.Program([IR.Input(IEEE16), IR.constant(1, IEEE16)]),
        )
        config = OracleConfig(initial_precision = 24, max_precision = 192)
        report = verify_samples(
            plan;
            checker,
            inputs = [bits],
            backend = :mpfr,
            config,
            max_refinements = 0,
        )
        @test report["status"] == "unresolved"
        report = verify_samples(plan; checker, inputs = [bits], backend = :mpfr, config)
        @test report["status"] == "passed"
        @test parse(Int, report["maximum_upper_witness"]["reference_precision"]) > 24
        # Both exponent and quadrant selection boundaries use the stored multiplier.
        exp = exp_polynomial_plan(
            FunctionSpec("exp(x)"; domain = (-2, 2)),
            [1],
            7 // 10,
            10 // 7;
            internal_format = FixedFormat(32, 8),
        )
        periodic = periodic_polynomial_plan(
            FunctionSpec("sin(x)"; domain = (-2, 2)),
            [1],
            [1],
            11 // 7,
            7 // 11;
            internal_format = FixedFormat(32, 8),
        )
        for p in (exp, periodic)
            points = Rational{BigInt}[]
            PRESAGe._sample_transitions!(points, p, 9)
            @test !isempty(points)
            words = sample_inputs(
                p;
                sampling = VerificationSampling(
                    exhaustive_bits = 0,
                    grid_points = 9,
                    random_points = 0,
                    exponent_points = 0,
                ),
            )
            @test all(point -> round_ieee(point, IEEE32) in words, points)
        end
    end

    @testset "CPU runners with official AP/AC headers and wide AC floating outputs" begin
        for backend in (:ap_fixed, :ac_fixed)
            spec = FunctionSpec(
                "1/3+x";
                input_format = FixedFormat(9, 3),
                output_format = FixedFormat(24, 4),
                domain = (-1, 1),
                absolute_error = 1 // (1 << 18),
            )
            plan = polynomial_plan(
                spec,
                [1 // 3, 1];
                internal_format = FixedFormat(32, 6),
                evaluation = :fma,
            )
            result = certify_plan(plan)
            @test result.status == :certified
            runner = verification_compile(plan, joinpath(root, "runner-$backend"); backend)
            if runner === nothing
                @test_skip false
                continue
            end
            report = verify_samples(result; checker, evaluator = runner)
            @test report["status"] == "passed"
            @test report["counts"]["bit_mismatches"] == 0
            @test report["counts"]["certificate_passed"] == 129
            @test report["maximum_upper_witness"]["certificate_bound"] ==
                  PRESAGe._rational_text(result.total_bound)
        end
        f = FloatFormat(11, 100)
        spec = FunctionSpec(
            "1/3+x";
            input_format = f,
            output_format = IEEE128,
            domain = (-1, 1),
            absolute_error = PRESAGe._pow2(-100),
        )
        plan = polynomial_plan(
            spec,
            [1 // 3, 1];
            internal_format = FixedFormat(160, 8),
            evaluation = :fma,
        )
        result = certify_plan(plan)
        @test result.status == :certified
        runner = verification_compile(
            plan,
            joinpath(root, "runner-wide");
            backend = :ac_fixed,
            float_backend = :ac_std_float,
        )
        words = round_ieee.([-1, -1 // 3, 0, 1 // 3, 1], Ref(f))
        if runner === nothing
            @test_skip false
        else
            report = verify_samples(result; checker, evaluator = runner, inputs = words)
            @test report["status"] == "passed"
            @test report["counts"]["certificate_passed"] == 5
            @test verification_rational(report["maximum_error"]["upper"]) <=
                  result.total_bound
        end
    end

    @testset "Sweep observations and verification CLI" begin
        config = PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1],
            internal_formats = [FixedFormat(24, 6)],
            max_attempts = 1,
            job_timeout = 60,
            total_timeout = 90,
        )
        result = sweep_polynomial(
            FunctionSpec(
                "x";
                input_format = FixedFormat(8, 3),
                output_format = FixedFormat(16, 4),
                domain = (-1, 1),
            ),
            config,
        )
        @test result.status == :complete
        observations = verify_sweep(result; checker)
        @test observations[1]["status"] == "passed"
        @test observations[1]["runner"] == "interpreter"
        io = IOBuffer()
        write_sweep_report(io, result; observations)
        data = TOML.parse(String(take!(io)))
        @test data["schema_version"] == 3
        @test data["rows"][1]["sampled"]["counts"]["tested"] == 65
        @test data["pareto_indices"] == collect(result.pareto_indices)
        @test_throws ArgumentError write_sweep_report(
            IOBuffer(),
            result;
            observations = Dict(2 => observations[1]),
        )
        path = joinpath(root, "cli-plan.toml")
        write_plan(path, only(result.rows).attempt.plan)
        @test verification_main([path, "-", "--checker=$checker"]) == 0
        @test_throws ErrorException verification_main([
            path,
            "-",
            "--checker=$checker",
            "--checker=$checker",
        ])
        contract = joinpath(root, "sweep-contract.toml")
        write_plan(contract, PlanArtifact(only(result.specs)))
        settings = joinpath(root, "sweep-settings.toml")
        write_search_config(settings, config)
        destination = joinpath(root, "cli-sweep")
        @test sweep_main([contract, settings, destination, "--checker=$checker"]) == 0
        data = TOML.parsefile(joinpath(destination, "sweep.toml"))
        @test data["schema_version"] == 3
        @test data["rows"][1]["sampled"]["status"] == "passed"
    end
end
