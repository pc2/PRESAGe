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
        sweep =
            sweep_polynomial(spec, config; resource_model = model, objective = :luts, cache)
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
