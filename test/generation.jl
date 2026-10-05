include(joinpath(@__DIR__,"..","scripts","generate.jl"))
include(joinpath(@__DIR__,"..","scripts","certify.jl"))
@testset "Certified generation commands" begin
    mktempdir() do directory
        generated = joinpath(directory,"generated")
        generate_main(["erf",generated])
        plan = read_plan(joinpath(generated,"plan.toml"))
        @test PRESAGe._has_fixed(plan.program)
        @test TOML.parsefile(joinpath(generated,"certificate.toml"))["status"] == "certified"
        repeated = joinpath(directory,"repeated")
        generate_main([joinpath(generated,"plan.toml"),repeated])
        @test read(joinpath(generated,"evaluator.hpp")) == read(joinpath(repeated,"evaluator.hpp"))
        @test read(joinpath(generated,"evaluate.cpp")) == read(joinpath(repeated,"evaluate.cpp"))
        report = joinpath(directory,"proof.toml")
        @test certify_main([joinpath(generated,"plan.toml"),report]).status == :certified
        @test_throws ErrorException generate_main(["erf",generated,"--degree=1","--fraction-bits=12","--max-fraction-bits=12"])
        @test TOML.parsefile(joinpath(generated,"certificate-failure.toml"))["status"] == "search_limit"
        @test read(joinpath(generated,"evaluator.hpp")) == read(joinpath(repeated,"evaluator.hpp"))
        generate_main(["erf",generated,"--internal=double"])
        @test !isfile(joinpath(generated,"certificate.toml"))
        @test !isfile(joinpath(generated,"certificate-failure.toml"))
        @test !PRESAGe._has_fixed(read_plan(joinpath(generated,"plan.toml")).program)
        @test_throws ErrorException generate_main(["erf",generated,"--internal=double","--fraction-bits=30"])
        @test_throws ErrorException generate_main(["erf",generated,"--certify=maybe"])
        @test_throws ErrorException generate_main(["erf",generated,"--certify=false","--proof-precision=128"])
    end
end
