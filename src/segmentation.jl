function _validate_segment_count(segments)
    segments isa Integer &&
        !(segments isa Bool) &&
        1 <= segments <= 512 &&
        ispow2(segments) || throw(ArgumentError("segments must be a power of two in 1:512"))
    return Int(segments)
end

_segment_index_format(count) = IR.UIntFormat(max(1, ndigits(count - 1; base = 2)))

function _fixed_segment_index!(nodes, input, format::FixedFormat, thresholds, domain)
    count = length(thresholds) + 1
    ispow2(count) || return nothing
    count == 1 && return _push!(nodes, IR.Const(IR.UIntFormat(1), 0))
    lower, upper = domain
    width = (upper - lower) / count
    exponent = _polynomial_binade(width)
    width == _pow2(exponent) || return nothing
    offset = _fraction(format) + exponent
    index_format = _segment_index_format(count)
    0 <= offset && offset + index_format.width <= format.width || return nothing
    base = lower / width
    denominator(base) == 1 || return nothing
    first_row = mod(numerator(base), count)
    # This proves that the selected bits implement the stored threshold partition.
    all(
        i -> thresholds[i] == round_fixed(lower + i * width, format),
        eachindex(thresholds),
    ) || return nothing
    raw = _push!(nodes, IR.BitCast(input, IR.UIntFormat(format.width)))
    row = _push!(nodes, IR.ExtractBits(raw, offset, index_format.width))
    if first_row == count ÷ 2
        mask = _push!(nodes, IR.Const(index_format, first_row))
        row = _push!(nodes, IR.BitOp(:bitxor, row, mask))
    elseif first_row != 0
        # Extraction yields floor(x/width) modulo count, including negative x.
        # Subtract the lower row modulo count to start the interval at row zero.
        offset_row = _push!(nodes, IR.Const(index_format, mod(-first_row, count)))
        row = _push!(nodes, IR.UIntAdd(row, offset_row))
    end
    # The inclusive upper endpoint would wrap to row zero after extraction.
    # Keep it in the last row, matching the certified representable partition.
    endpoint = _push!(nodes, IR.constant(upper, format))
    at_endpoint = _push!(nodes, IR.Compare(:eq, input, endpoint))
    last_row = _push!(nodes, IR.Const(index_format, count - 1))
    return _push!(nodes, IR.Select(at_endpoint, last_row, row))
end

function _float_segment_index!(
    nodes,
    input,
    format::FloatFormat,
    thresholds,
    domain;
    dispatch_ranges = nothing,
)
    count = length(thresholds) + 1
    ispow2(count) || return nothing
    lower, upper = _q.(domain)
    lower < upper || return nothing
    endpoint_bits = round_ieee(upper, format)
    endpoint_value = decode_ieee(endpoint_bits, format)
    endpoint_value.kind in (:finite, :zero) && endpoint_value.value == upper ||
        return nothing
    count == 1 && return _push!(nodes, IR.Const(IR.UIntFormat(1), 0))
    width = (upper - lower) / count
    exponent = -_polynomial_binade(width)
    width == _pow2(-exponent) || return nothing
    typemin(Cint) <= exponent <= typemax(Cint) || return nothing
    base = lower / width
    denominator(base) == 1 || return nothing
    # For representable x, x >= ceil_float(lower+i*width) iff
    # floor(x/width)-base >= i. The offset is an exact integer.
    # This proves equivalence to the stored comparison partition before emitting
    # any nodes. Callers must guard inputs outside the declared domain.
    all(
        i -> thresholds[i] == round_ieee(lower + i * width, format; mode = :up),
        eachindex(thresholds),
    ) || return nothing
    index_format = _segment_index_format(count)
    index_range = (_q(0), _q(count - 1))
    scaled_range = (base, base + count - 1)
    row_format = FixedFormat(index_format.width, index_format.width; signed = false)
    wide_format =
        iszero(base) ? row_format :
        _shared_fixed_format([scaled_range, _singleton(-base), index_range], 0)
    integer_format = FixedFormat(
        wide_format.width,
        wide_format.integer_bits;
        signed = wide_format.signed,
        rounding = :down,
    )
    function record(operation, range)
        node = _push!(nodes, operation)
        dispatch_ranges === nothing || (dispatch_ranges[node] = range)
        return node
    end
    scaled = record(IR.ScalePow2(input, exponent, integer_format), scaled_range)
    shifted = if iszero(base)
        scaled
    else
        offset = record(IR.constant(-base, wide_format), _singleton(-base))
        offset_row = record(IR.Add(scaled, offset, wide_format), index_range)
        record(IR.Quantize(offset_row, row_format), index_range)
    end
    row = _push!(nodes, IR.BitCast(shifted, index_format))
    # Scaling and conversion operate on the exact float encoding, with no
    # intermediate floating rounding. The lazy endpoint branch avoids count
    # overflowing the row format at the inclusive upper endpoint.
    endpoint = _push!(nodes, IR.Const(format, endpoint_bits))
    at_endpoint = _push!(nodes, IR.Compare(:eq, input, endpoint))
    last_row = _push!(nodes, IR.Const(index_format, count - 1))
    return _push!(nodes, IR.Select(at_endpoint, last_row, row))
end

# Prefer an exact direct mapping where the stored partition permits it.
# The lazy binary-search fallback selects the upper row at equal thresholds.
function _segment_index!(
    nodes,
    input,
    format,
    thresholds;
    domain = nothing,
    dispatch_ranges = nothing,
)
    if format isa FixedFormat && domain !== nothing
        direct = _fixed_segment_index!(nodes, input, format, thresholds, domain)
        direct === nothing || return direct
    end
    if format isa FloatFormat && domain !== nothing
        direct =
            _float_segment_index!(nodes, input, format, thresholds, domain; dispatch_ranges)
        direct === nothing || return direct
    end
    index_format = _segment_index_format(length(thresholds) + 1)
    function branch(first, last)
        first == last && return _push!(nodes, IR.Const(index_format, first))
        middle = (first + last + 1) ÷ 2
        threshold = _push!(nodes, IR.Const(format, thresholds[middle]))
        condition = _push!(nodes, IR.Compare(:ge, input, threshold))
        lower = branch(first, middle - 1)
        upper = branch(middle, last)
        return _push!(nodes, IR.Select(condition, upper, lower))
    end
    return branch(0, length(thresholds))
end

# Integer dispatch implements an audited floor, not an approximation operation.
# Only its reconstructed nodes may use downward rounding; polynomial arithmetic
# and interfaces retain the nearest-even/rejected-overflow contract.
function _segment_arithmetic_policy(p, dispatch_ranges)
    all(enumerate(p.types)) do (i, format)
        format isa FixedFormat || return true
        format.overflow == :reject || return false
        format.rounding == :nearest_even && return true
        node = p.nodes[i]
        return haskey(dispatch_ranges, i) &&
               node isa IR.ScalePow2 &&
               IR.format(p, node.source) isa FloatFormat &&
               format.integer_bits == format.width &&
               format.rounding == :down
    end || throw(
        ArgumentError(
            "polynomial arithmetic requires nearest-even rounding and rejected overflow outside audited integer dispatch",
        ),
    )
end

# Numerical predecessor, skipping the duplicate zero encoding. Both signed zeros
# satisfy the same comparisons and belong to the same certified path.
function _previous_input_value(word, f::FixedFormat)
    return decode_fixed(word, f) - _pow2(-_fraction(f))
end
function _previous_input_value(word, f::FloatFormat)
    value = _polynomial_value(word, f)
    previous = iszero(value) ? _sign(f) | 1 : value > 0 ? word - 1 : word + 1
    return _polynomial_value(previous, f)
end

function _segmented_domains(spec, segments)
    _validate_segment_count(segments)
    spec.domain === nothing &&
        throw(ArgumentError("normalized segmentation requires an explicit domain"))
    lo, hi = _polynomial_domain(spec)
    lo < hi || throw(ArgumentError("segmentation requires a nondegenerate input domain"))
    width = (hi - lo) / segments
    boundaries = [lo + i * width for i = 0:segments]
    thresholds = [
        _polynomial_round(b, spec.input_format; mode = :up) for b in boundaries[2:(end - 1)]
    ]
    starts = [lo; _polynomial_value.(thresholds, Ref(spec.input_format))]
    ends = [_previous_input_value.(thresholds, Ref(spec.input_format)); hi]
    all(i -> starts[i] <= ends[i], 1:segments) ||
        throw(ArgumentError("segment count creates empty representable branches"))
    return (; boundaries, thresholds, domains = collect(zip(starts, ends)))
end

function _segment_geometry(spec, segments, format)
    format isa FixedFormat &&
        !format.signed &&
        throw(ArgumentError("normalized coordinates require signed fixed internals"))
    partition = _segmented_domains(spec, segments)
    centers = [
        _polynomial_value(_polynomial_round((a + b) / 2, format), format) for
        (a, b) in zip(partition.boundaries[1:(end - 1)], partition.boundaries[2:end])
    ]
    radius = max(
        (partition.boundaries[2] - partition.boundaries[1]) / 2,
        maximum(
            max(abs(domain[1] - center), abs(domain[2] - center)) for
            (domain, center) in zip(partition.domains, centers)
        ),
    )
    exponent = -_polynomial_binade(radius)
    radius * _pow2(exponent) > 1 && (exponent -= 1)
    typemin(Cint) <= exponent <= typemax(Cint) ||
        throw(ArgumentError("normalization exponent exceeds C int range"))
    domains = [
        map(x -> (x - center) * _pow2(exponent), domain) for
        (domain, center) in zip(partition.domains, centers)
    ]
    return merge(partition, (; centers, exponent, normalized_domains = domains))
end

function _normalized_function(keep, expression, center, exponent)
    f = keep(Sollya.sollya(_exact_expression(expression)))
    transform = keep(_stored_polynomial([center, _pow2(-exponent)]))
    return keep(Sollya.substitute(f, transform))
end

function _segmented_layout(spec, rows, format, evaluation)
    count = length(rows)
    count >= 2 || throw(ArgumentError("segmented evaluators require at least two rows"))
    geometry = _segment_geometry(spec, count, format)
    all(row -> !isempty(row) && length(row) <= 33, rows) ||
        throw(ArgumentError("segment polynomial degrees must be in 0:32"))
    degree = maximum(length, rows) - 1
    coefficients = [
        [
            _polynomial_value(
                _polynomial_round(k <= length(row) ? _q(row[k]) : _q(0), format),
                format,
            ) for k = 1:(degree + 1)
        ] for row in rows
    ]
    segments = [
        Segment(geometry.boundaries[i], geometry.boundaries[i + 1], coefficients[i]) for
        i = 1:count
    ]
    tables = IR.Table[IR.Table(format, _polynomial_round.(-geometry.centers, Ref(format)))]
    for k = 1:(degree + 1)
        push!(
            tables,
            IR.Table(
                format,
                [_polynomial_round(row[k], format) for row in coefficients];
                unroll = true,
            ),
        )
    end
    nodes = IR.Node[IR.Input(spec.input_format)]
    dispatch_ranges = Dict{Int, _Interval}()
    index = _segment_index!(
        nodes,
        1,
        spec.input_format,
        geometry.thresholds;
        domain = (first(geometry.boundaries), last(geometry.boundaries)),
        dispatch_ranges,
    )
    converted = format == spec.input_format ? 1 : _push!(nodes, IR.Convert(1, format))
    center = _push!(nodes, IR.TableLoad(1, index))
    shifted = _push!(nodes, IR.Add(converted, center, format))
    coordinate = _push!(nodes, IR.ScalePow2(shifted, geometry.exponent, format))
    cs = [_push!(nodes, IR.TableLoad(k + 1, index)) for k = 1:(degree + 1)]
    h = cs[end]
    stages = NamedTuple[]
    for k = degree:-1:1
        previous = h
        product =
            evaluation == :separate ? _push!(nodes, IR.Mul(h, coordinate, format)) : nothing
        h =
            evaluation == :separate ? _push!(nodes, IR.Add(product, cs[k], format)) :
            evaluation == :fma ? _push!(nodes, IR.FMA(h, coordinate, cs[k], format)) :
            throw(ArgumentError("evaluation must be :separate or :fma"))
        push!(stages, (result = h, previous, product, coefficient = k))
    end
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported Horner arithmetic"))
    final = h
    result =
        format == spec.output_format ? final :
        _push!(nodes, IR.Convert(final, spec.output_format))
    output = _polynomial_guard!(nodes, result, spec)
    program = IR.Program(nodes; output, tables)
    paths = [
        (;
            coefficients = coefficients[i],
            stages,
            coordinate,
            converted,
            shifted,
            final,
            result,
            index,
            row = i,
            exponent = geometry.exponent,
            center = geometry.centers[i],
            domain = geometry.normalized_domains[i],
            input_domain = geometry.domains[i],
            dispatch_ranges,
        ) for i = 1:count
    ]
    return (; program, segments, paths, geometry, dispatch_ranges)
end

"""
    segmented_polynomial_plan(spec, coefficient_rows; internal_format=spec.output_format, precision=nothing,
                              evaluation=:separate)

Build an uncertified normalized evaluator on an explicit interval, using 2–512
equal segments (a power of two). Rows contain ascending coefficients in the
normalized coordinate, not in the original input. The coordinate is
`t = (x - stored_center) * 2^exponent`; centres, scaling, coefficient tables and
input-format dispatch predicates are stored in the IR. Coefficients are rounded
to the shared internal format by default. `PolynomialPrecision` separates
coefficient storage, coordinate and stage formats. Empty representable branches are rejected.
"""
function segmented_polynomial_plan(
    spec::FunctionSpec,
    coefficient_rows;
    precision::Union{Nothing, PolynomialPrecision} = nothing,
    internal_format::Union{FloatFormat, FixedFormat} = precision === nothing ?
                                                       spec.output_format :
                                                       precision.coordinate_format,
    evaluation::Symbol = :separate,
)
    if precision !== nothing
        internal_format == precision.coordinate_format || throw(
            ArgumentError("internal format must match the precision coordinate format"),
        )
        return _precision_plan(
            spec,
            coefficient_rows,
            precision,
            evaluation;
            segmented = true,
        )
    end
    layout = _segmented_layout(spec, coefficient_rows, internal_format, evaluation)
    return PlanArtifact(
        spec;
        program = layout.program,
        segments = layout.segments,
        settings = Dict(
            "kernel" => "normalized_segmented_horner",
            "evaluation" => string(evaluation),
        ),
    )
end

function _segmented_audit(plan)
    plan.precision === nothing || return _precision_audit(plan)
    p, spec = plan.program, plan.spec
    p === nothing && throw(ArgumentError("missing segmented program"))
    plan.dispatch === nothing || throw(ArgumentError("unsupported external dispatch"))
    isempty(p.tables) && throw(ArgumentError("missing segment tables"))
    format = p.tables[1].format
    format isa Union{FloatFormat, FixedFormat} ||
        throw(ArgumentError("unsupported internal format"))
    layout = _segmented_layout(
        spec,
        [s.coefficients for s in plan.segments],
        format,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    all(zip(plan.segments, layout.segments)) do (stored, canonical)
        stored.lower == canonical.lower &&
            stored.upper == canonical.upper &&
            stored.coefficients == canonical.coefficients
    end || throw(ArgumentError("segment metadata differs from the supported partition"))
    _program_data(p) == _program_data(layout.program) || throw(
        ArgumentError(
            "executed graph or tables differ from the supported segmented evaluator",
        ),
    )
    _segment_arithmetic_policy(p, layout.dispatch_ranges)
    return layout
end

function _certify_segmented(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" =>
            plan.precision === nothing ? "normalized_segmented_horner" :
            "precision_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        plan.precision === nothing ? _segmented_audit(plan) : _precision_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
        return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
    end
    paths = PathCertificate[]
    try
        Sollya.with_session(Sollya.Session(; precision)) do
            for path in layout.paths
                ranges, rho = _polynomial_ranges(plan.program, path)
                coordinate, arithmetic, output =
                    _polynomial_arithmetic(plan.program, path, ranges, rho)
                norm = Sollya.with_objects() do keep
                    p = keep(_stored_polynomial(path.coefficients))
                    f =
                        haskey(path, :exponent) ?
                        _normalized_function(
                            keep,
                            plan.spec.expression,
                            path.center,
                            path.exponent,
                        ) : keep(Sollya.sollya(_exact_expression(plan.spec.expression)))
                    domain = keep(Sollya.interval(path.domain...))
                    Sollya.bounds(domain) == path.domain || throw(
                        ArgumentError(
                            "native coordinate domain enlargement; increase proof precision",
                        ),
                    )
                    Sollya.bounds(keep(Sollya.enclosure(f, domain)))
                    norm, tightness = (_q(0), _q(0)), _q(accuracy)
                    for refinement = 0:max_refinements
                        norm = _polynomial_norm(p, f, domain, tightness)
                        0 <= norm[1] <= norm[2] ||
                            throw(ArgumentError("invalid polynomial norm enclosure"))
                        other = coordinate + arithmetic + output
                        norm[1] + other <= plan.spec.absolute_error < norm[2] + other ||
                            break
                        tightness /= 4
                    end
                    norm
                end
                bounds = Tuple(
                    _node_bound(node, IR.format(plan.program, node), range) for
                    (node, range) in sort!(collect(ranges); by = first)
                )
                push!(
                    paths,
                    PathCertificate(
                        get(path, :input_domain, path.domain),
                        true,
                        norm,
                        coordinate,
                        arithmetic,
                        output,
                        norm[2] + coordinate + arithmetic + output,
                        bounds,
                    ),
                )
            end
        end
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(plan, :proof_failed, sprint(showerror, err); settings)
    end
    total = maximum(p.total for p in paths)
    status = total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    reason =
        status == :certified ?
        "Audited evaluator covers every representable contract input; all paths meet the target" :
        "Conservative uniform evaluator bound exceeds the target"
    return CertificationResult(plan, status, total, Tuple(paths), nothing, settings, reason)
end
