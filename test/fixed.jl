@testset "Exact fixed formats and arithmetic" begin
    for signed in (true, false), width = 2:8
        f = FixedFormat(width, 2; signed)
        for bits = 0:((1 << width) - 1)
            @test round_fixed(decode_fixed(bits, f), f) == bits
        end
    end
    f = FixedFormat(4, 2)
    @test decode_fixed(15, f) == -1 // 4
    @test decode_fixed(8, f) == -2
    @test round_fixed(1 // 8, f) == 0
    @test round_fixed(-1 // 8, f) == 0
    @test decode_fixed(round_fixed(3 // 8, f), f) == 1 // 2
    @test decode_fixed(round_fixed(-3 // 8, f), f) == -1 // 2
    @test_throws OverflowError round_fixed(2, f)
    @test_throws OverflowError round_fixed(-9 // 4, f)
    @test_throws ArgumentError decode_fixed(16, f)
    for (mode, positive, negative) in
        ((:nearest_even, 0, 0), (:toward_zero, 0, 0), (:up, 1 // 4, 0), (:down, 0, -1 // 4))
        g = FixedFormat(4, 2; rounding = mode)
        @test decode_fixed(round_fixed(1 // 8, g), g) == positive
        @test decode_fixed(round_fixed(-1 // 8, g), g) == negative
    end
    for overflow in (:wrap, :saturate)
        g = FixedFormat(4, 2; overflow)
        @test decode_fixed(round_fixed(2, g), g) == (overflow == :wrap ? -2 : 7 // 4)
        @test decode_fixed(round_fixed(-9 // 4, g), g) == (overflow == :wrap ? 7 // 4 : -2)
        u = FixedFormat(3, 1; signed = false, overflow)
        @test decode_fixed(round_fixed(-1 // 4, u), u) == (overflow == :wrap ? 7 // 4 : 0)
    end
    wide = FixedFormat(8, 4)
    for a = 0:15, b = 0:15, operation in (:mul, :add)
        nodes = IR.Node[IR.Input(IEEE32), IR.Const(f, a), IR.Const(f, b)]
        push!(nodes, operation == :mul ? IR.Mul(2, 3, wide) : IR.Add(2, 3, wide))
        push!(nodes, IR.Convert(4, IEEE32))
        av, bv = decode_fixed(a, f), decode_fixed(b, f)
        exact = operation == :mul ? av * bv : av + bv
        @test evaluate_bits(IR.Program(nodes), 0) == round_ieee(exact, IEEE32)
    end
    nodes = IR.Node[
        IR.Input(IEEE32),
        IR.constant(1 // 4, f),
        IR.constant(1 // 2, f),
        IR.constant(1 // 4, f),
        IR.Mul(2, 3, f),
        IR.Add(5, 4, f),
        IR.FMA(2, 3, 4, f),
        IR.Convert(6, IEEE32),
        IR.Convert(7, IEEE32),
    ]
    @test evaluate_bits(IR.Program(nodes; output = 8), 0) == round_ieee(1 // 4, IEEE32)
    @test evaluate_bits(IR.Program(nodes; output = 9), 0) == round_ieee(1 // 2, IEEE32)
    bad = IR.Program([IR.Input(IEEE32), IR.Convert(1, f), IR.Convert(2, IEEE32)])
    @test_throws DomainError evaluate_bits(bad, 0x7f800000)
    @test_throws DomainError evaluate_bits(bad, 0x7fc00000)
    @test_throws OverflowError evaluate_bits(bad, 0x40000000)
    @test_throws ArgumentError IR.Program([
        IR.Input(IEEE32),
        IR.Convert(1, f; rounding = :up),
        IR.Convert(2, IEEE32),
    ])
    @test_throws ArgumentError IR.Program([
        IR.Input(IEEE32),
        IR.Convert(1, f),
        IR.BitCast(2, IR.UIntFormat(4)),
        IR.Const(IEEE32, 0),
    ])
    for overflow in (:wrap, :saturate, :reject)
        g = FixedFormat(20, 4; overflow)
        p = IR.Program([
            IR.Input(IEEE32),
            IR.constant(1, g),
            IR.ScalePow2(2, 1_000_000_000, g),
            IR.Convert(3, IEEE32),
        ])
        if overflow == :reject
            @test_throws OverflowError evaluate_bits(p, 0)
        else
            expected = overflow == :wrap ? 0 : 8 - PRESAGe._pow2(-16)
            @test evaluate_bits(p, 0) == round_ieee(expected, IEEE32)
        end
        p = IR.Program([
            IR.Input(IEEE32),
            IR.constant(-1, g),
            IR.ScalePow2(2, -1_000_000_000, g),
            IR.Convert(3, IEEE32),
        ])
        @test evaluate_bits(p, 0) == 0
    end
    huge = FixedFormat(200, 8)
    word = round_fixed(-7 // 8, huge)
    @test word > typemax(UInt64)
    p = IR.Program([IR.Input(IEEE32), IR.Const(huge, word), IR.Convert(2, IEEE32)])
    plan = PlanArtifact(FunctionSpec("-7/8"); program = p)
    io = IOBuffer()
    write_plan(io, plan)
    text = String(take!(io))
    @test occursin("schema_version = 3", text)
    @test evaluate_bits(read_plan(IOBuffer(text)), 0) == round_ieee(-7 // 8, IEEE32)
    @test_throws ArgumentError read_plan(
        IOBuffer(replace(text, "schema_version = 3" => "schema_version = 2")),
    )
end

function finite_fixed_plan(
    f;
    input_format = IEEE32,
    output_format = IEEE32,
    operation = :convert,
)
    nodes = IR.Node[IR.Input(input_format), IR.Convert(1, f)]
    operation == :scale && (nodes[2] = IR.ScalePow2(1, -1, f))
    if operation == :fma
        push!(nodes, IR.constant(1 // 2, f), IR.constant(1 // 4, f), IR.FMA(2, 3, 4, f))
    end
    result = length(nodes)
    push!(nodes, IR.Convert(result, output_format))
    result = length(nodes)
    push!(
        nodes,
        IR.Const(output_format, PRESAGe._nan(output_format)),
        IR.Classify(:finite, 1),
    )
    push!(nodes, IR.Select(length(nodes), result, length(nodes) - 1))
    return PlanArtifact(
        FunctionSpec("x"; input_format, output_format);
        program = IR.Program(nodes),
    )
end
@testset "Fixed CPU conformance" begin
    rejected = IR.Program([
        IR.Input(IEEE32),
        IR.Convert(1, FixedFormat(4, 2)),
        IR.Convert(2, IEEE32),
    ])
    plan = PlanArtifact(FunctionSpec("x"); program = rejected)
    @test cpu_check(
        plan,
        UInt64[0x40000000];
        expected_error = "fixed result exceeds declared format",
    ) == 1
    @test cpu_check(
        plan,
        UInt64[0x7f800000];
        expected_error = "fixed conversion requires a finite value",
    ) == 1
    # Even a trivially true fixed classification must execute its source.
    nodes = IR.Node[
        IR.Input(IEEE32),
        IR.Convert(1, FixedFormat(4, 2)),
        IR.Classify(:finite, 2),
        IR.constant(1, IEEE32),
        IR.constant(0, IEEE32),
        IR.Select(3, 4, 5),
    ]
    plan = PlanArtifact(FunctionSpec("x"); program = IR.Program(nodes))
    @test_throws OverflowError evaluate_bits(plan, 0x40000000)
    @test cpu_check(
        plan,
        UInt64[0x40000000];
        expected_error = "fixed result exceeds declared format",
    ) == 1
    # Every finite binary32 input fits; nonfinite inputs take the lazy NaN branch.
    for mode in (:nearest_even, :toward_zero, :up, :down)
        for overflow in (:reject, :saturate, :wrap)
            f = FixedFormat(138, 131; rounding = mode, overflow)
            plan = finite_fixed_plan(f)
            words = verification_inputs(plan; random_count = 64)
            append!(
                words,
                round_ieee.([1 // 256, -1 // 256, 3 // 256, -3 // 256], Ref(IEEE32)),
            )
            @test cpu_check(plan, words) == length(words)
        end
    end
    # Wide GMP products/sums, with exact fixed-to-IEEE conversion on all raw samples.
    @test cpu_check(finite_fixed_plan(FixedFormat(337, 131); operation = :fma)) > 2048
    @test cpu_check(finite_fixed_plan(FixedFormat(138, 131); operation = :scale)) > 2048
    double = finite_fixed_plan(
        FixedFormat(2104, 1030);
        input_format = IEEE64,
        output_format = IEEE64,
    )
    @test cpu_check(double, verification_inputs(double; random_count = 256)) > 256
    f = FixedFormat(1100, 10)
    for value in (
        PRESAGe._pow2(-1075),
        -PRESAGe._pow2(-1075),
        3PRESAGe._pow2(-1075),
        1 + PRESAGe._pow2(-53),
        1 + PRESAGe._pow2(-53) + PRESAGe._pow2(-1090),
    )
        nodes = IR.Node[IR.Input(IEEE64), IR.constant(value, f), IR.Convert(2, IEEE64)]
        plan = PlanArtifact(
            FunctionSpec("x"; input_format = IEEE64);
            program = IR.Program(nodes),
        )
        @test evaluate_bits(plan, 0) == round_ieee(value, IEEE64)
        @test cpu_check(plan, UInt64[0]) == 1
    end
    # Signed wrap/saturate operate on an actual overflow, with native temporaries.
    for overflow in (:wrap, :saturate), operation in (:mul, :add, :fma)
        f = FixedFormat(8, 4; overflow)
        nodes = IR.Node[
            IR.Input(IEEE32),
            IR.constant(7, f),
            IR.constant(2, f),
            IR.constant(1, f),
        ]
        push!(
            nodes,
            operation == :mul ? IR.Mul(2, 3, f) :
            operation == :add ? IR.Add(2, 3, f) : IR.FMA(2, 3, 4, f),
        )
        push!(nodes, IR.Convert(5, IEEE32))
        plan = PlanArtifact(FunctionSpec("x"); program = IR.Program(nodes))
        @test cpu_check(plan, UInt64[0]) == 1
    end
    for overflow in (:wrap, :saturate)
        f = FixedFormat(20, 4; overflow)
        nodes = IR.Node[
            IR.Input(IEEE32),
            IR.constant(-1, f),
            IR.ScalePow2(2, 1_000_000_000, f),
            IR.Convert(3, IEEE32),
        ]
        @test cpu_check(
            PlanArtifact(FunctionSpec("x"); program = IR.Program(nodes)),
            UInt64[0],
        ) == 1
    end
end
