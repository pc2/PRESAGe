include(joinpath(@__DIR__, "..", "scripts", "reference.jl"))
@testset "Reference command" begin
    mktempdir() do dir
        input = joinpath(dir, "input.bin")
        open(input, "w") do io
            PRESAGe._write_word(io, UInt64(0xc2af0001), 4, :little)
        end
        for (operation, backend, expected) in (
            ("exp", "mpfr", 0x006cb285),
            ("exp", "sollya", 0x006cb285),
            ("1", "sollya", 0x3f800000),
        )
            output = joinpath(dir, "$(operation)_$backend.bin")
            main([operation, input, output, "--backend=$backend", "--chunk-elements=2"])
            @test PRESAGe._read_word(read(output), 1, 4, :little) == expected
            @test TOML.parsefile(output * ".toml")["complete"]
        end
        @test_throws ErrorException main([
            "exp",
            input,
            joinpath(dir, "bad.bin"),
            "--unknown=1",
        ])
        @test_throws ErrorException main([
            "exp",
            input,
            joinpath(dir, "bad.bin"),
            "--format=half",
            "--format=single",
        ])
    end
end
