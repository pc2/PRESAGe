isdefined(Main, :sweep_main) || include(joinpath(@__DIR__, "..", "scripts", "sweep.jl"))
const sweep_spec = FunctionSpec(
    "x";
    input_format = FixedFormat(8, 3),
    output_format = FixedFormat(16, 4),
    domain = (-1, 1),
)
const sweep_format = FixedFormat(24, 6)
sweep_config(; kwargs...) = PolynomialSearchConfig(;
    evaluation = :separate,
    degrees = [1, 2],
    internal_formats = [sweep_format],
    job_timeout = 60,
    total_timeout = 120,
    kwargs...,
)

@testset "Local sweeps, concurrent workers and exact cache replay" begin
    mktempdir() do directory
        cache = NumericalCache(joinpath(directory, "cache"))
        processes, directories, peak = Base.Process[], String[], Ref(0)
        launched(process, directory) = begin
            push!(processes, process)
            push!(directories, directory)
            peak[] = max(peak[], count(process_running, processes))
        end
        cold = PRESAGe._sweep_polynomial(
            sweep_spec,
            sweep_config();
            max_parallel = 2,
            cache,
            process_started = launched,
        )
        @test cold.status == :complete && cold.stop_reason == :choices_exhausted
        @test [r.attempt.degree for r in cold.rows] == [1, 2]
        @test all(r -> r.attempt.status == :certified && r.cache_status == :miss, cold.rows)
        @test peak[] == 2 && all(process_exited, processes)
        @test all(d -> !isdir(d), directories)
        @test length(readdir(cache.directory)) == 2
        @test all(
            r -> r.attempt.generation_seconds >= 0 && r.attempt.proof_seconds >= 0,
            cold.rows,
        )
        warm = PRESAGe._sweep_polynomial(
            sweep_spec,
            sweep_config();
            max_parallel = 2,
            cache,
            process_started = (p, d) -> error("cache hit launched a worker"),
        )
        @test warm.status == :complete
        @test all(r -> r.cache_status == :hit, warm.rows)
        @test warm.pareto_indices == cold.pareto_indices
        for (a, b) in zip(cold.rows, warm.rows)
            @test PRESAGe._plan_data(a.attempt.plan) == PRESAGe._plan_data(b.attempt.plan)
            @test PRESAGe._certificate_data(a.attempt.certificate) ==
                  PRESAGe._certificate_data(b.attempt.certificate)
            @test b.compute_seconds == a.compute_seconds
            words = [w for w = 0:255 if -1 <= decode_fixed(w, sweep_spec.input_format) <= 1]
            @test all(
                w -> evaluate_bits(a.attempt.plan, w) == evaluate_bits(b.attempt.plan, w),
                words,
            )
            @test cpu_check(b.attempt.plan, words; backend = :ap_fixed) == length(words)
        end
        io = IOBuffer()
        write_sweep_report(io, warm)
        data = TOML.parse(String(take!(io)))
        @test data["schema"] == "presage-polynomial-sweep" && data["schema_version"] == 3
        @test data["pareto_indices"] == collect(warm.pareto_indices)
        @test all(
            r ->
                haskey(r, "certificate") &&
                    haskey(r, "precision_cost") &&
                    haskey(r, "generation_seconds"),
            data["rows"],
        )
        @test PRESAGe._plan_data(PRESAGe._read_plan(data["rows"][1]["plan"])) ==
              PRESAGe._plan_data(warm.rows[1].attempt.plan)
        # Execution limits and choice order do not change a numerical result.
        reordered = PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [2, 1],
            internal_formats = [sweep_format],
            job_timeout = 90,
            total_timeout = 180,
        )
        again = PRESAGe._sweep_polynomial(
            sweep_spec,
            reordered;
            cache,
            process_started = (p, d) -> error("execution-only change missed cache"),
        )
        @test [r.attempt.degree for r in again.rows] == [2, 1]
        @test all(r -> r.cache_status == :hit, again.rows)
        # Payload corruption is rejected and repaired through a fresh proof.
        entry = joinpath(cache.directory, first(cold.rows).cache_key * ".toml")
        damaged = TOML.parsefile(entry)
        damaged["payload"]["certificate"]["total_bound"] = "1/1"
        open(io -> TOML.print(io, damaged), entry, "w")
        repaired = sweep_polynomial(sweep_spec, sweep_config(); cache, max_parallel = 2)
        @test [r.cache_status for r in repaired.rows] == [:invalid, :hit]
        @test first(repaired.rows).attempt.status == :certified
        @test isempty(
            filter(n -> startswith(n, ".presage-cache-"), readdir(cache.directory)),
        )
        # A new proof precision launches a new proof and gets a distinct key.
        changed = sweep_polynomial(
            sweep_spec,
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [1],
                internal_formats = [sweep_format],
                proof_precision = 320,
            );
            cache,
        )
        @test only(changed.rows).cache_status == :miss
        @test only(changed.rows).cache_key != first(cold.rows).cache_key
    end
end

@testset "Numerical cache key coverage and artifact rejection" begin
    _, items, _, _ = PRESAGe._sweep_requests(sweep_spec, sweep_config())
    request = first(items).request
    original = PRESAGe._numerical_request(request)
    variants = Dict{String, Any}[]
    for spec in (
        FunctionSpec(
            "x+x";
            input_format = sweep_spec.input_format,
            output_format = sweep_spec.output_format,
            domain = (-1, 1),
        ),
        FunctionSpec(
            "x";
            input_format = FixedFormat(9, 3),
            output_format = sweep_spec.output_format,
            domain = (-1, 1),
        ),
        FunctionSpec(
            "x";
            input_format = sweep_spec.input_format,
            output_format = FixedFormat(17, 4),
            domain = (-1, 1),
        ),
        FunctionSpec(
            "x";
            input_format = sweep_spec.input_format,
            output_format = sweep_spec.output_format,
            domain = (-1, 0),
        ),
        FunctionSpec(
            "x";
            input_format = sweep_spec.input_format,
            output_format = sweep_spec.output_format,
            domain = (-1, 1),
            absolute_error = 1 // 1024,
        ),
    )
        push!(variants, PRESAGe._numerical_request(merge(request, (; spec))))
    end
    for fields in
        ((; degree = 2), (; segments = 2), (; internal_format = FixedFormat(25, 6)))
        push!(variants, PRESAGe._numerical_request(merge(request, fields)))
    end
    for kwargs in (
        (; evaluation = :fma),
        (; generation_precision = 320),
        (; proof_precision = 320),
        (; accuracy = 1 // 512),
        (; max_refinements = 3),
        (; transformation = :odd),
    )
        config = PolynomialSearchConfig(;
            evaluation = :separate,
            degrees = [1],
            internal_formats = [sweep_format],
            kwargs...,
        )
        push!(variants, PRESAGe._numerical_request(merge(request, (; config))))
    end
    for layout in (
        PolynomialPrecision(
            sweep_format;
            coefficient_formats = fill(sweep_format, 2),
            stage_formats = fill(sweep_format, 2),
        ),
        PolynomialPrecision(
            sweep_format;
            coefficient_formats = fill(FixedFormat(25, 6), 2),
            stage_formats = fill(sweep_format, 2),
        ),
        PolynomialPrecision(
            sweep_format;
            coefficient_formats = fill(sweep_format, 2),
            stage_formats = fill(FixedFormat(25, 6), 2),
        ),
    )
        push!(variants, PRESAGe._numerical_request(merge(request, (; precision = layout))))
    end
    @test all(
        v -> PRESAGe._numerical_digest(v) != PRESAGe._numerical_digest(original),
        variants,
    )
    @test length(unique(PRESAGe._numerical_digest.(variants))) == length(variants)
    identity = PRESAGe._numerical_identity()
    @test identity["source"] == PRESAGe._NUMERICAL_SOURCE_ID
    @test !isempty(identity["libraries"]) && haskey(identity["environment"], "project")
    key = PRESAGe._numerical_digest(Dict("request" => original, "identity" => identity))
    for field in keys(identity)
        changed = deepcopy(identity)
        changed[field] = "changed"
        @test PRESAGe._numerical_digest(
            Dict("request" => original, "identity" => changed),
        ) != key
    end
    mktempdir() do dir
        cache = NumericalCache(dir)
        result = sweep_polynomial(
            sweep_spec,
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [1],
                internal_formats = [sweep_format],
            );
            cache,
        )
        row = only(result.rows)
        @test row.cache_key == key
        path = joinpath(dir, key * ".toml")
        valid = TOML.parsefile(path)
        for damage in (
            d -> d["schema_version"] = 2,
            d -> d["identity"]["source"] = "old source",
            d -> d["request"]["degree"] = 9,
            d -> d["timings"] = Dict(),
            d -> d["payload"]["plan"]["program"]["nodes"][end]["op"] = "Unknown",
            d -> d["payload"]["certificate"]["status"] = "proof_failed",
        )
            bad = deepcopy(valid)
            damage(bad)
            # Even a matching payload checksum cannot authorize bad schemas,
            # graph semantics, proof status or an incompatible request identity.
            bad["checksum"] = PRESAGe._numerical_digest(bad["payload"])
            open(io -> TOML.print(io, bad), path, "w")
            hit, status = PRESAGe._cache_read(cache, key, original, identity)
            @test hit === nothing && status == :invalid
        end
        write(path, "malformed TOML [")
        @test last(PRESAGe._cache_read(cache, key, original, identity)) == :invalid
        open(io -> TOML.print(io, valid), path, "w")
        other = merge(identity, Dict("source" => "new source identity"))
        changed = PRESAGe._sweep_polynomial(
            sweep_spec,
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [1],
                internal_formats = [sweep_format],
            );
            cache,
            cache_identity = () -> other,
        )
        @test only(changed.rows).cache_status == :miss &&
              only(changed.rows).cache_key != key
    end
end

@testset "Sweep failures, Pareto sets and stored stage guards" begin
    spec = FunctionSpec(
        "exp(x)";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(24, 4),
        domain = (-1, 1),
        absolute_error = 1 // 2^18,
    )
    formats = [FixedFormat(18, 6), FixedFormat(32, 6)]
    config = PolynomialSearchConfig(
        degrees = [1, 9],
        internal_formats = formats,
        evaluation = :fma,
    )
    mktempdir() do dir
        cache = NumericalCache(dir)
        result = sweep_polynomial(spec, config; cache, max_parallel = 2)
        @test result.status == :complete && result.mode == :regenerate
        @test [(r.attempt.degree, r.attempt.internal_format) for r in result.rows] == [(d, f) for d in (1, 9) for f in formats]
        @test [r.attempt.status for r in result.rows] == [
            :bound_exceeds_budget,
            :bound_exceeds_budget,
            :bound_exceeds_budget,
            :certified,
        ]
        @test result.pareto_indices == (4,)
        @test length(readdir(dir)) == 1 # Failed proofs never enter the cache.
        base = last(result.rows).attempt.certificate
        p = PRESAGe._stored_precision(base.plan)
        layouts = [
            PolynomialPrecision(
                p.coordinate_format;
                coefficient_formats = p.coefficient_formats,
                stage_formats = fill(f, 10),
            ) for f in formats
        ]
        frozen = PolynomialSearchConfig(
            degrees = [9],
            internal_formats = fill(p.coordinate_format, 2),
            precisions = layouts,
            evaluation = :fma,
        )
        stored = sweep_polynomial(base.plan, frozen; cache, max_parallel = 2)
        @test stored.mode == :stored
        @test [r.attempt.status for r in stored.rows] == [:bound_exceeds_budget, :certified]
        for row in stored.rows
            @test PRESAGe._precision_audit(row.attempt.plan).paths[1].coefficients ==
                  PRESAGe._polynomial_audit(base.plan).coefficients
            @test row.attempt.generation_seconds == 0
        end
        replay = PRESAGe._sweep_polynomial(base.plan, frozen; cache, max_parallel = 2)
        @test [r.cache_status for r in replay.rows] == [:miss, :hit]
        words = [w for w = 0:255 if -1 <= decode_fixed(w, spec.input_format) <= 1]
        @test cpu_check(last(replay.rows).attempt.plan, words; backend = :ac_fixed) ==
              length(words)
        @test all(
            w ->
                evaluate_bits(base.plan, w) ==
                evaluate_bits(last(replay.rows).attempt.plan, w),
            words,
        )
    end
    # Equal rows remain nondominated, and different functions/domains have
    # independent Pareto sets. Concurrent writers publish complete entries.
    mktempdir() do dir
        result = sweep_polynomial(
            [sweep_spec, sweep_spec],
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [1],
                internal_formats = [sweep_format],
            );
            cache = NumericalCache(dir),
            max_parallel = 2,
        )
        @test result.pareto_indices == (1, 2)
        @test [r.spec_index for r in result.rows] == [1, 2]
        @test length(readdir(dir)) == 1
        warm = sweep_polynomial(
            sweep_spec,
            PolynomialSearchConfig(
                evaluation = :separate,
                degrees = [1],
                internal_formats = [sweep_format],
            );
            cache = NumericalCache(dir),
        )
        @test only(warm.rows).cache_status == :hit
    end
end

@testset "Sweep validation, limits and worker recovery" begin
    for inputs in ([], [sweep_spec, PlanArtifact(sweep_spec)], FunctionSpec("x"))
        @test_throws ArgumentError PRESAGe._sweep_polynomial(
            inputs,
            sweep_config();
            process_started = (p, d) -> error("invalid request launched"),
        )
    end
    for parallel in (0, -1, 65, true)
        @test_throws ArgumentError sweep_polynomial(
            sweep_spec,
            sweep_config();
            max_parallel = parallel,
        )
    end
    limited = sweep_polynomial(
        [sweep_spec, sweep_spec],
        PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1, 2],
            internal_formats = [sweep_format],
            max_attempts = 1,
        );
        max_parallel = 2,
    )
    @test limited.status == :sweep_limit && limited.stop_reason == :attempt_limit
    @test length(limited.rows) == 1 && only(limited.rows).spec_index == 1
    expired = sweep_polynomial(
        sweep_spec,
        PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1],
            internal_formats = [sweep_format],
            total_timeout = 1e-300,
        ),
    )
    @test expired.stop_reason == :total_deadline && isempty(expired.rows)
    processes, directories = Base.Process[], String[]
    live_deadline = PRESAGe._sweep_polynomial(
        sweep_spec,
        PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1, 2],
            internal_formats = [sweep_format],
            total_timeout = 0.05,
        );
        max_parallel = 2,
        process_started = (p, d) -> (push!(processes, p); push!(directories, d)),
    )
    @test live_deadline.stop_reason == :total_deadline
    @test all(r -> r.attempt.status == :timeout, live_deadline.rows)
    @test all(process_exited, processes) && all(d -> !isdir(d), directories)
    fixture = joinpath(@__DIR__, "fixtures", "polynomial_worker.jl")
    for mode in ("crash", "timeout", "late_result")
        empty!(processes)
        empty!(directories)
        mktempdir() do dir
            result = PRESAGe._sweep_polynomial(
                sweep_spec,
                PolynomialSearchConfig(
                    evaluation = :separate,
                    degrees = mode == "late_result" ? [1] : [0, 1],
                    internal_formats = [sweep_format],
                    job_timeout = 60,
                    total_timeout = 180,
                );
                cache = NumericalCache(dir),
                max_parallel = 2,
                worker_command = d -> addenv(
                    PRESAGe._polynomial_worker_command(d; script = fixture),
                    "PRESAGE_WORKER_TEST_MODE" => mode,
                ),
                process_started = (p, d) ->
                    (push!(processes, p); push!(directories, d)),
            )
            @test all(process_exited, processes) && all(d -> !isdir(d), directories)
            if mode == "late_result"
                @test only(result.rows).attempt.status == :timeout
                @test only(result.rows).attempt.certificate.status == :certified
                @test isempty(readdir(dir))
            else
                @test [r.attempt.status for r in result.rows] == [mode == "crash" ? :worker_crashed : :timeout, :certified]
                @test length(readdir(dir)) == 1
                @test first(result.rows).attempt.plan !== nothing
            end
        end
    end
    empty!(processes)
    empty!(directories)
    @test_throws CompositeException PRESAGe._sweep_polynomial(
        sweep_spec,
        sweep_config();
        max_parallel = 2,
        process_started = (p, d) -> begin
            push!(processes, p)
            push!(directories, d)
            yield()
            error("controlled parent failure")
        end,
    )
    @test all(process_exited, processes) && all(d -> !isdir(d), directories)
end

@testset "Sweep CLI exact artifacts and public replay" begin
    mktempdir() do dir
        contract, settings, output = joinpath(dir, "contract.toml"),
        joinpath(dir, "search.toml"),
        joinpath(dir, "out")
        write_plan(contract, PlanArtifact(sweep_spec))
        write_search_config(settings, sweep_config())
        args = [
            contract,
            settings,
            output,
            "--cache=$(joinpath(dir, "cache"))",
            "--max-parallel=2",
        ]
        @test sweep_main(args) == 0
        @test sweep_main(args) == 0
        report = TOML.parsefile(joinpath(output, "sweep.toml"))
        @test all(r -> r["cache_status"] == "hit", report["rows"])
        plan = PRESAGe._read_plan(report["rows"][1]["plan"])
        proof = certify_plan(plan)
        @test proof.status == :certified && proof.total_bound == 0
        @test cpu_check(plan, UInt64[0, 1, 31, 224, 255]; backend = :ac_fixed) == 5
        @test_throws ErrorException sweep_main([contract, settings, output, "--unknown=2"])
        @test_throws ErrorException sweep_main([
            contract,
            settings,
            output,
            "--max-parallel=1",
            "--max-parallel=2",
        ])
    end
end

@testset "Floating transformed cache and exact shared banks" begin
    base = certified_polynomial(
        FunctionSpec(
            "acos(x)";
            input_format = IEEE16,
            domain = (-1, 1),
            absolute_error = 1 // 512,
        );
        degree = 9,
        internal_format = FixedFormat(72, 24),
        transformation = :acos,
        evaluation = :fma,
    )
    @test base.status == :certified
    p = base.plan.precision
    narrower = PolynomialPrecision(
        p.coordinate_format;
        coefficient_formats = p.coefficient_formats,
        stage_formats = fill(FixedFormat(68, 24), 10),
    )
    config = PolynomialSearchConfig(
        degrees = [9],
        internal_formats = fill(p.coordinate_format, 2),
        precisions = [p, narrower],
        transformation = :acos,
        evaluation = :fma,
        job_timeout = 120,
        total_timeout = 300,
    )
    words = round_ieee.([-1, -3 // 4, -1 // 2, 0, 1 // 2, 3 // 4, 1], Ref(IEEE16))
    mktempdir() do dir
        cache = NumericalCache(dir)
        cold = sweep_polynomial(base.plan, config; cache, max_parallel = 2)
        @test [r.attempt.status for r in cold.rows] == [:certified, :certified]
        warm = PRESAGe._sweep_polynomial(
            base.plan,
            config;
            cache,
            process_started = (p, d) -> error("transformed cache launched a worker"),
        )
        @test all(r -> r.attempt.status == :certified && r.cache_status == :hit, warm.rows)
        for (a, b) in zip(cold.rows, warm.rows)
            @test PRESAGe._certificate_data(a.attempt.certificate) ==
                  PRESAGe._certificate_data(b.attempt.certificate)
            @test length(b.attempt.certificate.paths) == 7
            @test PRESAGe._inverse_trig_audit(b.attempt.plan).sqrt_coefficients ==
                  PRESAGe._inverse_trig_audit(base.plan).sqrt_coefficients
            @test all(
                w -> evaluate_bits(a.attempt.plan, w) == evaluate_bits(b.attempt.plan, w),
                words,
            )
        end
        @test cpu_check(
            last(warm.rows).attempt.plan,
            words;
            backend = :ac_fixed,
            float_backend = :ac_std_float,
        ) == length(words)
        changed = PolynomialPrecision(
            p.coordinate_format;
            coefficient_formats = fill(FixedFormat(73, 24), 10),
            stage_formats = p.stage_formats,
        )
        @test_throws ArgumentError sweep_polynomial(
            base.plan,
            PolynomialSearchConfig(
                degrees = [9],
                internal_formats = [p.coordinate_format],
                precisions = [changed],
                transformation = :acos,
                evaluation = :fma,
            ),
        )
        @test_throws ArgumentError sweep_polynomial(
            base.plan,
            PolynomialSearchConfig(
                degrees = [9],
                internal_formats = [p.coordinate_format],
                transformation = :acos,
                evaluation = :fma,
            ),
        )
    end
    spec = FunctionSpec(
        "x*x+1/3";
        input_format = FloatFormat(3, 4),
        output_format = FloatFormat(4, 7),
        domain = (-1, 1),
        absolute_error = 1 // 64,
    )
    config = PolynomialSearchConfig(
        degrees = [2],
        internal_formats = [FloatFormat(8, 32)],
        evaluation = :fma,
    )
    mktempdir() do dir
        cache = NumericalCache(dir)
        cold = sweep_polynomial(spec, config; cache)
        warm = PRESAGe._sweep_polynomial(
            spec,
            config;
            cache,
            process_started = (p, d) -> error("floating cache launched a worker"),
        )
        a, b = only(cold.rows), only(warm.rows)
        @test a.attempt.status == :certified && b.cache_status == :hit
        @test PRESAGe._certificate_data(a.attempt.certificate) ==
              PRESAGe._certificate_data(b.attempt.certificate)
        words = UInt64[
            w for w = 0:255 if
            (x = decode_ieee(w, spec.input_format).value) !== nothing && -1 <= x <= 1
        ]
        @test cpu_check(
            b.attempt.plan,
            words;
            backend = :ac_fixed,
            float_backend = :ac_std_float,
            public_api = true,
        ) == length(words)
    end
end

@testset "Loaded-source cache invalidation" begin
    mktempdir() do dir
        root = dirname(dirname(pathof(PRESAGe)))
        cp(joinpath(root, "src"), joinpath(dir, "src"))
        cp(joinpath(root, "Project.toml"), joinpath(dir, "Project.toml"))
        mkpath(joinpath(dir, "scripts"))
        cp(
            joinpath(root, "scripts", "polynomial_worker.jl"),
            joinpath(dir, "scripts", "polynomial_worker.jl"),
        )
        script = joinpath(dir, "check.jl")
        write(
            script,
            """
  using Test
  include(joinpath(@__DIR__, "src", "PRESAGe.jl"))
  @test PRESAGe._numerical_identity()["source"] == PRESAGe._NUMERICAL_SOURCE_ID
  open(joinpath(@__DIR__, "src", "inverse_trig.jl"), "a") do io
      write(io, "\\n# Changed after loading.\\n")
  end
  @test_throws ArgumentError PRESAGe._numerical_identity()
  """,
        )
        command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script`
        @test success(pipeline(command; stdout = devnull, stderr = stderr))
    end
end

@testset "Persistent cache reuse across Julia processes" begin
    mktempdir() do dir
        contract, settings = joinpath(dir, "contract.toml"), joinpath(dir, "config.toml")
        write_plan(contract, PlanArtifact(sweep_spec))
        write_search_config(settings, sweep_config())
        script = joinpath(@__DIR__, "..", "scripts", "sweep.jl")
        command = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $script $contract $settings $(joinpath(dir, "result")) --max-parallel=2 --cache=$(joinpath(dir, "cache"))`
        @test success(pipeline(command; stdout = devnull, stderr = stderr))
        @test success(pipeline(command; stdout = devnull, stderr = stderr))
        data = TOML.parsefile(joinpath(dir, "result", "sweep.toml"))
        @test all(
            r -> r["cache_status"] == "hit" && r["status"] == "certified",
            data["rows"],
        )
    end
end
