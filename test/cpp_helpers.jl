@testset "Selective single-header C++ support" begin
    identity = IR.Program([IR.Input(IEEE32)])
    multiply = IR.Program([IR.Input(IEEE32), IR.constant(2, IEEE32), IR.Mul(1, 2, IEEE32)])
    f = FixedFormat(8, 4; overflow = :wrap)
    # Unreachable arithmetic and tables are validated but need no emitted support.
    dead = IR.Program(
        [
            IR.Input(IEEE32),
            IR.Convert(1, f),
            IR.Const(IR.UIntFormat(1), 0),
            IR.TableLoad(1, 3),
            IR.FloatReciprocal(1),
        ];
        output = 1,
        tables = [IR.Table(f, [0])],
    )
    for p in (identity, multiply, dead)
        text = sprint(io -> emit_cpp(io, p))
        @test !occursin(
            r"Trace|\brecord\b|normalize_float|root_argument|fixed_from_float|\bload\b",
            text,
        )
        @test !occursin(r"gmpxx|ac_fixed|<tuple>|<array>|table1|\bHalf\b", text)
        @test occursin("canonical(", text) == (p === multiply)
        plan = PlanArtifact(FunctionSpec("x"); program = p)
        words = verification_inputs(plan; random_count = 32)
        @test cpu_check(plan, words; trace = false) == length(words)
        @test cpu_check(plan, words; trace = true) == length(words)
    end
    for backend in (:ac_fixed, :ap_fixed)
        available = try
            vendor_include(backend)
            true
        catch
            get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") in ("1", "true") && rethrow()
            false
        end
        if !available
            @test_skip false
            continue
        end
        p = IR.Program([IR.Input(f)])
        text = sprint(io -> emit_kernel(io, p; backend))
        @test !occursin(
            r"kernel_quantize|EncodedFloat|rounded_shift|struct Trace|from_chunks",
            text,
        )
        @test occursin("copy_bits", text)
        mktempdir() do directory
            header = joinpath(directory, "evaluator.hpp")
            emit_kernel(header, p; backend)
            @test readdir(directory) == ["evaluator.hpp"]
            @test read(header, String) == text
            source = joinpath(directory, "check.cpp")
            write(
                source,
                "#include \"evaluator.hpp\"\nint main() { return presage_evaluator::evaluate_bits(presage_evaluator::InputBits(1)).bits == 1 ? 0 : 1; }\n",
            )
            executable = joinpath(directory, "check")
            @test kernel_compile(source, executable, backend)
            @test success(`$executable`)
        end
    end
    float_identity = sprint(io -> emit_kernel(io, identity))
    @test occursin("struct EncodedFloat", float_identity)
    @test !occursin(
        r"dyadic_to_float|float_add|float_mul|ac_std_float|highest_bit|rounded_shift",
        float_identity,
    )
    float_product = sprint(io -> emit_kernel(io, multiply))
    @test occursin("float_mul", float_product)
    @test !occursin(
        r"float_add|float_fma|float_reciprocal|normalize|float_to_fixed|dyadic_to_float",
        float_product,
    )
    mktempdir() do directory
        path = joinpath(directory, "evaluator.hpp")
        emit_cpp(path, multiply)
        @test readdir(directory) == ["evaluator.hpp"]
        @test read(path, String) == sprint(io -> emit_cpp(io, multiply))
    end
    mktempdir() do directory
        source = joinpath(directory, "source.toml")
        plan = polynomial_plan(FunctionSpec("x"; input_format = f), [0, 1])
        write_plan(source, plan)
        generated = joinpath(directory, "generated")
        mkpath(generated)
        companion = joinpath(generated, "evaluator_support.hpp")
        write(companion, "obsolete generated support")
        generate_main([source, generated, "--backend=portable", "--certify=false"])
        @test !isfile(companion)
        @test !occursin("Trace", read(joinpath(generated, "evaluator.hpp"), String))
        @test cpu_check(plan, 0:255; generated_directory = generated) == 256
        generate_main([
            source,
            generated,
            "--backend=portable",
            "--certify=false",
            "--trace=true",
        ])
        @test !isfile(companion)
        @test occursin("using Trace", read(joinpath(generated, "evaluator.hpp"), String))
        @test cpu_check(plan, 0:255; generated_directory = generated, trace = true) == 256
        generate_main([
            source,
            generated,
            "--backend=portable",
            "--certify=false",
            "--trace=false",
        ])
        @test !occursin("Trace", read(joinpath(generated, "evaluator.hpp"), String))
        @test_throws ErrorException generate_main([source, generated, "--trace=maybe"])
    end
end
