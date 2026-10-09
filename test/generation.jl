include(joinpath(@__DIR__, "..", "scripts", "generate.jl"))
include(joinpath(@__DIR__, "..", "scripts", "certify.jl"))
@testset "Custom floating generation options" begin
    mktempdir() do directory
        source, output = joinpath(directory, "wide.toml"), joinpath(directory, "generated")
        plan = polynomial_plan(FunctionSpec("x"; input_format = IEEE128), [0, 1])
        write_plan(source, plan)
        generate_main([source, output])
        text = read(joinpath(output, "evaluator.hpp"), String)
        @test occursin(r"ac_std_float<128,\s*15>", text)
        @test !occursin("gmpxx.h", text)
        @test TOML.parsefile(joinpath(output, "certificate.toml"))["total_bound"] == "0/1"
        @test_throws ArgumentError generate_main([source, output, "--float-backend=native"])
        @test read(joinpath(output, "evaluator.hpp"), String) == text
        @test_throws ErrorException generate_main([
            source,
            output,
            "--float-backend=unknown",
        ])
        write_plan(source, polynomial_plan(FunctionSpec("x"), [0, 1]))
        generate_main([source, output, "--float-backend=ac_std_float"])
        @test occursin(
            r"ac_std_float<32,\s*8>",
            read(joinpath(output, "evaluator.hpp"), String),
        )
    end
end
@testset "Certified generation commands" begin
    mktempdir() do directory
        generated = joinpath(directory, "generated")
        generate_main(["erf", generated])
        plan = read_plan(joinpath(generated, "plan.toml"))
        @test PRESAGe._has_fixed(plan.program)
        @test TOML.parsefile(joinpath(generated, "certificate.toml"))["status"] ==
              "certified"
        repeated = joinpath(directory, "repeated")
        generate_main([joinpath(generated, "plan.toml"), repeated])
        @test read(joinpath(generated, "evaluator.hpp")) ==
              read(joinpath(repeated, "evaluator.hpp"))
        @test read(joinpath(generated, "evaluate.cpp")) ==
              read(joinpath(repeated, "evaluate.cpp"))
        report = joinpath(directory, "proof.toml")
        @test certify_main([joinpath(generated, "plan.toml"), report]).status == :certified
        @test_throws ErrorException generate_main([
            "erf",
            generated,
            "--degree=1",
            "--fraction-bits=12",
            "--max-fraction-bits=12",
        ])
        @test TOML.parsefile(joinpath(generated, "certificate-failure.toml"))["status"] ==
              "search_limit"
        @test read(joinpath(generated, "evaluator.hpp")) ==
              read(joinpath(repeated, "evaluator.hpp"))
        generate_main(["erf", generated, "--internal=double"])
        @test !isfile(joinpath(generated, "certificate.toml"))
        @test !isfile(joinpath(generated, "certificate-failure.toml"))
        @test !PRESAGe._has_fixed(read_plan(joinpath(generated, "plan.toml")).program)
        @test_throws ErrorException generate_main([
            "erf",
            generated,
            "--internal=double",
            "--fraction-bits=30",
        ])
        @test_throws ErrorException generate_main(["erf", generated, "--certify=maybe"])
        @test_throws ErrorException generate_main([
            "erf",
            generated,
            "--certify=false",
            "--proof-precision=128",
        ])
        @test_throws ErrorException generate_main(["erf", generated, "--backend=unknown"])
        for backend in ("ap_fixed", "ac_fixed")
            generate_main([
                joinpath(repeated, "plan.toml"),
                generated,
                "--backend=$backend",
            ])
            @test read(joinpath(repeated, "plan.toml")) ==
                  read(joinpath(generated, "plan.toml"))
            @test occursin(
                "#include <$backend.h>",
                read(joinpath(generated, "evaluator.hpp"), String),
            )
            @test TOML.parsefile(joinpath(generated, "certificate.toml"))["status"] ==
                  "certified"
        end
        fixed = polynomial_plan(FunctionSpec("x"; input_format = FixedFormat(9, 4)), [0, 1])
        fixedpath = joinpath(directory, "fixed.toml")
        write_plan(fixedpath, fixed)
        generate_main([fixedpath, generated])
        @test read_plan(joinpath(generated, "plan.toml")).spec.input_format ==
              fixed.spec.input_format
        @test TOML.parsefile(joinpath(generated, "certificate.toml"))["status"] ==
              "certified"
        @test occursin(
            "#include <ac_fixed.h>",
            read(joinpath(generated, "evaluator.hpp"), String),
        )
        @test certify_main([fixedpath, report]).total_bound == 0
        # Older canonical artifacts need no kernel label to select their proof.
        write_plan(
            fixedpath,
            PlanArtifact(
                fixed.spec;
                program = fixed.program,
                settings = Dict("evaluation" => "separate"),
            ),
        )
        generate_main([fixedpath, generated])
        @test TOML.parsefile(joinpath(generated, "certificate.toml"))["total_bound"] ==
              "0/1"
        generate_main([fixedpath, generated, "--certify=false"])
        @test !isfile(joinpath(generated, "certificate.toml"))
        bad = polynomial_plan(FunctionSpec("x+1"; input_format = FixedFormat(9, 4)), [0, 1])
        write_plan(fixedpath, bad)
        @test_throws ErrorException generate_main([fixedpath, generated])
        @test TOML.parsefile(joinpath(generated, "certificate-failure.toml"))["status"] ==
              "bound_exceeds_budget"
        @test read_plan(joinpath(generated, "plan.toml")).spec.expression == "x"
        unsupported = erf_candidate()
        write_plan(fixedpath, unsupported)
        @test_throws ErrorException generate_main([fixedpath, generated, "--certify"])
        @test TOML.parsefile(joinpath(generated, "certificate-failure.toml"))["status"] ==
              "unsupported_domain"
    end
end

@testset "Binary16 generation and implementation policy" begin
    mktempdir() do directory
        lut = joinpath(directory, "lut")
        generate_main(["erf", lut, "--input-format=half"])
        plan = read_plan(joinpath(lut, "plan.toml"))
        @test plan.spec.input_format == plan.spec.output_format == IEEE16
        @test plan.settings["kernel"] == "full_lut"
        @test implementation_cost(plan).table_bits == 1 << 20
        @test TOML.parsefile(joinpath(lut, "certificate.toml"))["status"] == "certified"
        repeated = joinpath(directory, "repeated")
        generate_main([joinpath(lut, "plan.toml"), repeated])
        @test read(joinpath(lut, "evaluator.hpp")) ==
              read(joinpath(repeated, "evaluator.hpp"))
        @test certify_main([
            joinpath(lut, "plan.toml"),
            joinpath(directory, "report.toml"),
        ]).status == :certified
        polynomial = joinpath(directory, "polynomial")
        generate_main([
            "erf",
            polynomial,
            "--input-format=half",
            "--output-format=half",
            "--lut-max-bits=0",
        ])
        @test read_plan(joinpath(polynomial, "plan.toml")).settings["kernel"] ==
              "erf_fixed_horner"
        @test TOML.parsefile(joinpath(polynomial, "certificate.toml"))["status"] ==
              "certified"
        generate_main([
            "erf",
            polynomial,
            "--input-format=half",
            "--implementation=polynomial",
            "--evaluation=fma",
        ])
        @test read_plan(joinpath(polynomial, "plan.toml")).settings["evaluation"] == "fma"
        @test TOML.parsefile(joinpath(polynomial, "certificate.toml"))["status"] ==
              "certified"
        generate_main([
            "erf",
            polynomial,
            "--input-format=half",
            "--implementation=polynomial",
            "--certify=false",
        ])
        @test !isfile(joinpath(polynomial, "certificate.toml"))
        @test_throws ErrorException generate_main([
            "erf",
            lut,
            "--input-format=half",
            "--absolute-error=1/1073741824",
        ])
        @test TOML.parsefile(joinpath(lut, "certificate-failure.toml"))["status"] ==
              "bound_exceeds_budget"
        @test read(joinpath(lut, "evaluator.hpp")) ==
              read(joinpath(repeated, "evaluator.hpp"))
        for options in (
            ["--input-format=half", "--output-format=single"],
            ["--input-format=double"],
            ["--input-format=half", "--degree=9"],
            ["--input-format=half", "--certify=false"],
            ["--input-format=half", "--internal=double"],
        )
            @test_throws ErrorException generate_main(["erf", lut, options...])
        end
        @test_throws ArgumentError generate_main(["erf", lut, "--implementation=lut"])
        @test_throws ArgumentError generate_main([
            "erf",
            lut,
            "--input-format=half",
            "--implementation=unknown",
        ])
    end
end
