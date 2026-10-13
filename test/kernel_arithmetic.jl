# Pack independent operand payloads into a fixed input. This exercises official
# AC arithmetic on arbitrary IEEE encodings, without host float conversions.
function kernel_arithmetic_program(f, operation)
    count = operation == :fma ? 3 : operation == :reciprocal ? 1 : 2
    width = PRESAGe._width(f)
    packed = IR.UIntFormat(count * width)
    nodes = IR.Node[
        IR.Input(FixedFormat(count * width, count * width; signed = false)),
        IR.BitCast(1, packed),
    ]
    operands = Int[]
    for k = 0:(count - 1)
        push!(nodes, IR.ExtractBits(2, k * width, width))
        push!(nodes, IR.BitCast(length(nodes), f))
        push!(operands, length(nodes))
    end
    node =
        operation == :add ? IR.Add(operands..., f) :
        operation == :mul ? IR.Mul(operands..., f) :
        operation == :fma ? IR.FMA(operands..., f) : IR.FloatReciprocal(only(operands))
    push!(nodes, node)
    return IR.Program(nodes)
end

function kernel_arithmetic_fixtures()
    fixtures = Any[]
    add(f, operation, words) = push!(
        fixtures,
        (; program = kernel_arithmetic_program(f, operation), words = BigInt.(words)),
    )
    for f in (FloatFormat(2, 1), FloatFormat(2, 2)),
        operation in (:add, :mul, :fma, :reciprocal)

        count = operation == :fma ? 3 : operation == :reciprocal ? 1 : 2
        add(f, operation, 0:((1 << (count * PRESAGe._width(f))) - 1))
    end
    f = FloatFormat(3, 4)
    for operation in (:add, :mul)
        add(f, operation, 0:65535)
    end
    # All half encodings, including every subnormal and NaN, combined with
    # constants that exercise fused cancellation, overflow and signed underflow.
    for operation in (:add, :mul, :fma, :reciprocal)
        f = IEEE16
        coefficient = round_ieee(-3 // 2, f)
        addend = round_ieee(1, f)
        words = [
            BigInt(x) |
            (operation == :reciprocal ? 0 : BigInt(coefficient) << 16) |
            (operation == :fma ? BigInt(addend) << 32 : 0) for x = 0:65535
        ]
        add(f, operation, words)
    end
    # Cartesian special/boundary values plus reproducible payload combinations.
    # Wide exponent fields use finite values near one, so the exact rational
    # interpreter does not have to allocate billion-bit numbers.
    for f in (
        FloatFormat(3, 4),
        IEEE16,
        IEEE32,
        IEEE64,
        IEEE128,
        IEEE256,
        FloatFormat(8, 300),
        FloatFormat(30, 80),
    )
        width = PRESAGe._width(f)
        values = kernel_float_words(f)
        for operation in (:add, :mul, :fma)
            words = BigInt[]
            if operation == :fma
                # Every special value in each operand; all signs of zeros and
                # invalid infinity combinations are covered exhaustively.
                specials = values[1:7]
                for a in specials, b in specials, c in specials
                    push!(words, a | b << width | c << (2width))
                end
                for (i, a) in enumerate(values), (j, b) in enumerate(values)
                    c = values[mod1(17i + 23j, length(values))]
                    push!(words, a | b << width | c << (2width))
                end
            else
                append!(words, (a | b << width for a in values for b in values))
            end
            add(f, operation, unique(words))
        end
        add(f, :reciprocal, values)
    end
    # Exercise the largest accepted floating arithmetic workspace without a
    # wider packed input: the operands all refer to the same wide value.
    f = FloatFormat(8, 2041)
    for node in
        (IR.Add(1, 1, f), IR.Mul(1, 1, f), IR.FMA(1, 1, 1, f), IR.FloatReciprocal(1))
        push!(
            fixtures,
            (; program = IR.Program([IR.Input(f), node]), words = kernel_float_words(f)),
        )
    end
    return fixtures
end

@testset "Official AC floating kernel arithmetic" begin
    kernel_trace_check(kernel_arithmetic_fixtures(), :ac_fixed)
end

@testset "Portable floating arithmetic matches exact rounding" begin
    fixtures = filter(kernel_arithmetic_fixtures()) do fixture
        !(last(fixture.program.nodes) isa IR.FloatReciprocal)
    end
    kernel_trace_check(fixtures, :ap_fixed)
end

function kernel_fma_rounding_words(format)
    width = PRESAGe._width(format)
    words = BigInt[]
    pack(a, b, c) = a | b << width | c << (2width)
    encode(a, b, c) = pack(
        BigInt(round_ieee(a, format)),
        BigInt(round_ieee(b, format)),
        BigInt(round_ieee(c, format)),
    )
    p = format.fraction_bits + 1
    unit = 1 // (big(1) << (p - 1))
    for sign in (-1, 1),
        gap in (0, 1, 2, 3, p - 1, p, p + 1, 2p, 2p + 4),
        offset in (-1, 0, 1)

        factor = PRESAGe._pow2(-gap)
        push!(words, encode(sign * (1 + unit), 1 - unit, factor * (1 + offset * unit)))
        push!(words, encode(sign * (1 + unit), 1 - unit, -factor * (1 + offset * unit)))
    end
    maximum = PRESAGe._inf(format) - 1
    push!(
        words,
        pack(maximum, BigInt(round_ieee(2, format)), maximum | PRESAGe._sign(format)),
    )
    mask = (big(1) << width) - 1
    state = big(0x243f6a8885a308d3)
    for _ = 1:4096
        operands = BigInt[]
        for _ = 1:3
            state =
                (state * 6364136223846793005 + 1442695040888963407) &
                ((big(1) << (3width)) - 1)
            push!(operands, (state >> width) & mask)
        end
        push!(words, pack(operands...))
    end
    return unique(words)
end

@testset "Portable FMA preserves cancellation and distant rounding bits" begin
    fixtures = [
        (;
            program = kernel_arithmetic_program(format, :fma),
            words = kernel_fma_rounding_words(format),
        ) for format in
        (FloatFormat(3, 4), IEEE16, FloatFormat(8, 17), IEEE32, IEEE64, IEEE128)
    ]
    kernel_trace_check(fixtures, :ap_fixed)
end

@testset "FMA polynomials preserve individual stage widths" begin
    spec = FunctionSpec(
        "1/3+2/7*x-3/11*x^2+4/13*x^3";
        input_format = FixedFormat(10, 3),
        output_format = IEEE32,
        domain = (-1, 1),
        absolute_error = 1 // 256,
    )
    precision = PolynomialPrecision(
        IEEE32;
        coefficient_formats = [FloatFormat(8, m) for m in (12, 18, 20, 22)],
        stage_formats = [FloatFormat(8, m) for m in (17, 22, 26, 23)],
    )
    plan = polynomial_plan(
        spec,
        [1 // 3, 2 // 7, -3 // 11, 4 // 13];
        internal_format = IEEE32,
        evaluation = :fma,
        precision,
    )
    @test certify_plan(plan).status == :certified
    @test target_support(plan, TargetProfile(:oneapi)).supported
    @test target_support(plan, TargetProfile(:vitis)).supported
    kernel_trace_check([(; program = plan.program, words = BigInt.(0:1023))], :ap_fixed)
end

@testset "AC floating kernel capabilities" begin
    for operation in (IR.Add, IR.Mul, IR.FMA), rounding in (:toward_zero, :up, :down)
        args = operation == IR.FMA ? (1, 1, 1) : (1, 1)
        p = IR.Program([IR.Input(IEEE32), operation(args..., IEEE32; rounding)])
        io = IOBuffer()
        @test_throws ArgumentError emit_kernel(io, p)
        @test isempty(take!(io))
    end
    for f in (FloatFormat(31, 23), FloatFormat(8, 2042))
        p = IR.Program([IR.Input(f), IR.Add(1, 1, f)])
        @test_throws ArgumentError emit_kernel(IOBuffer(), p)
    end
    # The floating arithmetic bound does not restrict encoded-only operations.
    p = IR.Program([IR.Input(FloatFormat(62, 80))])
    @test !occursin("ac_std_float.h", sprint(io -> emit_kernel(io, p)))
    p = IR.Program([IR.Input(IEEE32), IR.FMA(1, 1, 1, IEEE32)])
    text = sprint(io -> emit_kernel(io, p))
    @test occursin("#include <ac_std_float.h>", text)
    @test occursin("float_fma(input, input, input)", text)
end

@testset "Certified floating polynomial kernels" begin
    spec = FunctionSpec(
        "exp(x)";
        input_format = IEEE16,
        domain = (-1, 1),
        absolute_error = 1 // 256,
    )
    coefficients = [1 // factorial(big(k)) for k = 0:9]
    certificates = CertificationResult[]
    for evaluation in (:separate, :fma)
        plan = polynomial_plan(spec, coefficients; internal_format = IEEE32, evaluation)
        certificate = certify_plan(plan)
        @test certificate.status == :certified
        push!(certificates, certificate)
    end
    kernel_trace_check(
        [(; program = c.plan.program, words = BigInt.(0:65535)) for c in certificates],
        :ac_fixed,
    )
    mktempdir() do directory
        checker = build_verification_checker(joinpath(directory, "checker"))
        for (i, certificate) in enumerate(certificates)
            root = joinpath(directory, "kernel$i")
            mkpath(root)
            emit_kernel(joinpath(root, "evaluator.hpp"), certificate.plan)
            emit_kernel_harness(joinpath(root, "evaluate.cpp"), certificate.plan.program)
            exe = joinpath(root, "evaluate")
            if !kernel_compile(joinpath(root, "evaluate.cpp"), exe, :ac_fixed)
                @test_skip false
                continue
            end
            report = verify_samples(
                certificate;
                checker,
                evaluator = exe,
                directory = joinpath(root, "verification"),
            )
            @test report["status"] == "passed"
            @test report["counts"]["bit_mismatches"] == 0
            @test report["counts"]["certificate_failed"] == 0
        end
    end
end
