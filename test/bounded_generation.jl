function generation_snapshot(directory)
    return Dict(
        name => read(joinpath(directory, name)) for
        name in _GENERATION_OUTPUTS if isfile(joinpath(directory, name))
    )
end

@testset "Bounded generation CLI and artifact replay" begin
    mktempdir() do directory
        contract = joinpath(@__DIR__, "..", "examples", "exp-contract.toml")
        config = joinpath(@__DIR__, "..", "examples", "polynomial-search.toml")
        generated = joinpath(directory, "generated")
        command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(@__DIR__, "..", "scripts", "generate.jl")) $contract $generated --search-config=$config --backend=portable`
        open(joinpath(directory, "cli.log"), "w") do io
            run(pipeline(command; stdout = io, stderr = io))
        end
        @test occursin(
            "Generated certified evaluator",
            read(joinpath(directory, "cli.log"), String),
        )
        planpath = joinpath(generated, "plan.toml")
        plan = read_plan(planpath)
        report = TOML.parsefile(joinpath(generated, "search.toml"))
        certificate = TOML.parsefile(joinpath(generated, "certificate.toml"))
        @test report["status"] == certificate["status"] == "certified"
        @test report["selected_attempt"] == 4
        @test [attempt["status"] for attempt in report["attempts"]] == [
            "bound_exceeds_budget",
            "bound_exceeds_budget",
            "bound_exceeds_budget",
            "certified",
        ]
        @test PRESAGe._plan_data(plan) == report["attempts"][4]["plan"]
        @test certificate == report["attempts"][4]["certificate"]
        proof = certify_main([planpath, joinpath(directory, "recertified.toml")])
        @test PRESAGe._rational_text(proof.total_bound) == certificate["total_bound"]
        accepted = check_generated_polynomial(proof, 0:511)
        @test length(accepted) == 129
        @test cpu_check(plan, accepted; generated_directory = generated) == 129
        repeated = joinpath(directory, "repeated")
        generate_main([planpath, repeated, "--backend=portable"])
        @test generation_snapshot(repeated) == Dict(
            name => read(joinpath(generated, name)) for
            name in ("plan.toml", "certificate.toml", "evaluator.hpp", "evaluate.cpp")
        )
        @test !isfile(joinpath(repeated, "search.toml"))
        @test cpu_check(
            read_plan(joinpath(repeated, "plan.toml")),
            accepted;
            generated_directory = repeated,
        ) == 129
        for backend in (:ac_fixed, :ap_fixed)
            available = try
                vendor_include(backend)
                true
            catch
                get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" && rethrow()
                false
            end
            available || continue
            output = joinpath(directory, string(backend))
            generate_main([planpath, output, "--backend=$backend"])
            @test read(joinpath(output, "plan.toml")) == read(planpath)
            @test cpu_check(plan, accepted; backend, generated_directory = output) == 129
        end

        preserved = generation_snapshot(generated)
        failure_config = joinpath(directory, "limited.toml")
        write_search_config(
            failure_config,
            PolynomialSearchConfig(
                degrees = [1, 9],
                internal_formats = [FixedFormat(32, 6)],
                max_attempts = 1,
            ),
        )
        @test_throws ErrorException generate_main([
            contract,
            generated,
            "--search-config=$failure_config",
        ])
        failure = TOML.parsefile(joinpath(generated, "search-failure.toml"))
        @test failure["status"] == "search_limit"
        @test failure["stop_reason"] == "attempt_limit"
        @test length(failure["attempts"]) == 1
        @test failure["attempts"][1]["status"] == "bound_exceeds_budget"
        @test all(
            name -> read(joinpath(generated, name)) == preserved[name],
            keys(preserved),
        )
        @test !haskey(failure, "selected_attempt")
        fresh = joinpath(directory, "failed-fresh")
        @test_throws ErrorException generate_main([
            contract,
            fresh,
            "--search-config=$failure_config",
        ])
        @test readdir(fresh) == ["search-failure.toml"]
        write_search_config(
            failure_config,
            PolynomialSearchConfig(
                degrees = [9],
                internal_formats = [FixedFormat(32, 6)],
                total_timeout = 1e-300,
            ),
        )
        @test_throws ErrorException generate_main([
            contract,
            generated,
            "--search-config=$failure_config",
        ])
        failure = TOML.parsefile(joinpath(generated, "search-failure.toml"))
        @test failure["stop_reason"] == "total_deadline"
        @test isempty(failure["attempts"])
        @test all(
            name -> read(joinpath(generated, name)) == preserved[name],
            keys(preserved),
        )
        # Numerical success cannot replace a valid bundle if C++ emission fails.
        write_search_config(
            failure_config,
            PolynomialSearchConfig(degrees = [9], internal_formats = [FixedFormat(32, 6)]),
        )
        @test_throws ArgumentError generate_main([
            contract,
            generated,
            "--search-config=$failure_config",
            "--name=invalid-name",
        ])
        failure = TOML.parsefile(joinpath(generated, "search-failure.toml"))
        @test failure["status"] == "certified"
        @test failure["generation_failure"]["stage"] == "emission"
        @test occursin("identifier", failure["generation_failure"]["reason"])
        @test all(
            name -> read(joinpath(generated, name)) == preserved[name],
            keys(preserved),
        )
        # Successful replay clears stale search/failure reports.
        blocked = joinpath(directory, "publication-blocked")
        mkpath(joinpath(blocked, "evaluator.hpp"))
        write(joinpath(blocked, "notes.txt"), "keep")
        @test_throws ErrorException generate_main([
            contract,
            blocked,
            "--search-config=$failure_config",
        ])
        failure = TOML.parsefile(joinpath(blocked, "search-failure.toml"))
        @test failure["status"] == "certified"
        @test failure["generation_failure"]["stage"] == "publication"
        @test readdir(blocked) == ["evaluator.hpp", "notes.txt", "search-failure.toml"]
        @test isdir(joinpath(blocked, "evaluator.hpp"))
        @test read(joinpath(blocked, "notes.txt"), String) == "keep"
        generate_main([planpath, generated, "--backend=portable"])
        @test !isfile(joinpath(generated, "search.toml"))
        @test !isfile(joinpath(generated, "search-failure.toml"))
        for options in (
            ["--certify=false"],
            ["--degree=9"],
            ["--proof-precision=128"],
            ["--search-config=$config"],
            ["--evaluation=fma"],
        )
            @test_throws ErrorException generate_main([
                contract,
                generated,
                "--search-config=$config",
                options...,
            ])
        end
        @test_throws ErrorException generate_main([
            planpath,
            generated,
            "--search-config=$config",
        ])
        @test_throws ErrorException generate_main([
            "erf",
            generated,
            "--search-config=$config",
        ])
        @test_throws ErrorException generate_main([contract, generated])
        @test !any(name -> startswith(name, ".presage-"), readdir(generated))
    end
end

@testset "Bounded generation floating and exact expressions" begin
    mktempdir() do directory
        configpath, contract =
            joinpath(directory, "config.toml"), joinpath(directory, "contract.toml")
        write_search_config(
            configpath,
            PolynomialSearchConfig(
                degrees = [13],
                internal_formats = [FloatFormat(8, 27)],
                evaluation = :fma,
            ),
        )
        programs, certificates = Any[], Any[]
        for (index, expression) in enumerate(("exp(x)+1e-1*x", "exp(x)+x/10"))
            spec =
                FunctionSpec(expression; domain = (-1, 1), absolute_error = 1 // (1 << 21))
            write_plan(contract, PlanArtifact(spec))
            output = joinpath(directory, string(index))
            generate_main([contract, output, "--search-config=$configpath"])
            plan = read_plan(joinpath(output, "plan.toml"))
            certificate = certify_polynomial(plan)
            @test certificate.status == :certified
            words = verification_inputs(plan; random_count = 256)
            for point = -64:64
                word = round_ieee(point // 64, IEEE32)
                append!(words, [word - 1, word, word + 1] .& PRESAGe._wordmask(IEEE32))
            end
            accepted = check_generated_polynomial(certificate, unique(words))
            @test !isempty(accepted)
            @test cpu_check(
                plan,
                unique(words);
                float_backend = :ac_std_float,
                generated_directory = output,
            ) == length(unique(words))
            push!(programs, PRESAGe._program_data(plan.program))
            push!(certificates, certificate.total_bound)
        end
        @test programs[1] == programs[2]
        @test certificates[1] == certificates[2]

        # Small custom input/output formats include final subnormal ties.
        format = FloatFormat(3, 4)
        spec = FunctionSpec(
            "x/128";
            input_format = format,
            domain = (-1, 1),
            absolute_error = 1 // 128,
        )
        write_plan(contract, PlanArtifact(spec))
        write_search_config(
            configpath,
            PolynomialSearchConfig(
                degrees = [1],
                internal_formats = [FloatFormat(8, 18)],
                evaluation = :fma,
            ),
        )
        output = joinpath(directory, "custom")
        generate_main([contract, output, "--search-config=$configpath"])
        plan = read_plan(joinpath(output, "plan.toml"))
        proof = certify_polynomial(plan)
        @test proof.status == :certified
        for word = 0:255
            x = decode_ieee(word, format)
            if x.value === nothing || !(-1 <= x.value <= 1)
                @test evaluate_bits(plan, word) == PRESAGe._nan(format)
            else
                actual = decode_ieee(evaluate_bits(plan, word), format)
                @test abs(actual.value - x.value / 128) <= proof.total_bound
            end
        end
        @test cpu_check(
            plan,
            0:255;
            float_backend = :ac_std_float,
            generated_directory = output,
        ) == 256

        spec = FunctionSpec(
            "exp(x)";
            input_format = IEEE16,
            domain = (-1, 1),
            absolute_error = 1 // 512,
        )
        write_plan(contract, PlanArtifact(spec))
        write_search_config(
            configpath,
            PolynomialSearchConfig(
                degrees = [9],
                internal_formats = [FixedFormat(32, 6)],
                evaluation = :fma,
            ),
        )
        output = joinpath(directory, "half")
        generate_main([
            contract,
            output,
            "--search-config=$configpath",
            "--backend=ac_fixed",
        ])
        plan = read_plan(joinpath(output, "plan.toml"))
        accepted = check_generated_polynomial(certify_polynomial(plan), 0:65535)
        @test length(accepted) > 30000
        @test cpu_check(plan, 0:65535; backend = :ac_fixed, generated_directory = output) ==
              65536
    end
end

@testset "Generation artifact publication recovery" begin
    mktempdir() do directory
        for name in _GENERATION_OUTPUTS
            write(joinpath(directory, name), "old $name")
        end
        write(joinpath(directory, "notes.txt"), "keep these notes")
        old = generation_snapshot(directory)
        count = Ref(0)
        install =
            (source, target) -> begin
                count[] += 1
                count[] == 2 && error("controlled publication failure")
                mv(source, target)
            end
        @test_throws ErrorException _publish_generation(
            directory,
            Dict("evaluator.hpp" => "new header", "evaluate.cpp" => "new harness");
            install,
        )
        @test count[] == 2
        @test generation_snapshot(directory) == old
        @test read(joinpath(directory, "notes.txt"), String) == "keep these notes"
        @test !any(name -> startswith(name, ".presage-"), readdir(directory))
        _publish_generation(
            directory,
            Dict("evaluator.hpp" => "new header", "evaluate.cpp" => "new harness"),
        )
        @test generation_snapshot(directory) == Dict(
            "evaluator.hpp" => collect(codeunits("new header")),
            "evaluate.cpp" => collect(codeunits("new harness")),
        )
        @test read(joinpath(directory, "notes.txt"), String) == "keep these notes"
        mkpath(joinpath(directory, "plan.toml"))
        snapshot = generation_snapshot(directory)
        @test_throws ErrorException _publish_generation(
            directory,
            Dict("evaluator.hpp" => "another header"),
        )
        @test generation_snapshot(directory) == snapshot
        @test !any(name -> startswith(name, ".presage-"), readdir(directory))
    end
end
