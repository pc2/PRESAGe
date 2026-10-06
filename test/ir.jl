@testset "Typed IR and exact IEEE execution" begin
    @test_throws ArgumentError IR.Program([IR.Input(IEEE32), IR.Add(1, 3, IEEE32)])
    @test_throws ArgumentError IR.Program([
        IR.Input(IEEE32),
        IR.constant(1, IEEE64),
        IR.Mul(1, 2, IEEE32),
    ])
    @test_throws ArgumentError IR.Program([IR.Input(IEEE32), IR.Const(IR.UIntFormat(8), 0)])
    @test_throws ArgumentError IR.Program([
        IR.Input(IEEE32),
        IR.BitCast(1, IR.UIntFormat(64)),
    ])
    @test_throws ArgumentError IR.Const(IEEE32, 0x100000000)
    @test_throws ArgumentError IR.Table(IEEE32, [])
    @test_throws ArgumentError IR.Program([IR.Input(IEEE32), IR.Classify(:other, 1)])
    for f in (IEEE16, IEEE32, IEEE64, FloatFormat(3, 4))
        minuszero = IR.Const(f, PRESAGe._sign(f))
        positivezero = IR.Const(f, 0)
        p = IR.Program([IR.Input(f), minuszero, IR.Add(1, 2, f)])
        @test evaluate_bits(p, PRESAGe._sign(f)) == PRESAGe._sign(f)
        @test evaluate_bits(p, 0) == 0
        down = IR.Program([IR.Input(f), positivezero, IR.Add(1, 2, f; rounding = :down)])
        @test evaluate_bits(down, PRESAGe._sign(f)) == PRESAGe._sign(f)
        product = IR.Program([IR.Input(f), IR.constant(1 // 2, f), IR.Mul(1, 2, f)])
        @test evaluate_bits(product, 1) == 0
        @test evaluate_bits(product, PRESAGe._sign(f) | 1) == PRESAGe._sign(f)
        invalid = IR.Program([IR.Input(f), positivezero, IR.Mul(1, 2, f)])
        @test evaluate_bits(invalid, PRESAGe._inf(f)) == PRESAGe._nan(f)
        @test evaluate_bits(invalid, PRESAGe._nan(f) | 1) == PRESAGe._nan(f)
        scale = IR.Program([IR.Input(f), IR.ScalePow2(1, 1_000_000_000, f)])
        @test evaluate_bits(scale, round_ieee(1, f)) == PRESAGe._inf(f)
        scale = IR.Program([IR.Input(f), IR.ScalePow2(1, -1_000_000_000, f)])
        @test evaluate_bits(scale, round_ieee(-1, f)) == PRESAGe._sign(f)
    end
    separate = IR.Program([
        IR.Input(IEEE32),
        IR.Const(IEEE32, 0x3f7ffffe),
        IR.constant(-1, IEEE32),
        IR.Mul(1, 2, IEEE32),
        IR.Add(4, 3, IEEE32),
    ])
    fused = IR.Program([
        IR.Input(IEEE32),
        IR.Const(IEEE32, 0x3f7ffffe),
        IR.constant(-1, IEEE32),
        IR.FMA(1, 2, 3, IEEE32),
    ])
    @test evaluate_bits(separate, 0x3f800001) == 0
    @test evaluate_bits(fused, 0x3f800001) == 0xa8800000
    for (mode, expected) in
        ((:nearest_even, 0x3f800000), (:up, 0x3f800001), (:down, 0x3f800000))
        p = IR.Program([IR.Input(IEEE64), IR.Quantize(1, IEEE32; rounding = mode)])
        @test evaluate_bits(p, 0x3ff0000010000000) == expected
    end
    # An invalid table lookup in an unselected branch must never execute.
    p = IR.Program(
        [
            IR.Input(IEEE32),
            IR.Const(IR.UIntFormat(8), 99),
            IR.TableLoad(1, 2),
            IR.constant(1, IEEE32),
            IR.Const(Bool, 1),
            IR.Select(5, 4, 3),
        ];
        tables = [IR.Table(IEEE32, [round_ieee(2, IEEE32)])],
    )
    trace = interpret_trace(p, 0)
    @test trace.bits == 0x3f800000
    @test !haskey(trace.values, 3)
    @test_throws ArgumentError emit_cpp(
        IOBuffer(),
        IR.Program([IR.Input(FloatFormat(4, 3))]),
        float_backend = :native,
    )
    @test_throws ArgumentError emit_cpp(
        IOBuffer(),
        IR.Program([IR.Input(IEEE32), IR.Convert(1, IEEE32; rounding = :up)]),
    )
    @test_throws ArgumentError emit_cpp(IOBuffer(), p; name = "bad-name")

    # Float->bits->extract/shift/merge->float, preserving a raw payload exactly.
    bitsprogram = IR.Program([
        IR.Input(IEEE32),
        IR.BitCast(1, IR.UIntFormat(32)),
        IR.ExtractBits(2, 0, 16),
        IR.Const(IR.UIntFormat(16), 16),
        IR.BitOp(:shiftleft, 3, 4),
        IR.BitCast(2, IEEE32),
    ])
    @test evaluate_bits(bitsprogram, 0xffc12345) == 0xffc12345
    # Every node is validated and serialized, including unreachable diagnostic nodes.
    plan = PlanArtifact(FunctionSpec("x"); program = bitsprogram)
    io = IOBuffer()
    write_plan(io, plan)
    text = String(take!(io))
    restored = read_plan(IOBuffer(text))
    @test occursin("schema_version = 2", text)
    @test evaluate_bits(restored, 0xffc12345) == 0xffc12345
    @test_throws ArgumentError read_plan(
        IOBuffer(replace(text, "schema_version = 2" => "schema_version = 1")),
    )
    @test_throws ArgumentError read_plan(
        IOBuffer(replace(text, "BitCast" => "Unsupported")),
    )
    @test_throws ArgumentError PlanArtifact(
        erf_spec();
        program = IR.Program([IR.Input(IEEE64)]),
    )
    @test_throws ArgumentError PlanArtifact(
        erf_spec();
        program = IR.Program([IR.Input(IEEE32)]),
        status = :contract,
    )
end
