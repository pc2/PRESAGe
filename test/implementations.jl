function implementation_profile(;
    priority = (:luts, :rams, :dsps, :ffs),
    unknown_mul_ffs = false,
)
    rules = Tuple(
        ResourceRule(
            operation;
            luts = operation in (:mul, :fma) ? 20 : operation == :add ? 10 : 0,
            ffs = unknown_mul_ffs && operation == :mul ? nothing : 0,
            dsps = operation in (:mul, :fma) ? 1 : 0,
            rams = 0,
        ) for operation in PRESAGe._RESOURCE_OPERATIONS
    )
    ResourceModel(; name = "selection fixture", memory_policy = :block, priority, rules)
end

function implementation_lut_fixtures()
    specs = [
        FunctionSpec(
            "sin(x)";
            input_format = FixedFormat(6, 3),
            output_format = FixedFormat(12, 3),
            domain = (-1, 1),
            absolute_error = 1 // 128,
        ),
        FunctionSpec(
            "exp(x)+x/10";
            input_format = FixedFormat(6, 2; signed = false),
            output_format = IEEE128,
            domain = (0, 1),
            absolute_error = 1 // big(2)^100,
        ),
        FunctionSpec(
            "sqrt(x)";
            input_format = FloatFormat(3, 2),
            output_format = FixedFormat(16, 3),
            domain = (0, 4),
            absolute_error = 1 // 128,
        ),
        FunctionSpec(
            "sin(x)";
            input_format = FloatFormat(3, 3),
            output_format = FloatFormat(4, 6),
            absolute_error = 1 // 16,
        ),
        FunctionSpec(
            "x+1/32";
            input_format = FixedFormat(4, 1; signed = false),
            output_format = FixedFormat(
                4,
                1;
                signed = false,
                rounding = :down,
                overflow = :saturate,
            ),
            absolute_error = 1 // 8,
        ),
        FunctionSpec(
            "erf(x)";
            input_format = FloatFormat(3, 2),
            output_format = IEEE16,
            domain = (-1, 1),
            absolute_error = 1 // 1024,
        ),
    ]
    return [certified_lut(spec) for spec in specs]
end

@testset "General exhaustive LUT contracts and graph audits" begin
    fixtures = implementation_lut_fixtures()
    for certificate in fixtures
        @test certificate.status == :certified
        @test certificate.total_bound <= certificate.plan.spec.absolute_error
        @test certify_plan(certificate.plan).status == :certified
        plan, spec = certificate.plan, certificate.plan.spec
        entries = 1 << PRESAGe._width(spec.input_format)
        @test length(only(plan.program.tables).values) == entries
        @test only(plan.program.tables).format == spec.output_format
        @test implementation_cost(plan).table_bits ==
              entries * PRESAGe._width(spec.output_format)
        with_oracle(spec; backend = PRESAGe._lut_backend(spec, :auto)) do oracle
            for word = 0:(entries - 1)
                input = PRESAGe._decode_input(word, spec.input_format)
                covered =
                    input.kind in (:finite, :zero) && (
                        spec.domain === nothing ||
                        spec.domain[1] <= input.value <= spec.domain[2]
                    )
                if !covered &&
                   (spec.domain !== nothing || spec.output_format isa FixedFormat)
                    if spec.output_format isa FixedFormat
                        @test_throws DomainError evaluate_bits(plan, word)
                    else
                        @test evaluate_bits(plan, word) == PRESAGe._nan(spec.output_format)
                    end
                    continue
                end
                ref = reference(oracle, word)
                @test evaluate_bits(plan, word) == ref.bits
                if covered && ref.enclosure !== nothing
                    y = PRESAGe._decode_input(ref.bits, spec.output_format).value
                    lo, hi = ref.enclosure
                    error = max(
                        abs(y - lo.significand * PRESAGe._pow2(lo.exponent)),
                        abs(y - hi.significand * PRESAGe._pow2(hi.exponent)),
                    )
                    @test error <= certificate.total_bound
                end
            end
        end
        mktemp() do filename, io
            write_plan(io, plan)
            close(io)
            replay = read_plan(filename)
            @test certify_plan(replay).status == :certified
        end
        report = TOML.parse(sprint(io -> write_certificate(io, certificate)))
        @test report["coverage"]["inputs"] == "all $entries input encodings"
        @test report["coverage"]["table_bits"] ==
              entries * PRESAGe._width(spec.output_format)
    end
    plan = first(fixtures).plan
    words = collect(only(plan.program.tables).values)
    words[1] ⊻= 1
    @test certify_lut(PRESAGe._lut_plan(plan.spec, words)).status == :proof_failed
    # Inactive entries and domain guards are audited too.
    words = collect(only(plan.program.tables).values)
    words[17] ⊻= 1
    @test certify_lut(PRESAGe._lut_plan(plan.spec, words)).status == :proof_failed
    nodes = collect(plan.program.nodes)
    nodes[end] = IR.Guard(7, 3)
    changed = PlanArtifact(
        plan.spec;
        program = IR.Program(nodes; tables = plan.program.tables),
        settings = plan.settings,
    )
    @test certify_plan(changed).status == :unsupported_domain
    wide = FunctionSpec("x"; input_format = FixedFormat(10^6, 1))
    @test !PRESAGe._lut_availability(wide, 65536).available
    @test certified_lut(wide).status == :unsupported_domain
    @test !PRESAGe._lut_availability(
        FunctionSpec("x"; input_format = FixedFormat(8, 2)),
        255,
    ).available
    @test PRESAGe._lut_availability(
        FunctionSpec("x"; input_format = FixedFormat(8, 2)),
        256,
    ).available
    @test_throws ArgumentError certified_lut(plan.spec; max_entries = true)
    @test_throws ArgumentError certified_lut(plan.spec; max_entries = 0)
    @test_throws ArgumentError certified_lut(plan.spec; max_entries = big(2)^100)
    @test certified_lut(
        FunctionSpec("x"; input_format = FixedFormat(8, 2), domain = (1 // 1000, 1 // 100)),
    ).status == :unsupported_domain
    @test certified_lut(FunctionSpec("sqrt(x)"; input_format = FloatFormat(3, 2))).status ==
          :unsupported_domain
    @test certified_lut(FunctionSpec("1/x"; input_format = FixedFormat(4, 2))).status ==
          :proof_failed
    saturated = FunctionSpec(
        "exp(x)";
        input_format = FixedFormat(2, 2),
        output_format = FixedFormat(2, 1; overflow = :saturate),
        domain = (0, 0),
        absolute_error = 1 // 4,
    )
    result = certified_lut(saturated)
    @test result.status == :bound_exceeds_budget
    @test result.total_bound == 1 // 2
    ties = FunctionSpec(
        "x+1/16";
        input_format = FixedFormat(4, 2),
        output_format = FixedFormat(4, 1; overflow = :wrap),
        absolute_error = 4,
    )
    lut = certified_lut(ties)
    @test lut.status == :certified
    for word = 0:15
        x = decode_fixed(word, ties.input_format)
        @test evaluate_bits(lut.plan, word) == round_fixed(x + 1 // 16, ties.output_format)
    end
end

@testset "Shared backend resource selection and explicit overrides" begin
    spec = FunctionSpec(
        "sin(x)";
        input_format = FixedFormat(6, 3),
        output_format = IEEE32,
        domain = (-1, 1),
        absolute_error = 1 // 256,
    )
    lut = certified_lut(spec)
    polynomial =
        certified_polynomial(spec; degree = 3, internal_format = FixedFormat(24, 4))
    @test lut.status == polynomial.status == :certified
    candidates = (lut, polynomial)
    profile = implementation_profile()
    # An explicitly audited LUT does not need generator metadata to rank.
    unlabelled = certify_lut(PlanArtifact(spec; program = lut.plan.program))
    @test unlabelled.status == :certified
    @test select_implementation(
        (unlabelled, polynomial);
        resource_model = profile,
    ).selected === unlabelled
    result = select_implementation(candidates; resource_model = profile)
    @test result.status == :selected && result.selected === lut
    memory = select_implementation(
        candidates;
        resource_model = implementation_profile(priority = (:rams,)),
    )
    @test memory.selected === polynomial
    budget = select_implementation(
        candidates;
        resource_model = profile,
        resource_budget = ResourceBudget(rams = 0),
    )
    @test budget.selected === polynomial
    @test select_implementation(
        candidates;
        resource_model = profile,
        implementation = :polynomial,
    ).selected === polynomial
    @test select_implementation(
        candidates;
        resource_model = profile,
        implementation = :lut,
        resource_budget = ResourceBudget(rams = 0),
    ).status == :resource_budget_exceeded
    @test select_implementation(
        candidates;
        resource_model = profile,
        resource_budget = ResourceBudget(luts = 0, rams = 0),
    ).status == :resource_budget_exceeded
    incomplete = implementation_profile(priority = (:ffs,), unknown_mul_ffs = true)
    @test select_implementation(candidates; resource_model = incomplete).selected === lut
    @test select_implementation((polynomial,); resource_model = incomplete).status ==
          :resource_model_incomplete
    @test select_implementation((lut, lut); resource_model = profile).selected_index == 1
    @test select_implementation(candidates).selected === polynomial
    @test_throws ArgumentError select_implementation(candidates; objective = :resources)
    @test_throws ArgumentError select_implementation(
        candidates;
        resource_budget = ResourceBudget(rams = 1),
    )
    @test_throws ArgumentError select_implementation((); resource_model = profile)
    @test_throws ArgumentError select_implementation(candidates; implementation = :other)
    other = certified_lut(
        FunctionSpec(
            "cos(x)";
            input_format = spec.input_format,
            output_format = spec.output_format,
            domain = spec.domain,
            absolute_error = spec.absolute_error,
        ),
    )
    @test_throws ArgumentError select_implementation((lut, other); resource_model = profile)
    failed = CertificationResult(
        polynomial.plan,
        :proof_failed,
        nothing,
        (),
        nothing,
        Dict{String, String}(),
        "failed proof",
    )
    @test select_implementation((failed, lut); resource_model = profile).selected === lut
    report = TOML.parse(sprint(io -> write_implementation_report(io, budget)))
    @test report["schema"] == "presage-implementation-selection"
    @test report["selected_index"] == 2
    @test !report["candidates"][1]["selection_eligible"]
    @test occursin("rams", only(report["candidates"][1]["selection_reasons"]))
    # Small custom floating contracts use the same selector, including mixed outputs.
    spec = FunctionSpec(
        "x";
        input_format = FloatFormat(3, 2),
        output_format = FixedFormat(16, 6),
        domain = (-1, 1),
    )
    lut = certified_lut(spec)
    polynomial = certify_polynomial(
        polynomial_plan(spec, [0, 1]; internal_format = FixedFormat(16, 6)),
    )
    @test lut.status == polynomial.status == :certified
    @test select_implementation((lut, polynomial); resource_model = profile).status ==
          :selected
end

@testset "General backend sweeps, reports and generation" begin
    profile = implementation_profile()
    specs = [
        FunctionSpec(
            expression;
            input_format = FixedFormat(6, 3),
            output_format = IEEE32,
            domain = (-1, 1),
            absolute_error = 1 // 256,
        ) for expression in ("sin(x)", "cos(x)")
    ]
    config = PolynomialSearchConfig(
        evaluation = :separate,
        degrees = (3, 5),
        internal_formats = (FixedFormat(24, 4),),
        max_attempts = 12,
        total_timeout = 120,
    )
    result =
        sweep_implementations(specs, config; resource_model = profile, max_parallel = 2)
    @test result.status == :complete
    @test length(result.rows) == 6
    @test [r.implementation for r in result.rows] == [:lut, :polynomial, :polynomial, :lut, :polynomial, :polynomial]
    @test all(s -> s.status == :selected, result.selections)
    @test all(s -> result.rows[s.row_index].implementation == :lut, result.selections)
    memory = select_sweep(result; resource_budget = ResourceBudget(rams = 0))
    @test memory.rows === result.rows
    @test all(
        s -> memory.rows[s.row_index].implementation == :polynomial,
        memory.selections,
    )
    @test memory.implementations == (:lut, :polynomial)
    report = TOML.parse(sprint(io -> write_sweep_report(io, memory)))
    @test report["schema_version"] == 5
    @test report["implementations"] == ["lut", "polynomial"]
    @test all(a -> a["available"], report["lut_availability"])
    @test all(row -> haskey(row, "implementation"), report["rows"])
    @test all(
        row -> !haskey(row, "precision_cost"),
        filter(row -> row["implementation"] == "lut", report["rows"]),
    )
    mktempdir() do directory
        write_sweep_artifacts(directory, result)
        for selection in result.selections
            selected = joinpath(directory, "selected", string(selection.spec_index))
            plan = read_plan(joinpath(selected, "plan.toml"))
            @test plan.settings["kernel"] == "full_lut"
            @test certify_plan(plan).status == :certified
            @test isfile(joinpath(selected, "resource-model.toml"))
        end
        write_sweep_artifacts(directory, memory)
        @test read_plan(joinpath(directory, "selected", "1", "plan.toml")).settings["kernel"] !=
              "full_lut"
        contract, search_config, model = joinpath(directory, "contract.toml"),
        joinpath(directory, "search.toml"),
        joinpath(directory, "profile.toml")
        write_plan(contract, PlanArtifact(first(specs)))
        short = PolynomialSearchConfig(
            evaluation = :separate,
            degrees = (3,),
            internal_formats = (FixedFormat(24, 4),),
            max_attempts = 4,
            total_timeout = 120,
        )
        write_search_config(search_config, short)
        write_resource_model(model, profile)
        output = joinpath(directory, "generated")
        generated = generate_main([
            contract,
            output,
            "--search-config=$search_config",
            "--resource-model=$model",
            "--implementation=auto",
            "--target=kernel",
            "--backend=ap_fixed",
            "--max-parallel=2",
        ])
        @test generated.settings["kernel"] == "full_lut"
        @test isfile(joinpath(output, "implementations.toml"))
        @test TOML.parsefile(joinpath(output, "implementations.toml"))["schema_version"] ==
              5
        generate_main([
            contract,
            output,
            "--search-config=$search_config",
            "--resource-model=$model",
            "--max-rams=0",
            "--target=kernel",
            "--backend=ac_fixed",
        ])
        @test read_plan(joinpath(output, "plan.toml")).settings["kernel"] != "full_lut"
        previous = read(joinpath(output, "evaluator.hpp"))
        @test_throws ErrorException generate_main([
            contract,
            output,
            "--search-config=$search_config",
            "--resource-model=$model",
            "--max-rams=0",
            "--max-luts=0",
        ])
        @test read(joinpath(output, "evaluator.hpp")) == previous
        @test isfile(joinpath(output, "implementation-failure.toml"))
        # A direct contract LUT needs no polynomial configuration.
        generate_main([
            contract,
            output,
            "--implementation=lut",
            "--target=kernel",
            "--backend=ac_fixed",
        ])
        @test !isfile(joinpath(output, "implementation-failure.toml"))
        @test !isfile(joinpath(output, "implementations.toml"))
        @test !isfile(joinpath(output, "resource-model.toml"))
        @test read_plan(joinpath(output, "plan.toml")).settings["kernel"] == "full_lut"
        # Resource selection also applies to the canonical all-finite erf graph.
        half_output = joinpath(directory, "half")
        generate_main([
            "erf",
            half_output,
            "--input-format=half",
            "--resource-model=$model",
        ])
        @test read_plan(joinpath(half_output, "plan.toml")).settings["kernel"] == "full_lut"
        half_report = TOML.parsefile(joinpath(half_output, "implementations.toml"))
        @test half_report["schema"] == "presage-implementation-selection"
        @test length(half_report["candidates"]) == 2
        @test all(c -> c["status"] == "certified", half_report["candidates"])
        @test_throws ErrorException generate_main([
            contract,
            output,
            "--search-config=$search_config",
            "--lut-max-entries=64",
        ])
        @test sweep_main([
            contract,
            search_config,
            joinpath(directory, "sweep"),
            "--implementation=auto",
            "--resource-model=$model",
            "--max-parallel=2",
        ]) == 0
    end
    wide = FunctionSpec(
        "x";
        input_format = FixedFormat(17, 3),
        output_format = FixedFormat(32, 4),
        domain = (0, 1),
    )
    linear = PolynomialSearchConfig(
        evaluation = :separate,
        degrees = (1,),
        internal_formats = (FixedFormat(32, 4),),
        max_attempts = 1,
    )
    wide_result = sweep_implementations(wide, linear; resource_model = profile)
    @test wide_result.status == :complete
    @test only(wide_result.rows).implementation == :polynomial
    @test only(wide_result.selections).status == :selected
    availability = only(
        TOML.parse(sprint(io -> write_sweep_report(io, wide_result)))["lut_availability"],
    )
    @test !availability["available"]
    @test occursin("65536", availability["reason"])
    # An unsupported polynomial policy must not prevent a usable LUT.
    unbounded =
        FunctionSpec("sin(x)"; input_format = FloatFormat(3, 2), absolute_error = 1 // 4)
    result = sweep_implementations(unbounded, linear; resource_model = profile)
    @test only(result.rows).implementation == :lut # max_attempts=1 still applies
    @test only(result.selections).status == :selected
    both = PolynomialSearchConfig(
        evaluation = :separate,
        degrees = (1,),
        internal_formats = (FixedFormat(32, 4),),
        max_attempts = 2,
    )
    result = sweep_implementations(unbounded, both; resource_model = profile)
    @test result.status == :complete
    @test result.rows[2].attempt.status == :unsupported_domain
    @test occursin("explicit domain", result.rows[2].attempt.reason)
    @test only(result.selections).status == :selected
    @test_throws ArgumentError sweep_implementations(
        specs,
        config;
        implementations = (:lut, :lut),
    )
    @test_throws ArgumentError sweep_implementations(specs, config; lut_max_entries = 0)
end

@testset "General LUTs through official AP/AC kernels" begin
    certificates = implementation_lut_fixtures()
    fixtures = [
        (
            program = c.plan.program,
            words = collect(0:((1 << PRESAGe._width(c.plan.spec.input_format)) - 1)),
            resource_model = implementation_profile(),
        ) for c in certificates
    ]
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check(fixtures, backend)
    end
end
