@testset "Automatic arithmetic records concrete certified choices" begin
    format = IEEE32
    spec = FunctionSpec(
        "1/3+2/7*x";
        input_format = format,
        output_format = format,
        domain = (1, 2),
        absolute_error = 1,
    )
    proofs = [
        certified_polynomial(spec; degree = 1, internal_format = format, evaluation) for
        evaluation in (:separate, :fma)
    ]
    @test all(proof -> proof.status == :certified, proofs)
    @test proofs[2].total_bound < proofs[1].total_bound
    budget = (proofs[1].total_bound + proofs[2].total_bound) / 2
    tight = FunctionSpec(
        spec.expression;
        input_format = format,
        output_format = format,
        domain = spec.domain,
        absolute_error = budget,
    )
    config = PolynomialSearchConfig(degrees = [1], internal_formats = [format])
    @test config.evaluation == :auto
    @test_throws ArgumentError search_polynomial(
        tight,
        config;
        target = TargetProfile(:vitis),
        resource_model = resource_profile("oneapi"),
        worker_command = _ -> error("An incompatible target must not start a worker."),
    )
    result = search_polynomial(tight, config; target = TargetProfile(:oneapi))
    @test result.status == :certified
    @test [attempt.status for attempt in result.attempts] == [:bound_exceeds_budget, :certified]
    @test [attempt.evaluation for attempt in result.attempts] == [:separate, :fma]
    @test [attempt.plan.settings["evaluation"] for attempt in result.attempts] == ["separate", "fma"]
    @test result.selected.total_bound <= budget
    @test target_support(result.selected.plan, TargetProfile(:oneapi)).supported
    replay = PRESAGe._read_plan(PRESAGe._plan_data(result.selected.plan))
    @test certify_plan(replay).total_bound == result.selected.total_bound
    @test any(node -> node isa IR.FMA, replay.program.nodes)

    data = PRESAGe._search_config_data(config)
    @test data["schema_version"] == 15
    @test PRESAGe._read_search_config(data).evaluation == :auto
    for evaluation in (:separate, :fma)
        explicit = deepcopy(data)
        explicit["settings"]["evaluation"] = string(evaluation)
        @test PRESAGe._read_search_config(explicit).evaluation == evaluation
    end
    delete!(data, "settings")
    @test PRESAGe._read_search_config(data).evaluation == :auto
    legacy = PRESAGe._search_config_data(PRESAGe._evaluation_config(config, :separate))
    delete!(legacy, "settings")
    @test PRESAGe._read_search_config(legacy).evaluation == :separate
    report = PRESAGe._search_data(result)
    @test report["settings"]["evaluation"] == "auto"
    @test report["attempts"][2]["plan"]["settings"]["evaluation"] == "fma"
end

@testset "Failed automatic candidates retain their arithmetic without a plan" begin
    spec = FunctionSpec("x"; input_format = IEEE32, domain = (-1, 1))
    config = PolynomialSearchConfig(
        degrees = [1],
        internal_formats = [IEEE32],
        job_timeout = 1e-12,
    )
    worker_command = _ -> error("An expired candidate must not launch a worker.")
    result = PRESAGe._search_polynomial(spec, config; worker_command)
    @test all(
        attempt -> attempt.status == :timeout && attempt.plan === nothing,
        result.attempts,
    )
    @test [attempt.evaluation for attempt in result.attempts] == [:separate, :fma]
    @test [attempt["evaluation"] for attempt in PRESAGe._search_data(result)["attempts"]] == ["separate", "fma"]
    sweep = PRESAGe._sweep_polynomial(spec, config; worker_command)
    @test all(
        row -> row.attempt.status == :timeout && row.attempt.plan === nothing,
        sweep.rows,
    )
    @test [row.attempt.evaluation for row in sweep.rows] == [:separate, :fma]
    @test [row["evaluation"] for row in PRESAGe._sweep_data(sweep)["rows"]] == ["separate", "fma"]
end

@testset "Automatic search selects certified arithmetic by resource priorities" begin
    spec = FunctionSpec(
        "1/3+2/7*x";
        input_format = IEEE32,
        domain = (1, 2),
        absolute_error = 1,
    )
    config = PolynomialSearchConfig(degrees = [1], internal_formats = [IEEE32])
    rules = [
        ResourceRule(
            operation;
            luts = operation == :fma ? 10 : operation in (:mul, :add) ? 1 : 0,
            dsps = operation in (:fma, :mul, :add) ? 1 : 0,
            ffs = 0,
            rams = 0,
        ) for operation in PRESAGe._RESOURCE_OPERATIONS
    ]
    logic = ResourceModel(; rules, priority = (:luts, :dsps))
    dsp = ResourceModel(; rules, priority = (:dsps, :luts))
    for (model, evaluation, index) in ((logic, "separate", 1), (dsp, "fma", 2))
        result = search_polynomial(spec, config; resource_model = model)
        @test result.status == :certified
        @test length(result.attempts) == 2
        @test all(attempt -> attempt.status == :certified, result.attempts)
        @test result.selected.plan.settings["evaluation"] == evaluation
        @test result.selection.objective == :resources
        @test result.selection.status == :complete
        report = PRESAGe._search_data(result)
        @test report["schema_version"] == 16
        @test report["selected_attempt"] == index
        @test report["selection"]["selection_policy"]["objective"] == "resources"
    end
    constrained = search_polynomial(
        spec,
        config;
        resource_model = logic,
        resource_budget = ResourceBudget(dsps = 1),
    )
    @test constrained.selected.plan.settings["evaluation"] == "fma"
    @test length(constrained.attempts) == 2

    partial = ResourceModel(
        rules = filter(rule -> rule.operation != :fma, rules),
        priority = (:luts,),
    )
    unresolved = select_sweep(
        constrained.selection;
        resource_model = partial,
        resource_budget = ResourceBudget(),
    )
    @test only(unresolved.selections).status == :resource_model_incomplete
    @test only(unresolved.selections).row_index === nothing
    @test occursin("calibration", only(unresolved.selections).reason)
    @test all(row -> row.attempt.status == :certified, unresolved.rows)
    over_budget = ResourceModel(
        rules = [partial.rules..., ResourceRule(:fma; dsps = 4)],
        priority = (:luts,),
    )
    eligible = select_sweep(
        constrained.selection;
        resource_model = over_budget,
        resource_budget = ResourceBudget(dsps = 2),
    )
    @test only(eligible.selections).row_index == 1
    excluded = select_implementation(
        (constrained.selected,);
        resource_model = over_budget,
        resource_budget = ResourceBudget(dsps = 2),
    )
    @test excluded.status == :resource_budget_exceeded

    missing = search_polynomial(spec, config; resource_model = ResourceModel())
    @test missing.status == :resource_model_incomplete
    @test missing.selected === nothing
    @test all(attempt -> attempt.status == :certified, missing.attempts)
    @test !haskey(PRESAGe._search_data(missing), "selected_attempt")

    limited = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [1],
            internal_formats = [IEEE32],
            max_attempts = 1,
        );
        resource_model = dsp,
    )
    @test limited.selected.plan.settings["evaluation"] == "separate"
    @test limited.stop_reason == :attempt_limit
    @test limited.selection.status == :sweep_limit

    mktempdir() do directory
        contract = joinpath(directory, "contract.toml")
        configuration = joinpath(directory, "search.toml")
        profile = joinpath(directory, "model.toml")
        output = joinpath(directory, "output")
        write_plan(contract, PlanArtifact(spec))
        write_search_config(configuration, config)
        write_resource_model(profile, logic)
        generate_main([
            contract,
            output,
            "--search-config=$configuration",
            "--resource-model=$profile",
            "--implementation=polynomial",
        ])
        selected = read_plan(joinpath(output, "plan.toml"))
        @test selected.settings["evaluation"] == "separate"
        report = TOML.parsefile(joinpath(output, "implementations.toml"))
        @test length(report["rows"]) == 2
        replay = joinpath(directory, "replay")
        generate_main([joinpath(output, "plan.toml"), replay])
        @test read(joinpath(output, "evaluator.hpp")) ==
              read(joinpath(replay, "evaluator.hpp"))
        @test read_plan(joinpath(replay, "plan.toml")).settings["evaluation"] == "separate"
    end
end

@testset "Automatic arithmetic respects target widths and stored plans" begin
    target = TargetProfile(:oneapi)
    format = FloatFormat(8, 17)
    config = PolynomialSearchConfig(degrees = [1], internal_formats = [format])
    spec = FunctionSpec(
        "x";
        input_format = IEEE32,
        domain = (-1, 1),
        absolute_error = 1 // 256,
    )
    _, requests, count, _ = PRESAGe._sweep_requests(spec, config; target)
    @test count == 2
    @test [item.request.config.evaluation for item in requests] == [:separate, :fma]
    explicit = PRESAGe._evaluation_config(config, :fma)
    result = PRESAGe._search_polynomial(spec, explicit; target)
    @test only(result.attempts).status == :certified
    @test target_support(result.selected.plan, target).supported

    precision = PolynomialPrecision(
        IEEE32;
        coefficient_formats = [IEEE32, IEEE32],
        stage_formats = [format, IEEE32],
    )
    mixed = PolynomialSearchConfig(
        degrees = [1],
        internal_formats = [IEEE32],
        precisions = [precision],
    )
    _, requests, count, _ = PRESAGe._sweep_requests(spec, mixed; target)
    @test count == 2
    @test [item.request.config.evaluation for item in requests] == [:separate, :fma]
    @test all(item -> item.request.precision == precision, requests)

    odd_spec = FunctionSpec("sin(x)"; input_format = IEEE32, domain = (-1, 1))
    for transformation in (:odd, :atan)
        transformed_spec =
            transformation == :odd ? odd_spec :
            FunctionSpec("atan(x)"; input_format = IEEE32, domain = (-1, 1))
        layout = PolynomialPrecision(
            IEEE32;
            coefficient_formats = fill(IEEE32, 2),
            stage_formats = fill(IEEE32, 2),
        )
        transformed = PolynomialSearchConfig(
            degrees = [3],
            internal_formats = [IEEE32],
            precisions = [layout],
            transformation = transformation,
        )
        _, requests, count, _ =
            PRESAGe._sweep_requests(transformed_spec, transformed; target)
        @test count == 2
        @test [item.request.config.evaluation for item in requests] == [:separate, :fma]
    end

    plan = polynomial_plan(spec, [0, 1]; internal_format = IEEE32, evaluation = :fma)
    stored = PolynomialSearchConfig(
        degrees = [1],
        internal_formats = [IEEE32],
        precisions = [PRESAGe._stored_precision(plan)],
    )
    _, requests, count, mode = PRESAGe._sweep_requests(plan, stored; target)
    @test mode == :stored
    @test count == 1
    @test only(requests).request.config.evaluation == :fma

    constant = PolynomialSearchConfig(degrees = [0], internal_formats = [IEEE32])
    @test PRESAGe._sweep_requests(spec, constant; target)[3] == 1

    reconstructed = PolynomialSearchConfig(
        degrees = [0],
        internal_formats = [IEEE32],
        transformation = :log,
    )
    logarithm = FunctionSpec("log(x)"; input_format = IEEE32, domain = (1, 2))
    @test PRESAGe._sweep_requests(logarithm, reconstructed; target)[3] == 2
    odd_constant = PolynomialSearchConfig(
        degrees = [1],
        internal_formats = [format],
        transformation = :odd,
    )
    @test PRESAGe._sweep_requests(odd_spec, odd_constant; target)[3] == 1
    explicit_odd = PRESAGe._evaluation_config(odd_constant, :fma)
    _, requests, _, _ = PRESAGe._sweep_requests(odd_spec, explicit_odd; target)
    @test PRESAGe._target_candidate_reason(only(requests).request, target) === nothing
end

@testset "Automatic arithmetic uses distinct cache identities and resource costs" begin
    spec = FunctionSpec(
        "1/3+2/7*x";
        input_format = IEEE32,
        domain = (1, 2),
        absolute_error = 1,
    )
    config = PolynomialSearchConfig(degrees = [1], internal_formats = [IEEE32])
    _, requests, count, _ = PRESAGe._sweep_requests(spec, config)
    @test count == 2
    keys = [
        PRESAGe._numerical_digest(PRESAGe._numerical_request(item.request)) for
        item in requests
    ]
    @test length(unique(keys)) == 2
    for operation in (:separate, :fma)
        explicit = PRESAGe._evaluation_config(config, operation)
        _, single, _, _ = PRESAGe._sweep_requests(spec, explicit)
        @test PRESAGe._numerical_digest(PRESAGe._numerical_request(only(single).request)) in
              keys
    end
    rules = [
        ResourceRule(:input; luts = 0),
        ResourceRule(:constant; luts = 0),
        ResourceRule(:mul; luts = 1),
        ResourceRule(:add; luts = 1),
        ResourceRule(:fma; luts = 10),
        ResourceRule(:compare; luts = 0),
        ResourceRule(:select; luts = 0),
        ResourceRule(:classify; luts = 0),
        ResourceRule(:bitop; luts = 0),
    ]
    model = ResourceModel(; rules, priority = (:luts,))
    mktempdir() do directory
        cache = NumericalCache(directory)
        sweep = sweep_polynomial(spec, config; resource_model = model, cache)
        @test sweep.objective == :resources
        @test length(sweep.rows) == 2
        @test all(row -> row.attempt.status == :certified, sweep.rows)
        @test only(sweep.selections).status == :selected
        selected = sweep.rows[only(sweep.selections).row_index].attempt.plan
        @test selected.settings["evaluation"] == "separate"
        replay =
            sweep_polynomial(spec, config; resource_model = model, objective = :luts, cache)
        @test all(row -> row.cache_status == :hit, replay.rows)
    end
end
