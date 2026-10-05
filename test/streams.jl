@testset "Bounded binary streams, metadata and failures" begin
    mktempdir() do dir
        for order in (:little, :big)
            input = joinpath(dir, "input_$order.bin")
            output = joinpath(dir, "output_$order.bin")
            words = UInt64[0x00000000, 0x80000000, 0x3f800000, 0xbf800000, 0x7f800000]
            open(input, "w") do io
                foreach(x -> PRESAGe._write_word(io, x, 4, order), words)
            end
            summary = generate_references(
                erf_spec(),
                input,
                output;
                byteorder = order,
                chunk_elements = 2,
            )
            @test summary["complete"]
            @test summary["inputs_read"] == 5
            @test summary["maximum_chunk_elements"] == 2
            @test filesize(output) == 20
            bytes = read(output)
            @test PRESAGe._read_word(bytes, 1, 4, order) == 0
            @test PRESAGe._read_word(bytes, 5, 4, order) == 0x80000000
            @test PRESAGe._read_word(bytes, 17, 4, order) == 0x3f800000
            @test length(readlines(output * ".status.tsv")) == 6
            metadata = TOML.parsefile(output * ".toml")
            @test metadata["complete"]
            @test metadata["byteorder"] == string(order)
            @test metadata["input_format"] == "binary32"
            @test metadata["output_format"] == "binary32"
            @test_throws ArgumentError generate_references(erf_spec(), input, output)
        end
        input = joinpath(dir, "input_little.bin")
        failed = joinpath(dir, "unresolved.bin")
        @test_throws ReferenceFailure generate_references(
            FunctionSpec("exp(x)"; output_format = IEEE64),
            input,
            failed;
            chunk_elements = 2,
            config = OracleConfig(initial_precision = 24, max_precision = 24),
        )
        @test !isfile(failed)
        metadata = TOML.parsefile(failed * ".toml")
        @test !metadata["complete"]
        @test metadata["status_counts"]["unresolved"] == 1
        @test occursin("unresolved", read(failed * ".status.tsv", String))
        truncated = joinpath(dir, "truncated.bin")
        write(truncated, UInt8[0, 0, 0])
        result = joinpath(dir, "truncated_output.bin")
        @test_throws ArgumentError generate_references(erf_spec(), truncated, result)
        @test !isfile(result)
        @test occursin("truncated", TOML.parsefile(result * ".toml")["failure"])
        emptyinput = joinpath(dir, "empty.bin")
        write(emptyinput, UInt8[])
        emptyoutput = joinpath(dir, "empty_output.bin")
        @test generate_references(erf_spec(), emptyinput, emptyoutput)["inputs_read"] == 0
        @test filesize(emptyoutput) == 0
        @test_throws ArgumentError generate_references(erf_spec(), input, input)
        @test_throws ArgumentError generate_references(
            erf_spec(),
            input,
            joinpath(dir, "bad.bin");
            byteorder = :native,
        )
        @test_throws ArgumentError generate_references(
            erf_spec(),
            input,
            joinpath(dir, "bad.bin");
            chunk_elements = 0,
        )
        @test_throws ArgumentError generate_references(
            FunctionSpec("x"; input_format = FloatFormat(3, 3)),
            input,
            joinpath(dir, "custom.bin"),
        )
    end
end
