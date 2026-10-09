function check_segmented_polynomial(result, words; exact = nothing)
    @test result.status == :certified
    plan = result.plan
    layout = PRESAGe._segmented_audit(plan)
    accepted = BigInt[]
    backend = plan.spec.expression == "exp(x)" ? :mpfr : :sollya
    # Point-domain norm proofs can be tighter than a 256-bit reference enclosure.
    config = OracleConfig(initial_precision = 512, max_precision = 2048)
    with_oracle(plan.spec; backend, config) do oracle
        for word in words
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
                    @test !any(keys(trace.values)) do i
                        plan.program.nodes[i] isa
                        Union{IR.TableLoad, IR.Add, IR.Mul, IR.FMA, IR.ScalePow2}
                    end
                end
                continue
            end
            @test count(p -> p.domain[1] <= x <= p.domain[2], result.paths) == 1
            push!(accepted, word)
            path = result.paths[row]
            trace = interpret_trace(plan, word)
            @test trace.values[layout.paths[row].index] == row - 1
            actual = PRESAGe._decode_input(trace.bits, plan.spec.output_format).value
            lo, hi = if exact !== nothing
                value = PRESAGe._q(exact(x))
                value, value
            else
                ref = reference(oracle, word)
                @test ref.status in (:resolved, :special)
                ref.enclosure === nothing ? (PRESAGe._q(1), PRESAGe._q(1)) :
                map(b -> b.significand * PRESAGe._pow2(b.exponent), ref.enclosure)
            end
            @test max(abs(actual - lo), abs(actual - hi)) <=
                  path.total <=
                  result.total_bound
            bounds = Dict(b.node => b.range for b in path.ranges)
            @test all(trace.values) do (i, value)
                f = IR.format(plan.program, i)
                f isa Union{FloatFormat, FixedFormat} || return true
                q = PRESAGe._decode_input(value.bits, f).value
                haskey(bounds, i) && q !== nothing && bounds[i][1] <= q <= bounds[i][2]
            end
            if haskey(trace.values, layout.paths[row].coordinate)
                t = PRESAGe._polynomial_value(
                    trace.values[layout.paths[row].coordinate].bits,
                    IR.format(plan.program, layout.paths[row].coordinate),
                )
                ideal =
                    (x - layout.paths[row].center) *
                    PRESAGe._pow2(layout.paths[row].exponent)
                @test abs(ideal) <= 1
                @test bounds[layout.paths[row].coordinate][1] <=
                      t <=
                      bounds[layout.paths[row].coordinate][2]
            end
        end
    end
    return accepted
end

@testset "Normalized segmentation and complete certificates" begin
    for evaluation in (:separate, :fma),
        internal_format in (FixedFormat(32, 6), FloatFormat(8, 27))

        spec = FunctionSpec(
            "exp(x)";
            input_format = FixedFormat(9, 3),
            output_format = FixedFormat(24, 4),
            domain = (-1, 1),
            absolute_error = 1 // (1 << 18),
        )
        result = certified_polynomial(
            spec;
            degree = 5,
            segments = 4,
            internal_format,
            evaluation,
        )
        @test length(result.paths) == 4
        @test result.settings["method"] == "normalized_segmented_horner"
        @test all(path -> path.upper_inclusive, result.paths)
        @test result.plan.settings["segments"] == "4"
        words = check_segmented_polynomial(result, 0:511)
        @test length(words) == 129
        for backend in (:portable, :ac_fixed, :ap_fixed)
            try
                backend == :portable || vendor_include(backend)
            catch
                get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" && rethrow()
                continue
            end
            @test cpu_check(result.plan, words; backend) == length(words)
        end
        io = IOBuffer()
        write_plan(io, result.plan)
        restored = read_plan(IOBuffer(String(take!(io))))
        fresh = certify_plan(restored)
        @test fresh.status == :certified
        @test fresh.total_bound == result.total_bound
        @test PRESAGe._certificate_data(fresh) == PRESAGe._certificate_data(result)
        report = PRESAGe._certificate_data(fresh)
        @test report["coverage"]["input_domain"] == ["-1/1", "1/1"]
        @test occursin("adjacent representable", report["coverage"]["dispatch"])
        @test all(p -> haskey(p["coordinate"], "rounded_domain"), report["paths"])
    end
    # Nonrepresentable contract endpoints and boundaries, including both zeros.
    for input_format in (FixedFormat(8, 3), FloatFormat(3, 4)),
        output_format in (FixedFormat(16, 4), IEEE16),
        evaluation in (:separate, :fma)

        spec = FunctionSpec(
            "x/2+1/4";
            input_format,
            output_format,
            domain = (-9 // 10, 7 // 10),
            absolute_error = 1 // (1 << 9),
        )
        result = certified_polynomial(
            spec;
            degree = 1,
            segments = 4,
            internal_format = FixedFormat(24, 6),
            evaluation,
        )
        @test result.total_bound == 0
        words = check_segmented_polynomial(result, 0:255; exact = x -> x / 2 + 1 // 4)
        @test cpu_check(result.plan, words) == length(words)
        layout = PRESAGe._segmented_audit(result.plan)
        @test first(result.paths).domain[1] == PRESAGe._polynomial_domain(spec)[1]
        @test last(result.paths).domain[2] == PRESAGe._polynomial_domain(spec)[2]
        for i = 2:4
            threshold = layout.geometry.thresholds[i - 1]
            @test result.paths[i].domain[1] ==
                  PRESAGe._polynomial_value(threshold, input_format)
            @test result.paths[i - 1].domain[2] ==
                  PRESAGe._previous_input_value(threshold, input_format)
        end
    end
end

@testset "Rounded coordinates, scaling and empty branches" begin
    for (input_format, internal_format, output_format) in (
        (FixedFormat(8, 3), FixedFormat(8, 4), FixedFormat(10, 3)),
        (FloatFormat(3, 4), FloatFormat(4, 2), FloatFormat(3, 4)),
    )
        spec = FunctionSpec(
            "x/4";
            input_format,
            output_format,
            domain = (-9 // 10, 7 // 10),
            absolute_error = 1 // 8,
        )
        result = certified_polynomial(spec; degree = 1, segments = 4, internal_format)
        @test any(p -> p.coordinate_error > 0, result.paths)
        words = check_segmented_polynomial(result, 0:255; exact = x -> x / 4)
        @test cpu_check(result.plan, words) == length(words)
        layout = PRESAGe._segmented_audit(result.plan)
        for path in layout.paths
            @test maximum(abs, path.domain) <= 1
        end
        @test any(zip(layout.paths, result.paths)) do (layout_path, certificate)
            bound = only(
                b.range for b in certificate.ranges if b.node == layout_path.coordinate
            )
            bound[1] < layout_path.domain[1] || bound[2] > layout_path.domain[2]
        end
    end
    # Scaling down is exact when the fixed grid is wide enough.
    spec = FunctionSpec(
        "x/4";
        input_format = FixedFormat(8, 6),
        output_format = FixedFormat(16, 6),
        domain = (-8, 8),
    )
    result = certified_polynomial(
        spec;
        degree = 1,
        segments = 4,
        internal_format = FixedFormat(20, 6),
    )
    @test result.total_bound == 0
    @test PRESAGe._segmented_audit(result.plan).geometry.exponent == -1
    words = check_segmented_polynomial(result, 0:255; exact = x -> x / 4)
    @test cpu_check(result.plan, words; backend = :ac_fixed) == length(words)
    @test cpu_check(result.plan, words; backend = :ap_fixed) == length(words)

    # A segment may consist of a single input. No degenerate native Remez call.
    spec = FunctionSpec(
        "exp(x)";
        input_format = FixedFormat(3, 2),
        output_format = FixedFormat(24, 4),
        domain = (0, 1 // 2),
        absolute_error = 1 // (1 << 18),
    )
    result = certified_polynomial(
        spec;
        degree = 5,
        segments = 2,
        internal_format = FixedFormat(32, 6),
    )
    @test all(p -> p.domain[1] == p.domain[2], result.paths)
    check_segmented_polynomial(result, 0:7)
    @test length(result.plan.program.tables) == 2
    @test all(
        p -> !haskey(p["coordinate"], "rounded_domain"),
        PRESAGe._certificate_data(result)["paths"],
    )

    defaults = (degrees = [1], internal_formats = [FixedFormat(24, 6)])
    for segments in ([], [1, 1], [0], [3], [1024], [true], [1.0], "4")
        @test_throws ArgumentError PolynomialSearchConfig(; defaults..., segments)
    end
    for segments in (0, 3, 1024, true)
        @test_throws ArgumentError certified_polynomial(spec; degree = 1, segments)
    end
    @test_throws ArgumentError certified_polynomial(spec; degree = 1, segments = 4)
    @test_throws ArgumentError certified_polynomial(
        FunctionSpec("x"; domain = (1, 1));
        degree = 1,
        segments = 2,
    )
    @test_throws ArgumentError PolynomialSearchConfig(
        degrees = [1],
        internal_formats = [FixedFormat(16, 4; signed = false)],
        segments = [2],
    )
    launched = Ref(false)
    @test_throws ArgumentError PRESAGe._search_polynomial(
        spec,
        PolynomialSearchConfig(; defaults..., segments = [1, 4]);
        process_started = (process, directory) -> (launched[] = true),
    )
    @test !launched[]

    # Coordinate conversion overflow refuses a nonconstant proof; lazy guards
    # reject excluded inputs before loading any segment payloads.
    overflow_spec = FunctionSpec(
        "x";
        input_format = IEEE32,
        output_format = IEEE32,
        domain = (4, 8),
        absolute_error = 1,
    )
    plan = segmented_polynomial_plan(
        overflow_spec,
        [[0, 1], [0, 1]];
        internal_format = FixedFormat(8, 4),
    )
    @test certify_plan(plan).status == :proof_failed
    @test evaluate_bits(plan, round_ieee(100, IEEE32)) == PRESAGe._nan(IEEE32)
end

@testset "Segmented graph and table audit" begin
    spec = FunctionSpec(
        "x/2+1/4";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(16, 4),
        domain = (-1, 1),
    )
    result = certified_polynomial(
        spec;
        degree = 1,
        segments = 4,
        internal_format = FixedFormat(24, 6),
    )
    plan, p = result.plan, result.plan.program
    layout = PRESAGe._segmented_audit(plan)
    function changed(
        nodes = collect(p.nodes),
        tables = collect(p.tables);
        segments = plan.segments,
    )
        return PlanArtifact(
            spec;
            program = IR.Program(nodes; output = p.output, tables),
            segments,
            settings = plan.settings,
        )
    end
    replacements = Pair{Int, IR.Node}[]
    for (i, n) in enumerate(p.nodes)
        if n isa IR.Compare && n.predicate == :ge
            push!(replacements, i => IR.Compare(:gt, n.a, n.b))
            constant = p.nodes[n.b]
            push!(replacements, n.b => IR.Const(constant.format, constant.bits ⊻ 1))
        elseif n isa IR.ScalePow2
            push!(replacements, i => IR.ScalePow2(n.source, n.exponent + 1, n.format))
        elseif n isa IR.TableLoad
            constant_index = findfirst(p.nodes) do node
                node isa IR.Const && node.format == IR.format(p, n.index)
            end
            push!(replacements, i => IR.TableLoad(n.table, constant_index))
        elseif n isa IR.Add
            push!(replacements, i => IR.Add(n.b, n.a, n.format))
        elseif n isa IR.Guard
            condition = findfirst(n -> n isa IR.Compare, p.nodes)
            push!(replacements, i => IR.Guard(condition, n.source))
        end
    end
    for (i, replacement) in replacements
        nodes = collect(p.nodes)
        nodes[i] = replacement
        @test certify_plan(changed(nodes)).status == :unsupported_domain
    end
    for (i, t) in enumerate(p.tables), row in eachindex(t.values)
        tables = collect(p.tables)
        values = collect(t.values)
        values[row] ⊻= 1
        tables[i] = IR.Table(t.format, values; banks = t.banks, unroll = t.unroll)
        @test certify_plan(changed(collect(p.nodes), tables)).status == :unsupported_domain
    end
    for (banks, unroll) in ((2, true), (1, false))
        tables = collect(p.tables)
        t = tables[end]
        tables[end] = IR.Table(t.format, t.values; banks, unroll)
        @test certify_plan(changed(collect(p.nodes), tables)).status == :unsupported_domain
    end
    segments = copy(plan.segments)
    s = segments[1]
    segments[1] = Segment(s.lower, s.upper - 1 // 64, s.coefficients)
    @test certify_plan(changed(; segments)).status == :unsupported_domain
    @test certify_polynomial(
        PlanArtifact(spec; program = p, settings = plan.settings),
    ).status == :unsupported_domain

    # Changing coefficient metadata and matching payloads requires a fresh norm
    # proof, and cannot carry the old certificate to a different function.
    bad = segmented_polynomial_plan(
        spec,
        [[1, 0] for _ = 1:4];
        internal_format = FixedFormat(24, 6),
    )
    @test certify_plan(bad).status == :bound_exceeds_budget
end

@testset "Segment boundaries and exhaustive binary16" begin
    spec = FunctionSpec("x/2+1/4"; input_format = IEEE32, domain = (-9 // 10, 7 // 10))
    result = certified_polynomial(
        spec;
        degree = 1,
        segments = 4,
        internal_format = FloatFormat(8, 27),
    )
    layout = PRESAGe._segmented_audit(result.plan)
    words = UInt64[0, PRESAGe._sign(IEEE32), PRESAGe._nan(IEEE32), PRESAGe._inf(IEEE32)]
    for boundary in [spec.domain...; layout.geometry.boundaries]
        word = round_ieee(boundary, IEEE32)
        append!(words, [word - 1, word, word + 1])
    end
    accepted =
        check_segmented_polynomial(result, unique(words); exact = x -> x / 2 + 1 // 4)
    @test cpu_check(result.plan, words) == length(words)
    @test !isempty(accepted)

    # The six-bit index reaches row 63 and every fixed input is checked.
    spec = FunctionSpec(
        "x/2+1/4";
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(16, 4),
        domain = (-1, 1),
    )
    result = certified_polynomial(
        spec;
        degree = 1,
        segments = 64,
        internal_format = FixedFormat(24, 6),
    )
    @test result.total_bound == 0
    words = check_segmented_polynomial(result, 0:511; exact = x -> x / 2 + 1 // 4)
    @test cpu_check(result.plan, words) == length(words)

    spec = FunctionSpec(
        "exp(x)";
        input_format = IEEE16,
        domain = (-1, 1),
        absolute_error = 1 // (1 << 9),
    )
    result = certified_polynomial(
        spec;
        degree = 5,
        segments = 4,
        internal_format = FixedFormat(32, 6),
        evaluation = :fma,
    )
    @test length(result.paths) == 4
    words = check_segmented_polynomial(result, 0:65535)
    @test cpu_check(result.plan, 0:65535; backend = :portable) == 65536
    @test cpu_check(result.plan, 0:65535; backend = :ac_fixed) == 65536
    @test cpu_check(result.plan, 0:65535; backend = :ap_fixed) == 65536
    @test !isempty(words)
end

@testset "Segment choices, CLI and replay" begin
    spec = FunctionSpec(
        "exp(x)";
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(24, 4),
        domain = (-1, 1),
        absolute_error = 1 // (1 << 18),
    )
    config = PolynomialSearchConfig(
        degrees = [5],
        internal_formats = [FixedFormat(32, 6)],
        segments = [1, 4],
        max_attempts = 2,
        job_timeout = 30,
        total_timeout = 60,
    )
    io = IOBuffer()
    write_search_config(io, config)
    data = TOML.parse(String(take!(io)))
    @test data["schema_version"] == 2
    @test data["order"] == "segment_then_degree_then_format"
    @test PRESAGe._read_search_config(data).segments == (1, 4)
    decoded = PRESAGe._read_search_config(data)
    @test all(
        key -> getfield(decoded, key) == getfield(config, key),
        fieldnames(PolynomialSearchConfig),
    )
    delete!(data, "order")
    @test PRESAGe._read_search_config(data).segments == (1, 4)
    for (key, value) in
        (("schema_version", 1), ("segments", [2, 2]), ("order", "degree_then_format"))
        invalid = deepcopy(data)
        invalid[key] = value
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
    end
    mktempdir() do directory
        contract, configuration =
            joinpath.(Ref(directory), ("contract.toml", "search-config.toml"))
        write_plan(contract, PlanArtifact(spec))
        write_search_config(configuration, config)
        output = joinpath(directory, "generated")
        generate_main([
            contract,
            output,
            "--search-config=$configuration",
            "--backend=portable",
        ])
        report = TOML.parsefile(joinpath(output, "search.toml"))
        @test report["schema_version"] == 2
        @test [a["segments"] for a in report["attempts"]] == [1, 4]
        @test [a["status"] for a in report["attempts"]] == ["bound_exceeds_budget", "certified"]
        plan = read_plan(joinpath(output, "plan.toml"))
        proof = certify_plan(plan)
        @test proof.status == :certified
        words = check_segmented_polynomial(proof, 0:511)
        @test cpu_check(plan, words; generated_directory = output) == length(words)
        repeated = joinpath(directory, "replayed")
        generate_main([joinpath(output, "plan.toml"), repeated, "--backend=portable"])
        for name in ("plan.toml", "certificate.toml", "evaluator.hpp", "evaluate.cpp")
            @test read(joinpath(output, name)) == read(joinpath(repeated, name))
        end
    end
end
