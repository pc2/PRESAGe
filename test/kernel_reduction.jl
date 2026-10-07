function kernel_normalization_words(f)
    words = kernel_float_words(f)
    # Normalization reads encoded fields directly, including extreme exponents;
    # unlike general floating arithmetic, it needs no expanded rational value.
    for field in (0, 1, 2, 2 * PRESAGe._bias(f)),
        fraction in (0, 1, big(2)^f.fraction_bits - 1),
        negative in (false, true)

        push!(
            words,
            (BigInt(field) << f.fraction_bits) |
            fraction |
            (negative ? PRESAGe._sign(f) : 0),
        )
    end
    return unique(words)
end

function kernel_reduction_fixtures(; exhaustive = true)
    fixtures = Any[]
    add(program, words) = push!(fixtures, (; program, words = BigInt.(words)))
    for f in (FloatFormat(2, 3), IEEE16, IEEE32, IEEE128, IEEE256, FloatFormat(62, 80))
        words =
            f == IEEE16 && exhaustive ? (0:65535) :
            f == FloatFormat(2, 3) ? (0:63) : kernel_normalization_words(f)
        for node in (
            IR.FloatMantissa(1),
            IR.FloatExponent(1),
            IR.RootArgument(1, 2),
            IR.RootArgument(1, 3),
        )
            add(IR.Program([IR.Input(f), node]), words)
        end
        for multiplier in (-1, 1), divisor in (1, 2, 3)
            fixed = FixedFormat(40, 6)
            add(
                IR.Program([
                    IR.Input(f),
                    IR.constant(3 // 4 + 1 // 1024 + 1 // 2^20, fixed),
                    IR.ScaleByInputExponent(2, 1, multiplier, IEEE16; divisor),
                ]),
                words,
            )
        end
    end
    # Directed reconstruction rounds once from the full last-stage payload.
    # Small formats exhaust exponent residues, both signs and every policy.
    for input in (FloatFormat(3, 4), IEEE32),
        source in (FixedFormat(24, 4), IEEE32),
        rounding in (:nearest_even, :toward_zero, :up, :down),
        multiplier in (-1, 1),
        divisor in (1, 2, 3)

        words = input == IEEE32 ? kernel_float_words(input) : (0:255)
        for negative in (false, true)
            add(
                IR.Program([
                    IR.Input(input),
                    IR.constant(
                        (negative ? -1 : 1) * (3 // 4 + 1 // 1024 + 1 // 2^20),
                        source,
                    ),
                    IR.ScaleByInputExponent(2, 1, multiplier, IEEE16; divisor, rounding),
                ]),
                words,
            )
        end
    end
    # A node can use the same input as its source and normalizing operand.
    add(
        IR.Program([IR.Input(IEEE16), IR.ScaleByInputExponent(1, 1, -1, IEEE16)]),
        exhaustive ? (0:65535) : kernel_float_words(IEEE16),
    )
    # Full-width signed exponents are compared before narrowing; include scales
    # far outside int64, as well as cancellation near wide output exponents.
    for width in (8, 32, 64, 129, 4096), output in (IEEE16, FloatFormat(62, 80))
        exponent = FixedFormat(width, width)
        words = width == 8 ? (0:255) : kernel_wide_words(width)
        values =
            width < 64 ? Int[] :
            [
                PRESAGe._bias(output) - 2,
                PRESAGe._bias(output),
                PRESAGe._bias(output) + 1,
                PRESAGe._emin(output) - output.fraction_bits - 1,
                PRESAGe._emin(output) - output.fraction_bits,
            ]
        words = unique(vcat(BigInt.(words), round_fixed.(values, Ref(exponent))))
        for source in (FixedFormat(25, 4), FloatFormat(62, 80)), negative in (false, true)
            add(
                IR.Program([
                    IR.Input(exponent),
                    IR.constant(
                        (negative ? -1 : 1) * (3 // 4 + 1 // 1024 + 1 // 2^20),
                        source,
                    ),
                    IR.ScaleByExponent(2, 1, output),
                ]),
                words,
            )
        end
    end
    for bits in (
        0,
        PRESAGe._sign(IEEE32),
        PRESAGe._inf(IEEE32),
        PRESAGe._sign(IEEE32) | PRESAGe._inf(IEEE32),
        PRESAGe._nan(IEEE32),
        PRESAGe._inf(IEEE32) | 1,
    )
        exponent = FixedFormat(129, 129)
        add(
            IR.Program([
                IR.Input(exponent),
                IR.Const(IEEE32, bits),
                IR.ScaleByExponent(2, 1, IEEE16),
            ]),
            kernel_wide_words(129),
        )
        add(
            IR.Program([
                IR.Input(IEEE16),
                IR.Const(IEEE32, bits),
                IR.ScaleByInputExponent(2, 1, -1, IEEE16; divisor = 3),
            ]),
            kernel_float_words(IEEE16),
        )
    end
    # Preserve interpreter rejection order, including normalization before the
    # source of input-exponent scaling, and source before dynamic exponents.
    fixed = FixedFormat(8, 8)
    for failure in (:overflow, :table, :domain)
        nodes = IR.Node[IR.Input(IEEE16), IR.constant(127, fixed), IR.constant(1, fixed)]
        tables = IR.Table[]
        if failure == :overflow
            push!(nodes, IR.Add(2, 3, fixed))
        elseif failure == :table
            push!(nodes, IR.Const(IR.UIntFormat(2), 1), IR.TableLoad(1, 4))
            push!(tables, IR.Table(fixed, [0]))
        else
            push!(nodes, IR.Classify(:zero, 1), IR.Guard(4, 2))
        end
        source = length(nodes)
        push!(nodes, IR.ScaleByInputExponent(source, 1, 1, IEEE16))
        add(IR.Program(nodes; tables), kernel_float_words(IEEE16))
    end
    add(
        IR.Program([
            IR.Input(IEEE16),
            IR.Convert(1, fixed),
            IR.constant(127, fixed),
            IR.constant(1, fixed),
            IR.Add(3, 4, fixed),
            IR.ScaleByExponent(2, 5, IEEE16),
        ]),
        kernel_float_words(IEEE16),
    )
    # An invalid normalization in an untaken branch must remain unvisited.
    add(
        IR.Program([
            IR.Input(IEEE16),
            IR.Classify(:zero, 1),
            IR.FloatMantissa(1),
            IR.Select(2, 1, 3),
        ]),
        exhaustive ? (0:65535) : kernel_float_words(IEEE16),
    )
    # Maximum source width and root-argument format widening remain explicit.
    for f in (FloatFormat(2, 4092), FloatFormat(62, 4033))
        for node in (IR.FloatMantissa(1), IR.FloatExponent(1), IR.RootArgument(1, 3))
            add(IR.Program([IR.Input(f), node]), kernel_normalization_words(f))
        end
    end
    input = FixedFormat(4096, 4096)
    for signed in (false, true)
        source = FixedFormat(4096, 3; signed)
        add(
            IR.Program([
                IR.Input(input),
                IR.constant(signed ? -3 // 4 : 3 // 4, source),
                IR.ScaleByExponent(2, 1, IEEE32),
            ]),
            kernel_wide_words(4096),
        )
    end
    return fixtures
end

@testset "Kernel normalization and exponent reconstruction" begin
    fixtures = kernel_reduction_fixtures()
    for backend in (:ap_fixed, :ac_fixed)
        @testset "$backend" begin
            kernel_trace_check(fixtures, backend)
        end
    end
end

@testset "Root normalization width validation" begin
    for backend in (:ap_fixed, :ac_fixed)
        # Widening E=2 to E=3 would exceed the vendor word limit.
        io = IOBuffer()
        @test_throws ArgumentError emit_kernel(
            io,
            IR.Program([IR.Input(FloatFormat(2, 4093)), IR.RootArgument(1, 3)]);
            backend,
        )
        @test isempty(take!(io))
    end
end

@testset "Certified fixed kernels with floating reductions" begin
    configurations = (
        (:reciprocal, "1/x", (1 // 16, 16), 1 // 64, 7, FixedFormat(40, 12)),
        (:sqrt, "sqrt(x)", (0, 65504), 1 // 4, 11, FixedFormat(80, 24)),
        (:rsqrt, "1/sqrt(x)", (0, 65504), 4, 11, FixedFormat(80, 24)),
        (:cbrt, "cbrt(x)", (-65504, 65504), 1 // 16, 13, FixedFormat(96, 24)),
        (:log, "log(x)", (0, 65504), 1 // 64, 9, FixedFormat(80, 24)),
    )
    certificates = CertificationResult[]
    fixtures = Any[]
    for (kind, expression, domain, budget, degree, internal) in configurations
        spec =
            FunctionSpec(expression; input_format = IEEE16, domain, absolute_error = budget)
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
        search.selected === nothing && error(only(search.attempts).reason)
        selected = search.selected
        layout =
            kind == :reciprocal ? PRESAGe._reciprocal_audit(selected.plan) :
            kind == :log ? PRESAGe._log_audit(selected.plan) :
            PRESAGe._root_audit(selected.plan)
        path = only(layout.paths)
        for input in (IEEE16, IEEE32), evaluation in (:fma, :separate)
            narrowed = kind == :cbrt ? (-16, 16) : kind == :sqrt ? (0, 16) : (1 // 16, 16)
            contract =
                input == IEEE16 ? spec :
                FunctionSpec(
                    expression;
                    input_format = input,
                    output_format = IEEE16,
                    domain = narrowed,
                    absolute_error = budget,
                )
            plan = if kind == :reciprocal
                reciprocal_polynomial_plan(
                    contract,
                    path.coefficients;
                    precision = layout.precision,
                    evaluation,
                )
            elseif kind == :log
                log_polynomial_plan(
                    contract,
                    path.coefficients,
                    path.log2;
                    precision = layout.precision,
                    evaluation,
                )
            else
                root_polynomial_plan(
                    contract,
                    path.coefficients;
                    precision = layout.precision,
                    evaluation,
                    transformation = kind,
                )
            end
            certificate =
                input == IEEE16 && evaluation == :fma ? selected : certify_plan(plan)
            @test certificate.status == :certified
            certificate.status == :certified || error(certificate.reason)
            words =
                input == IEEE16 && evaluation == :fma ? BigInt.(0:65535) :
                BigInt.(sample_inputs(plan))
            push!(fixtures, (; program = plan.program, words))
            evaluation == :fma && push!(certificates, certificate)
        end
    end
    for backend in (:ap_fixed, :ac_fixed)
        @testset "$backend traces" begin
            kernel_trace_check(fixtures, backend)
        end
    end
    mktempdir() do directory
        checker = build_verification_checker(joinpath(directory, "checker"))
        for (index, certificate) in enumerate(certificates)
            bundle = joinpath(directory, "bundle$index")
            write_verification_bundle(certificate, bundle; backend = :mpfr)
            for backend in (:ap_fixed, :ac_fixed)
                root = joinpath(directory, "kernel$index-$backend")
                mkpath(root)
                plan = certificate.plan
                emit_kernel(joinpath(root, "evaluator.hpp"), plan; backend)
                emit_kernel_harness(joinpath(root, "evaluate.cpp"), plan.program)
                exe = joinpath(root, "evaluate")
                if !kernel_compile(joinpath(root, "evaluate.cpp"), exe, backend)
                    @test_skip false
                    continue
                end
                outputs = joinpath(root, "outputs.bin")
                run(
                    pipeline(
                        `$exe`;
                        stdin = joinpath(bundle, "inputs.bin"),
                        stdout = outputs,
                    ),
                )
                report = check_outputs(bundle, outputs; checker)
                @test report["status"] == "passed"
                @test report["counts"]["bit_mismatches"] == 0
                @test report["counts"]["certificate_failed"] == 0
                @test check_outputs(bundle, outputs; checker)["status"] == "passed"
            end
        end
    end
end
