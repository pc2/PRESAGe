# One dispatch graph exercises each policy/operation independently, so every
# output exposes the selected fixed result without cancellation between cases.
function vendor_matrix_plan()
    u = IR.UIntFormat(32)
    a, b, c = FixedFormat(12, 5), FixedFormat(9, 3; signed = false), FixedFormat(8, 2)
    values = collect(-128:127)
    tables = [
        IR.Table(a, round_fixed.(values .// 16, Ref(a))),
        IR.Table(b, round_fixed.((mod.(values, 32)) .// 16, Ref(b))),
        IR.Table(c, round_fixed.((mod.(values, 64) .- 32) .// 16, Ref(c))),
    ]
    nodes = IR.Node[
        IR.Input(IEEE32),
        IR.BitCast(1, u),
        IR.ExtractBits(2, 0, 8),
        IR.ExtractBits(2, 16, 6),
        IR.TableLoad(1, 3),
        IR.TableLoad(2, 3),
        IR.TableLoad(3, 3),
    ]
    results = Int[]
    for mode in (:nearest_even, :toward_zero, :up, :down),
        overflow in (:wrap, :saturate),
        signed in (true, false),
        operation in (:convert, :mul, :add, :fma)

        f = FixedFormat(5, 2; signed, rounding = mode, overflow)
        node =
            operation == :convert ? IR.Convert(5, f) :
            operation == :mul ? IR.Mul(5, 6, f) :
            operation == :add ? IR.Add(5, 7, f) : IR.FMA(5, 6, 7, f)
        push!(nodes, node, IR.Convert(length(nodes) + 1, IEEE64))
        push!(results, length(nodes))
    end
    selected = results[end]
    for case = (length(results) - 1):-1:1
        push!(
            nodes,
            IR.Const(IR.UIntFormat(6), case - 1),
            IR.Compare(:eq, 4, length(nodes) + 1),
        )
        push!(nodes, IR.Select(length(nodes), results[case], selected))
        selected = length(nodes)
    end
    return PlanArtifact(
        FunctionSpec("x"; output_format = IEEE64);
        program = IR.Program(nodes; tables),
    )
end

@testset "Native vendor fixed arithmetic" begin
    matrix = vendor_matrix_plan()
    words = UInt64[(case << 16) | row for case = 0:63 for row = 0:255]
    rejected = PlanArtifact(
        FunctionSpec("x");
        program = IR.Program([
            IR.Input(IEEE32),
            IR.Convert(1, FixedFormat(4, 2)),
            IR.Convert(2, IEEE32),
        ]),
    )
    erf = certified_erf().plan
    for backend in (:ap_fixed, :ac_fixed)
        @testset "$backend" begin
            available = try
                vendor_include(backend)
                true
            catch
                false
            end
            if !available
                get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" &&
                    error("$backend headers required")
                @info "Skipping $backend CPU tests; install the public headers or set its include directory"
                @test_skip available
                continue
            end
            header = IOBuffer()
            emit_cpp(header, erf; backend)
            text = String(take!(header))
            @test occursin(
                backend == :ap_fixed ? "#include <ap_fixed.h>" : "#include <ac_fixed.h>",
                text,
            )
            @test occursin("hls_quantize<", text)
            @test !occursin("value = fixed_round<", text)
            @test cpu_check(matrix, words; backend) == 16384
            @test cpu_check(erf; backend) == 2107
            for evaluation in (:separate, :fma)
                wide =
                    certified_erf(;
                        initial_fraction_bits = 80,
                        max_fraction_bits = 80,
                        evaluation,
                    ).plan
                @test cpu_check(wide; backend) == 2107
            end
            # Overflow is checked after rounding: this negative midpoint fits.
            accepted = round_ieee.([-2, -17 // 8, 7 // 4], Ref(IEEE32))
            @test cpu_check(rejected, accepted; backend) == length(accepted)
            @test cpu_check(
                rejected,
                UInt64[round_ieee(15 // 8, IEEE32)];
                backend,
                expected_error = "fixed result exceeds declared format",
            ) == 1
            for word in (0x7f800000, 0x7fc00000)
                @test cpu_check(
                    rejected,
                    UInt64[word];
                    backend,
                    expected_error = "fixed conversion requires a finite value",
                ) == 1
            end
            for mode in (:nearest_even, :toward_zero, :up, :down)
                finite = finite_fixed_plan(FixedFormat(138, 131; rounding = mode))
                @test cpu_check(finite; backend) > 2048
            end
            double = finite_fixed_plan(
                FixedFormat(2104, 1030);
                input_format = IEEE64,
                output_format = IEEE64,
            )
            @test cpu_check(double; backend) > 2048
            # Reinterpret the binary point rather than relying on library shifts
            # whose result width and discarded-bit behavior differ.
            @test cpu_check(
                finite_fixed_plan(FixedFormat(138, 131); operation = :scale);
                backend,
            ) > 2048
            f = FixedFormat(16, 4)
            for exponent in (-3, 3)
                p = IR.Program([
                    IR.Input(IEEE32),
                    IR.constant(-3 // 16, f),
                    IR.ScalePow2(2, exponent, f),
                    IR.Convert(3, IEEE32),
                ])
                @test cpu_check(
                    PlanArtifact(FunctionSpec("x"); program = p),
                    UInt64[0];
                    backend,
                ) == 1
            end
            # FMA has one narrowing; separate arithmetic can differ at a tie.
            f = FixedFormat(4, 2)
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
            for output in (8, 9)
                p = IR.Program(nodes; output)
                @test cpu_check(
                    PlanArtifact(FunctionSpec("x"); program = p),
                    UInt64[0];
                    backend,
                ) == 1
            end
            # Lazy classification still executes and rejects an invalid source.
            p = IR.Program([
                IR.Input(IEEE32),
                IR.Convert(1, f),
                IR.Classify(:finite, 2),
                IR.constant(1, IEEE32),
                IR.constant(0, IEEE32),
                IR.Select(3, 4, 5),
            ])
            @test cpu_check(
                PlanArtifact(FunctionSpec("x"); program = p),
                UInt64[0x40000000];
                backend,
                expected_error = "fixed result exceeds declared format",
            ) == 1
        end
    end
    @test_throws ArgumentError emit_cpp(IOBuffer(), matrix; backend = :unknown)
    # Refuse excessive native widths before writing an incomplete header.
    p = IR.Program([
        IR.Input(IEEE32),
        IR.constant(0, FixedFormat(4097, 2)),
        IR.Convert(2, IEEE32),
    ])
    io = IOBuffer()
    @test_throws ArgumentError emit_cpp(io, p; backend = :ap_fixed)
    @test isempty(take!(io))
    p = IR.Program([
        IR.Input(IEEE32),
        IR.Convert(1, FixedFormat(8, 4)),
        IR.ScalePow2(2, 1_000_000_000, FixedFormat(8, 4)),
        IR.Convert(3, IEEE32),
    ])
    @test_throws ArgumentError emit_cpp(IOBuffer(), p; backend = :ac_fixed)
end
