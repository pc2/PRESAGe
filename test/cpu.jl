include(joinpath(@__DIR__, "..", "scripts", "verify_cpu.jl"))
function cpu_check(
    plan,
    words = verification_inputs(plan);
    expected_error = nothing,
    backend = :portable,
    float_backend = :auto,
    public_api = false,
    input_bytes = nothing,
    host_rounding = nothing,
    generated_directory = nothing,
    trace = generated_directory === nothing,
)
    compiler = get(
        ENV,
        "CXX",
        Sys.isapple() && isfile("/opt/homebrew/opt/llvm/bin/clang++") ?
        "/opt/homebrew/opt/llvm/bin/clang++" : "c++",
    )
    mktempdir() do directory
        header, source, exe =
            joinpath.(Ref(directory), ("evaluator.hpp", "evaluate.cpp", "evaluate"))
        if generated_directory === nothing
            emit_cpp(header, plan; backend, float_backend, trace)
            emit_harness(source, plan.program; trace)
        else
            cp(joinpath(generated_directory, "evaluator.hpp"), header)
            cp(joinpath(generated_directory, "evaluate.cpp"), source)
        end
        if host_rounding !== nothing
            mode = Dict(
                :down => "FE_DOWNWARD",
                :up => "FE_UPWARD",
                :toward_zero => "FE_TOWARDZERO",
            )[host_rounding]
            write(
                source,
                replace(
                    read(source, String),
                    "std::fesetround(FE_TONEAREST);" => "std::fesetround($mode);",
                ),
            )
        end
        if public_api
            infmt, outfmt = plan.spec.input_format, plan.spec.output_format
            mode = PRESAGe._resolved_float_backend(plan.program, float_backend)
            decode = PRESAGe._cpp_decode_bits("word", infmt, backend, mode)
            encode = PRESAGe._cpp_encode_bits("typed", outfmt, backend, mode)
            replacement = """
            using namespace presage_evaluator;
            $(!any(f -> f isa FloatFormat,plan.program.types) ? "std::fesetround(FE_DOWNWARD);" : "")
            auto result = evaluate_bits(word$(trace ? ", (trace || fixed_trace) ? &observations : nullptr" : ""));
            auto typed = evaluate($decode);
            if ($encode != result)
                throw std::runtime_error("public evaluator API mismatch");
            """
            text = read(source, String)
            original = "auto result = presage_evaluator::evaluate_bits(word$(trace ? ", (trace || fixed_trace) ? &observations : nullptr" : ""));"
            occursin(original, text) || error("missing harness output call")
            write(source, replace(text, original => replacement))
        end
        gmp = if PRESAGe._has_fixed(plan.program)
            prefix = get(
                ENV,
                "GMP_PREFIX",
                isdir("/opt/homebrew/opt/gmp") ? "/opt/homebrew/opt/gmp" : "",
            )
            isempty(prefix) ? ["-lgmpxx", "-lgmp"] :
            [
                "-isystem",
                joinpath(prefix, "include"),
                "-L" * joinpath(prefix, "lib"),
                "-lgmpxx",
                "-lgmp",
            ]
        else
            String[]
        end
        vendor = backend == :portable ? String[] : ["-isystem", vendor_include(backend)]
        PRESAGe._resolved_float_backend(plan.program, float_backend) == :ac_std_float &&
            append!(vendor, ["-isystem", vendor_include(:ac_fixed)])
        run(
            `$compiler -std=c++20 -O2 -ffp-contract=off -fno-fast-math -frounding-math -Wall -Wextra -Werror $source $gmp $vendor -o $exe`,
        )
        # Check serialized programs, not just the in-memory generator state.
        path = joinpath(directory, "plan.toml")
        write_plan(path, plan)
        if expected_error !== nothing
            input = IOBuffer()
            if input_bytes === nothing
                for word in words
                    PRESAGe._write_word(
                        input,
                        word,
                        PRESAGe._word_bytes(plan.spec.input_format),
                        :little,
                    )
                end
            else
                write(input, input_bytes)
            end
            seekstart(input)
            output, errors = IOBuffer(), IOBuffer()
            process = run(
                pipeline(
                    ignorestatus(`$exe`);
                    stdin = input,
                    stdout = output,
                    stderr = errors,
                ),
            )
            process.exitcode == 1 && occursin(expected_error, String(take!(errors))) ||
                error("CPU did not report the expected failure")
            return length(words)
        end
        return verify_cpu(read_plan(path), exe; words, trace)
    end
end

function vendor_include(backend)
    variable, repository, header =
        backend == :ap_fixed ?
        ("PRESAGE_AP_INCLUDE_DIR", "HLS_arbitrary_Precision_Types", "ap_fixed.h") :
        ("PRESAGE_AC_INCLUDE_DIR", "ac_types", "ac_fixed.h")
    path =
        get(ENV, variable, normpath(joinpath(@__DIR__, "..", "..", repository, "include")))
    isfile(joinpath(path, header)) ||
        error("$header not found; set $variable to its include directory")
    return path
end

@testset "Portable CPU conformance" begin
    for f in (IEEE32, IEEE64), operation in (:mul, :add, :fma)
        nodes = IR.Node[
            IR.Input(f),
            IR.constant(1 - PRESAGe._pow2(-f.fraction_bits), f),
            IR.constant(-1, f),
        ]
        push!(
            nodes,
            operation == :mul ? IR.Mul(1, 2, f) :
            operation == :add ? IR.Add(1, 3, f) : IR.FMA(1, 2, 3, f),
        )
        plan =
            PlanArtifact(FunctionSpec("x"; input_format = f); program = IR.Program(nodes))
        words = verification_inputs(plan; random_count = 256)
        push!(words, round_ieee(1 + PRESAGe._pow2(-f.fraction_bits), f))
        @test cpu_check(plan, words) == length(words)
    end
    spec = FunctionSpec("1/4+3/2*x-1/2*x^2"; domain = (-2, 2))
    for mode in (:separate, :fma)
        plan = polynomial_plan(spec, [1 // 4, 3 // 2, -1 // 2]; evaluation = mode)
        @test cpu_check(plan) > 2048
    end
    # Domain guards must use inward thresholds for nonrepresentable endpoints.
    plan = polynomial_plan(FunctionSpec("x"; domain = (-1 // 3, 1 // 3)), [0, 1])
    @test evaluate_bits(plan, round_ieee(1 // 3, IEEE32)) == 0x7fc00000
    @test evaluate_bits(plan, round_ieee(1 // 3, IEEE32; mode = :down)) ==
          round_ieee(1 // 3, IEEE32; mode = :down)
    @test cpu_check(plan) > 2048

    # Exercise bit operations, comparisons, zero-based loads and lazy selection.
    u = IR.UIntFormat(32)
    nodes = IR.Node[
        IR.Input(IEEE32),
        IR.BitCast(1, u),
        IR.Const(u, 3),
        IR.BitOp(:bitand, 2, 3),
        IR.TableLoad(1, 4),
        IR.Const(u, 32),
        IR.BitOp(:shiftright, 2, 6),
        IR.BitOp(:bitor, 2, 7),
        IR.Compare(:eq, 4, 3),
        IR.Classify(:negative, 1),
        IR.Select(10, 5, 5),
        IR.BitCast(8, IEEE32),
        IR.Const(Bool, 1),
        IR.Select(13, 11, 12),
    ]
    plan = PlanArtifact(
        FunctionSpec("x");
        program = IR.Program(
            nodes;
            tables = [
                IR.Table(
                    IEEE32,
                    round_ieee.([1, 2, 3, 4], Ref(IEEE32));
                    banks = 2,
                    unroll = true,
                ),
            ],
        ),
    )
    @test cpu_check(plan) > 2048
    # Keep extraction and shifts on the executed path, including counts at and
    # above the operand width. Unsigned operations wrap to their declared width.
    for operation in (:shiftleft, :shiftright, :bitor, :bitxor)
        width = operation in (:shiftleft, :shiftright) ? 8 : 32
        nodes = IR.Node[
            IR.Input(IEEE32),
            IR.BitCast(1, u),
            IR.ExtractBits(2, 0, width),
            IR.BitOp(operation, 2, 3),
            IR.BitCast(4, IEEE32),
        ]
        bitplan = PlanArtifact(FunctionSpec("x"); program = IR.Program(nodes))
        words = UInt64[0, 1, 31, 32, 33, 64, 255, 0x80000001, 0xffffffff]
        @test cpu_check(bitplan, words) == length(words)
    end
    # The chosen branch must skip an invalid lookup in generated code as well.
    lazy = IR.Program(
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
    @test cpu_check(
        PlanArtifact(FunctionSpec("x"); program = lazy),
        UInt64[0, 0x7fc12345],
    ) == 2
    mixed = IR.Program([
        IR.Input(IEEE64),
        IR.Convert(1, IEEE32),
        IR.ScalePow2(2, -1, IEEE32),
        IR.Quantize(3, IEEE32),
    ])
    @test cpu_check(
        PlanArtifact(
            FunctionSpec("x"; input_format = IEEE64, output_format = IEEE32);
            program = mixed,
        ),
    ) > 2048
end

@testset "Fresh erf candidate" begin
    plan = erf_candidate()
    @test plan.status == :candidate
    @test length(plan.segments) == 4
    words = verification_inputs(plan)
    @test cpu_check(plan, words) == length(words)
    indexnode = only(unique(n.index for n in plan.program.nodes if n isa IR.TableLoad))
    for (word, expected) in (
        (0x3f7fffff, 0),
        (0x3f800000, 1),
        (0x3fffffff, 1),
        (0x40000000, 2),
        (0x403fffff, 2),
        (0x40400000, 3),
        (0x40800000, 3),
    )
        @test interpret_trace(plan, word).values[indexnode] == expected
        @test interpret_trace(plan, word | 0x80000000).values[indexnode] == expected
    end
    for (word, expected) in (
        (0, 0),
        (0x80000000, 0x80000000),
        (0x7f800000, 0x3f800000),
        (0xff800000, 0xbf800000),
        (0xffa12345, 0x7fc00000),
    )
        trace = interpret_trace(plan, word)
        @test trace.bits == expected
        @test !haskey(trace.values, indexnode)
    end
    # Enclosed mathematical reference checks are sampled evidence, not a uniform certificate.
    maximum_error = BigInt(0) // BigInt(1)
    with_oracle(erf_spec(); backend = :mpfr) do oracle
        for word in words
            x = decode_ieee(word, IEEE32)
            x.kind in (:finite, :zero) || continue
            ref = reference(oracle, word)
            actual = decode_ieee(evaluate_bits(plan, word), IEEE32).value
            if ref.enclosure === nothing
                @test evaluate_bits(plan, word) == ref.bits
            else
                a, b = ref.enclosure
                lo, hi = a.significand * PRESAGe._pow2(a.exponent),
                b.significand * PRESAGe._pow2(b.exponent)
                error = max(abs(actual - lo), abs(actual - hi))
                maximum_error = max(maximum_error, error)
                @test error <= plan.spec.absolute_error
            end
        end
    end
    println("Sampled erf absolute-error upper bound: ", Float64(maximum_error))
    single = erf_candidate(;
        degree = 7,
        segments = 2,
        internal_format = IEEE32,
        evaluation = :fma,
    )
    @test cpu_check(single, verification_inputs(single; random_count = 128)) > 128
end
