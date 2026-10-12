isdefined(Main, :generate_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))

function kernel_compile(source, exe, backend)
    root = try
        vendor_include(backend)
    catch err
        get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") in ("1", "true") && rethrow()
        @info "Skipping $backend kernel tests: vendor headers unavailable" exception =
            err
        return false
    end
    compiler = get(
        ENV,
        "CXX",
        isfile("/opt/homebrew/opt/llvm/bin/clang++") ?
        "/opt/homebrew/opt/llvm/bin/clang++" : "c++",
    )
    run(
        `$compiler -std=c++17 -O2 -fno-exceptions -fno-rtti -Wall -Wextra -Werror -isystem $root $source -o $exe`,
    )
    return true
end

function kernel_bytes(io, value, width)
    PRESAGe._write_word(io, value, cld(width, 8), :little)
end
kernel_width(f) = f == Bool ? 1 : f isa FloatFormat ? PRESAGe._width(f) : f.width

function kernel_expected(p, words)
    output = IOBuffer()
    for word in words
        trace = try
            interpret_trace(p, word)
        catch err
            status =
                err isa DomainError ? 1 :
                err isa OverflowError ? 2 : err isa BoundsError ? 3 : rethrow()
            write(output, UInt8(status))
            kernel_bytes(output, 0, kernel_width(IR.format(p)))
            continue
        end
        write(output, UInt8(0))
        kernel_bytes(output, trace.bits, kernel_width(IR.format(p)))
        for (i, f) in enumerate(p.types)
            ready = haskey(trace.values, i)
            write(output, UInt8(ready))
            value = ready ? trace.values[i] : nothing
            bits =
                !ready ? 0 :
                f == Bool ? Int(value) : f isa IR.UIntFormat ? value : value.bits
            kernel_bytes(output, bits, kernel_width(f))
        end
    end
    return take!(output)
end

# One compilation per backend; compare all visited values and laziness as well
# as the public typed/raw results. A rejected evaluation has no numerical result.
function kernel_trace_check(fixtures, backend)
    mktempdir() do directory
        source, exe = joinpath(directory, "check.cpp"), joinpath(directory, "check")
        open(source, "w") do io
            println(io, "#include <iostream>\n#include <cstdlib>")
            for (i, fixture) in enumerate(fixtures)
                header = "kernel$i.hpp"
                emit_kernel(
                    joinpath(directory, header),
                    fixture.program;
                    name = "test$i",
                    backend,
                    toolchain = backend == :ap_fixed ? :vitis :
                                PRESAGe._kernel_has_float_arithmetic(fixture.program) ?
                                :generic : :oneapi,
                    trace = true,
                    resource_model = hasproperty(fixture, :resource_model) ?
                                     fixture.resource_model : nothing,
                )
                println(io, "#include \"$header\"")
            end
            println(
                io,
                """
template<class T> void write_word(const T& value, int width) {
    for (int byte = 0; byte < (width+7)/8; ++byte) {
        unsigned c = 0;
        for (int bit=0; bit<8 && byte*8+bit<width; ++bit)
            if (value[byte*8+bit]) c |= 1U << bit;
        std::cout.put(static_cast<char>(c));
    }
}
void write_word(bool value, int) { std::cout.put(value ? 1 : 0); }
template<class T> T read_word(int width) {
    T value = 0;
    for (int byte=0; byte<(width+7)/8; ++byte) {
        int c = std::cin.get();
        if (c < 0) std::exit(3);
        for (int bit=0; bit<8 && byte*8+bit<width; ++bit)
            value[byte*8+bit] = (unsigned(c) >> bit) & 1U;
    }
    return value;
}
""",
            )
            for (i, fixture) in enumerate(fixtures)
                p = fixture.program
                println(io, "void run$i() { using namespace presage_test$i;")
                println(io, "for (int k=0; k<$(length(fixture.words)); ++k) {")
                println(
                    io,
                    "auto raw = read_word<InputBits>($(kernel_width(IR.format(p,p.input))));",
                )
                println(
                    io,
                    "Input input = copy_bits<Input,$(kernel_width(IR.format(p,p.input)))>(raw);",
                )
                println(io, "Trace trace; auto observed = evaluate(input, &trace);")
                println(
                    io,
                    "auto typed = evaluate(input); auto result = evaluate_bits(raw);",
                )
                println(
                    io,
                    "if (typed.status != observed.status || result.status != observed.status || typed.valid() != result.valid()) std::exit(4);",
                )
                println(
                    io,
                    "if (result.valid() && (copy_bits<OutputBits,$(kernel_width(IR.format(p)))>(observed.value) != result.bits || copy_bits<OutputBits,$(kernel_width(IR.format(p)))>(typed.value) != result.bits)) std::exit(5);",
                )
                println(
                    io,
                    "std::cout.put(static_cast<char>(result.status)); write_word(result.bits,$(kernel_width(IR.format(p))));",
                )
                println(io, "if (!result.valid()) continue;")
                for (j, f) in enumerate(p.types)
                    println(
                        io,
                        "std::cout.put(trace.visited$j ? 1 : 0); write_word(trace.value$j,$(kernel_width(f)));",
                    )
                end
                println(io, "} }")
            end
            println(io, "int main() {")
            for i in eachindex(fixtures)
                println(io, "run$i();")
            end
            println(io, "return std::cout ? 0 : 6; }")
        end
        if !kernel_compile(source, exe, backend)
            @test_skip false
            return
        end
        input, expected = IOBuffer(), IOBuffer()
        for fixture in fixtures
            for word in fixture.words
                kernel_bytes(
                    input,
                    word,
                    kernel_width(IR.format(fixture.program, fixture.program.input)),
                )
            end
            write(expected, kernel_expected(fixture.program, fixture.words))
        end
        seekstart(input)
        actual = read(pipeline(`$exe`; stdin = input))
        expected_bytes = take!(expected)
        @test length(actual) == length(expected_bytes)
        mismatch = findfirst(
            i -> actual[i] != expected_bytes[i],
            1:min(length(actual), length(expected_bytes)),
        )
        @test mismatch === nothing
        if mismatch !== nothing
            @info "Kernel trace mismatch" backend byte = mismatch actual = actual[mismatch] expected =
                expected_bytes[mismatch]
        end
    end
end

function kernel_matrix(mode, overflow, signed)
    a, b, c = FixedFormat(12, 5), FixedFormat(9, 3; signed = false), FixedFormat(8, 2)
    values = collect(-128:127)
    tables = [
        IR.Table(a, round_fixed.(values .// 16, Ref(a)); banks = 4),
        IR.Table(
            b,
            round_fixed.(mod.(values, 32) .// 16, Ref(b));
            banks = 2,
            unroll = true,
        ),
        IR.Table(
            c,
            round_fixed.((mod.(values, 64) .- 32) .// 16, Ref(c));
            banks = 4,
            unroll = true,
        ),
    ]
    u = IR.UIntFormat(11)
    nodes = IR.Node[
        IR.Input(FixedFormat(11, 11; signed = false)),
        IR.BitCast(1, u),
        IR.ExtractBits(2, 0, 8),
        IR.ExtractBits(2, 8, 3),
        IR.TableLoad(1, 3),
        IR.TableLoad(2, 3),
        IR.TableLoad(3, 3),
    ]
    f = FixedFormat(5, 2; signed, rounding = mode, overflow)
    output = FixedFormat(16, 8)
    results = Int[]
    for operation in (:convert, :quantize, :mul, :add, :fma, :scale)
        node =
            operation == :convert ? IR.Convert(5, f) :
            operation == :quantize ? IR.Quantize(5, f) :
            operation == :mul ? IR.Mul(5, 6, f) :
            operation == :add ? IR.Add(5, 7, f) :
            operation == :fma ? IR.FMA(5, 6, 7, f) : IR.ScalePow2(5, -2, f)
        push!(nodes, node, IR.Convert(length(nodes) + 1, output))
        push!(results, length(nodes))
    end
    selected = results[end]
    for k = (length(results) - 1):-1:1
        push!(
            nodes,
            IR.Const(IR.UIntFormat(3), k - 1),
            IR.Compare(:eq, 4, length(nodes) + 1),
        )
        push!(nodes, IR.Select(length(nodes), results[k], selected))
        selected = length(nodes)
    end
    return IR.Program(nodes; tables)
end

function kernel_wide_words(width)
    mask = (BigInt(1) << width) - 1
    words = BigInt[0, 1, mask, mask - 1, (mask + 1) >> 1, (mask - 1) >> 1]
    state = UInt64(42)
    for _ = 1:64
        word = BigInt(0)
        for bit = 0:64:(width - 1)
            state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
            word |= BigInt(state) << bit
        end
        push!(words, word & mask)
    end
    return unique(words)
end

function kernel_fixtures()
    fixtures = []
    add(p, words) = push!(fixtures, (; program = p, words = BigInt.(words)))
    for mode in (:nearest_even, :toward_zero, :up, :down),
        overflow in (:reject, :wrap, :saturate),
        signed in (true, false)

        add(kernel_matrix(mode, overflow, signed), 0:1535)
    end
    # Inward domain guards, normalized segments and individual coefficient/stage
    # formats, with both separate rounding and a single-rounding FMA.
    spec = FunctionSpec(
        "1/4+x/2-x^2/8";
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(24, 5),
        domain = (-1 // 3, 1 // 3),
        absolute_error = 1 // 512,
    )
    precision = PolynomialPrecision(
        FixedFormat(28, 6);
        coefficient_formats = [FixedFormat(17, 4), FixedFormat(20, 5), FixedFormat(14, 2)],
        stage_formats = [FixedFormat(25, 6), FixedFormat(23, 5), FixedFormat(19, 3)],
    )
    for evaluation in (:separate, :fma)
        plan = polynomial_plan(spec, [1 // 4, 1 // 2, -1 // 8]; precision, evaluation)
        add(plan.program, 0:511)
        segmented = segmented_polynomial_plan(
            spec,
            [[1 // 4, 1 // 16], [1 // 2, 1 // 32]];
            precision,
            evaluation,
        )
        add(segmented.program, 0:511)
    end
    # Full-width multiplication/FMA, nonstandard binary points, bit extraction,
    # wide shift counts, and unsigned classification/comparisons.
    for width in (65, 129, 257), signed in (true, false)
        f = FixedFormat(width, signed ? 4 : width; signed)
        u = IR.UIntFormat(width)
        tiny = FixedFormat(7, 1)
        product = FixedFormat(2width + 4, 2f.integer_bits + 4)
        nodes = IR.Node[
            IR.Input(f),
            IR.BitCast(1, u),
            IR.Const(u, 1),
            IR.Const(u, width),
            IR.BitOp(:shiftleft, 2, 3),
            IR.BitOp(:shiftright, 2, 4),
            IR.BitOp(:bitxor, 5, 6),
            IR.BitOp(:bitor, 7, 2),
            IR.BitOp(:bitand, 8, 2),
            IR.ExtractBits(9, width - 3, 3),
            IR.Compare(:ge, 10, 10),
            IR.Classify(:negative, 1),
            IR.Classify(:finite, 1),
            IR.Classify(:infinity, 1),
            IR.Classify(:nan, 1),
            IR.Classify(:zero, 1),
            IR.Compare(:ne, 14, 15),
            IR.Select(17, 12, 13),
            IR.Select(18, 11, 16),
            IR.constant(-3 // 64, tiny),
            IR.Mul(1, 1, product),
            IR.FMA(1, 1, 20, product),
            IR.Select(19, 21, 22),
        ]
        add(IR.Program(nodes), kernel_wide_words(width))
    end
    # Both scale directions, negative intermediate binary points and integer outputs.
    for exponent in (-5, 0, 4), mode in (:nearest_even, :toward_zero, :up, :down)
        f = FixedFormat(8, 2)
        out = FixedFormat(9, 9; rounding = mode, overflow = :saturate)
        add(IR.Program([IR.Input(f), IR.ScalePow2(1, exponent, out)]), 0:255)
    end
    for mode in (:nearest_even, :toward_zero, :up, :down)
        f = FixedFormat(8, 2; signed = false)
        out = FixedFormat(9, 9; signed = false, rounding = mode)
        add(IR.Program([IR.Input(f), IR.ScalePow2(1, -5, out)]), 0:255)
    end
    # Wide shift counts must be tested before narrowing, and unsigned tables
    # carry the same exact payloads as constants. Include every comparison.
    f, u = FixedFormat(8, 4), IR.UIntFormat(129)
    for operation in (:shiftleft, :shiftright), predicate in (:eq, :ne, :lt, :le, :gt, :ge)
        nodes = IR.Node[
            IR.Input(f),
            IR.BitCast(1, IR.UIntFormat(8)),
            IR.ExtractBits(2, 0, 3),
            IR.TableLoad(1, 3),
            IR.Const(u, BigInt(1) << 100),
            IR.BitOp(operation, 4, 5),
            IR.Compare(predicate, 4, 6),
            IR.constant(1, f),
            IR.constant(-1, f),
            IR.Select(7, 8, 9),
        ]
        add(
            IR.Program(
                nodes;
                tables = [IR.Table(u, [0, 1, (BigInt(1) << 128) + 3]; banks = 2)],
            ),
            0:255,
        )
    end
    add(IR.Program([IR.Input(FixedFormat(1, 1)), IR.constant(1, FixedFormat(8, 4))]), 0:1)
    # An exact product followed by one rounding differs from separate Mul/Add.
    input = FixedFormat(6, 2)
    f = FixedFormat(4, 2)
    for fused in (true, false)
        nodes = IR.Node[
            IR.Input(input),
            IR.constant(3 // 4, input),
            IR.constant(-1 // 4, input),
        ]
        if fused
            push!(nodes, IR.FMA(1, 2, 3, f))
        else
            push!(nodes, IR.Mul(1, 2, f), IR.Add(4, 3, f))
        end
        add(IR.Program(nodes), 0:63)
    end
    # Invalid table loads and overflow must remain hidden behind an untaken
    # branch. Guards and operands reject in the interpreter's evaluation order.
    f, narrow, u = FixedFormat(8, 4), FixedFormat(2, 1), IR.UIntFormat(129)
    tables = [IR.Table(f, [0, 1, 2, 3, 4]; banks = 2, unroll = true)]
    for index in (0, 4, 5, BigInt(1) << 100),
        reversed in (false, true),
        guarded in (false, true)

        nodes = IR.Node[
            IR.Input(f),
            IR.constant(0, f),
            IR.Compare(:ge, 1, 2),
            IR.Const(u, index),
            IR.TableLoad(1, 4),
            IR.Convert(1, narrow),
            IR.Convert(6, f),
        ]
        push!(nodes, reversed ? IR.Add(5, 7, f) : IR.Add(7, 5, f))
        push!(nodes, guarded ? IR.Guard(3, 8) : IR.Select(3, 2, 8))
        add(IR.Program(nodes; tables), 0:255)
    end
    # A shared value computed in only one branch must be reused afterwards,
    # without eagerly visiting its dependencies in the other branch.
    f = FixedFormat(8, 4; overflow = :wrap)
    nodes = IR.Node[
        IR.Input(f),
        IR.constant(0, f),
        IR.constant(1, f),
        IR.Compare(:lt, 1, 2),
        IR.Add(1, 3, f),
        IR.Select(4, 5, 2),
        IR.Add(6, 5, f),
    ]
    add(IR.Program(nodes), 0:255)
    # Common work may occur after a different rejection in one branch. It must
    # stay there: negative inputs reject on the table, others on the guard.
    nodes = IR.Node[
        IR.Input(f),
        IR.constant(0, f),
        IR.Compare(:lt, 1, 2),
        IR.Const(Bool, 0),
        IR.Guard(4, 2),
        IR.Const(IR.UIntFormat(2), 1),
        IR.TableLoad(1, 6),
        IR.Add(7, 5, f),
        IR.Select(3, 8, 5),
    ]
    add(IR.Program(nodes; tables = [IR.Table(f, [0])]), 0:255)
    return fixtures
end

@testset "Readable kernel output" begin
    f = FixedFormat(8, 4; overflow = :wrap)
    nodes = IR.Node[IR.Input(f), IR.constant(1, f)]
    value = 1
    for k = 1:24
        push!(nodes, IR.constant(k // 16, f))
        push!(nodes, IR.Compare(:lt, 1, length(nodes)))
        condition = length(nodes)
        push!(nodes, IR.Add(value, 2, f))
        push!(nodes, IR.Select(condition, length(nodes), value))
        value = length(nodes)
    end
    p = IR.Program(nodes)
    mktempdir() do directory
        path = joinpath(directory, "evaluator.hpp")
        emit_kernel(path, p)
        text = read(path, String)
        @test !isfile(joinpath(directory, "evaluator_support.hpp"))
        @test occursin("kernel_quantize", text)
        @test !occursin(r"Context|ready\d|\bn\d+\(\)|EncodedFloat|struct Trace", text)
        @test occursin("using Fixed8_4", text)
        @test occursin("if (condition_", text)
        @test !occursin("computed_", text) # all shared work is a common prefix
        @test sizeof(text) < 20_000 # nested selections must not duplicate the DAG
        @test text == sprint(io -> emit_kernel(io, p))
        source = joinpath(directory, "check.cpp")
        write(
            source,
            "#include \"evaluator.hpp\"\nint main() { return presage_evaluator::evaluate(presage_evaluator::Input(0)).valid() ? 0 : 1; }\n",
        )
        @test kernel_compile(source, joinpath(directory, "check"), :ac_fixed)
    end
end

@testset "AP CPU scaling regression" begin
    available = try
        vendor_include(:ap_fixed)
        true
    catch
        get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") in ("1", "true") && rethrow()
        false
    end
    for mode in (:nearest_even, :toward_zero, :up, :down)
        if !available
            @test_skip false
            continue
        end
        input, output = FixedFormat(8, 2), FixedFormat(9, 9; rounding = mode)
        plan = PlanArtifact(
            FunctionSpec("x/32"; input_format = input, output_format = output);
            program = IR.Program([IR.Input(input), IR.ScalePow2(1, -5, output)]),
        )
        @test cpu_check(plan, 0:255; backend = :ap_fixed) == 256
    end
end

@testset "Fixed kernel exact arithmetic, branches and intermediate values" begin
    fixtures = kernel_fixtures()
    for backend in (:ap_fixed, :ac_fixed)
        @testset "$backend" begin
            kernel_trace_check(fixtures, backend)
        end
    end
end

@testset "Kernel emission validates before writing" begin
    good = IR.Program([IR.Input(FixedFormat(8, 4))])
    float = IR.Program([IR.Input(IEEE32), IR.Add(1, 1, IEEE32)])
    for options in (
        (; backend = :portable),
        (; backend = :ac_fixed, toolchain = :vitis),
        (; backend = :ap_fixed, toolchain = :oneapi),
        (; toolchain = :unknown),
    )
        io = IOBuffer()
        @test_throws ArgumentError emit_kernel(io, good; options...)
        @test isempty(take!(io))
    end
    @test_throws ArgumentError emit_kernel(IOBuffer(), float; backend = :ap_fixed)
    @test_throws ArgumentError emit_kernel(
        IOBuffer(),
        IR.Program([IR.Input(FixedFormat(4097, 4))]),
    )
    @test_throws ArgumentError emit_kernel(
        IOBuffer(),
        IR.Program(
            [IR.Input(FixedFormat(8, 4)), IR.Const(IR.UIntFormat(4097), 0)];
            output = 1,
        ),
    )
    @test_throws ArgumentError emit_kernel(IOBuffer(), good; name = "bad::name")
    f = FixedFormat(8, 4)
    p = IR.Program(
        [IR.Input(f), IR.Const(IR.UIntFormat(2), 0), IR.TableLoad(1, 2)];
        tables = [IR.Table(f, [0, 1, 2]; banks = 3, unroll = true)],
    )
    text = sprint(io -> emit_kernel(io, p))
    @test occursin("static const UInt8 table[3][1]", text)
    @test occursin("table1_banks = 3", text)
    @test occursin("table1_unroll = true", text)
    @test_throws ArgumentError emit_kernel(IOBuffer(), p; toolchain = :oneapi)
    @test_throws ArgumentError emit_kernel(
        IOBuffer(),
        IR.Program([IR.Input(f)]; tables = [IR.Table(f, [0]; banks = 2)]),
    )
    mktempdir() do directory
        file = joinpath(directory, "kernel.hpp")
        write(file, "existing")
        @test_throws ArgumentError emit_kernel(file, float; backend = :ap_fixed)
        @test read(file, String) == "existing"
    end
    for backend in (:ap_fixed, :ac_fixed)
        text = sprint(io -> emit_kernel(io, good; backend))
        @test !occursin(r"gmp|mpfr|std::(cin|cout)|throw|stdexcept|Big", text)
        @test !occursin("kernel_quantize", text)
    end
end

@testset "Kernel bundles, standalone replay, host streams and generation" begin
    mktempdir() do directory
        checker = build_verification_checker(joinpath(directory, "checker"))
        spec = FunctionSpec(
            "1/3+x";
            input_format = FixedFormat(9, 3),
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
            absolute_error = 1 // 2^18,
        )
        plan = polynomial_plan(
            spec,
            [1 // 3, 1];
            internal_format = FixedFormat(32, 6),
            evaluation = :fma,
        )
        certificate = certify_plan(plan)
        @test certificate.status == :certified
        source = joinpath(directory, "plan.toml")
        write_plan(source, plan)
        for backend in (:ap_fixed, :ac_fixed)
            generated = joinpath(directory, string(backend))
            generate_main([source, generated, "--target=kernel", "--backend=$backend"])
            @test PRESAGe._program_data(
                read_plan(joinpath(generated, "plan.toml")).program,
            ) == PRESAGe._program_data(plan.program)
            exe = joinpath(generated, "evaluate")
            if !kernel_compile(joinpath(generated, "evaluate.cpp"), exe, backend)
                @test_skip false
                continue
            end
            bundle = joinpath(directory, "$backend-bundle")
            report =
                verify_samples(certificate; checker, evaluator = exe, directory = bundle)
            @test report["status"] == "passed"
            @test report["counts"]["tested"] == 129
            @test report["counts"]["bit_mismatches"] == 0
            @test report["counts"]["certificate_failed"] == 0
            replay = check_outputs(bundle, joinpath(bundle, "outputs.bin"); checker)
            @test replay["status"] == "passed"
            input = IOBuffer()
            for word = 0:511
                kernel_bytes(input, word, 9)
            end
            seekstart(input)
            statuses = IOBuffer(read(pipeline(`$exe --status`; stdin = input)))
            for word = 0:511
                status = read(statuses, UInt8)
                bits = PRESAGe._read_word(read(statuses, 3), 1, 3, :little)
                inside = -1 <= decode_fixed(word, spec.input_format) <= 1
                @test status == (inside ? 0 : 1)
                @test bits == (inside ? evaluate_bits(plan, word) : 0)
            end
            @test eof(statuses)
            for bytes in (UInt8[0], UInt8[0, 2])
                errors = IOBuffer()
                process = run(
                    pipeline(
                        ignorestatus(`$exe`);
                        stdin = IOBuffer(bytes),
                        stdout = devnull,
                        stderr = errors,
                    ),
                )
                @test process.exitcode == 3
                @test occursin(
                    bytes == UInt8[0] ? "truncated" : "padding",
                    String(take!(errors)),
                )
            end
            errors = IOBuffer()
            process = run(
                pipeline(
                    ignorestatus(`$exe`);
                    stdin = IOBuffer(UInt8[0, 1]),
                    stdout = devnull,
                    stderr = errors,
                ),
            )
            @test process.exitcode == 1
            @test occursin("status=1", String(take!(errors)))
            saved = read(joinpath(generated, "evaluator.hpp"))
            @test !isfile(joinpath(generated, "evaluator_support.hpp"))
            write_plan(source, polynomial_plan(FunctionSpec("x"), [0, 1]))
            @test_throws ArgumentError generate_main([
                source,
                generated,
                "--target=kernel",
                "--backend=$backend",
                "--name=bad::name",
            ])
            @test read(joinpath(generated, "evaluator.hpp")) == saved
            @test !isfile(joinpath(generated, "evaluator_support.hpp"))
            write_plan(source, plan)
        end
        @test_throws ErrorException generate_main([source, directory, "--target=unknown"])
        @test_throws ErrorException generate_main([
            source,
            directory,
            "--toolchain=generic",
        ])
        @test_throws ErrorException generate_main([
            source,
            directory,
            "--target=kernel",
            "--float-backend=native",
        ])
    end
end
