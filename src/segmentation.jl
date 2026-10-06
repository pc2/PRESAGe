function _validate_segment_count(segments)
    segments isa Integer &&
        !(segments isa Bool) &&
        1 <= segments <= 64 &&
        ispow2(segments) || throw(ArgumentError("segments must be a power of two in 1:64"))
    return Int(segments)
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
    index_format = IR.UIntFormat(6)
    index = _push!(nodes, IR.Const(index_format, 0))
    for (i, word) in enumerate(geometry.thresholds)
        threshold = _push!(nodes, IR.Const(spec.input_format, word))
        condition = _push!(nodes, IR.Compare(:ge, 1, threshold))
        row = _push!(nodes, IR.Const(index_format, i))
        index = _push!(nodes, IR.Select(condition, row, index))
    end
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
        ) for i = 1:count
    ]
    return (; program, segments, paths, geometry)
end

"""
    segmented_polynomial_plan(spec, coefficient_rows; internal_format=spec.output_format,
                              evaluation=:separate)

Build an uncertified normalized evaluator on an explicit interval, using 2–64
equal segments (a power of two). Rows contain ascending coefficients in the
normalized coordinate, not in the original input. The coordinate is
`t = (x - stored_center) * 2^exponent`; centres, scaling, coefficient tables and
input-format dispatch predicates are stored in the IR. Coefficients are rounded
to the shared internal format. Empty representable branches are rejected.
"""
function segmented_polynomial_plan(
    spec::FunctionSpec,
    coefficient_rows;
    internal_format::Union{FloatFormat, FixedFormat} = spec.output_format,
    evaluation::Symbol = :separate,
)
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
    p, spec = plan.program, plan.spec
    p === nothing && throw(ArgumentError("missing segmented program"))
    plan.dispatch === nothing || throw(ArgumentError("unsupported external dispatch"))
    isempty(p.tables) && throw(ArgumentError("missing segment tables"))
    format = p.tables[1].format
    format isa Union{FloatFormat, FixedFormat} ||
        throw(ArgumentError("unsupported internal format"))
    all(p.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "segmented proof requires nearest-even rounding and rejected fixed overflow",
        ),
    )
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
    return layout
end

function _certify_segmented(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "normalized_segmented_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _segmented_audit(plan)
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
                    f = _normalized_function(
                        keep,
                        plan.spec.expression,
                        path.center,
                        path.exponent,
                    )
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
                        path.input_domain,
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
        "Audited dispatch covers every representable contract input; all paths meet the target" :
        "Conservative segmented uniform bound exceeds the target"
    return CertificationResult(plan, status, total, Tuple(paths), nothing, settings, reason)
end
