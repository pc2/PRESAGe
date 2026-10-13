"""One configured candidate, with its current elapsed time and cache outcome."""
struct PolynomialSweepRow
    index::Int
    spec_index::Int
    attempt::SearchAttempt
    cache_status::Symbol
    cache_key::Union{Nothing, String}
    compute_seconds::Float64
    implementation::Symbol
end
PolynomialSweepRow(index, spec_index, attempt, cache_status, cache_key, compute_seconds) =
    PolynomialSweepRow(
        index,
        spec_index,
        attempt,
        cache_status,
        cache_key,
        compute_seconds,
        :polynomial,
    )

"""One contract's selected row, or an explicit reason no certified design was eligible."""
struct PolynomialSweepSelection
    spec_index::Int
    row_index::Union{Nothing, Int}
    status::Symbol
    reason::String
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
    memory_model::BlockMemoryModel
    max_table_blocks::Union{Nothing, BigInt}
    objective::Symbol
    selections::Tuple{Vararg{PolynomialSweepSelection}}
    resource_model::Union{Nothing, ResourceModel}
    resource_budget::ResourceBudget
    implementations::Tuple{Vararg{Symbol}}
    lut_max_entries::Int
end
PolynomialSweepResult(args::Vararg{Any, 15}) =
    PolynomialSweepResult(args..., (:polynomial,), 65536)

const _SWEEP_PARETO_METRICS = (
    :total_bound,
    :table_blocks,
    :arithmetic_result_bits,
    :operand_bits,
    :stage_bits,
    :comparisons,
    :conversions,
    :table_reads,
)

_sweep_pareto_metrics(model) =
    model === nothing ? _SWEEP_PARETO_METRICS :
    (_SWEEP_PARETO_METRICS..., _RESOURCE_NAMES...)

function _sweep_selection_order(objective, model = nothing)
    arithmetic = (
        :arithmetic_result_bits,
        :operand_bits,
        :stage_bits,
        :comparisons,
        :conversions,
        :table_reads,
    )
    primary =
        objective == :memory ? (:table_blocks, arithmetic...) :
        objective == :arithmetic ? (arithmetic..., :table_blocks) :
        objective == :resources ? (model.priority..., :table_blocks, arithmetic...) :
        (objective, :table_blocks, arithmetic...)
    return (primary..., :total_bound, :table_bits, :coefficient_bits)
end

function _validate_sweep_selection(
    max_table_blocks,
    objective,
    model = nothing,
    resources = ResourceBudget(),
)
    (
        max_table_blocks === nothing ||
        max_table_blocks isa Integer &&
        !(max_table_blocks isa Bool) &&
        max_table_blocks >= 0
    ) || throw(ArgumentError("max_table_blocks must be a nonnegative integer or nothing"))
    objective in (:memory, :arithmetic, :resources, _RESOURCE_NAMES...) ||
        throw(ArgumentError("unknown sweep objective $objective"))
    model !== nothing ||
        (
            objective in (:memory, :arithmetic) &&
            all(name -> getfield(resources, name) === nothing, _RESOURCE_NAMES)
        ) ||
        throw(ArgumentError("resource objectives and budgets require a resource_model"))
    return max_table_blocks === nothing ? nothing : BigInt(max_table_blocks)
end

function _candidate_precision_cost(plan, implementation = :polynomial)
    kernel = get(plan.settings, "kernel", "")
    (kernel == "full_lut" || implementation == :lut) && return (
        arithmetic_result_bits = BigInt(0),
        operand_bits = BigInt(0),
        stage_bits = BigInt(0),
        table_bits = implementation_cost(plan).table_bits,
        coefficient_bits = BigInt(0),
    )
    kernel == "erf_fixed_horner" || return precision_cost(plan)
    layout = _erf_audit(plan)
    p = plan.program
    operations = [
        i for
        (i, n) in enumerate(p.nodes) if n isa Union{IR.Mul, IR.Add, IR.FMA, IR.UIntAdd}
    ]
    return (;
        arithmetic_result_bits = sum(
            (BigInt(_cost_width(IR.format(p, i))) for i in operations);
            init = BigInt(0),
        ),
        operand_bits = sum(
            (
                BigInt(_cost_width(IR.format(p, j))) for i in operations for
                j in IR.refs(p.nodes[i])
            );
            init = BigInt(0),
        ),
        stage_bits = sum(
            (
                BigInt(_cost_width(IR.format(p, i))) for
                i in (layout.initial, (s.result for s in layout.stages)...)
            );
            init = BigInt(0),
        ),
        table_bits = implementation_cost(plan).table_bits,
        coefficient_bits = sum(
            (BigInt(length(t.values)) * _cost_width(t.format) for t in p.tables[2:end]);
            init = BigInt(0),
        ),
    )
end

function _sweep_metrics(row, memory_model, resource_model = nothing)
    result = row.attempt.certificate
    cost = _candidate_precision_cost(result.plan, row.implementation)
    implementation = implementation_cost(result.plan; memory_model)
    metrics = (;
        total_bound = result.total_bound,
        table_blocks = implementation.table_blocks,
        arithmetic_result_bits = cost.arithmetic_result_bits,
        operand_bits = cost.operand_bits,
        stage_bits = cost.stage_bits,
        comparisons = implementation.comparisons,
        conversions = implementation.conversions,
        table_reads = implementation.table_reads,
        table_bits = cost.table_bits,
        coefficient_bits = cost.coefficient_bits,
    )
    resource_model === nothing && return metrics
    estimate = estimate_resources(result.plan; model = resource_model, memory_model)
    return merge(metrics, estimate.totals, (; target_reasons = estimate.support.reasons))
end

function _sweep_resource_requirements(objective, model, budget)
    ranked =
        objective == :resources ? model.priority :
        objective in _RESOURCE_NAMES ? (objective,) : ()
    return unique((
        ranked...,
        (name for name in _RESOURCE_NAMES if getfield(budget, name) !== nothing)...,
    ))
end

function _sweep_eligibility(cost, max_table_blocks, objective, model, budget)
    reasons = String[get(cost, :target_reasons, ())...]
    max_table_blocks === nothing ||
        cost.table_blocks <= max_table_blocks ||
        push!(
            reasons,
            "table allocation $(cost.table_blocks) exceeds block budget $max_table_blocks",
        )
    for name in _sweep_resource_requirements(objective, model, budget)
        value, limit = getfield(cost, name), getfield(budget, name)
        if value === nothing
            push!(reasons, "$name estimate is unknown")
        elseif limit !== nothing && value > limit
            push!(reasons, "$name estimate $value exceeds budget $limit")
        end
    end
    return reasons
end

function _sweep_needs_calibration(cost, max_table_blocks, objective, model, budget)
    isempty(get(cost, :target_reasons, ())) || return false
    max_table_blocks === nothing || cost.table_blocks <= max_table_blocks || return false
    required = _sweep_resource_requirements(objective, model, budget)
    for name in required
        value, limit = getfield(cost, name), getfield(budget, name)
        value !== nothing && limit !== nothing && value > limit && return false
    end
    return any(name -> getfield(cost, name) === nothing, required)
end

function _sweep_choices(
    rows,
    spec_count,
    memory_model,
    max_table_blocks,
    objective,
    resource_model = nothing,
    resource_budget = ResourceBudget(),
)
    passing = [i for (i, r) in enumerate(rows) if r.attempt.status == :certified]
    metrics =
        Dict(i => _sweep_metrics(rows[i], memory_model, resource_model) for i in passing)
    reasons = Dict(
        i => _sweep_eligibility(
            metrics[i],
            max_table_blocks,
            objective,
            resource_model,
            resource_budget,
        ) for i in passing
    )
    eligible = filter(i -> isempty(reasons[i]), passing)
    pareto_metrics = _sweep_pareto_metrics(resource_model)
    pareto = Tuple(
        rows[i].index for i in eligible if !any(eligible) do j
            rows[j].spec_index == rows[i].spec_index &&
                all(
                    k ->
                        metrics[j][k] !== nothing &&
                            metrics[i][k] !== nothing &&
                            metrics[j][k] <= metrics[i][k],
                    pareto_metrics,
                ) &&
                any(k -> metrics[j][k] < metrics[i][k], pareto_metrics)
        end
    )
    order = _sweep_selection_order(objective, resource_model)
    selections = Tuple(
        map(1:spec_count) do spec_index
            unresolved = filter(passing) do i
                rows[i].spec_index == spec_index && _sweep_needs_calibration(
                    metrics[i],
                    max_table_blocks,
                    objective,
                    resource_model,
                    resource_budget,
                )
            end
            if !isempty(unresolved)
                indices = join([rows[i].index for i in unresolved], ", ")
                return PolynomialSweepSelection(
                    spec_index,
                    nothing,
                    :resource_model_incomplete,
                    "Resource comparison needs synthesis or calibration for certified rows $indices with unknown required estimates.",
                )
            end
            choices = filter(i -> rows[i].spec_index == spec_index, eligible)
            if isempty(choices)
                certified = count(i -> rows[i].spec_index == spec_index, passing)
                if certified == 0
                    candidates = [r for r in rows if r.spec_index == spec_index]
                    if !isempty(candidates) &&
                       all(r -> r.attempt.status == :target_unsupported, candidates)
                        return PolynomialSweepSelection(
                            spec_index,
                            nothing,
                            :target_unsupported,
                            join(unique([r.attempt.reason for r in candidates]), ", "),
                        )
                    end
                    return PolynomialSweepSelection(
                        spec_index,
                        nothing,
                        :no_certified_candidate,
                        "No certified candidate among the completed rows for this contract",
                    )
                end
                rejected = [i for i in passing if rows[i].spec_index == spec_index]
                if all(
                    i ->
                        max_table_blocks !== nothing &&
                            metrics[i].table_blocks > max_table_blocks,
                    rejected,
                )
                    return PolynomialSweepSelection(
                        spec_index,
                        nothing,
                        :memory_budget_exceeded,
                        "All $certified certified candidates exceed the $max_table_blocks modeled table-block budget",
                    )
                end
                unsupported =
                    any(i -> !isempty(get(metrics[i], :target_reasons, ())), rejected)
                status = unsupported ? :target_unsupported : :resource_budget_exceeded
                detail = join(unique(vcat([reasons[i] for i in rejected]...)), "; ")
                return PolynomialSweepSelection(
                    spec_index,
                    nothing,
                    status,
                    "No eligible candidate among $certified certified rows: $detail",
                )
            end
            key(i) = (Tuple(metrics[i][k] for k in order)..., rows[i].index)
            chosen = first(sort(choices; by = key))
            cost = metrics[chosen]
            resources =
                resource_model === nothing ? "" :
                "; " * join(
                    [
                        "$name=$(cost[name] === nothing ? "unknown" : cost[name])" for
                        name in _RESOURCE_NAMES
                    ],
                    ", ",
                )
            PolynomialSweepSelection(
                spec_index,
                rows[chosen].index,
                :selected,
                "Selected row $(rows[chosen].index) from $(length(choices)) eligible certified candidates using $objective priority; $(cost.table_blocks) modeled table blocks, $(cost.arithmetic_result_bits) arithmetic result bits, $(cost.comparisons) comparisons$resources; exact ties use request order",
            )
        end,
    )
    return pareto, selections
end

"""
    select_sweep(result; memory_model=result.memory_model,
        max_table_blocks=result.max_table_blocks, objective=result.objective,
        resource_model=result.resource_model, resource_budget=result.resource_budget)

Recompute Pareto membership and one selection per contract from existing
certified rows, without numerical workers or new proofs. `:memory` prioritizes
modeled blocks; `:arithmetic` prioritizes declared arithmetic widths. The exact
lexicographic order is recorded in reports. Exclude over-budget rows from both
selection and Pareto membership while retaining their certificates in the result.
"""
function select_sweep(
    result::PolynomialSweepResult;
    memory_model::BlockMemoryModel = result.memory_model,
    max_table_blocks = result.max_table_blocks,
    objective::Symbol = result.objective,
    resource_model::Union{Nothing, ResourceModel} = result.resource_model,
    resource_budget::ResourceBudget = result.resource_budget,
)
    budget = _validate_sweep_selection(
        max_table_blocks,
        objective,
        resource_model,
        resource_budget,
    )
    pareto, selections = _sweep_choices(
        result.rows,
        length(result.specs),
        memory_model,
        budget,
        objective,
        resource_model,
        resource_budget,
    )
    return PolynomialSweepResult(
        result.specs,
        result.config,
        result.mode,
        result.status,
        result.rows,
        pareto,
        result.elapsed_seconds,
        result.stop_reason,
        result.max_parallel,
        memory_model,
        budget,
        objective,
        selections,
        resource_model,
        resource_budget,
        result.implementations,
        result.lut_max_entries,
    )
end

function _sweep_requests(
    inputs,
    config;
    implementations = (:polynomial,),
    lut_max_entries = 65536,
    allow_unsupported = false,
    target = nothing,
)
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
    :polynomial in implementations ||
        stored === nothing ||
        throw(ArgumentError("stored stage sweeps require the polynomial implementation"))
    preflight = map(specs) do spec
        :polynomial in implementations || return (; domain = nothing, reason = nothing)
        try
            return (; domain = _validate_search_request(spec, config), reason = nothing)
        catch err
            allow_unsupported && err isa ArgumentError || rethrow()
            return (; domain = nothing, reason = sprint(showerror, err))
        end
    end
    domains = [item.domain for item in preflight]
    if stored !== nothing
        base = _stored_precision(stored)
        degree =
            config.transformation in (:odd, :atan) ? 2length(base.coefficient_formats) - 1 :
            length(base.coefficient_formats) - 1
        config.degrees == (degree,) &&
            config.segments == (max(1, length(stored.segments)),) &&
            string(config.transformation) ==
            get(stored.settings, "transformation", "none") &&
            (
                config.evaluation == :auto ||
                string(config.evaluation) == stored.settings["evaluation"]
            ) || throw(
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
    arithmetic =
        stored === nothing ? _evaluation_configs(config) :
        (_evaluation_config(config, Symbol(stored.settings["evaluation"])),)
    configurations(degree, format, precision) =
        _evaluation_configs(arithmetic, degree, format, precision, target)
    polynomial_count =
        BigInt(length(config.segments)) * sum(
            length(configurations(degree, format, precision)) for degree in config.degrees
            for (format, precision) in zip(config.internal_formats, config.precisions)
        )
    count = sum(
        (
            implementation == :polynomial ? polynomial_count :
            Int(_lut_availability(spec, lut_max_entries).available) for spec in specs
            for implementation in implementations
        );
        init = BigInt(0),
    )
    requests = NamedTuple[]
    for (i, spec) in enumerate(specs), implementation in implementations
        length(requests) >= config.max_attempts && break
        if implementation == :lut
            _lut_availability(spec, lut_max_entries).available || continue
            request = (;
                spec,
                config,
                implementation,
                lut_max_entries,
                degree = 0,
                internal_format = spec.output_format,
                segments = 1,
                precision = nothing,
            )
            push!(requests, (; spec_index = i, request))
            continue
        end
        for segments in config.segments,
            degree in config.degrees,
            (format, precision) in zip(config.internal_formats, config.precisions),
            candidate in configurations(degree, format, precision)

            length(requests) >= config.max_attempts && break
            request = (;
                spec,
                config = candidate,
                domain = domains[i],
                degree,
                internal_format = format,
                segments,
                precision,
            )
            preflight[i].reason === nothing ||
                (request = merge(request, (; unsupported_reason = preflight[i].reason)))
            stored === nothing ||
                (request = merge(request, (; stored_plan = _plan_data(stored))))
            push!(requests, (; spec_index = i, request))
        end
    end
    return specs, requests, count, stored === nothing ? :regenerate : :stored
end

function _sweep_job(
    item,
    index,
    started,
    cache,
    identity;
    target = nothing,
    worker_command,
    process_started,
    cancelled,
)
    request = item.request
    implementation = get(request, :implementation, :polynomial)
    reason = _target_candidate_reason(request, target)
    if reason !== nothing
        attempt = SearchAttempt(
            request.degree,
            request.internal_format,
            request.segments,
            request.precision,
            :target_unsupported,
            0.0,
            nothing,
            nothing,
            reason;
            evaluation = _request_evaluation(request),
        )
        return PolynomialSweepRow(
            index,
            item.spec_index,
            attempt,
            :disabled,
            nothing,
            0.0,
            implementation,
        )
    end
    # LUT proofs do not use the polynomial cache audit. Keep cache semantics
    # unchanged until table regeneration is an observed bottleneck.
    implementation == :lut && (cache = nothing)
    job_started = time_ns()
    request_data = cache === nothing ? nothing : _numerical_request(request)
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
            attempt.proof_seconds;
            evaluation = attempt.evaluation,
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
        attempt.proof_seconds;
        evaluation = attempt.evaluation,
    )
    PolynomialSweepRow(
        index,
        item.spec_index,
        attempt,
        cache_status,
        key,
        compute_seconds,
        implementation,
    )
end

"""
    sweep_polynomial(spec_or_specs_or_plan, config; max_parallel=1, cache=nothing,
        memory_model=BlockMemoryModel(), max_table_blocks=nothing,
        objective=resource_model === nothing ? :memory : :resources)

Evaluate every candidate in spec/segment/degree/format order, up to the global
`config.max_attempts` and `total_timeout`. Run at most `max_parallel` owned Julia
workers concurrently; job limits include startup. Preserve failures and order
regardless of completion order. `status=:complete` means all choices were visited,
not that every candidate passed. Pareto indices compare eligible certified rows
within each spec using total error, modeled blocks, declared arithmetic widths
and static comparison/conversion/table-read counts. Select one candidate per
contract under the optional table-block budget, using an explicit lexicographic
memory, arithmetic or resource priority. Resource limits/ranking require known
estimates from an editable profile. Costs remain assumptions pending synthesis.

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
    resource_model::Union{Nothing, ResourceModel} = nothing,
    resource_budget::ResourceBudget = ResourceBudget(),
    memory_model::BlockMemoryModel = resource_model === nothing ? BlockMemoryModel() :
                                     resource_model.memory,
    max_table_blocks = nothing,
    objective::Symbol = resource_model === nothing ? :memory : :resources,
    target::Union{Nothing, TargetProfile} = nothing,
) = _sweep_polynomial(
    inputs,
    config;
    max_parallel,
    cache,
    memory_model,
    resource_model,
    resource_budget,
    max_table_blocks,
    objective,
    target,
)

"""
    sweep_implementations(spec_or_specs, config; implementations=(:lut, :polynomial),
        lut_max_entries=65536, resource_model=nothing, objective=:resources, kwargs...)

Compare full LUTs and every configured polynomial candidate using the same
certification, resource budgets, Pareto metrics and deterministic selection.
Accept small fixed/custom floating inputs and arbitrary supported outputs.
LUT availability is checked before allocation and recorded in the report;
wide inputs retain polynomial planning. Both kinds share worker deadlines and
attempt limits. Stored stage sweeps remain available through `sweep_polynomial`.
Without a resource profile the default objective is modeled memory blocks.
Returns the shared `PolynomialSweepResult` report/artifact interface.
"""
function sweep_implementations(
    inputs,
    config::PolynomialSearchConfig;
    implementations = (:lut, :polynomial),
    lut_max_entries::Integer = 65536,
    resource_model::Union{Nothing, ResourceModel} = nothing,
    objective::Symbol = resource_model === nothing ? :memory : :resources,
    kwargs...,
)
    inputs isa PlanArtifact &&
        throw(ArgumentError("implementation sweeps require function contracts"))
    choices = Tuple(implementations)
    !isempty(choices) &&
        length(unique(choices)) == length(choices) &&
        all(x -> x in (:lut, :polynomial), choices) ||
        throw(ArgumentError("implementations must contain distinct lut/polynomial choices"))
    limit = _lut_entry_limit(lut_max_entries)
    return _sweep_polynomial(
        inputs,
        config;
        implementations = choices,
        lut_max_entries = limit,
        implementation_sweep = true,
        resource_model,
        objective,
        kwargs...,
    )
end

function _sweep_polynomial(
    inputs,
    config;
    max_parallel::Integer = 1,
    cache = nothing,
    resource_model::Union{Nothing, ResourceModel} = nothing,
    resource_budget::ResourceBudget = ResourceBudget(),
    target::Union{Nothing, TargetProfile} = nothing,
    memory_model::BlockMemoryModel = resource_model === nothing ? BlockMemoryModel() :
                                     resource_model.memory,
    max_table_blocks = nothing,
    objective::Symbol = :memory,
    worker_command = _polynomial_worker_command,
    process_started = (process, directory) -> nothing,
    cache_identity = _numerical_identity,
    implementations = (:polynomial,),
    lut_max_entries = 65536,
    implementation_sweep = false,
)
    if resource_model !== nothing && resource_model.toolchain != :generic
        target === nothing ||
            target.toolchain == resource_model.toolchain ||
            throw(ArgumentError("target does not match the resource model"))
        target = TargetProfile(resource_model.toolchain)
    end
    !(max_parallel isa Bool) && 1 <= max_parallel <= 64 ||
        throw(ArgumentError("max_parallel must be an integer in 1:64"))
    budget = _validate_sweep_selection(
        max_table_blocks,
        objective,
        resource_model,
        resource_budget,
    )
    specs, requests, count, mode = _sweep_requests(
        inputs,
        config;
        implementations,
        lut_max_entries,
        allow_unsupported = implementation_sweep,
        target,
    )
    implementation_sweep && (mode = :implementations)
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
                        target,
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
    pareto, selections = _sweep_choices(
        rows,
        length(specs),
        memory_model,
        budget,
        objective,
        resource_model,
        resource_budget,
    )
    PolynomialSweepResult(
        specs,
        config,
        mode,
        reason == :choices_exhausted ? :complete : :sweep_limit,
        rows,
        pareto,
        _elapsed(started),
        reason,
        Int(max_parallel),
        memory_model,
        budget,
        objective,
        selections,
        resource_model,
        resource_budget,
        Tuple(implementations),
        Int(lut_max_entries),
    )
end

# TOML integers are signed 64-bit; retain larger modeled counts as decimal text.
_sweep_integer_data(value::Integer) =
    typemin(Int64) <= value <= typemax(Int64) ? Int64(value) : string(value)
_sweep_integer_data(value::Rational) = _resource_number_data(value)

_sweep_selection_paths(selection) = (
    plan = "selected/$(selection.spec_index)/plan.toml",
    certificate = "selected/$(selection.spec_index)/certificate.toml",
)

function _sweep_data(result; observations = Dict())
    all(i -> i in (r.index for r in result.rows), keys(observations)) ||
        throw(ArgumentError("observation index is not a sweep row"))
    data = Dict{String, Any}(
        "schema" => "presage-polynomial-sweep",
        "schema_version" =>
            result.mode == :implementations ? 5 : result.resource_model === nothing ? 3 : 4,
        "status" => string(result.status),
        "stop_reason" => string(result.stop_reason),
        "mode" => string(result.mode),
        "specs" => [_spec_data(s) for s in result.specs],
        "config" => _search_config_data(result.config),
        "max_parallel" => result.max_parallel,
        "elapsed_seconds" => result.elapsed_seconds,
        "pareto_indices" => collect(result.pareto_indices),
        "pareto_metrics" =>
            string.(collect(_sweep_pareto_metrics(result.resource_model))),
        "memory_model" => Dict(
            "depth" => result.memory_model.depth,
            "word_bits" => result.memory_model.word_bits,
        ),
        "selection_policy" => Dict{String, Any}(
            "objective" => string(result.objective),
            "order" => [
                string.(_sweep_selection_order(result.objective, result.resource_model))...,
                "request_index",
            ],
        ),
    )
    if result.mode == :implementations
        data["implementations"] = string.(collect(result.implementations))
        data["lut_max_entries"] = result.lut_max_entries
        data["lut_availability"] = [
            Dict(
                "spec_index" => i,
                "available" => availability.available,
                "reason" => availability.reason,
            ) for (i, spec) in enumerate(result.specs) for
            availability in (_lut_availability(spec, result.lut_max_entries),)
        ]
    end
    if result.resource_model !== nothing
        data["resource_model"] = _resource_model_data(result.resource_model)
        data["selection_policy"]["resource_budget"] =
            _resource_budget_data(result.resource_budget)
    end
    result.max_table_blocks === nothing || (
        data["selection_policy"]["max_table_blocks"] =
            _sweep_integer_data(result.max_table_blocks)
    )
    data["selections"] = map(collect(result.selections)) do selection
        d = Dict{String, Any}(
            "spec_index" => selection.spec_index,
            "status" => string(selection.status),
            "reason" => selection.reason,
        )
        if selection.row_index !== nothing
            d["row_index"] = selection.row_index
            paths = _sweep_selection_paths(selection)
            d["plan_path"], d["certificate_path"] = paths.plan, paths.certificate
        end
        d
    end
    data["rows"] = map(collect(result.rows)) do row
        a = row.attempt
        d = Dict{String, Any}(
            "index" => row.index,
            "spec_index" => row.spec_index,
            "implementation" => string(row.implementation),
            "degree" => a.degree,
            "segments" => a.segments,
            "internal_format" => _format_data(a.internal_format),
            "status" => string(a.status),
            "reason" => a.reason,
            "elapsed_seconds" => a.elapsed_seconds,
            "compute_seconds" => row.compute_seconds,
            "cache_status" => string(row.cache_status),
            "selection_eligible" => false,
        )
        row.cache_key === nothing || (d["cache_key"] = row.cache_key)
        a.evaluation === nothing || (d["evaluation"] = string(a.evaluation))
        a.precision === nothing || (d["precision"] = _precision_data(a.precision))
        a.generation_seconds === nothing ||
            (d["generation_seconds"] = a.generation_seconds)
        a.proof_seconds === nothing || (d["proof_seconds"] = a.proof_seconds)
        if a.plan !== nothing
            d["plan"] = _plan_data(a.plan)
            if a.plan.program !== nothing
                if result.resource_model !== nothing
                    d["resources"] = _resource_estimate_data(
                        estimate_resources(
                            a.plan;
                            model = result.resource_model,
                            memory_model = result.memory_model,
                        ),
                    )
                end
                d["operations"] = Dict(
                    string(k) => _sweep_integer_data(v) for (k, v) in pairs(
                        implementation_cost(a.plan; memory_model = result.memory_model),
                    )
                )
                # Interrupted/malformed candidates may not have auditable widths.
                try
                    row.implementation == :lut ||
                        (d["precision_cost"] = _precision_cost_data(a.plan))
                catch err
                    err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
                end
            end
        end
        if a.status == :certified
            cost = _sweep_metrics(row, result.memory_model, result.resource_model)
            d["selection_cost"] = Dict(
                string(k) =>
                    v === nothing ? "unknown" :
                    k == :total_bound ? _rational_text(v) : _sweep_integer_data(v)
                for (k, v) in pairs(cost) if k != :target_reasons
            )
            reasons = _sweep_eligibility(
                cost,
                result.max_table_blocks,
                result.objective,
                result.resource_model,
                result.resource_budget,
            )
            d["selection_eligible"] = isempty(reasons)
            isempty(reasons) || (d["selection_reasons"] = reasons)
        end
        a.certificate === nothing ||
            (d["certificate"] = _certificate_data(a.certificate))
        haskey(observations, row.index) && (d["sampled"] = observations[row.index])
        d
    end
    data
end

"""Write every candidate, exact artifacts, assumed memory model, Pareto set and selections."""
write_sweep_report(io::IO, result::PolynomialSweepResult; observations = Dict()) =
    TOML.print(io, _sweep_data(result; observations); sorted = true)
write_sweep_report(path::AbstractString, result::PolynomialSweepResult; kwargs...) =
    open(io -> write_sweep_report(io, result; kwargs...), path, "w")
