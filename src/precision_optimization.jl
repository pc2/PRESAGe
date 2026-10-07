"""
    precision_cost(plan)

Declared coefficient storage and Horner widths for an audited polynomial.
Stage widths include the initial coefficient load. Arithmetic/operand sums count
static IR operations, including coordinate formation; these are structural counts,
not FPGA resource or timing estimates.
"""
function precision_cost(plan::PlanArtifact)
    precision = _stored_precision(plan)
    p = plan.program
    rows =
        get(plan.settings, "transformation", "none") == "erfc" ? 3 :
        get(plan.settings, "transformation", "none") in ("sinh", "cosh", "sin", "cos") ? 2 :
        max(1, length(plan.segments))
    evaluations =
        get(plan.settings, "transformation", "none") in ("sinh", "cosh", "erfc") ? 3 :
        get(plan.settings, "transformation", "none") in ("sin", "cos") ? 2 : 1
    operations = [n for n in p.nodes if n isa Union{IR.Mul, IR.Add, IR.FMA}]
    operand_widths = [[_width(IR.format(p, i)) for i in IR.refs(n)] for n in operations]
    return (;
        coefficient_bits = BigInt(rows) *
                           sum(BigInt(_width(f)) for f in precision.coefficient_formats),
        coefficient_widths = [_width(f) for f in precision.coefficient_formats],
        stage_widths = [_width(f) for f in precision.stage_formats],
        stage_bits = BigInt(evaluations) *
                     sum(BigInt(_width(f)) for f in precision.stage_formats),
        arithmetic_result_bits = sum(
            (BigInt(_width(n.format)) for n in operations);
            init = BigInt(0),
        ),
        operand_bits = sum(
            (sum(BigInt.(widths)) for widths in operand_widths);
            init = BigInt(0),
        ),
        operand_widths,
        table_bits = implementation_cost(plan).table_bits,
        conversions = implementation_cost(plan).conversions,
    )
end

"""A proposed format change and its complete supervised generation/proof result."""
struct PrecisionAttempt
    kind::Symbol
    index::Union{Nothing, Int}
    before::Union{Nothing, PolynomialFormat}
    after::Union{Nothing, PolynomialFormat}
    estimated_error::Rational{BigInt}
    accepted::Bool
    result::SearchAttempt
end

"""Best fresh certificate found within the precision search limits."""
struct PrecisionOptimizationResult
    baseline::PlanArtifact
    status::Symbol
    selected::Union{Nothing, CertificationResult}
    attempts::Tuple{Vararg{PrecisionAttempt}}
    elapsed_seconds::Float64
    stop_reason::Symbol
    settings::Dict{String, Any}
end

_precision_layouts(result) = _precision_audit(result.plan).paths
_precision_ranges(path) = Dict(b.node => b.range for b in path.ranges)

function _precision_amplification(layout, ranges, power)
    factor = _q(1)
    factor *= get(layout, :reconstruction_bound, _q(1))
    haskey(layout, :reconstruction_coordinate) &&
        (factor *= _interval_magnitude(ranges[layout.reconstruction_coordinate]))
    # h_k and a_k feed the remaining stages k-1,...,0.
    for stage in layout.stages
        stage.coefficient <= power || continue
        factor *= _interval_magnitude(ranges[stage.coordinate])
    end
    return factor
end

function _precision_stage_nodes(layout, k, count)
    k == count && return [layout.initial]
    stage = only(s for s in layout.stages if s.coefficient == k)
    nodes = [stage.result, stage.operand, stage.coordinate, stage.coefficient_value]
    stage.product === nothing || push!(nodes, stage.product)
    return unique(nodes)
end

function _precision_fixed_range(format, ranges)
    fraction = _fraction(format)
    lo = minimum(first, ranges) * _pow2(fraction)
    hi = maximum(last, ranges) * _pow2(fraction)
    # The certified ranges are already rounded values in this format.
    denominator(lo) == denominator(hi) == 1 ||
        throw(ArgumentError("nonintegral certified fixed range"))
    low, high = numerator(lo), numerator(hi)
    bits(n) = iszero(n) ? 0 : ndigits(n; base = 2)
    width = if format.signed
        max(1, 1 + bits(max(high, 0)), 1 + bits(max(-low - 1, 0)))
    else
        low >= 0 || throw(ArgumentError("negative unsigned range"))
        max(1, bits(high))
    end
    width = max(width, fraction + 1) # FixedFormat retains at least one integer bit.
    width >= format.width && return nothing
    return FixedFormat(width, width - fraction; signed = format.signed)
end

function _precision_reduce(f::FixedFormat, step, minimum)
    fraction = _fraction(f)
    fraction > minimum && f.width > 1 || return nothing
    reduction = min(step, fraction - minimum, f.width - 1)
    return FixedFormat(f.width - reduction, f.integer_bits; signed = f.signed)
end
function _precision_reduce(f::FloatFormat, step, minimum)
    floor = max(1, minimum)
    f.fraction_bits > floor || return nothing
    return FloatFormat(f.exponent_bits, max(floor, f.fraction_bits - step))
end

function _precision_error_estimate(range, format)
    format isa FixedFormat && return _pow2(-_fraction(format) - 1)
    try
        return _float_rounding_bound(range, format)
    catch err
        err isa OverflowError || rethrow()
        # An overflowing proposal is still refused by its full proof. The finite
        # estimate only orders it after changes with small local errors.
        return _interval_magnitude(range) + 1
    end
end

function _precision_replace(p, kind, k, format)
    coefficients, stages = collect(p.coefficient_formats), collect(p.stage_formats)
    (kind in (:coefficient_range, :coefficient_precision) ? coefficients : stages)[k] =
        format
    return PolynomialPrecision(
        p.coordinate_format;
        coefficient_formats = coefficients,
        stage_formats = stages,
    )
end

function _precision_proposals(result, step, minimum)
    precision = result.plan.precision
    layouts = _precision_layouts(result)
    get(result.plan.settings, "transformation", "none") == "odd" &&
        all(p -> p.input_domain == (0, 0), layouts) &&
        return NamedTuple[]
    isempty(result.paths) && return NamedTuple[]
    ranges = _precision_ranges.(result.paths)
    if get(result.plan.settings, "transformation", "none") in ("sinh", "cosh")
        # Both residual signs execute the shared stage formats. Include their
        # distinct ranges when proposing widths; every proposal is recertified.
        pairs = Tuple{NamedTuple, Dict{Int, _Interval}}[]
        for (p, r) in zip(layouts, ranges)
            if p.tail
                kmin, kmax = numerator.(r[p.exponent_node])
                push!(pairs, (merge(p, (; reconstruction_bound = _pow2(Int(kmax - 1)))), r))
                negative = merge(
                    p.negative_kernel,
                    (; reconstruction_bound = _pow2(Int(-kmin - 1))),
                )
                push!(pairs, (negative, r))
            else
                central =
                    get(result.plan.settings, "transformation", "") == "sinh" ?
                    merge(p, (; reconstruction_coordinate = p.argument)) : p
                push!(pairs, (central, r))
            end
        end
        layouts = first.(pairs)
        ranges = last.(pairs)
    end
    if get(result.plan.settings, "transformation", "none") == "erfc"
        pairs = Tuple{NamedTuple, Dict{Int, _Interval}}[]
        for (p, r) in zip(layouts, ranges)
            if p.tail
                f = result.plan.spec.output_format
                kmax = numerator(r[p.exponent_node][2])
                scale = _pow2(Int(max(kmax, _emin(f) - f.fraction_bits - 4)))
                ep = merge(
                    p,
                    (;
                        reconstruction_bound = scale *
                                               _interval_magnitude(r[p.scaled_wide])
                    ),
                )
                phi = merge(
                    p.scaled_kernel,
                    (; reconstruction_bound = scale * _interval_magnitude(r[p.exp_wide])),
                )
                push!(pairs, (ep, r), (phi, r))
            else
                push!(pairs, (p, r))
            end
        end
        # Each tail executes two distinct Horner graphs with shared formats.
        layouts = first.(pairs)
        ranges = last.(pairs)
    end
    count = length(precision.coefficient_formats)
    storage_rows = if get(result.plan.settings, "transformation", "none") == "erfc"
        layout = _erfc_audit(result.plan)
        (layout.central_coefficients, layout.scaled_coefficients, layout.exp_coefficients)
    else
        [p.coefficients for p in layouts]
    end
    proposals = NamedTuple[]
    for (kind, formats) in
        ((:coefficient, precision.coefficient_formats), (:stage, precision.stage_formats))
        for (k, format) in enumerate(formats)
            storage = kind == :coefficient
            local_ranges =
                storage ? [_singleton(cs[k]) for cs in storage_rows] :
                [
                    r[node] for (p, r) in zip(layouts, ranges) for
                    node in _precision_stage_nodes(p, k, count)
                ]
            smaller =
                format isa FixedFormat ? _precision_fixed_range(format, local_ranges) :
                nothing
            if smaller !== nothing
                tag = storage ? :coefficient_range : :stage_range
                push!(
                    proposals,
                    (;
                        kind = tag,
                        index = k,
                        before = format,
                        after = smaller,
                        estimate = _q(0),
                        precision = _precision_replace(precision, tag, k, smaller),
                        rank = 0,
                    ),
                )
            end
            smaller = _precision_reduce(format, step, minimum)
            smaller === nothing && continue
            estimate = maximum(zip(layouts, ranges)) do (layout, bounds)
                value_ranges =
                    storage ? [_singleton(layout.coefficients[k])] :
                    [bounds[node] for node in _precision_stage_nodes(layout, k, count)]
                local_error = maximum(value_ranges) do range
                    _precision_error_estimate(range, smaller)
                end
                local_error * _precision_amplification(layout, bounds, k - 1)
            end
            tag = storage ? :coefficient_precision : :stage_precision
            push!(
                proposals,
                (;
                    kind = tag,
                    index = k,
                    before = format,
                    after = smaller,
                    estimate,
                    precision = _precision_replace(precision, tag, k, smaller),
                    rank = 1,
                ),
            )
        end
    end
    # Estimates rank proposals only. Every accepted proposal needs a new complete proof.
    sort!(proposals; by = p -> (p.rank, p.estimate, p.index, string(p.kind)))
    return proposals
end

"""
    optimize_precision(baseline::CertificationResult; max_attempts=64,
        job_timeout=60, total_timeout=300, bit_step=1, min_precision_bits=0, ...)

Greedily reduce fixed integer/fraction widths or floating fraction widths, keeping
coordinate formats and floating exponent headroom unchanged. The bounded contract
must have a complete polynomial certificate. The baseline is freshly recertified
in an owned worker; this counts as the first attempt. Coefficient changes regenerate
coefficients and their norm proof. Stage changes reuse exact stored coefficients
and recertify the whole evaluator. Failed changes retain the last passing plan.

Coordinate bounds and amplification through later stages rank proposals. Accept
only a complete passing certificate with reduced declared storage/arithmetic widths.
Workers, startup, generation and proof share the supplied deadlines. No global
optimality or hardware benefit is claimed. `min_precision_bits` applies to fixed
fractional or floating fraction bits; integer and exponent range checks remain active.
"""
optimize_precision(baseline::CertificationResult; kwargs...) =
    _optimize_precision(baseline; kwargs...)

function _optimize_precision(
    baseline;
    max_attempts::Integer = 64,
    job_timeout::Real = 60,
    total_timeout::Real = 300,
    bit_step::Integer = 1,
    min_precision_bits::Integer = 0,
    generation_precision::Integer = parse(
        Int,
        get(baseline.plan.settings, "generation_precision", "256"),
    ),
    proof_precision::Integer = parse(Int, get(baseline.settings, "precision", "256")),
    accuracy::Union{Integer, Rational} = 1 // 1024,
    max_refinements::Integer = 2,
    worker_command = _polynomial_worker_command,
    process_started = (process, directory) -> nothing,
)
    baseline.status == :certified ||
        throw(ArgumentError("optimization requires a certified baseline"))
    spec = baseline.plan.spec
    spec.domain !== nothing ||
        throw(ArgumentError("optimization requires an explicit bounded domain"))
    precision = _stored_precision(baseline.plan) # Audit before launching any worker.
    !(bit_step isa Bool || min_precision_bits isa Bool) ||
        throw(ArgumentError("precision reduction limits must be integers, not Bool"))
    1 <= bit_step <= typemax(Int) && 0 <= min_precision_bits <= typemax(Int) ||
        throw(ArgumentError("invalid precision reduction limits"))
    degree = _executed_degree(baseline.plan, precision)
    segments = max(1, length(baseline.plan.segments))
    config = PolynomialSearchConfig(;
        degrees = [degree],
        internal_formats = [precision.coordinate_format],
        precisions = [precision],
        transformation = Symbol(get(baseline.plan.settings, "transformation", "none")),
        segments = [segments],
        evaluation = Symbol(baseline.plan.settings["evaluation"]),
        generation_precision,
        proof_precision,
        accuracy,
        max_refinements,
        max_attempts,
        job_timeout,
        total_timeout,
    )
    domain = _validate_polynomial_request(
        spec,
        degree,
        precision.coordinate_format,
        config.evaluation,
        generation_precision,
        proof_precision,
        accuracy,
        max_refinements,
    )
    settings = merge(
        _search_config_fields(config),
        Dict{String, Any}(
            "bit_step" => Int(bit_step),
            "min_precision_bits" => Int(min_precision_bits),
        ),
    )
    started = time_ns()
    attempts = PrecisionAttempt[]
    selected = nothing
    finish(reason) = PrecisionOptimizationResult(
        baseline.plan,
        selected === nothing ? :optimization_failed : :certified,
        selected,
        Tuple(attempts),
        _elapsed(started),
        reason,
        settings,
    )
    function run(precision, stored_plan)
        request = (;
            spec,
            config,
            domain,
            degree = config.transformation in (:odd, :atan) ?
                     2length(precision.coefficient_formats) - 1 :
                     length(precision.coefficient_formats) - 1,
            internal_format = precision.coordinate_format,
            segments,
            precision,
            stored_plan,
        )
        return _run_polynomial_job(request, started; worker_command, process_started)
    end
    fresh, deadline = run(precision, _plan_data(baseline.plan))
    accepted = fresh.status == :certified && !deadline
    push!(
        attempts,
        PrecisionAttempt(:baseline, nothing, nothing, nothing, _q(0), accepted, fresh),
    )
    accepted || return finish(deadline ? :total_deadline : :baseline_failed)
    selected = fresh.certificate
    tried = Set([precision])
    while true
        _search_remaining(started, config.total_timeout) <= 0 &&
            return finish(:total_deadline)
        length(attempts) >= config.max_attempts && return finish(:attempt_limit)
        proposals = _precision_proposals(selected, Int(bit_step), Int(min_precision_bits))
        choice = findfirst(p -> !(p.precision in tried), proposals)
        choice === nothing && return finish(:choices_exhausted)
        proposal = proposals[choice]
        push!(tried, proposal.precision)
        regenerate = proposal.kind in (:coefficient_range, :coefficient_precision)
        attempt, deadline =
            run(proposal.precision, regenerate ? nothing : _plan_data(selected.plan))
        accepted = false
        if attempt.status == :certified && !deadline
            before, after = precision_cost(selected.plan), precision_cost(attempt.plan)
            accepted =
                after.coefficient_bits < before.coefficient_bits ||
                after.stage_bits < before.stage_bits ||
                after.arithmetic_result_bits < before.arithmetic_result_bits
            accepted && (selected = attempt.certificate)
        end
        push!(
            attempts,
            PrecisionAttempt(
                proposal.kind,
                proposal.index,
                proposal.before,
                proposal.after,
                proposal.estimate,
                accepted,
                attempt,
            ),
        )
        deadline && return finish(:total_deadline)
    end
end

function _precision_cost_data(plan)
    cost = precision_cost(plan)
    data = Dict{String, Any}(string(k) => v for (k, v) in pairs(cost))
    data["operand_widths"] = [Dict("widths" => w) for w in cost.operand_widths]
    return data
end

function _precision_report_data(result::PrecisionOptimizationResult)
    data = Dict{String, Any}(
        "schema" => "presage-precision-search",
        "schema_version" => 1,
        "status" => string(result.status),
        "stop_reason" => string(result.stop_reason),
        "elapsed_seconds" => result.elapsed_seconds,
        "settings" => result.settings,
        "baseline" => Dict(
            "plan" => _plan_data(result.baseline),
            "cost" => _precision_cost_data(result.baseline),
        ),
        "attempts" => [
            begin
                a = attempt.result
                item = Dict{String, Any}(
                    "kind" => string(attempt.kind),
                    "accepted" => attempt.accepted,
                    "estimated_error" => _rational_text(attempt.estimated_error),
                    "status" => string(a.status),
                    "reason" => a.reason,
                    "elapsed_seconds" => a.elapsed_seconds,
                    "precision" => _precision_data(a.precision),
                )
                attempt.index === nothing ||
                    (item["coefficient_or_stage_index"] = attempt.index)
                attempt.before === nothing ||
                    (item["before"] = _format_data(attempt.before))
                attempt.after === nothing ||
                    (item["after"] = _format_data(attempt.after))
                if a.plan !== nothing
                    item["plan"] = _plan_data(a.plan)
                    a.plan.program === nothing ||
                        (item["cost"] = _precision_cost_data(a.plan))
                end
                a.certificate === nothing ||
                    (item["certificate"] = _certificate_data(a.certificate))
                item
            end for attempt in result.attempts
        ],
    )
    result.selected === nothing || (
        data["selected"] = Dict(
            "plan" => _plan_data(result.selected.plan),
            "certificate" => _certificate_data(result.selected),
            "cost" => _precision_cost_data(result.selected.plan),
        )
    )
    return data
end

"""Write precision choices, complete proof history and structural before/after counts."""
write_precision_report(io::IO, result::PrecisionOptimizationResult) =
    TOML.print(io, _precision_report_data(result); sorted = true)
write_precision_report(path::AbstractString, result::PrecisionOptimizationResult) =
    open(io -> write_precision_report(io, result), path, "w")
