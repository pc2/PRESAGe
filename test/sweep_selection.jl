function selection_linear_certificate(segments, degree; width = 32, precision = nothing)
    input, output = FixedFormat(12, 2), FixedFormat(32, 4)
    spec = FunctionSpec("x"; input_format = input, output_format = output, domain = (-1, 1))
    internal = precision === nothing ? FixedFormat(width, 4) : precision.coordinate_format
    geometry = PRESAGe._segment_geometry(spec, segments, internal)
    rows = [
        [center, PRESAGe._pow2(-geometry.exponent), fill(0, degree - 1)...] for
        center in geometry.centers
    ]
    plan = segmented_polynomial_plan(spec, rows; internal_format = internal, precision)
    certificate = certify_polynomial(plan)
    @test certificate.status == :certified && certificate.total_bound == 0
    return certificate
end

function selection_fixture(
    certificates;
    spec_indices = fill(1, length(certificates)),
    statuses = fill(:certified, length(certificates)),
)
    specs = Tuple(
        certificates[findfirst(==(i), spec_indices)].plan.spec for
        i = 1:maximum(spec_indices)
    )
    rows = Tuple(
        map(enumerate(certificates)) do (i, certificate)
            plan = certificate.plan
            precision = PRESAGe._stored_precision(plan)
            attempt = SearchAttempt(
                length(precision.coefficient_formats) - 1,
                precision.coordinate_format,
                length(plan.segments),
                plan.precision,
                statuses[i],
                0.0,
                plan,
                certificate,
                "certified fixture",
                0.0,
                0.0,
            )
            PolynomialSweepRow(i, spec_indices[i], attempt, :disabled, nothing, 0.0)
        end,
    )
    config = PolynomialSearchConfig(degrees = [1], internal_formats = [FixedFormat(32, 4)])
    result = PolynomialSweepResult(
        specs,
        config,
        :regenerate,
        :complete,
        rows,
        (),
        0.0,
        :choices_exhausted,
        1,
        BlockMemoryModel(),
        nothing,
        :memory,
        (),
    )
    return select_sweep(result)
end

@testset "Memory-aware candidate selection and model changes" begin
    # The larger table has more logical bits, fewer independent columns and less arithmetic.
    cubic = selection_linear_certificate(128, 3)
    linear = selection_linear_certificate(512, 1)
    result = selection_fixture([cubic, linear])
    @test implementation_cost(cubic.plan).table_bits <
          implementation_cost(linear.plan).table_bits
    @test [implementation_cost(c.plan).table_blocks for c in (cubic, linear)] == [5, 3]
    @test result.pareto_indices == (2,)
    @test only(result.selections).row_index == 2
    @test occursin("memory priority", only(result.selections).reason)
    tiled = select_sweep(result; memory_model = BlockMemoryModel(depth = 128))
    @test tiled.rows === result.rows && tiled.elapsed_seconds == result.elapsed_seconds
    @test tiled.pareto_indices == (1, 2)
    @test only(tiled.selections).row_index == 1
    arithmetic = select_sweep(tiled; objective = :arithmetic)
    @test only(arithmetic.selections).row_index == 2
    @test arithmetic.memory_model.depth == 128
    @test occursin("arithmetic priority", only(arithmetic.selections).reason)
    budgeted = select_sweep(arithmetic; max_table_blocks = 5)
    @test budgeted.pareto_indices == (1,)
    @test only(budgeted.selections).row_index == 1
    impossible = select_sweep(result; max_table_blocks = 2)
    @test isempty(impossible.pareto_indices)
    @test only(impossible.selections).status == :memory_budget_exceeded
    @test only(impossible.selections).row_index === nothing
    @test occursin("2 modeled", only(impossible.selections).reason)
    @test all(r -> r.attempt.status == :certified, impossible.rows)
    @test only(select_sweep(impossible; max_table_blocks = nothing).selections).row_index ==
          2
    at_limit = select_sweep(result; max_table_blocks = 3)
    @test only(at_limit.selections).row_index == 2

    narrow = selection_linear_certificate(128, 3; width = 17)
    wide = selection_linear_certificate(512, 1; width = 33)
    width_choices = selection_fixture([narrow, wide])
    @test [implementation_cost(c.plan).table_blocks for c in (narrow, wide)] == [5, 6]
    @test only(width_choices.selections).row_index == 1
    wider_block =
        select_sweep(width_choices; memory_model = BlockMemoryModel(word_bits = 36))
    @test only(wider_block.selections).row_index == 2
    @test only(select_sweep(width_choices; objective = :arithmetic).selections).row_index ==
          2

    precision = PolynomialPrecision(
        FixedFormat(32, 4);
        coefficient_formats = [FixedFormat(w, 4) for w in (17, 33, 65, 9)],
        stage_formats = fill(FixedFormat(32, 4), 4),
    )
    individual = selection_fixture([selection_linear_certificate(512, 3; precision)])
    @test only(select_sweep(individual; max_table_blocks = 7).selections).status ==
          :memory_budget_exceeded
    @test only(select_sweep(individual; max_table_blocks = 8).selections).row_index == 1
    model36 = select_sweep(
        individual;
        memory_model = BlockMemoryModel(word_bits = 36),
        max_table_blocks = 6,
    )
    @test only(model36.selections).row_index == 1

    for budget in (-1, true, 1.0, "1")
        @test_throws ArgumentError select_sweep(result; max_table_blocks = budget)
        @test_throws ArgumentError PRESAGe._sweep_polynomial(
            sweep_spec,
            sweep_config();
            max_table_blocks = budget,
            process_started = (p, d) -> error("invalid budget launched a worker"),
        )
    end
    @test_throws ArgumentError select_sweep(result; objective = :unknown)
    @test_throws ArgumentError PRESAGe._sweep_polynomial(
        sweep_spec,
        sweep_config();
        objective = :unknown,
        process_started = (p, d) -> error("invalid objective launched a worker"),
    )

    failed =
        selection_fixture([cubic, linear]; statuses = [:bound_exceeds_budget, :timeout])
    @test isempty(failed.pareto_indices)
    @test only(failed.selections).status == :no_certified_candidate
    @test all(r -> r.attempt.certificate.status == :certified, failed.rows) # Attempt status controls eligibility.
    duplicate = selection_fixture([linear, linear])
    @test duplicate.pareto_indices == (1, 2)
    @test only(duplicate.selections).row_index == 1
    independent = selection_fixture([cubic, linear]; spec_indices = [1, 2])
    @test independent.pareto_indices == (1, 2)
    @test [s.row_index for s in independent.selections] == [1, 2]
    constrained = select_sweep(independent; max_table_blocks = 3)
    @test [s.status for s in constrained.selections] == [:memory_budget_exceeded, :selected]
    @test constrained.pareto_indices == (2,)

    io = IOBuffer()
    write_sweep_report(io, tiled; observations = Dict(1 => Dict("status" => "passed")))
    report = TOML.parse(String(take!(io)))
    @test report["schema_version"] == 3
    @test report["memory_model"] == Dict("depth" => 128, "word_bits" => 32)
    @test report["rows"][2]["operations"]["table_blocks"] == 12
    @test report["rows"][2]["operations"]["table_block_depth"] == 128
    @test report["rows"][2]["selection_cost"]["table_blocks"] == 12
    @test report["rows"][1]["sampled"]["status"] == "passed"
    @test report["selections"][1]["row_index"] == 1
    @test report["selection_policy"]["order"][1] == "table_blocks"
    @test report["selection_policy"]["order"][end] == "request_index"
    @test "table_blocks" in report["pareto_metrics"]
    @test "comparisons" in report["pareto_metrics"]
    huge = select_sweep(
        result;
        memory_model = BlockMemoryModel(depth = typemax(Int), word_bits = typemax(Int)),
        max_table_blocks = big(2)^100,
    )
    report = TOML.parse(sprint(io -> write_sweep_report(io, huge)))
    @test parse(BigInt, report["selection_policy"]["max_table_blocks"]) == big(2)^100
    @test parse(BigInt, report["rows"][1]["operations"]["table_allocated_bits"]) ==
          5big(typemax(Int))^2

    for selected in
        (result, tiled, arithmetic, width_choices, wider_block, individual, model36)
        choice = only(selected.selections)
        row = selected.rows[choice.row_index]
        @test certify_plan(row.attempt.plan).status == :certified
        @test choice.row_index in selected.pareto_indices
    end
end

@testset "Selected sweep artifacts, replacement and rollback" begin
    certificates = [selection_linear_certificate(4, 1), selection_linear_certificate(8, 3)]
    result = selection_fixture(certificates; spec_indices = [1, 2])
    mktempdir() do directory
        write(joinpath(directory, "keep.txt"), "unrelated")
        write_sweep_artifacts(directory, result)
        report = TOML.parsefile(joinpath(directory, "sweep.toml"))
        for selection in report["selections"]
            plan_path = joinpath(directory, selection["plan_path"])
            proof_path = joinpath(directory, selection["certificate_path"])
            plan = read_plan(plan_path)
            @test PRESAGe._plan_data(plan) ==
                  PRESAGe._plan_data(certificates[selection["spec_index"]].plan)
            @test TOML.parsefile(proof_path) ==
                  report["rows"][selection["row_index"]]["certificate"]
            @test certify_plan(plan).status == :certified
        end
        before = read(joinpath(directory, "sweep.toml"), String)
        calls = Ref(0)
        install(source, destination) = begin
            calls[] += 1
            calls[] == 2 && error("controlled publication failure")
            mv(source, destination)
        end
        @test_throws ErrorException PRESAGe._write_sweep_artifacts(
            directory,
            select_sweep(result; max_table_blocks = 0);
            install,
        )
        @test read(joinpath(directory, "sweep.toml"), String) == before
        @test isfile(joinpath(directory, "selected", "1", "plan.toml"))
        @test isfile(joinpath(directory, "selected", "2", "plan.toml"))
        @test read(joinpath(directory, "keep.txt"), String) == "unrelated"
        write_sweep_artifacts(directory, select_sweep(result; max_table_blocks = 0))
        @test isempty(readdir(joinpath(directory, "selected")))
        @test all(
            s -> s["status"] == "memory_budget_exceeded",
            TOML.parsefile(joinpath(directory, "sweep.toml"))["selections"],
        )
        @test read(joinpath(directory, "keep.txt"), String) == "unrelated"
        @test !any(name -> startswith(name, ".presage-sweep-"), readdir(directory))
        write_sweep_artifacts(directory, selection_fixture(certificates[1:1]))
        @test readdir(joinpath(directory, "selected")) == ["1"]
        limited = PolynomialSweepResult(
            result.specs,
            result.config,
            result.mode,
            :sweep_limit,
            result.rows[1:1],
            (),
            result.elapsed_seconds,
            :attempt_limit,
            result.max_parallel,
            result.memory_model,
            result.max_table_blocks,
            result.objective,
            (),
        )
        partial = select_sweep(limited)
        @test [s.status for s in partial.selections] == [:selected, :no_certified_candidate]
        write_sweep_artifacts(directory, partial)
        partial_report = TOML.parsefile(joinpath(directory, "sweep.toml"))
        @test partial_report["status"] == "sweep_limit"
        @test partial_report["stop_reason"] == "attempt_limit"
        @test partial_report["selections"][1]["row_index"] == 1
        @test !haskey(partial_report["selections"][2], "plan_path")
        @test readdir(joinpath(directory, "selected")) == ["1"]
    end
    mktempdir() do directory
        write(joinpath(directory, "selected"), "occupied")
        @test_throws ArgumentError write_sweep_artifacts(directory, result)
        @test read(joinpath(directory, "selected"), String) == "occupied"
        @test !isfile(joinpath(directory, "sweep.toml"))
    end
end

@testset "Sweep policy CLI, numerical replay and selected evaluator conformance" begin
    mktempdir() do directory
        input = FixedFormat(10, 3)
        spec = FunctionSpec(
            "x";
            input_format = input,
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
        )
        config = PolynomialSearchConfig(
            degrees = [3, 1],
            segments = [4, 8],
            internal_formats = [FixedFormat(24, 4)],
        )
        contract, settings =
            joinpath(directory, "contract.toml"), joinpath(directory, "search.toml")
        write_plan(contract, PlanArtifact(spec))
        write_search_config(settings, config)
        output, cache =
            joinpath(directory, "output"), NumericalCache(joinpath(directory, "cache"))
        cold = sweep_polynomial(spec, config; cache, max_parallel = 2, max_table_blocks = 3)
        @test cold.status == :complete
        # Sollya reduces all identity candidates to the same linear evaluator.
        # Selection uses the emitted graph; exact ties retain request order.
        @test only(cold.selections).row_index == 1
        warm = PRESAGe._sweep_polynomial(
            spec,
            config;
            cache,
            memory_model = BlockMemoryModel(depth = 4, word_bits = 12),
            max_table_blocks = 20,
            objective = :arithmetic,
            process_started = (p, d) ->
                error("selection-only change launched a numerical worker"),
        )
        @test all(r -> r.cache_status == :hit, warm.rows)
        @test [r.cache_key for r in warm.rows] == [r.cache_key for r in cold.rows]
        @test all(
            i ->
                PRESAGe._certificate_data(cold.rows[i].attempt.certificate) ==
                PRESAGe._certificate_data(warm.rows[i].attempt.certificate),
            eachindex(cold.rows),
        )
        args = [
            contract,
            settings,
            output,
            "--cache=$(cache.directory)",
            "--memory-depth=4",
            "--memory-word-bits=12",
            "--max-table-blocks=20",
            "--objective=arithmetic",
        ]
        @test sweep_main(args) == 0
        report = TOML.parsefile(joinpath(output, "sweep.toml"))
        @test report["memory_model"] == Dict("depth" => 4, "word_bits" => 12)
        @test report["selection_policy"]["max_table_blocks"] == 20
        @test report["selection_policy"]["objective"] == "arithmetic"
        @test all(r -> r["cache_status"] == "hit", report["rows"])
        @test report["selections"][1]["row_index"] == only(warm.selections).row_index
        path = joinpath(output, report["selections"][1]["plan_path"])
        plan = read_plan(path)
        @test certify_plan(plan).status == :certified
        accepted = [word for word = 0:1023 if -1 <= decode_fixed(word, input) <= 1]
        for word in accepted
            @test evaluate_bits(plan, word) ==
                  round_fixed(decode_fixed(word, input), spec.output_format)
        end
        for backend in (:portable, :ap_fixed, :ac_fixed)
            @test cpu_check(plan, accepted; backend, public_api = true) == length(accepted)
        end
        for backend in (:ap_fixed, :ac_fixed)
            kernel_trace_check([(; program = plan.program, words = 0:1023)], backend)
        end
        blocked = copy(args)
        blocked[findfirst(==("--max-table-blocks=20"), blocked)] = "--max-table-blocks=0"
        @test sweep_main(blocked) == 1
        @test isempty(readdir(joinpath(output, "selected")))
        denied = TOML.parsefile(joinpath(output, "sweep.toml"))
        @test denied["status"] == "complete"
        @test denied["selections"][1]["status"] == "memory_budget_exceeded"
        @test all(
            r -> r["status"] == "certified" && !r["selection_eligible"],
            denied["rows"],
        )
        for option in (
            "--memory-depth=0",
            "--memory-word-bits=0",
            "--max-table-blocks=-1",
            "--objective=unknown",
        )
            @test_throws ArgumentError sweep_main([contract, settings, output, option])
        end
        @test_throws ErrorException sweep_main([
            contract,
            settings,
            output,
            "--objective=memory",
            "--objective=arithmetic",
        ])
    end
end
