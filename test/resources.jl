isdefined(Main, :resource_examples_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "resource_examples.jl"))
isdefined(Main, :check_resources_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "check_resources.jl"))

resource_profile(name) =
    read_resource_model(joinpath(@__DIR__, "..", "config", "resources", "$name.toml"))
function resource_operation_program(format, operation; rounding = :nearest_even)
    nodes =
        IR.Node[IR.Input(format), IR.constant(1 // 3, format), IR.constant(2 // 7, format)]
    node =
        operation == :fma ? IR.FMA(1, 2, 3, format; rounding) :
        operation == :mul ? IR.Mul(1, 2, format; rounding) : IR.Add(1, 2, format; rounding)
    push!(nodes, node)
    IR.Program(nodes)
end

function resource_table_program(entries, width; banks = 1)
    input = FixedFormat(12, 12; signed = false)
    nodes = IR.Node[IR.Input(input), IR.BitCast(1, IR.UIntFormat(12)), IR.TableLoad(1, 2)]
    IR.Program(
        nodes;
        tables = [
            IR.Table(FixedFormat(width, width; signed = false), fill(0, entries); banks),
        ],
    )
end

@testset "Exact resource rules and missing floating point calibration" begin
    for profile in ("oneapi", "vitis"),
        program in (
            resource_operation_program(IEEE32, :mul),
            resource_operation_program(IEEE32, :fma),
            resource_operation_program(IEEE64, :fma),
            resource_operation_program(IEEE16, :fma),
            resource_operation_program(IEEE32, :fma; rounding = :down),
        )

        estimate =
            estimate_resources(program; model = resource_profile(profile), target = nothing)
        @test estimate.status == :partial
        @test all(name -> estimate.totals[name] === nothing, (:luts, :ffs, :dsps, :rams))
        @test length(filter(node -> !isempty(node.missing), estimate.nodes)) == 1
        @test estimate.known == (luts = 0, ffs = 0, dsps = 0, rams = 0, mlabs = 0)
    end

    input, operand, output = FixedFormat(32, 4), FixedFormat(17, 4), FixedFormat(65, 8)
    program =
        IR.Program([IR.Input(input), IR.constant(1 // 3, operand), IR.Mul(1, 2, output)])
    baseline = resource_profile("generic")
    rule = ResourceRule(
        :mul;
        format = :fixed,
        luts = ResourceFormula(result_bits = 1 // 2, operand_product = 1 // 16),
        ffs = ResourceFormula(result_bits = 1),
        dsps = ResourceFormula(dsp_tiles = 1),
        rams = 0,
    )
    model = ResourceModel(rules = (rule, baseline.rules...))
    estimate = estimate_resources(program; model)
    @test estimate.totals == (luts = 67, ffs = 65, dsps = 2, rams = 0, mlabs = 0)
    @test last(estimate.nodes).signature.operand_bits == 49
    @test last(estimate.nodes).signature.dsp_tiles == 2
    @test last(estimate.nodes).rule_index == 1
    swapped = ResourceModel(rules = model.rules, dsp_operand_bits = (17, 24))
    @test estimate_resources(program; model = swapped).totals == estimate.totals
    tiny = ResourceModel(rules = model.rules, dsp_operand_bits = (8, 8))
    @test estimate_resources(program; model = tiny).totals.dsps == 12
    restricted = ResourceModel(
        rules = [
            ResourceRule(
                :mul;
                format = :fixed,
                max_width = 64,
                luts = 0,
                ffs = 0,
                dsps = 0,
                rams = 0,
            ),
        ],
    )
    @test estimate_resources(program; model = restricted).totals.luts === nothing
    @test estimate_resources(
        resource_operation_program(FixedFormat(257, 4), :mul);
        model = baseline,
    ).status == :partial

    for model in (
        baseline,
        resource_profile("vitis"),
        resource_profile("oneapi"),
        ResourceModel(
            rules = [
                ResourceRule(
                    :add;
                    luts = ResourceFormula(constant = big(2)^100, operand_bits = 1 // 3),
                ),
            ],
            distributed_max_bits = big(2)^100,
        ),
    )
        text = sprint(io -> write_resource_model(io, model))
        @test PRESAGe._resource_model_data(read_resource_model(IOBuffer(text))) ==
              PRESAGe._resource_model_data(model)
    end
    data = PRESAGe._resource_model_data(baseline)
    for change in (
        d -> d["typo"] = 1,
        d -> d["memory"]["typo"] = 1,
        d -> d["rules"][1]["luts"] = 1.0,
        d -> d["rules"][1]["luts"] = Dict("bad" => 1),
        d -> d["priority"] = ["luts", "luts"],
        d -> d["schema_version"] = 2,
        d -> d["schema_version"] = true,
        d -> d["dsp"]["operand_bits"] = [0, 1],
    )
        invalid = deepcopy(data)
        change(invalid)
        @test_throws ArgumentError PRESAGe._read_resource_model(invalid)
    end
    for invalid in (-1, true, 1.5, "2")
        @test_throws ArgumentError ResourceBudget(dsps = invalid)
        @test_throws ArgumentError ResourceFormula(result_bits = invalid)
    end
    @test_throws ArgumentError ResourceRule(:unknown)
    @test_throws ArgumentError ResourceRule(:add; format = :float, exponent_bits = 8)
    @test_throws ArgumentError ResourceModel(priority = ())
    @test_throws ArgumentError ResourceModel(memory_policy = :unknown)
    @test_throws ArgumentError estimate_resources(
        PlanArtifact(FunctionSpec("x"));
        model = baseline,
    )
end

@testset "ROM policy, independent banking and matching kernel hints" begin
    baseline = resource_profile("generic")
    block = ResourceModel(rules = baseline.rules)
    auto = ResourceModel(memory_policy = :auto, rules = baseline.rules)
    for (entries, width, banks, rams, luts) in
        ((128, 32, 1, 0, 64), (129, 32, 1, 1, 0), (65, 17, 2, 0, 34), (512, 33, 1, 2, 0))
        program = resource_table_program(entries, width; banks)
        estimate = estimate_resources(program; model = auto)
        @test estimate.status == :complete
        @test estimate.totals == (luts = luts, ffs = 0, dsps = 0, rams = rams, mlabs = 0)
        @test only(estimate.tables).blocks == table_memory_cost(program).blocks
        @test only(estimate.tables).storage == (rams == 0 ? :distributed : :block)
    end
    program = resource_table_program(513, 33; banks = 2)
    @test estimate_resources(
        program;
        model = block,
        memory_model = BlockMemoryModel(depth = 128),
    ).totals.rams == 12
    oneapi = ResourceModel(
        toolchain = :oneapi,
        memory_policy = :distributed,
        distributed_depth = 32,
        distributed_word_bits = 16,
        distributed_luts = 20,
        rules = baseline.rules,
    )
    @test estimate_resources(resource_table_program(512, 32); model = oneapi).known.mlabs ==
          32
    @test estimate_resources(resource_table_program(512, 32); model = oneapi).status ==
          :unsupported
    dead = IR.Program(
        [IR.Input(FixedFormat(8, 2))];
        tables = [IR.Table(IR.UIntFormat(32), [0])],
    )
    @test isempty(estimate_resources(dead; model = block).tables)
    @test estimate_resources(dead; model = block).totals.rams == 0

    for (backend, toolchain, block_hint, distributed_hint) in (
        (:ap_fixed, :vitis, "impl=bram", "impl=lutram"),
        (:ac_fixed, :oneapi, "fpga_memory(\"BLOCK_RAM\")", "fpga_memory(\"MLAB\")"),
    )
        for (policy, hint) in ((:block, block_hint), (:distributed, distributed_hint))
            model = ResourceModel(
                toolchain = toolchain,
                memory_policy = policy,
                rules = baseline.rules,
            )
            if toolchain == :oneapi && policy == :distributed
                @test_throws ArgumentError emit_kernel(
                    IOBuffer(),
                    resource_table_program(128, 32);
                    backend,
                    toolchain,
                    resource_model = model,
                )
                continue
            end
            text = sprint(
                io -> emit_kernel(
                    io,
                    resource_table_program(128, 32);
                    backend,
                    toolchain,
                    resource_model = model,
                ),
            )
            @test occursin(hint, text)
            @test !occursin("struct Trace", text)
        end
    end
    io = IOBuffer()
    @test_throws ArgumentError emit_kernel(
        io,
        program;
        backend = :ap_fixed,
        toolchain = :vitis,
        resource_model = oneapi,
    )
    @test position(io) == 0
    report = TOML.parse(
        sprint(io -> write_resource_report(io, estimate_resources(program; model = block))),
    )
    @test report["schema"] == "presage-resource-estimate"
    @test report["totals"]["rams"] == 4
    @test report["tables"][1]["storage"] == "block"
end

@testset "Resource budgets, selection and exact exported model replay" begin
    cubic, linear =
        selection_linear_certificate(128, 3), selection_linear_certificate(512, 1)
    result = selection_fixture([cubic, linear])
    model = resource_profile("generic")
    resources = select_sweep(result; resource_model = model, objective = :rams)
    @test resources.rows === result.rows
    @test only(resources.selections).row_index == 1
    @test only(select_sweep(resources; objective = :dsps).selections).row_index == 2
    @test only(select_sweep(resources; objective = :memory).selections).row_index == 2
    @test only(
        select_sweep(
            resources;
            resource_budget = ResourceBudget(rams = 0, mlabs = 0),
        ).selections,
    ).row_index == 1
    denied = select_sweep(resources; resource_budget = ResourceBudget(rams = 0, dsps = 4))
    @test only(denied.selections).status == :resource_budget_exceeded
    @test all(row -> row.attempt.status == :certified, denied.rows)
    @test isempty(denied.pareto_indices)
    partial =
        ResourceModel(rules = [rule for rule in model.rules if rule.operation != :mul])
    unknown = select_sweep(result; resource_model = partial, objective = :resources)
    @test only(unknown.selections).status == :resource_model_incomplete
    @test occursin("unknown", only(unknown.selections).reason)
    @test only(select_sweep(unknown; objective = :memory).selections).status == :selected
    @test_throws ArgumentError select_sweep(result; objective = :dsps)
    @test_throws ArgumentError select_sweep(
        result;
        resource_budget = ResourceBudget(luts = 0),
    )
    @test_throws ArgumentError PRESAGe._sweep_polynomial(
        result.specs,
        result.config;
        objective = :resources,
        process_started = (p, d) -> error("invalid selection launched worker"),
    )

    profile_data = PRESAGe._resource_model_data(model)
    profile_data["priority"] = ["rams", "dsps"]
    priority = PRESAGe._read_resource_model(profile_data)
    @test only(
        select_sweep(result; resource_model = priority, objective = :resources).selections,
    ).row_index == 1
    for objective in (:luts, :ffs, :dsps, :rams)
        choice = select_sweep(result; resource_model = model, objective)
        selected = only(choice.selections).row_index
        estimates = [
            estimate_resources(row.attempt.plan; model).totals[objective] for
            row in result.rows
        ]
        @test estimates[selected] == minimum(estimates)
    end
    mktempdir() do directory
        selected = select_sweep(resources; memory_model = BlockMemoryModel(depth = 256))
        write_sweep_artifacts(directory, selected)
        report = TOML.parsefile(joinpath(directory, "sweep.toml"))
        @test report["schema_version"] == 4
        @test "dsps" in report["pareto_metrics"]
        @test report["rows"][1]["resources"]["status"] == "complete"
        root = joinpath(directory, "selected", "1")
        replay_model = read_resource_model(joinpath(root, "resource-model.toml"))
        @test replay_model.memory.depth == 256
        plan = read_plan(joinpath(root, "plan.toml"))
        actual = TOML.parsefile(joinpath(root, "resources.toml"))
        @test actual == TOML.parse(
            sprint(
                io -> write_resource_report(
                    io,
                    estimate_resources(plan; model = replay_model),
                ),
            ),
        )
        @test certify_plan(plan).status == :certified
        unknown_data = TOML.parse(sprint(io -> write_sweep_report(io, unknown)))
        @test unknown_data["rows"][1]["resources"]["totals"]["dsps"] == "unknown"
        @test !unknown_data["rows"][1]["selection_eligible"]
        @test !isempty(unknown_data["rows"][1]["selection_reasons"])
    end
end

@testset "Synthesis-count comparisons and small CI examples" begin
    totals = (;
        totals = (
            luts = big(12),
            ffs = big(12),
            dsps = big(2),
            rams = big(3),
            mlabs = big(0),
        )
    )
    measured = ResourceBudget(luts = 9, ffs = 9, dsps = 2, rams = 3, mlabs = 0)
    exact = ResourceBudget(luts = 0, ffs = 0, dsps = 0, rams = 0, mlabs = 0)
    relative = (luts = 1 // 3, ffs = 1 // 3, dsps = 0, rams = 0, mlabs = 0)
    @test compare_resources(totals, measured; absolute = exact, relative)["status"] ==
          "passed"
    @test compare_resources(
        totals,
        measured;
        absolute = exact,
        relative = (luts = 1 // 4, ffs = 1 // 3, dsps = 0, rams = 0, mlabs = 0),
    )["status"] == "failed"
    @test compare_resources(totals, ResourceBudget())["status"] == "unresolved"
    @test compare_resources(
        (; totals = (luts = nothing, ffs = 9, dsps = 2, rams = 3, mlabs = 0)),
        measured,
    )["status"] == "unresolved"
    @test_throws ArgumentError compare_resources(totals, measured; relative = (luts = 1,))
    @test_throws ArgumentError compare_resources(
        totals,
        measured;
        relative = (luts = -1, ffs = 0, dsps = 0, rams = 0, mlabs = 0),
    )
    @test_throws ArgumentError compare_resources(
        totals,
        measured;
        absolute = ResourceBudget(),
    )
    huge = Dict(
        "totals" => Dict(
            "luts" => string(big(2)^100),
            "ffs" => 0,
            "dsps" => 0,
            "rams" => 0,
            "mlabs" => 0,
        ),
    )
    @test compare_resources(
        huge,
        ResourceBudget(luts = big(2)^100, ffs = 0, dsps = 0, rams = 0, mlabs = 0),
    )["status"] == "passed"

    fixtures = resource_example_plans()
    @test length(fixtures) == 6
    for (_, plan) in fixtures
        isempty(plan.program.tables) && continue
        @test all(table -> length(unique(table.values)) > 1, plan.program.tables)
        @test all(table -> any(!=(0), table.values), plan.program.tables)
    end
    for backend in (:ap_fixed, :ac_fixed)
        model = resource_profile(backend == :ap_fixed ? "vitis" : "oneapi")
        for (_, plan) in fixtures
            @test certify_plan(plan).status == :certified
            @test estimate_resources(plan; model).status == :complete
        end
        kernel_trace_check(
            [
                (;
                    program = plan.program,
                    words = 0:((1 << plan.spec.input_format.width) - 1),
                    resource_model = model,
                ) for (_, plan) in fixtures
            ],
            backend,
        )
    end
    floating = last(resource_example_plans(include_float = true), 2)
    @test length(floating) == 2
    model = resource_profile("oneapi")
    for (_, plan) in floating
        @test certify_plan(plan).status == :certified
        estimate = estimate_resources(plan; model)
        @test estimate.status == :partial
        @test estimate.support.supported
        @test estimate.totals.dsps === nothing
    end
    kernel_trace_check(
        [
            (;
                program = plan.program,
                words = unique(
                    [
                        round_ieee(x, plan.spec.input_format) for
                        x in (-2, -1, -1 // 2, 0, 1 // 2, 1, 2)
                    ] ∪ [
                        PRESAGe._sign(plan.spec.input_format),
                        PRESAGe._nan(plan.spec.input_format),
                        PRESAGe._inf(plan.spec.input_format),
                    ],
                ),
                resource_model = model,
            ) for (_, plan) in floating
        ],
        :ac_fixed,
    )
    mktempdir() do directory
        profile = joinpath(@__DIR__, "..", "config", "resources", "vitis.toml")
        @test resource_examples_main([profile, directory]) == 0
        manifest_path = joinpath(directory, "examples.toml")
        manifest = TOML.parsefile(manifest_path)
        rows = map(manifest["examples"]) do entry
            prediction = TOML.parsefile(joinpath(directory, entry["resources"]))
            @test isfile(joinpath(directory, entry["header"]))
            @test isfile(joinpath(directory, entry["kernel"]))
            merge(Dict("name" => entry["name"]), prediction["totals"])
        end
        # Synthetic counts test the CI protocol; these are not synthesis measurements.
        measured = Dict(
            "schema" => "presage-resource-measurements",
            "schema_version" => 1,
            "examples" => rows,
        )
        path, output =
            joinpath(directory, "measured.toml"), joinpath(directory, "checked.toml")
        save() = open(io -> TOML.print(io, measured; sorted = true), path, "w")
        save()
        @test check_resources_main([manifest_path, path, output]) == 0
        measured["examples"][1]["dsps"] += 1
        save()
        @test check_resources_main([manifest_path, path, output]) == 1
        @test TOML.parsefile(output)["status"] == "failed"
        measured["examples"][1]["dsps"] -= 1
        pop!(measured["examples"])
        save()
        @test check_resources_main([manifest_path, path, output]) == 2
        measured["examples"] = [rows[1], rows[1]]
        save()
        @test_throws ErrorException check_resources_main([manifest_path, path, output])
        @test resource_examples_main([
            joinpath(@__DIR__, "..", "config", "resources", "oneapi.toml"),
            joinpath(directory, "floating"),
            "--include-float=true",
        ]) == 0
        @test length(
            TOML.parsefile(joinpath(directory, "floating", "examples.toml"))["examples"],
        ) == 8
    end
end

@testset "Resource profile CLI, cache replay and generation artifacts" begin
    mktempdir() do directory
        spec = FunctionSpec(
            "x";
            input_format = FixedFormat(9, 3),
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
        )
        config = PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1],
            segments = [4],
            internal_formats = [FixedFormat(24, 4)],
        )
        cache = NumericalCache(joinpath(directory, "cache"))
        cold = sweep_polynomial(
            spec,
            config;
            cache,
            resource_model = resource_profile("vitis"),
            objective = :resources,
        )
        @test cold.status == :complete
        warm = PRESAGe._sweep_polynomial(
            spec,
            config;
            cache,
            resource_model = resource_profile("oneapi"),
            objective = :dsps,
            resource_budget = ResourceBudget(rams = 3, mlabs = 0),
            process_started = (p, d) ->
                error("resource-only change launched numerical worker"),
        )
        @test only(warm.rows).cache_status == :hit
        @test only(warm.rows).cache_key == only(cold.rows).cache_key
        @test PRESAGe._certificate_data(only(warm.rows).attempt.certificate) ==
              PRESAGe._certificate_data(only(cold.rows).attempt.certificate)
        contract, settings, output = joinpath(directory, "contract.toml"),
        joinpath(directory, "search.toml"),
        joinpath(directory, "sweep")
        write_plan(contract, PlanArtifact(spec))
        write_search_config(settings, config)
        profile = joinpath(@__DIR__, "..", "config", "resources", "oneapi.toml")
        args = [
            contract,
            settings,
            output,
            "--cache=$(cache.directory)",
            "--resource-model=$profile",
            "--max-luts=100000",
            "--max-ffs=100000",
            "--max-dsps=7/2",
            "--max-rams=3",
            "--max-mlabs=0",
            "--objective=resources",
            "--memory-depth=128",
            "--memory-word-bits=36",
        ]
        @test sweep_main(args) == 0
        report = TOML.parsefile(joinpath(output, "sweep.toml"))
        @test report["schema_version"] == 4
        @test report["selection_policy"]["resource_budget"]["rams"] == 3
        @test report["rows"][1]["cache_status"] == "hit"
        selected = joinpath(output, "selected", "1")
        model_path = joinpath(selected, "resource-model.toml")
        @test read_resource_model(model_path).memory ==
              BlockMemoryModel(depth = 128, word_bits = 36)
        generated = joinpath(directory, "generated")
        @test generate_main([
            joinpath(selected, "plan.toml"),
            generated,
            "--target=kernel",
            "--toolchain=oneapi",
            "--resource-model=$model_path",
        ]) isa PlanArtifact
        @test TOML.parsefile(joinpath(generated, "resources.toml")) ==
              TOML.parsefile(joinpath(selected, "resources.toml"))
        @test occursin(
            "fpga_memory(\"BLOCK_RAM\")",
            read(joinpath(generated, "evaluator.hpp"), String),
        )
        @test generate_main([
            joinpath(selected, "plan.toml"),
            generated,
            "--target=kernel",
        ]) isa PlanArtifact
        @test !isfile(joinpath(generated, "resources.toml")) &&
              !isfile(joinpath(generated, "resource-model.toml"))
        blocked = replace.(args, "--max-dsps=7/2" => "--max-dsps=0")
        @test sweep_main(blocked) == 1
        @test isempty(readdir(joinpath(output, "selected")))
        denied = TOML.parsefile(joinpath(output, "sweep.toml"))
        @test denied["selections"][1]["status"] == "resource_budget_exceeded"
        @test denied["rows"][1]["status"] == "certified"
        @test_throws ArgumentError sweep_main([
            contract,
            settings,
            output,
            "--objective=resources",
        ])
        @test_throws ArgumentError sweep_main([
            contract,
            settings,
            output,
            "--resource-model=$profile",
            "--max-ffs=-1",
        ])
    end
end
