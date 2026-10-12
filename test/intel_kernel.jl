@testset "Intel floating kernels match the exact interpreter" begin
    compiler = Sys.which("icpx")
    if compiler === nothing
        @test_skip false
    else
        mktempdir() do directory
            source = joinpath(directory, "check.cpp")
            functions = String[]
            open(source, "w") do io
                println(
                    io,
                    """
#include <iostream>
template <class T, int Width, unsigned Chunks>
T word(const unsigned long long (&chunks)[Chunks]) {
    T value = 0;
    int offset = 0;
    for (auto chunk : chunks)
        for (int bit = 0; bit < 64 && offset < Width; ++bit, ++offset)
            value[offset] = bool((chunk >> bit) & 1);
    return value;
}
""",
                )
                for (e, m) in PRESAGe._INTEL_FLOAT_FORMATS,
                    operation in (
                        FloatFormat(e, m) in (IEEE32, IEEE64) ?
                        (:add, :mul, :reciprocal, :fma) : (:add, :mul, :reciprocal)
                    )

                    format = FloatFormat(e, m)
                    width = PRESAGe._width(format)
                    count = operation == :reciprocal ? 1 : operation == :fma ? 3 : 2
                    nodes = IR.Node[
                        IR.Input(FixedFormat(count * width, count * width; signed = false)),
                        IR.BitCast(1, IR.UIntFormat(count * width)),
                    ]
                    operands = Int[]
                    for index = 0:(count - 1)
                        push!(nodes, IR.ExtractBits(2, index * width, width))
                        push!(nodes, IR.BitCast(length(nodes), format))
                        push!(operands, length(nodes))
                    end
                    push!(
                        nodes,
                        operation == :add ? IR.Add(operands..., format) :
                        operation == :mul ? IR.Mul(operands..., format) :
                        operation == :fma ? IR.FMA(operands..., format) :
                        IR.FloatReciprocal(only(operands)),
                    )
                    program = IR.Program(nodes)
                    values = unique(
                        BigInt[
                            0,
                            PRESAGe._sign(format),
                            1,
                            PRESAGe._sign(format) | 1,
                            (big(1) << m) - 1,
                            big(1) << m,
                            round_ieee(1, format),
                            round_ieee(-1, format),
                            round_ieee(3 // 2, format),
                            round_ieee(-7 // 4, format),
                            PRESAGe._inf(format),
                            PRESAGe._inf(format) | PRESAGe._sign(format),
                            PRESAGe._nan(format),
                        ],
                    )
                    words =
                        count == 1 ? values :
                        count == 2 ? [a | b << width for a in values for b in values] :
                        [
                            a | b << width | c << (2width) for a in values for b in values
                            for c in values
                        ]
                    if operation == :fma
                        encode(a, b, c) =
                            BigInt(round_ieee(a, format)) |
                            BigInt(round_ieee(b, format)) << width |
                            BigInt(round_ieee(c, format)) << (2width)
                        epsilon = 1 // (big(1) << m)
                        push!(words, encode(1 + epsilon, 1 - epsilon, -1))
                        push!(words, encode(1 + epsilon, 1 + epsilon, -(1 + 2epsilon)))
                        maximum = ((big(1) << e) - 2) << m | ((big(1) << m) - 1)
                        push!(
                            words,
                            maximum |
                            BigInt(round_ieee(2, format)) << width |
                            (maximum | PRESAGe._sign(format)) << (2width),
                        )
                    end
                    name = "case_$(e)_$(m)_$operation"
                    emit_kernel(
                        joinpath(directory, "$name.hpp"),
                        program;
                        name,
                        toolchain = :oneapi,
                    )
                    namespace = PRESAGe._cpp_name(name)
                    println(
                        io,
                        "#include \"$name.hpp\"\nint $name() {\nusing namespace $namespace;",
                    )
                    println(
                        io,
                        "constexpr unsigned long long inputs[][$(cld(count * width, 64))] = {",
                    )
                    for word in words
                        println(io, "{$(PRESAGe._kernel_chunks(word, count * width))},")
                    end
                    println(
                        io,
                        "};\nconstexpr unsigned long long expected[][$(cld(width, 64))] = {",
                    )
                    for word in words
                        bits = interpret_trace(program, word).bits
                        println(io, "{$(PRESAGe._kernel_chunks(bits, width))},")
                    end
                    println(
                        io,
                        """
};
for (unsigned i = 0; i < $(length(words)); ++i) {
    auto result = evaluate_bits(word<InputBits, $(count * width)>(inputs[i]));
    auto expected_bits = word<OutputBits, $width>(expected[i]);
    if (static_cast<unsigned>(result.status) != 0 || result.bits != expected_bits) {
        std::cerr << "$name at " << i << " got " << result.bits.to_string(AC_HEX)
                  << " expected " << expected_bits.to_string(AC_HEX) << std::endl;
        return 1;
    }
}
return 0;
}
""",
                    )
                    push!(functions, "$name()")
                end
                println(io, "int main() { return $(join(functions, " | ")); }")
            end
            executable = joinpath(directory, "check")
            library = normpath(
                joinpath(
                    dirname(compiler),
                    "..",
                    "opt",
                    "oclfpga",
                    "host",
                    "linux64",
                    "lib",
                ),
            )
            run(
                `$compiler -std=c++17 -O1 -fp-model=strict -no-ftz -fsycl -fintelfpga -qactypes -D__EMULATION_FLOW__
                -L$library -Wl,-rpath,$library -lac_types_vpfp_library $source -o $executable`,
            )
            process = run(ignorestatus(`$executable`))
            @test process.exitcode == 0
        end
    end
end

@testset "Intel calibration kernels compile constants and ROMs for the device" begin
    compiler = Sys.which("icpx")
    if compiler === nothing
        @test_skip false
    else
        model = read_resource_model(
            joinpath(@__DIR__, "..", "config", "resources", "oneapi.toml"),
        )
        for (name, plan) in
            resource_example_plans(; include_float = true, float_evaluation = :separate)
            @testset "$name" begin
                mktempdir() do directory
                    emit_kernel(
                        joinpath(directory, "evaluator.hpp"),
                        plan;
                        toolchain = :oneapi,
                        resource_model = model,
                    )
                    source = joinpath(directory, "synthesis.cpp")
                    write(source, PRESAGe._synthesis_oneapi_source(plan))
                    command = `$compiler -std=c++17 -fsycl -fintelfpga -qactypes
                        -fsycl-device-only -fsyntax-only $source`
                    @test success(command)
                end
            end
        end
    end
end

@testset "Intel ROMs preserve wide words and bank selection" begin
    compiler = Sys.which("icpx")
    if compiler === nothing
        @test_skip false
    else
        mktempdir() do directory
            source = joinpath(directory, "rom.cpp")
            functions = String[]
            open(source, "w") do io
                println(io, "#include <iostream>")
                for width in (9, 17, 33, 65, 129),
                    (banks, unroll) in ((1, false), (4, false), (4, true))

                    format = FixedFormat(width, width; signed = false)
                    values = [
                        ((big(1) << (width - 1)) + i * big(0x9e3779b97f4a7c15)) &
                        ((big(1) << width) - 1) for i = 0:6
                    ]
                    program = IR.Program(
                        [
                            IR.Input(FixedFormat(4, 4; signed = false)),
                            IR.BitCast(1, IR.UIntFormat(4)),
                            IR.TableLoad(1, 2),
                        ];
                        tables = [IR.Table(format, values; banks, unroll)],
                    )
                    name = "rom_$(width)_$(banks)_$(unroll)"
                    emit_kernel(
                        joinpath(directory, "$name.hpp"),
                        program;
                        name,
                        toolchain = :oneapi,
                    )
                    namespace = PRESAGe._cpp_name(name)
                    println(
                        io,
                        "#include \"$name.hpp\"\nint $name() {\nusing namespace $namespace;",
                    )
                    for word = 0:7
                        bits =
                            word < length(values) ? interpret_trace(program, word).bits :
                            big(0)
                        status = word < length(values) ? 0 : 3
                        println(io, "{ OutputBits expected = 0;")
                        for bit = 0:(width - 1)
                            isodd(bits >> bit) && println(io, "expected[$bit] = true;")
                        end
                        println(
                            io,
                            """
auto result = evaluate_bits(InputBits($word));
if (result.bits != expected || static_cast<unsigned>(result.status) != $status) {
    std::cerr << "$name at $word" << std::endl;
    return 1;
}
}
""",
                        )
                    end
                    println(io, "return 0;\n}")
                    push!(functions, "$name()")
                end
                println(io, "int main() { return $(join(functions, " | ")); }")
            end
            executable = joinpath(directory, "rom")
            run(
                `$compiler -std=c++17 -O1 -fsycl -fintelfpga -qactypes $source -o $executable`,
            )
            @test success(`$executable`)
        end
    end
end
