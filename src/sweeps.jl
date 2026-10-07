"""One configured candidate, with its current elapsed time and cache outcome."""
struct PolynomialSweepRow
    index::Int
    spec_index::Int
    attempt::SearchAttempt
    cache_status::Symbol
    cache_key::Union{Nothing, String}
    compute_seconds::Float64
end

"""All completed/started candidates in request order; Pareto indices refer to rows."""
struct PolynomialSweepResult
    specs::Tuple{Vararg{FunctionSpec}}
    config::PolynomialSearchConfig
    mode::Symbol
    status::Symbol
    rows::Tuple{Vararg{PolynomialSweepRow}}
    pareto_indices::Tuple{Vararg{Int}}
    elapsed_seconds::Float64
    stop_reason::Symbol
    max_parallel::Int
end

function _sweep_metrics(row)
    result = row.attempt.certificate
    cost = precision_cost(result.plan)
    (
        result.total_bound,
        cost.coefficient_bits,
        cost.stage_bits,
        cost.arithmetic_result_bits,
        cost.table_bits,
    )
end

function _sweep_pareto(rows)
    passing = [i for (i, r) in enumerate(rows) if r.attempt.status == :certified]
    metrics = Dict(i => _sweep_metrics(rows[i]) for i in passing)
    Tuple(
        i for i in passing if !any(passing) do j
            rows[j].spec_index == rows[i].spec_index &&
                all(metrics[j] .<= metrics[i]) &&
                any(metrics[j] .< metrics[i])
        end
    )
end

function _sweep_requests(inputs, config)
    inputs isa Union{FunctionSpec, PlanArtifact} && (inputs = (inputs,))
    inputs isa Union{Tuple, AbstractVector} &&
            !isempty(inputs) && all(x -> x isa FunctionSpec, inputs) ||
        inputs isa Tuple{PlanArtifact} ||
        throw(
            ArgumentError(
                "sweep requires a spec, a nonempty spec list, or one stored plan",
            ),
        )
    stored = first(inputs) isa PlanArtifact ? _read_plan(_plan_data(only(inputs))) : nothing
    specs = stored === nothing ? Tuple(inputs) : (stored.spec,)
    domains = [_validate_search_request(spec, config) for spec in specs]
    if stored !== nothing
        base = _stored_precision(stored)
        degree =
            config.transformation in (:odd, :atan) ? 2length(base.coefficient_formats) - 1 :
            length(base.coefficient_formats) - 1
        config.degrees == (degree,) &&
            config.segments == (max(1, length(stored.segments)),) &&
            string(config.transformation) ==
            get(stored.settings, "transformation", "none") &&
            string(config.evaluation) == stored.settings["evaluation"] || throw(
            ArgumentError(
                "stored sweep must preserve degree, segments, transformation and evaluation",
            ),
        )
        for precision in config.precisions
            precision !== nothing &&
                precision.coordinate_format == base.coordinate_format &&
                precision.coefficient_formats == base.coefficient_formats || throw(
                ArgumentError(
                    "stored sweep requires explicit layouts preserving coordinates and coefficient storage",
                ),
            )
        end
    end
    # Cap allocation before materializing a possibly huge Cartesian product.
    count =
        BigInt(length(specs)) *
        length(config.segments) *
        length(config.degrees) *
        length(config.internal_formats)
    requests = NamedTuple[]
    for (i, spec) in enumerate(specs),
        segments in config.segments,
        degree in config.degrees,
        (format, precision) in zip(config.internal_formats, config.precisions)

        length(requests) >= config.max_attempts && break
        request = (;
            spec,
            config,
            domain = domains[i],
            degree,
            internal_format = format,
            segments,
            precision,
        )
        stored === nothing ||
            (request = merge(request, (; stored_plan = _plan_data(stored))))
        push!(requests, (; spec_index = i, request))
    end
    return specs, requests, count, stored === nothing ? :regenerate : :stored
end

function _sweep_job(
    item,
    index,
    started,
    cache,
    identity;
    worker_command,
    process_started,
    cancelled,
)
    request = item.request
    job_started = time_ns()
    request_data = _numerical_request(request)
    key =
        cache === nothing ? nothing :
        _numerical_digest(Dict("request" => request_data, "identity" => identity))
    cached, cache_status =
        cache === nothing ? (nothing, :disabled) :
        _cache_read(cache, key, request_data, identity)
    if cached === nothing
        attempt, _ = _run_polynomial_job(
            request,
            started;
            worker_command,
            process_started,
            job_started,
            cancelled,
        )
        compute_seconds = attempt.elapsed_seconds
    else
        result, timings = cached
        compute_seconds = timings["compute_seconds"]
        attempt = SearchAttempt(
            request.degree,
            request.internal_format,
            request.segments,
            request.precision,
            :certified,
            _elapsed(job_started),
            result.plan,
            result,
            result.reason,
            get(timings, "generation_seconds", nothing),
            get(timings, "proof_seconds", nothing),
        )
    end
    on_time() =
        !cancelled() &&
        _search_remaining(started, request.config.total_timeout) > 0 &&
        _search_remaining(job_started, request.config.job_timeout) > 0
    if on_time() && cache !== nothing && cached === nothing && attempt.status == :certified
        _cache_write(cache, key, request_data, identity, attempt; publish = on_time)
    end
    if !on_time() && attempt.status == :certified
        attempt = SearchAttempt(
            attempt.degree,
            attempt.internal_format,
            attempt.segments,
            attempt.precision,
            :timeout,
            _elapsed(job_started),
            attempt.plan,
            attempt.certificate,
            "Sweep deadline expired before accepting the result",
            attempt.generation_seconds,
            attempt.proof_seconds,
        )
    end
    attempt = SearchAttempt(
        attempt.degree,
        attempt.internal_format,
        attempt.segments,
        attempt.precision,
        attempt.status,
        _elapsed(job_started),
        attempt.plan,
        attempt.certificate,
        attempt.reason,
        attempt.generation_seconds,
        attempt.proof_seconds,
    )
    PolynomialSweepRow(index, item.spec_index, attempt, cache_status, key, compute_seconds)
end

"""
    sweep_polynomial(spec_or_specs_or_plan, config; max_parallel=1, cache=nothing)

Evaluate every candidate in spec/segment/degree/format order, up to the global
`config.max_attempts` and `total_timeout`. Run at most `max_parallel` owned Julia
workers concurrently; job limits include startup. Preserve failures and order
regardless of completion order. `status=:complete` means all choices were visited,
not that every candidate passed. Pareto indices compare certified rows within
each spec using total error and declared coefficient/stage/arithmetic/table bits.

A stored plan requires explicit layouts with unchanged coordinates and coefficient
storage, plus matching degree/segments/transformation/evaluation. Only stage widths
vary; exact coefficients are replayed and the whole evaluator is recertified.
Cache only on-time passing results. Hits audit exact artifacts without rerunning
native proofs; changed numerical requests, source/dependencies/libraries invalidate
reuse. Cache files are trusted local artifacts, not imported proof credentials.
"""
sweep_polynomial(
    inputs,
    config::PolynomialSearchConfig;
    max_parallel::Integer = 1,
    cache::Union{Nothing, NumericalCache} = nothing,
) = _sweep_polynomial(inputs, config; max_parallel, cache)

function _sweep_polynomial(
    inputs,
    config;
    max_parallel::Integer = 1,
    cache = nothing,
    worker_command = _polynomial_worker_command,
    process_started = (process, directory) -> nothing,
    cache_identity = _numerical_identity,
)
    !(max_parallel isa Bool) && 1 <= max_parallel <= 64 ||
        throw(ArgumentError("max_parallel must be an integer in 1:64"))
    specs, requests, count, mode = _sweep_requests(inputs, config)
    started = time_ns()
    identity = cache === nothing ? nothing : cache_identity()
    # Pin the resolved library so workers and the cache identity agree even if
    # this process loaded Sollya before an environment-variable change.
    command =
        cache === nothing ? worker_command :
        directory ->
            addenv(worker_command(directory), "SOLLYA_LIBRARY" => Sollya.library_path())
    results = Vector{Union{Nothing, PolynomialSweepRow}}(nothing, length(requests))
    next_index = 1
    aborted = false
    tasks = Task[]
    # Cooperative tasks supervise separate processes; no parent-native calls run
    # concurrently. @sync also reaps sibling workers before propagating an error.
    try
        @sync for _ = 1:min(Int(max_parallel), length(requests))
            task = @async try
                while !aborted &&
                          next_index <= length(requests) &&
                          _search_remaining(started, config.total_timeout) > 0
                    i = next_index
                    next_index += 1
                    results[i] = _sweep_job(
                        requests[i],
                        i,
                        started,
                        cache,
                        identity;
                        worker_command = command,
                        process_started,
                        cancelled = () -> aborted,
                    )
                end
            catch
                aborted = true
                rethrow()
            end
            push!(tasks, task)
        end
    catch
        aborted = true
        for task in tasks
            try
                wait(task)
            catch
                # Preserve the original parent error after every worker is reaped.
            end
        end
        rethrow()
    end
    rows = Tuple(r for r in results if r !== nothing)
    reason =
        _search_remaining(started, config.total_timeout) <= 0 ? :total_deadline :
        BigInt(length(rows)) < count ? :attempt_limit : :choices_exhausted
    PolynomialSweepResult(
        specs,
        config,
        mode,
        reason == :choices_exhausted ? :complete : :sweep_limit,
        rows,
        _sweep_pareto(rows),
        _elapsed(started),
        reason,
        Int(max_parallel),
    )
end

function _sweep_data(result)
    data = Dict{String, Any}(
        "schema" => "presage-polynomial-sweep",
        "schema_version" => 1,
        "status" => string(result.status),
        "stop_reason" => string(result.stop_reason),
        "mode" => string(result.mode),
        "specs" => [_spec_data(s) for s in result.specs],
        "config" => _search_config_data(result.config),
        "max_parallel" => result.max_parallel,
        "elapsed_seconds" => result.elapsed_seconds,
        "pareto_indices" => collect(result.pareto_indices),
        "pareto_metrics" => [
            "total_bound",
            "coefficient_bits",
            "stage_bits",
            "arithmetic_result_bits",
            "table_bits",
        ],
    )
    data["rows"] = map(collect(result.rows)) do row
        a = row.attempt
        d = Dict{String, Any}(
            "index" => row.index,
            "spec_index" => row.spec_index,
            "degree" => a.degree,
            "segments" => a.segments,
            "internal_format" => _format_data(a.internal_format),
            "status" => string(a.status),
            "reason" => a.reason,
            "elapsed_seconds" => a.elapsed_seconds,
            "compute_seconds" => row.compute_seconds,
            "cache_status" => string(row.cache_status),
        )
        row.cache_key === nothing || (d["cache_key"] = row.cache_key)
        a.precision === nothing || (d["precision"] = _precision_data(a.precision))
        a.generation_seconds === nothing ||
            (d["generation_seconds"] = a.generation_seconds)
        a.proof_seconds === nothing || (d["proof_seconds"] = a.proof_seconds)
        if a.plan !== nothing
            d["plan"] = _plan_data(a.plan)
            if a.plan.program !== nothing
                d["operations"] = Dict(
                    string(k) => v for (k, v) in pairs(implementation_cost(a.plan))
                )
                # Interrupted/malformed candidates may not have auditable widths.
                try
                    d["precision_cost"] = _precision_cost_data(a.plan)
                catch err
                    err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
                end
            end
        end
        a.certificate === nothing ||
            (d["certificate"] = _certificate_data(a.certificate))
        d
    end
    data
end

"""Write every candidate, exact artifacts, error contributions and structural Pareto set."""
write_sweep_report(io::IO, result::PolynomialSweepResult) =
    TOML.print(io, _sweep_data(result); sorted = true)
write_sweep_report(path::AbstractString, result::PolynomialSweepResult) =
    open(io -> write_sweep_report(io, result), path, "w")
