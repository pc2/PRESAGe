function kernel_float_words(f)
    width = PRESAGe._width(f)
    mask, sign, inf = PRESAGe._wordmask(f), PRESAGe._sign(f), PRESAGe._inf(f)
    words = BigInt[0, sign, inf, sign | inf, inf | 1, sign | inf | 1, mask]
    # Avoid gigantic rational allocation in the exact interpreter for very wide
    # exponent fields; exercise their finite encodings near a unit binade.
    fields =
        f.exponent_bits <= 15 ? [0, 1, 2, PRESAGe._bias(f), 2 * PRESAGe._bias(f)] :
        [PRESAGe._bias(f) - 2, PRESAGe._bias(f), PRESAGe._bias(f) + 2]
    fractions = [
        0,
        1,
        (BigInt(1) << (f.fraction_bits - 1)) - 1,
        BigInt(1) << (f.fraction_bits - 1),
        (BigInt(1) << f.fraction_bits) - 1,
    ]
    for field in fields, fraction in fractions, negative in (false, true)
        push!(words, (BigInt(field) << f.fraction_bits) | fraction | (negative ? sign : 0))
    end
    if f.exponent_bits <= 15
        append!(words, kernel_wide_words(width))
    end
    return unique(words)
end

function kernel_float_fixtures(; exhaustive = true)
    fixtures = []
    add(p, words) = push!(fixtures, (; program = p, words = BigInt.(words)))
    # Exhaust small custom formats across every fixed policy, sign and scale.
    for f in (FloatFormat(2, 1), FloatFormat(3, 4)),
        mode in (:nearest_even, :toward_zero, :up, :down),
        overflow in (:reject, :saturate, :wrap),
        signed in (false, true),
        scale in (-7, 0, 7)

        fixed = FixedFormat(5, 2; rounding = mode, overflow, signed)
        add(
            IR.Program([IR.Input(f), IR.ScalePow2(1, scale, fixed)]),
            0:((1 << PRESAGe._width(f)) - 1),
        )
    end
    # All binary16 words through all directed modes and representative overflow
    # policies. Nonfinite-to-fixed conversion rejects even under wrap/saturation.
    for mode in (:nearest_even, :toward_zero, :up, :down),
        (signed, overflow) in ((true, :reject), (true, :wrap), (false, :saturate))

        fixed = FixedFormat(13, 5; signed, rounding = mode, overflow)
        p = IR.Program([
            IR.Input(IEEE16),
            IR.Convert(1, fixed),
            IR.Convert(2, IEEE16; rounding = mode),
        ])
        add(p, exhaustive ? (0:65535) : kernel_float_words(IEEE16))
    end
    # Direct floating conversions canonicalize NaNs while raw operations retain
    # payloads. Include both normal/subnormal transitions and both signs of zero.
    for output in (FloatFormat(3, 4), IEEE32),
        mode in (:nearest_even, :toward_zero, :up, :down)

        add(
            IR.Program([IR.Input(IEEE16), IR.Convert(1, output; rounding = mode)]),
            exhaustive ? (0:65535) : kernel_float_words(IEEE16),
        )
    end
    for f in (IEEE32, IEEE64, IEEE128, IEEE256, FloatFormat(30, 70), FloatFormat(62, 80)),
        mode in (:nearest_even, :toward_zero, :up, :down),
        (signed, overflow) in ((true, :reject), (true, :wrap), (false, :saturate))

        fixed = FixedFormat(129, 12; signed, rounding = mode, overflow)
        add(
            IR.Program([
                IR.Input(f),
                IR.Quantize(1, fixed),
                IR.Convert(2, f; rounding = mode),
            ]),
            kernel_float_words(f),
        )
    end
    # Fixed output conversion: subnormal underflow, carry into a normal binade,
    # rounding to infinity/maxfinite, minimum signed values and wide unsigneds.
    for (width, integer) in ((9, 4), (65, 16), (129, 129), (257, 5)),
        signed in (true, false),
        mode in (:nearest_even, :toward_zero, :up, :down),
        output in (FloatFormat(2, 1), IEEE16, IEEE32, FloatFormat(3, 90))

        fixed = FixedFormat(width, integer; signed)
        words = width == 9 ? collect(0:511) : kernel_wide_words(width)
        add(IR.Program([IR.Input(fixed), IR.Convert(1, output; rounding = mode)]), words)
    end
    # Extreme static scales are bounded without enormous temporaries or shifts.
    for scale in (typemin(Cint), -200, -25, -1, 0, 1, 16, 200, typemax(Cint)),
        mode in (:nearest_even, :toward_zero, :up, :down)

        add(
            IR.Program([IR.Input(IEEE32), IR.ScalePow2(1, scale, IEEE32; rounding = mode)]),
            kernel_float_words(IEEE32),
        )
        fixed = FixedFormat(24, 7; rounding = mode, overflow = :wrap)
        add(
            IR.Program([IR.Input(IEEE32), IR.ScalePow2(1, scale, fixed)]),
            kernel_float_words(IEEE32),
        )
        add(
            IR.Program([
                IR.Input(fixed),
                IR.Convert(1, IEEE16; rounding = mode),
                IR.ScalePow2(2, scale, IEEE16; rounding = mode),
            ]),
            kernel_wide_words(24),
        )
    end
    # Every comparison and classification participates in a lazy dispatch graph;
    # test canonical and noncanonical NaNs, signed zeros and ordered infinities.
    for f in (IEEE16, IEEE32, IEEE128)
        nodes = IR.Node[IR.Input(f)]
        conditions = Int[]
        for kind in (:finite, :negative, :zero, :nan, :infinity)
            push!(nodes, IR.Classify(kind, 1))
            push!(conditions, length(nodes))
        end
        for value in (0, -1, 1)
            push!(nodes, IR.constant(value, f))
            constant = length(nodes)
            for predicate in (:eq, :ne, :lt, :le, :gt, :ge)
                push!(nodes, IR.Compare(predicate, 1, constant))
                push!(conditions, length(nodes))
            end
        end
        format = FixedFormat(25, 25; signed = false)
        push!(nodes, IR.constant(0, format), IR.constant(1, format))
        result, quantum = length(nodes) - 1, length(nodes)
        for (i, condition) in enumerate(conditions)
            push!(nodes, IR.ScalePow2(quantum, i - 1, format))
            increment = length(nodes)
            push!(nodes, IR.Add(result, increment, format))
            push!(nodes, IR.Select(condition, length(nodes), result))
            result = length(nodes)
        end
        add(
            IR.Program(nodes),
            f == IEEE16 && exhaustive ? (0:65535) : kernel_float_words(f),
        )
    end
    # CopySign and exact bit casts preserve signaling NaNs and payloads. Table
    # loads preserve all words, including signed zero and noncanonical NaNs.
    for f in (IEEE16, IEEE32, IEEE128)
        u = IR.UIntFormat(PRESAGe._width(f))
        nodes = IR.Node[
            IR.Input(f),
            IR.BitCast(1, u),
            IR.BitCast(2, f),
            IR.constant(-1, IEEE16),
            IR.CopySign(3, 4),
            IR.CopySign(5, 1),
        ]
        add(
            IR.Program(nodes),
            f == IEEE16 && exhaustive ? (0:65535) : kernel_float_words(f),
        )
    end
    tablewords = BigInt.(collect(0:65535))
    add(
        IR.Program(
            [IR.Input(IEEE16), IR.BitCast(1, IR.UIntFormat(16)), IR.TableLoad(1, 2)];
            tables = [IR.Table(IEEE16, tablewords; banks = 4, unroll = true)],
        ),
        exhaustive ? (0:65535) : kernel_float_words(IEEE16),
    )
    return fixtures
end

@testset "Encoded floating kernel conversions and branch semantics" begin
    fixtures = kernel_float_fixtures()
    for backend in (:ap_fixed, :ac_fixed)
        @testset "$backend" begin
            kernel_trace_check(fixtures, backend)
        end
    end
end

@testset "Floating kernel capability validation" begin
    for node in (
        IR.Add(1, 1, IEEE32),
        IR.Mul(1, 1, IEEE32),
        IR.FMA(1, 1, 1, IEEE32),
        IR.FloatReciprocal(1),
    )
        io = IOBuffer()
        @test_throws ArgumentError emit_kernel(io, IR.Program([IR.Input(IEEE32), node]))
        @test isempty(take!(io))
    end
    @test_throws ArgumentError emit_kernel(
        IOBuffer(),
        IR.Program([IR.Input(FloatFormat(5, 4091))]),
    )
    @test_throws ArgumentError emit_kernel(
        IOBuffer(),
        IR.Program([IR.Input(IEEE16), IR.Convert(1, FixedFormat(4096, 4))]),
    )
    for backend in (:ap_fixed, :ac_fixed)
        text = sprint(io -> emit_kernel(io, IR.Program([IR.Input(IEEE128)]); backend))
        @test occursin("EncodedFloat<", text)
        @test !occursin(
            r"gmp|mpfr|std::(cin|cout)|throw|stdexcept|\b(float|double)\b",
            text,
        )
    end
end

@testset "Floating conversion maximum vendor work widths" begin
    fixtures = Any[]
    for signed in (false, true), rounding in (:nearest_even, :toward_zero, :up, :down)
        input = FixedFormat(4096, 3; signed)
        push!(
            fixtures,
            (
                program = IR.Program([IR.Input(input), IR.Convert(1, IEEE32; rounding)]),
                words = BigInt[0, 1, big(2)^4095 - 1, big(2)^4095, big(2)^4096 - 1],
            ),
        )
        output = FixedFormat(4095, 3; signed, rounding, overflow = :wrap)
        input_float = FloatFormat(3, 80)
        push!(
            fixtures,
            (
                program = IR.Program([IR.Input(input_float), IR.Convert(1, output)]),
                words = kernel_float_words(input_float),
            ),
        )
    end
    for backend in (:ap_fixed, :ac_fixed)
        @testset "$backend" begin
            kernel_trace_check(fixtures, backend)
        end
    end
end

@testset "Mixed kernels, erf branches, certificates and saved-output replay" begin
    mktempdir() do directory
        checker = build_verification_checker(joinpath(directory, "checker"))
        for input in (IEEE16, IEEE32),
            output in (IEEE16, IEEE32),
            evaluation in (:separate, :fma)

            spec = FunctionSpec(
                "1/3+x/2";
                input_format = input,
                output_format = output,
                domain = (-1, 1),
                absolute_error = output == IEEE16 ? 1 // 1024 : 1 // 2^20,
            )
            plan = polynomial_plan(
                spec,
                [1 // 3, 1 // 2];
                internal_format = FixedFormat(40, 6),
                evaluation,
            )
            certificate = certify_plan(plan)
            @test certificate.status == :certified
            bundle = joinpath(
                directory,
                "bundle-$(input.exponent_bits)-$(output.exponent_bits)-$evaluation",
            )
            sampling = VerificationSampling(; exhaustive_bits = input == IEEE16 ? 16 : 12)
            write_verification_bundle(certificate, bundle; sampling)
            for backend in (:ap_fixed, :ac_fixed)
                root = joinpath(
                    directory,
                    "$(input.exponent_bits)-$(output.exponent_bits)-$evaluation-$backend",
                )
                mkpath(root)
                source = joinpath(root, "plan.toml")
                write_plan(source, plan)
                generated = joinpath(root, "generated")
                generate_main([source, generated, "--target=kernel", "--backend=$backend"])
                exe = joinpath(root, "evaluate")
                if !kernel_compile(joinpath(generated, "evaluate.cpp"), exe, backend)
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
        for input in (IEEE16, IEEE32)
            plan = erf_fixed_candidate(;
                spec = erf_spec(; format = input),
                degree = 9,
                segments = 4,
                fraction_bits = 36,
            )
            certificate = certify_erf(plan)
            @test certificate.status == :certified
            words = input == IEEE16 ? collect(0:65535) : sample_inputs(plan)
            for backend in (:ap_fixed, :ac_fixed)
                kernel_trace_check(
                    [(; program = plan.program, words = BigInt.(words))],
                    backend,
                )
                root = joinpath(directory, "erf-$(input.exponent_bits)-$backend")
                mkpath(root)
                emit_kernel(joinpath(root, "evaluator.hpp"), plan; backend)
                emit_kernel_harness(joinpath(root, "evaluate.cpp"), plan.program)
                exe = joinpath(root, "evaluate")
                if kernel_compile(joinpath(root, "evaluate.cpp"), exe, backend)
                    report = verify_samples(
                        certificate;
                        checker,
                        evaluator = exe,
                        backend = :mpfr,
                    )
                    @test report["status"] == "passed"
                    @test report["counts"]["certificate_failed"] == 0
                end
            end
        end
    end
end
