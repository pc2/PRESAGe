# Exhaust exact input words, checking the full mathematical error and every
# visited numeric node against its path certificate.
function check_precision_polynomial(result, words; exact)
    @test result.status == :certified
    layout = PRESAGe._precision_audit(result.plan)
    accepted = BigInt[]
    for word in words
        plan = result.plan
        x = PRESAGe._decode_input(word, plan.spec.input_format).value
        row =
            x === nothing ? nothing :
            findfirst(p -> p.domain[1] <= x <= p.domain[2], result.paths)
        if row === nothing
            if plan.spec.output_format isa FixedFormat
                @test_throws DomainError evaluate_bits(plan, word)
            else
                trace = interpret_trace(plan, word)
                @test trace.bits == PRESAGe._nan(plan.spec.output_format)
                @test !any(
                    i ->
                        plan.program.nodes[i] isa
                        Union{IR.Mul, IR.Add, IR.FMA, IR.Quantize},
                    keys(trace.values),
                )
            end
            continue
        end
        push!(accepted, word)
        trace = interpret_trace(plan, word)
        actual = PRESAGe._decode_input(trace.bits, plan.spec.output_format).value
        path = result.paths[row]
        @test abs(actual - exact(x)) <= path.total <= result.total_bound
        bounds = PRESAGe._precision_ranges(path)
        @test all(trace.values) do (i, value)
            f = IR.format(plan.program, i)
            f isa Union{FloatFormat, FixedFormat} || return true
            q = PRESAGe._polynomial_value(value.bits, f)
            haskey(bounds, i) && bounds[i][1] <= q <= bounds[i][2]
        end
        isempty(plan.segments) || @test trace.values[layout.paths[row].index] == row - 1
    end
    return accepted
end

@testset "Individual precision formats and exact artifacts" begin
    f = FixedFormat(24, 6)
    coefficients = [FixedFormat(12, 2), FixedFormat(10, 2)]
    stages = [FixedFormat(20, 4), FixedFormat(16, 3)]
    p = PolynomialPrecision(f; coefficient_formats = coefficients, stage_formats = stages)
    coefficients[1] = f
    @test p.coefficient_formats[1] == FixedFormat(12, 2)
    @test hash(p) == hash(
        PolynomialPrecision(
            f;
            coefficient_formats = p.coefficient_formats,
            stage_formats = stages,
        ),
    )
    for (cs, hs) in (
        ([], []),
        ([f], [f, f]),
        ([IEEE32], [f]),
        (fill(f, 34), fill(f, 34)),
        ([FixedFormat(8, 2; overflow = :wrap)], [f]),
    )
        @test_throws ArgumentError PolynomialPrecision(
            f;
            coefficient_formats = cs,
            stage_formats = hs,
        )
    end
    spec = FunctionSpec(
        "x/2+1/4";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(16, 4),
        domain = (-1, 1),
    )
    for plan in (
        polynomial_plan(spec, [1 // 4, 1 // 2]; precision = p),
        segmented_polynomial_plan(
            spec,
            [[-1 // 8, 1 // 8], [1 // 8, 1 // 8], [3 // 8, 1 // 8], [5 // 8, 1 // 8]];
            precision = p,
        ),
    )
        @test certify_plan(plan).status == :certified
        without_label = PlanArtifact(
            spec;
            program = plan.program,
            segments = plan.segments,
            precision = p,
            settings = Dict("evaluation" => "separate"),
        )
        @test PRESAGe._has_supported_certificate(without_label)
        @test certify_plan(without_label).status == :certified
        io = IOBuffer()
        write_plan(io, plan)
        text = String(take!(io))
        # Direct segmented indexing includes the fixed payload bitcast added
        # in schema 12; the untabled precision graph remains schema 5.
        @test TOML.parse(text)["schema_version"] == (isempty(plan.segments) ? 5 : 12)
        restored = read_plan(IOBuffer(text))
        @test restored.precision == p
        @test PRESAGe._plan_data(restored) == PRESAGe._plan_data(plan)
        data = PRESAGe._plan_data(plan)
        data["schema_version"] = 4
        @test_throws ArgumentError PRESAGe._read_plan(data)
    end
    wide = PolynomialPrecision(
        FloatFormat(15, 130);
        coefficient_formats = [IEEE128],
        stage_formats = [FloatFormat(15, 120)],
    )
    plan = polynomial_plan(
        FunctionSpec(
            "1/3";
            input_format = IEEE128,
            domain = (-1, 1),
            absolute_error = 1 // big(2)^100,
        ),
        [1 // 3];
        precision = wide,
    )
    @test certify_plan(plan; precision = 512).status == :certified
    @test PRESAGe._read_plan(PRESAGe._plan_data(plan)).precision == wide
    # Arithmetic-only rebuilding preserves stored negative-zero payloads.
    fixed_precision = p
    f = FloatFormat(5, 10)
    p = PolynomialPrecision(
        f;
        coefficient_formats = [FloatFormat(5, 5), FloatFormat(5, 6)],
        stage_formats = [FloatFormat(5, 7), FloatFormat(5, 8)],
    )
    spec_float = FunctionSpec(
        "x";
        input_format = FloatFormat(3, 4),
        output_format = f,
        domain = (-1, 1),
    )
    plan = polynomial_plan(spec_float, [0, 1]; precision = p)
    node = first(PRESAGe._precision_audit(plan).coefficient_nodes)
    nodes = collect(plan.program.nodes)
    nodes[node] =
        IR.Const(p.coefficient_formats[1], PRESAGe._sign(p.coefficient_formats[1]))
    signed = PlanArtifact(
        spec_float;
        program = IR.Program(nodes; output = plan.program.output),
        precision = p,
        settings = plan.settings,
    )
    altered = PolynomialPrecision(
        f;
        coefficient_formats = p.coefficient_formats,
        stage_formats = [FloatFormat(5, 8), FloatFormat(5, 8)],
    )
    rebuilt = PRESAGe._reformat_polynomial(signed, altered)
    @test certify_plan(rebuilt).status == :certified
    @test rebuilt.program.nodes[first(
        PRESAGe._precision_audit(rebuilt).coefficient_nodes,
    )].bits == nodes[node].bits
    p = fixed_precision
    @test_throws ArgumentError polynomial_plan(
        spec,
        [1 // 4, 1 // 2];
        precision = p,
        internal_format = FixedFormat(32, 6),
    )
    @test_throws ArgumentError polynomial_plan(spec, [0, 0, 1]; precision = p)
    for bad in (
        Dict("extra" => 1),
        Dict("stage_formats" => []),
        Dict("coordinate_format" => "binary32"),
    )
        @test_throws ArgumentError PRESAGe._read_precision(
            merge(PRESAGe._precision_data(p), bad),
        )
    end
end

@testset "Precision conversion error and exhaustive CPU conformance" begin
    exact(x) = 9x^3 / 64 + 5x / 16 + 3 // 16
    layouts = (
        PolynomialPrecision(
            FixedFormat(12, 4);
            coefficient_formats = [
                FixedFormat(8, 2),
                FixedFormat(8, 2),
                FixedFormat(8, 2),
                FixedFormat(8, 2),
            ],
            stage_formats = [
                FixedFormat(8, 3),
                FixedFormat(7, 3),
                FixedFormat(6, 3),
                FixedFormat(4, 2),
            ],
        ),
        PolynomialPrecision(
            FloatFormat(5, 8);
            coefficient_formats = [
                FloatFormat(4, 6),
                FloatFormat(4, 5),
                FloatFormat(4, 4),
                FloatFormat(4, 3),
            ],
            stage_formats = [
                FloatFormat(4, 5),
                FloatFormat(4, 3),
                FloatFormat(4, 2),
                FloatFormat(4, 1),
            ],
        ),
    )
    for p in layouts, evaluation in (:separate, :fma)
        input_format =
            p.coordinate_format isa FixedFormat ? FixedFormat(8, 3) : FloatFormat(3, 4)
        spec = FunctionSpec(
            "9*x^3/64+5*x/16+3/16";
            input_format,
            output_format = input_format,
            domain = (-3 // 4, 3 // 4),
            absolute_error = 1 // 2,
        )
        result = certify_plan(
            polynomial_plan(
                spec,
                [3 // 16, 5 // 16, 0, 9 // 64];
                precision = p,
                evaluation,
            ),
        )
        @test only(result.paths).arithmetic_error > 0
        @test only(result.paths).coordinate_error > 0
        path = only(PRESAGe._precision_audit(result.plan).paths)
        _, rho = PRESAGe._polynomial_ranges(result.plan.program, path)
        @test rho[path.initial] > 0 # Initial coefficient conversion is included.
        words = check_precision_polynomial(result, 0:255; exact)
        for backend in (:portable, :ac_fixed, :ap_fixed)
            @test cpu_check(result.plan, words; backend, public_api = true) == length(words)
        end
        if input_format isa FloatFormat
            @test cpu_check(result.plan, words; float_backend = :ac_std_float) ==
                  length(words)
        else
            # a_d=9/64 rounds to +0.25 in the two-fraction-bit seed format.
            @test PRESAGe._polynomial_value(
                interpret_trace(
                    result.plan,
                    round_fixed(1 // 2, input_format),
                ).values[path.initial].bits,
                p.stage_formats[end],
            ) == 1 // 4
        end
    end
    # Constants exercise seed rounding without any Horner stage.
    f = FixedFormat(12, 3)
    p = PolynomialPrecision(
        f;
        coefficient_formats = [f],
        stage_formats = [FixedFormat(4, 2)],
    )
    for coefficient in (1 // 8, 3 // 8, -1 // 8, -3 // 8)
        spec = FunctionSpec(
            PRESAGe._rational_text(coefficient);
            input_format = FixedFormat(4, 2),
            output_format = f,
            domain = (-1, 1),
            absolute_error = 1 // 8,
        )
        result = certify_plan(polynomial_plan(spec, [coefficient]; precision = p))
        @test result.total_bound == 1 // 8
        words = check_precision_polynomial(result, 0:15; exact = x -> coefficient)
        @test cpu_check(result.plan, words; backend = :ac_fixed) == length(words)
        @test cpu_check(result.plan, words; backend = :ap_fixed) == length(words)
    end
end

@testset "Precision overflow refusal and canonical graph audit" begin
    spec = FunctionSpec(
        "x/2+1/4";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(16, 4),
        domain = (-1, 1),
    )
    f = FixedFormat(24, 6)
    p = PolynomialPrecision(
        f;
        coefficient_formats = [FixedFormat(12, 2), FixedFormat(10, 2)],
        stage_formats = [FixedFormat(16, 4), FixedFormat(12, 3)],
    )
    for plan in (
        polynomial_plan(spec, [1 // 4, 1 // 2]; precision = p),
        segmented_polynomial_plan(
            spec,
            [[-1 // 8, 1 // 8], [1 // 8, 1 // 8], [3 // 8, 1 // 8], [5 // 8, 1 // 8]];
            precision = p,
        ),
    )
        mutate(nodes; precision = p, tables = plan.program.tables) = PlanArtifact(
            spec;
            program = IR.Program(nodes; output = plan.program.output, tables),
            precision,
            settings = plan.settings,
            segments = plan.segments,
        )
        for i in eachindex(plan.program.nodes)
            node = plan.program.nodes[i]
            node isa Union{IR.Quantize, IR.Add, IR.Mul} || continue
            nodes = collect(plan.program.nodes)
            nodes[i] = if node isa IR.Quantize
                IR.Convert(node.source, node.format)
            elseif node isa IR.Add
                IR.Add(node.b, node.a, node.format)
            else
                IR.Mul(node.b, node.a, node.format)
            end
            @test certify_plan(mutate(nodes)).status == :unsupported_domain
        end
        altered = PolynomialPrecision(
            f;
            coefficient_formats = p.coefficient_formats,
            stage_formats = [FixedFormat(15, 4), p.stage_formats[2]],
        )
        @test certify_plan(mutate(plan.program.nodes; precision = altered)).status ==
              :unsupported_domain
        if !isempty(plan.program.tables)
            tables = collect(plan.program.tables)
            t = tables[2]
            values = collect(t.values)
            values[1] += 1
            tables[2] = IR.Table(t.format, values; unroll = t.unroll)
            @test certify_plan(mutate(plan.program.nodes; tables)).status ==
                  :unsupported_domain
        end
    end
    for (coordinate, coefficients, stages, input_format, expression, cs, domain) in (
        (
            f,
            [f, f],
            [FixedFormat(8, 1), f],
            FixedFormat(8, 3),
            "x+1/2",
            [1 // 2, 1],
            (-1, 1),
        ),
        (
            FloatFormat(5, 10),
            [FloatFormat(5, 10), FloatFormat(5, 10)],
            [FloatFormat(2, 3), FloatFormat(5, 10)],
            FloatFormat(4, 3),
            "x+1",
            [1, 1],
            (0, 4),
        ),
    )
        precision = PolynomialPrecision(
            coordinate;
            coefficient_formats = coefficients,
            stage_formats = stages,
        )
        plan = polynomial_plan(
            FunctionSpec(expression; input_format, domain, absolute_error = 1),
            cs;
            precision,
        )
        @test certify_plan(plan).status == :proof_failed
        @test occursin("overflow", certify_plan(plan).reason)
    end
end

@testset "Generated individual storage and stage formats" begin
    for coordinate in (FixedFormat(32, 6), FloatFormat(8, 27)),
        evaluation in (:separate, :fma)

        fixed = coordinate isa FixedFormat
        coefficients =
            fixed ?
            [
                FixedFormat(25, 4),
                FixedFormat(23, 3),
                FixedFormat(22, 2),
                FixedFormat(21, 2),
                FixedFormat(20, 2),
                FixedFormat(19, 2),
            ] :
            [
                FloatFormat(8, 24),
                FloatFormat(7, 23),
                FloatFormat(7, 22),
                FloatFormat(7, 21),
                FloatFormat(7, 20),
                FloatFormat(7, 19),
            ]
        stages =
            fixed ?
            [
                FixedFormat(29, 4),
                FixedFormat(28, 4),
                FixedFormat(27, 4),
                FixedFormat(26, 4),
                FixedFormat(25, 4),
                FixedFormat(24, 4),
            ] :
            [
                FloatFormat(8, 27),
                FloatFormat(8, 26),
                FloatFormat(8, 25),
                FloatFormat(8, 24),
                FloatFormat(8, 23),
                FloatFormat(8, 22),
            ]
        precision = PolynomialPrecision(
            coordinate;
            coefficient_formats = coefficients,
            stage_formats = stages,
        )
        spec = FunctionSpec(
            "exp(x)";
            input_format = FixedFormat(9, 3),
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
            absolute_error = 1 // 2^18,
        )
        config = PolynomialSearchConfig(
            degrees = [5],
            internal_formats = [coordinate],
            precisions = [precision],
            segments = [4],
            evaluation = evaluation,
            job_timeout = 60,
            total_timeout = 180,
        )
        result = search_polynomial(spec, config)
        @test result.status == :certified
        proof = result.selected
        proof === nothing && error(only(result.attempts).reason)
        baseline = certified_polynomial(
            spec;
            degree = 5,
            segments = 4,
            internal_format = coordinate,
            evaluation,
        )
        @test precision_cost(proof.plan).coefficient_bits <
              precision_cost(baseline.plan).coefficient_bits
        @test precision_cost(proof.plan).arithmetic_result_bits <
              precision_cost(baseline.plan).arithmetic_result_bits
        @test length(unique(proof.plan.precision.stage_formats)) > 1
        @test length(unique(proof.plan.precision.coefficient_formats)) > 1
        words = check_segmented_polynomial(proof, 0:511)
        for backend in (:portable, :ac_fixed, :ap_fixed)
            @test cpu_check(proof.plan, words; backend) == length(words)
        end
        @test certify_plan(
            PRESAGe._read_plan(PRESAGe._plan_data(proof.plan)),
        ).total_bound == proof.total_bound
        io = IOBuffer()
        write_search_config(io, config)
        data = TOML.parse(String(take!(io)))
        @test data["schema_version"] == 3
        @test PRESAGe._read_search_config(data).precisions == (precision,)
        io = IOBuffer()
        write_search_report(io, result)
        report = TOML.parse(String(take!(io)))
        @test report["attempts"][1]["precision"] == PRESAGe._precision_data(precision)
    end
    # Generation precision is independent of coefficient storage and stage bits.
    f = FixedFormat(24, 6)
    p = PolynomialPrecision(
        f;
        coefficient_formats = [FixedFormat(12, 2), FixedFormat(10, 2)],
        stage_formats = [FixedFormat(18, 4), FixedFormat(14, 3)],
    )
    generated = [
        certified_polynomial(
            FunctionSpec(
                expr;
                input_format = FixedFormat(8, 3),
                output_format = FixedFormat(16, 4),
                domain = (-1, 1),
            );
            degree = 1,
            precision = p,
        ) for expr in ("0.5*x+2.5e-1", "x/2+1/4")
    ]
    @test all(r -> r.status == :certified, generated)
    @test PRESAGe._program_data(generated[1].plan.program) ==
          PRESAGe._program_data(generated[2].plan.program)
    singleton = certified_polynomial(
        FunctionSpec(
            "exp(x)";
            input_format = FixedFormat(8, 3),
            output_format = FixedFormat(24, 4),
            domain = (1, 1),
            absolute_error = 1 // 2^18,
        );
        degree = 5,
        precision = PolynomialPrecision(
            FixedFormat(32, 6);
            coefficient_formats = fill(FixedFormat(28, 4), 6),
            stage_formats = fill(FixedFormat(32, 6), 6),
        ),
    )
    @test singleton.status == :certified
    @test length(singleton.plan.precision.coefficient_formats) == 1
end

@testset "Bounded certified precision optimization and reports" begin
    for format in (FixedFormat(24, 6), FloatFormat(5, 12))
        spec = FunctionSpec(
            "x/2+1/4";
            input_format = FixedFormat(8, 3),
            output_format = FixedFormat(16, 4),
            domain = (-1, 1),
            absolute_error = 1 // 64,
        )
        baseline = certified_polynomial(spec; degree = 1, internal_format = format)
        result = optimize_precision(
            baseline;
            max_attempts = 10,
            bit_step = format isa FixedFormat ? 12 : 4,
            job_timeout = 60,
            total_timeout = 600,
        )
        @test result.status == :certified
        @test result.stop_reason == :attempt_limit
        @test length(result.attempts) == 10
        @test first(result.attempts).kind == :baseline
        @test first(result.attempts).accepted
        @test any(a -> a.kind == :coefficient_precision && a.accepted, result.attempts)
        @test any(a -> a.kind == :stage_precision && a.accepted, result.attempts)
        @test any(a -> !a.accepted, result.attempts)
        proof = result.selected
        @test precision_cost(proof.plan).coefficient_bits <
              precision_cost(baseline.plan).coefficient_bits
        @test precision_cost(proof.plan).stage_bits <
              precision_cost(baseline.plan).stage_bits
        @test proof.plan.precision.coordinate_format == format
        if format isa FloatFormat
            @test all(
                f -> f.exponent_bits == format.exponent_bits,
                (
                    proof.plan.precision.coefficient_formats...,
                    proof.plan.precision.stage_formats...,
                ),
            )
        end
        words = check_precision_polynomial(proof, 0:255; exact = x -> x / 2 + 1 // 4)
        @test cpu_check(proof.plan, words; backend = :ac_fixed) == length(words)
        io = IOBuffer()
        write_precision_report(io, result)
        report = TOML.parse(String(take!(io)))
        @test report["schema"] == "presage-precision-search"
        @test report["baseline"]["cost"]["coefficient_bits"] >
              report["selected"]["cost"]["coefficient_bits"]
        @test certify_plan(PRESAGe._read_plan(report["selected"]["plan"])).total_bound ==
              proof.total_bound
        @test count(a -> a["accepted"], report["attempts"]) ==
              count(a -> a.accepted, result.attempts)
    end
    spec = FunctionSpec(
        "x";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(16, 4),
        domain = (-1, 1),
    )
    baseline = certified_polynomial(spec; degree = 1, internal_format = FixedFormat(24, 6))
    limited = optimize_precision(baseline; max_attempts = 1)
    @test limited.status == :certified
    @test limited.stop_reason == :attempt_limit
    expired = optimize_precision(baseline; total_timeout = 1e-12)
    @test expired.status == :optimization_failed
    @test expired.selected === nothing
    @test expired.stop_reason == :total_deadline
    # A completed proof in a still-running worker cannot bypass the deadline.
    processes, directories = Base.Process[], String[]
    fixture = joinpath(@__DIR__, "fixtures", "polynomial_worker.jl")
    worker_command =
        directory -> addenv(
            `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $fixture $directory`,
            "PRESAGE_WORKER_TEST_MODE" => "late_result",
        )
    timed = PRESAGe._optimize_precision(
        baseline;
        job_timeout = 60,
        total_timeout = 180,
        worker_command,
        process_started = (process, directory) ->
            (push!(processes, process); push!(directories, directory)),
    )
    @test timed.status == :optimization_failed
    @test timed.stop_reason == :baseline_failed
    @test only(timed.attempts).result.status == :timeout
    @test only(timed.attempts).result.certificate !== nothing
    @test only(timed.attempts).result.certificate.status == :certified
    @test all(process_exited, processes)
    @test all(directory -> !isdir(directory), directories)
    io = IOBuffer()
    write_precision_report(io, timed)
    @test !haskey(TOML.parse(String(take!(io))), "selected")
    for kwargs in (
        (bit_step = 0,),
        (min_precision_bits = -1,),
        (bit_step = true,),
        (max_attempts = 0,),
    )
        @test_throws ArgumentError optimize_precision(baseline; kwargs...)
    end
    failed = PRESAGe._certificate_failure(baseline.plan, :proof_failed, "test")
    @test_throws ArgumentError optimize_precision(failed)
end

@testset "Precision configuration CLI and replay" begin
    mktempdir() do directory
        spec = FunctionSpec(
            "x/2+1/4";
            input_format = FixedFormat(8, 3),
            output_format = FixedFormat(16, 4),
            domain = (-1, 1),
        )
        f = FixedFormat(24, 6)
        p = PolynomialPrecision(
            f;
            coefficient_formats = [FixedFormat(12, 2), FixedFormat(10, 2)],
            stage_formats = [FixedFormat(20, 4), FixedFormat(16, 3)],
        )
        contract, configuration =
            joinpath(directory, "contract.toml"), joinpath(directory, "config.toml")
        write_plan(contract, PlanArtifact(spec))
        config = PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1],
            internal_formats = [f],
            precisions = [p],
            job_timeout = 60,
            total_timeout = 180,
        )
        write_search_config(configuration, config)
        output = joinpath(directory, "generated")
        script = joinpath(@__DIR__, "..", "scripts", "generate.jl")
        command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script $contract $output --search-config=$configuration --backend=portable`
        open(joinpath(directory, "cli.log"), "w") do io
            run(pipeline(command; stdout = io, stderr = io))
        end
        plan = read_plan(joinpath(output, "plan.toml"))
        @test plan.precision == p
        @test TOML.parsefile(joinpath(output, "search.toml"))["schema_version"] == 3
        certificate = TOML.parsefile(joinpath(output, "certificate.toml"))
        @test certificate["precision"] == PRESAGe._precision_data(p)
        @test certify_plan(plan).status == :certified
        words = check_precision_polynomial(
            certify_plan(plan),
            0:255;
            exact = x -> x / 2 + 1 // 4,
        )
        @test cpu_check(plan, words; generated_directory = output) == length(words)
        replay = joinpath(directory, "replayed")
        replay_command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script $(joinpath(output,"plan.toml")) $replay --backend=ap_fixed`
        open(joinpath(directory, "replay.log"), "w") do io
            run(pipeline(replay_command; stdout = io, stderr = io))
        end
        @test read_plan(joinpath(replay, "plan.toml")).precision == p
        @test cpu_check(plan, words; backend = :ap_fixed, generated_directory = replay) ==
              length(words)
        saved = Dict(name => read(joinpath(output, name)) for name in readdir(output))
        coarse = PolynomialPrecision(
            f;
            coefficient_formats = p.coefficient_formats,
            stage_formats = [FixedFormat(6, 1), FixedFormat(8, 2)],
        )
        write_search_config(
            configuration,
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [1],
                internal_formats = [f],
                precisions = [coarse],
                job_timeout = 60,
                total_timeout = 180,
            ),
        )
        process = open(joinpath(directory, "failure.log"), "w") do io
            run(pipeline(ignorestatus(command); stdout = io, stderr = io))
        end
        @test !success(process)
        @test all(name -> read(joinpath(output, name)) == saved[name], keys(saved))
        failure = TOML.parsefile(joinpath(output, "search-failure.toml"))
        @test failure["schema_version"] == 3
        @test failure["attempts"][1]["status"] == "proof_failed"
        # Reject malformed precision fields and duplicate complete choices.
        @test_throws ArgumentError PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1],
            internal_formats = [f, f],
            precisions = [p, p],
        )
        alternative = PolynomialPrecision(
            f;
            coefficient_formats = p.coefficient_formats,
            stage_formats = p.coefficient_formats,
        )
        @test PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1],
            internal_formats = [f, f],
            precisions = [p, alternative],
        ).precisions == (p, alternative)
        data = PRESAGe._search_config_data(config)
        data["internal_formats"][1]["precision"]["stage_formats"][1]["format"]["typo"] = 1
        @test_throws ArgumentError PRESAGe._read_search_config(data)
    end
end
