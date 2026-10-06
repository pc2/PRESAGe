@testset "Wide floating core" begin
    @test round_ieee(1, IEEE64) isa UInt64
    @test round_ieee(1, FloatFormat(11, 53)) isa BigInt
    @test_throws ArgumentError FloatFormat(8sizeof(Int) - 1, 1)
    @test_throws ArgumentError FloatFormat(3, typemax(Int))
    for f in (IEEE128, IEEE256, FloatFormat(8, 300), FloatFormat(7, 16))
        one = round_ieee(1, f)
        sign, inf = PRESAGe._sign(f), PRESAGe._inf(f)
        midpoint = 1 + PRESAGe._pow2(-f.fraction_bits - 1)
        @test round_ieee(midpoint, f) == one
        @test round_ieee(midpoint, f; mode = :up) == one + 1
        @test round_dyadic(3, PRESAGe._emin(f) - f.fraction_bits - 1, f) == 2
        @test round_dyadic(-1, PRESAGe._emin(f) - f.fraction_bits - 1, f; mode = :down) ==
              sign | 1
        @test round_dyadic(1, typemax(Int), f) == inf
        @test round_dyadic(-1, typemin(Int), f; mode = :down) == sign | 1
        for bits in (0, sign, 1, sign | 1, one, one - 1, one + 1, inf - 1, sign | (inf - 1))
            x = decode_ieee(bits, f)
            @test round_ieee(x.value, f; zero_sign = x.negative) == bits
            @test round_dyadic(
                numerator(x.value),
                -(ndigits(denominator(x.value); base = 2) - 1),
                f;
                zero_sign = x.negative,
            ) == bits
        end
        @test decode_ieee(inf, f).kind == :infinity
        @test decode_ieee(PRESAGe._nan(f), f).kind == :nan
        @test_throws ArgumentError hex_bits(PRESAGe._wordmask(f) + BigInt(1), f)
        spec = FunctionSpec("x"; input_format = f)
        p = IR.Program([IR.Input(f), IR.Const(f, one), IR.Mul(1, 2, f)])
        plan = PlanArtifact(spec; program = p, dispatch = Dispatch(round_ieee(4, f)))
        io = IOBuffer()
        write_plan(io, plan)
        seekstart(io)
        restored = read_plan(io)
        @test restored.dispatch.magnitude_threshold == round_ieee(4, f)
        @test restored.spec.input_format == f
        @test evaluate_bits(restored, one + 1) == one + 1
        @test hex_bits(one, f) ==
              "0x" * string(one; base = 16, pad = cld(PRESAGe._width(f), 4))
    end
    @test IR.Const(IR.UIntFormat(128), BigInt(1) << 100).bits isa BigInt
    @test IR.Const(IR.UIntFormat(16), 1).bits isa UInt64
    # Stream non-byte-aligned formats with zero padding, in both byte orders.
    for f in (IEEE128, FloatFormat(8, 100)), order in (:little, :big)
        spec = FunctionSpec("x"; input_format = f)
        words = [round_ieee(1 // 3, f), round_ieee(-1, f), PRESAGe._nan(f)]
        mktempdir() do dir
            input, output = joinpath(dir, "input.bin"), joinpath(dir, "output.bin")
            open(input, "w") do io
                for word in words
                    PRESAGe._write_word(io, word, PRESAGe._word_bytes(f), order)
                end
            end
            summary = generate_references(
                spec,
                input,
                output;
                byteorder = order,
                chunk_elements = 2,
            )
            bytes = read(output)
            actual = [
                PRESAGe._read_word(
                    bytes,
                    1 + (i - 1) * PRESAGe._word_bytes(f),
                    PRESAGe._word_bytes(f),
                    order,
                ) for i in eachindex(words)
            ]
            @test actual == words
            @test summary["complete"]
            @test summary["maximum_chunk_elements"] == 2
        end
    end
    # Reference working precision follows the input width automatically.
    f = FloatFormat(8, 300)
    result = reference(
        FunctionSpec("erf(x)"; input_format = f),
        round_ieee(1 // 3, f);
        backend = :mpfr,
    )
    @test result.status == :resolved
    @test result.bits isa BigInt
    @test result.precision >= 301
    f = FloatFormat(8, 5000)
    @test_throws ArgumentError reference(
        FunctionSpec("erf(x)"; input_format = f),
        round_ieee(1 // 3, f);
        backend = :mpfr,
    )
    io = IOBuffer()
    @test_throws ArgumentError emit_cpp(io, IR.Program([IR.Input(FloatFormat(31, 20))]))
    @test isempty(take!(io))
end

function ac_float_fixed_matrix()
    f, fixed = FloatFormat(5, 100), FixedFormat(160, 40)
    float_values = [
        0,
        1,
        -1,
        1 // 1024,
        -1 // 1024,
        3 // 1024,
        -3 // 1024,
        7 // 2,
        -4,
        4,
        2^15,
        -2^15,
        PRESAGe._pow2(-115),
        -PRESAGe._pow2(-115),
        1 + PRESAGe._pow2(-100),
        -1 - PRESAGe._pow2(-100),
    ]
    fixed_values = [
        0,
        1,
        -1,
        1 + PRESAGe._pow2(-101),
        -1 - PRESAGe._pow2(-101),
        1 + 3PRESAGe._pow2(-101),
        -1 - 3PRESAGe._pow2(-101),
        2^16 - PRESAGe._pow2(-86),
        -2^16 + PRESAGe._pow2(-86),
        2^17,
        -2^17,
        PRESAGe._pow2(-115),
        -PRESAGe._pow2(-115),
        3PRESAGe._pow2(-115),
        -3PRESAGe._pow2(-115),
        PRESAGe._pow2(-14) - PRESAGe._pow2(-115),
    ]
    nodes = IR.Node[
        IR.Input(IEEE32),
        IR.BitCast(1, IR.UIntFormat(32)),
        IR.ExtractBits(2, 0, 4),
        IR.ExtractBits(2, 8, 5),
        IR.TableLoad(1, 3),
        IR.TableLoad(2, 3),
    ]
    tables = [
        IR.Table(f, round_ieee.(float_values, Ref(f))),
        IR.Table(fixed, round_fixed.(fixed_values, Ref(fixed))),
    ]
    outputs = Int[]
    for mode in (:nearest_even, :toward_zero, :up, :down),
        policy in (:wrap, :saturate),
        signed in (true, false)

        target = FixedFormat(12, 3; signed, rounding = mode, overflow = policy)
        push!(nodes, IR.Convert(5, target), IR.Convert(length(nodes) + 1, f))
        push!(outputs, length(nodes))
    end
    for mode in (:nearest_even, :toward_zero, :up, :down)
        push!(nodes, IR.Convert(6, f; rounding = mode))
        push!(outputs, length(nodes))
    end
    for mode in (:nearest_even, :toward_zero, :up, :down), exponent in (-3, 3)
        target = FixedFormat(12, 3; rounding = mode, overflow = :wrap)
        push!(nodes, IR.ScalePow2(5, exponent, target), IR.Convert(length(nodes) + 1, f))
        push!(outputs, length(nodes))
    end
    selected = outputs[end]
    for case = (length(outputs) - 1):-1:1
        push!(
            nodes,
            IR.Const(IR.UIntFormat(5), case - 1),
            IR.Compare(:eq, 4, length(nodes) + 1),
        )
        push!(nodes, IR.Select(length(nodes), outputs[case], selected))
        selected = length(nodes)
    end
    spec = FunctionSpec("x"; output_format = f)
    return PlanArtifact(spec; program = IR.Program(nodes; tables)),
    UInt64[(case << 8) | row for case = 0:(length(outputs) - 1) for row = 0:15]
end

@testset "Official AC floating arithmetic" begin
    available = try
        isfile(joinpath(vendor_include(:ac_fixed), "ac_std_float.h"))
    catch
        false
    end
    if !available
        get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" &&
            error("ac_std_float.h required")
        @test_skip available
    else
        # Binary32 is the initial oneAPI candidate; other formats test header
        # simulation independently of oneAPI synthesis availability.
        for f in (
            IEEE32,
            IEEE128,
            IEEE256,
            FloatFormat(8, 300),
            FloatFormat(8, 7),
            FloatFormat(3, 4),
            FloatFormat(2, 1),
        )
            for operation in (:add, :mul, :fma)
                nodes = IR.Node[
                    IR.Input(f),
                    IR.constant(1 - PRESAGe._pow2(-f.fraction_bits), f),
                    IR.constant(-1, f),
                ]
                push!(
                    nodes,
                    operation == :add ? IR.Add(1, 3, f) :
                    operation == :mul ? IR.Mul(1, 2, f) : IR.FMA(1, 2, 3, f),
                )
                plan = PlanArtifact(
                    FunctionSpec("x"; input_format = f);
                    program = IR.Program(nodes),
                )
                words =
                    PRESAGe._width(f) <= 8 ? UInt64.(0:Int(PRESAGe._wordmask(f))) :
                    verification_inputs(plan; random_count = 64)
                @test cpu_check(
                    plan,
                    words;
                    float_backend = :ac_std_float,
                    public_api = true,
                    host_rounding = :down,
                ) == length(words)
                io = IOBuffer()
                emit_cpp(io, plan; float_backend = :ac_std_float)
                text = String(take!(io))
                @test occursin("#include <ac_std_float.h>", text)
                @test !occursin("#include <gmpxx.h>", text)
            end
        end
        # Cancellation distinguishes an actual fused operation from Mul/Add.
        f = IEEE128
        x = 1 + PRESAGe._pow2(-112)
        nodes = IR.Node[
            IR.Input(f),
            IR.constant(1 - PRESAGe._pow2(-112), f),
            IR.constant(-1, f),
            IR.Mul(1, 2, f),
            IR.Add(4, 3, f),
            IR.FMA(1, 2, 3, f),
        ]
        @test evaluate_bits(IR.Program(nodes; output = 5), round_ieee(x, f)) == 0
        @test decode_ieee(evaluate_bits(IR.Program(nodes), round_ieee(x, f)), f).value ==
              -PRESAGe._pow2(-224)
        for exponent in (-1, 1, -20000, 20000, -1_000_000_000, 1_000_000_000)
            plan = PlanArtifact(
                FunctionSpec("x"; input_format = f);
                program = IR.Program([IR.Input(f), IR.ScalePow2(1, exponent, f)]),
            )
            words = verification_inputs(plan; random_count = 16)
            @test cpu_check(plan, words; public_api = true) == length(words)
        end
        # Conversions may change both exponent and significand widths.
        for (input, output) in (
            (IEEE128, IEEE32),
            (IEEE32, IEEE128),
            (IEEE128, IEEE256),
            (IEEE256, FloatFormat(8, 300)),
            (FloatFormat(8, 7), IEEE16),
        )
            p = IR.Program([IR.Input(input), IR.Convert(1, output)])
            plan = PlanArtifact(
                FunctionSpec("x"; input_format = input, output_format = output);
                program = p,
            )
            words = verification_inputs(plan; random_count = 32)
            @test cpu_check(
                plan,
                words;
                float_backend = :ac_std_float,
                public_api = true,
            ) == length(words)
        end
        # Wide bitcasts, extraction, wrapping and out-of-range shifts.
        u = IR.UIntFormat(128)
        for operation in (:bitand, :bitor, :bitxor, :shiftleft, :shiftright)
            nodes = IR.Node[
                IR.Input(f),
                IR.BitCast(1, u),
                IR.Const(u, 128),
                IR.BitOp(operation, 2, 3),
                IR.BitCast(4, f),
            ]
            plan = PlanArtifact(
                FunctionSpec("x"; input_format = f);
                program = IR.Program(nodes),
            )
            words = verification_inputs(plan; random_count = 16)
            @test cpu_check(plan, words; public_api = true) == length(words)
        end
        # Raw table payloads and lazy lookup indexes remain exact above 64 bits.
        nodes = IR.Node[
            IR.Input(f),
            IR.BitCast(1, u),
            IR.ExtractBits(2, 0, 2),
            IR.TableLoad(1, 3),
        ]
        table = IR.Table(
            f,
            [round_ieee(1 // 3, f), round_ieee(-1, f), PRESAGe._nan(f), PRESAGe._sign(f)],
        )
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = f);
            program = IR.Program(nodes; tables = [table]),
        )
        @test cpu_check(plan, BigInt.(0:3); public_api = true) == 4
        for f in (FloatFormat(3, 3), FloatFormat(8, 100))
            plan = polynomial_plan(FunctionSpec("x"; input_format = f), [0, 1])
            words = verification_inputs(plan; random_count = 16)
            @test cpu_check(plan, words; public_api = true) == length(words)
            @test cpu_check(
                plan,
                [BigInt(1) << PRESAGe._width(f)];
                expected_error = "bits exceed floating format width",
            ) == 1
        end
        @test_throws ArgumentError emit_cpp(IOBuffer(), plan; float_backend = :native)
        @test_throws ArgumentError emit_cpp(IOBuffer(), plan; float_backend = :unknown)
        f = FloatFormat(8, 5000)
        wide = PlanArtifact(
            FunctionSpec("x"; input_format = f);
            program = IR.Program([IR.Input(f)]),
        )
        @test cpu_check(
            wide,
            [round_ieee(1 // 3, f), PRESAGe._nan(f)];
            public_api = true,
        ) == 2
        matrix, words = ac_float_fixed_matrix()
        for backend in (:portable, :ac_fixed, :ap_fixed)
            if backend != :portable
                present = try
                    vendor_include(backend)
                    true
                catch
                    false
                end
                if !present
                    get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" &&
                        error("$backend headers required")
                    @test_skip present
                    continue
                end
            end
            @test cpu_check(matrix, words; backend, public_api = true) == length(words)
            f = FloatFormat(5, 100)
            p = IR.Program([
                IR.Input(f),
                IR.Convert(1, FixedFormat(4, 2)),
                IR.Convert(2, f),
            ])
            rejected = PlanArtifact(FunctionSpec("x"; input_format = f); program = p)
            @test cpu_check(
                rejected,
                round_ieee.([-2, -17 // 8, 7 // 4], Ref(f));
                backend,
            ) == 3
            @test cpu_check(
                rejected,
                [round_ieee(15 // 8, f)];
                backend,
                expected_error = "fixed result exceeds declared format",
            ) == 1
        end
    end
end
