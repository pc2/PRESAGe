function _atan_geometry(spec)
    _primitive(spec.expression) == :atan ||
        throw(ArgumentError("atan transformation requires atan(x)"))
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("atan reduction requires floating interfaces"))
    spec.domain !== nothing ||
        throw(ArgumentError("atan reduction requires an explicit bounded domain"))
    domain = _polynomial_domain(spec)
    successor = decode_ieee(round_ieee(1, spec.input_format) + 1, spec.input_format).value
    branches = NamedTuple[]
    for (kind, lo, hi) in (
        (:negative_tail, domain[1], min(domain[2], -successor)),
        (:central, max(domain[1], -_q(1)), min(domain[2], _q(1))),
        (:positive_tail, max(domain[1], successor), domain[2]),
    )
        lo <= hi || continue
        magnitude = (lo <= 0 <= hi ? _q(0) : min(abs(lo), abs(hi)), max(abs(lo), abs(hi)))
        tail = kind != :central
        argument_domain = tail ? (inv(magnitude[2]), inv(magnitude[1])) : magnitude
        push!(
            branches,
            (;
                kind,
                tail,
                input_domain = (lo, hi),
                argument_domain,
                domain = _odd_square_domain(argument_domain),
                negative = lo < 0 && hi <= 0,
                both_signs = lo < 0 < hi,
            ),
        )
    end
    return (; accepted_domain = domain, branches)
end

function _atan_reduction_format(spec, precision)
    f = precision.coordinate_format
    exponent =
        max(11, spec.input_format.exponent_bits, f isa FloatFormat ? f.exponent_bits : 2)
    fraction = max(
        52,
        spec.input_format.fraction_bits,
        spec.output_format.fraction_bits,
        f isa FloatFormat ? f.fraction_bits : _fraction(f),
    )
    return FloatFormat(exponent, fraction)
end

function _atan_layout(spec, coefficients, pi2, precision, evaluation)
    geometry = _atan_geometry(spec)
    1 <= length(coefficients) <= 16 ||
        throw(ArgumentError("atan odd kernels need 1:16 coefficients"))
    precision = _precision_prefix(precision, length(coefficients))
    f, fc = precision.coordinate_format, precision.coefficient_formats
    f isa FixedFormat &&
        !f.signed &&
        throw(ArgumentError("atan reconstruction requires signed fixed coordinates"))
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported evaluation"))
    coefficients = [
        _polynomial_value(_polynomial_round(_q(c), format), format) for
        (c, format) in zip(coefficients, fc)
    ]
    pi2 = _polynomial_value(_polynomial_round(_q(pi2), f), f)
    reduction_format = _atan_reduction_format(spec, precision)
    nodes = IR.Node[IR.Input(spec.input_format)]
    zero_constant = _push!(nodes, IR.constant(0, spec.input_format))
    magnitude = _push!(nodes, IR.CopySign(1, zero_constant))
    one = _push!(nodes, IR.constant(1, spec.input_format))
    is_tail = _push!(nodes, IR.Compare(:gt, magnitude, one))
    wide = _precision_convert!(nodes, magnitude, spec.input_format, reduction_format)
    reciprocal = _push!(nodes, IR.FloatReciprocal(wide))
    tail_argument = _precision_convert!(nodes, reciprocal, reduction_format, f)
    central_argument = _precision_convert!(nodes, magnitude, spec.input_format, f)
    argument = _push!(nodes, IR.Select(is_tail, tail_argument, central_argument))
    square = _push!(nodes, IR.Mul(argument, argument, f))
    cs = [_push!(nodes, IR.constant(c, format)) for (c, format) in zip(coefficients, fc)]
    horner = _precision_horner!(nodes, square, cs, precision, evaluation)
    q = _precision_convert!(nodes, horner.final, precision.stage_formats[1], f)
    kernel = _push!(nodes, IR.Mul(argument, q, f))
    pi2_node = _push!(nodes, IR.constant(pi2, f))
    minus_one = _push!(nodes, IR.constant(-1, f))
    negated =
        evaluation == :separate ? _push!(nodes, IR.Mul(minus_one, kernel, f)) : nothing
    tail_value =
        evaluation == :fma ? _push!(nodes, IR.FMA(minus_one, kernel, pi2_node, f)) :
        _push!(nodes, IR.Add(pi2_node, negated, f))
    selected = _push!(nodes, IR.Select(is_tail, tail_value, kernel))
    converted = _precision_convert!(nodes, selected, f, spec.output_format)
    restored = _push!(nodes, IR.CopySign(converted, 1))
    zero = _push!(nodes, IR.Classify(:zero, 1))
    zero_value = _push!(nodes, IR.Convert(1, spec.output_format))
    zero_select = _push!(nodes, IR.Select(zero, zero_value, restored))
    guarded = _polynomial_guard!(nodes, zero_select, spec)
    infinity = _push!(nodes, IR.Classify(:infinity, 1))
    limit_value = _precision_convert!(nodes, pi2_node, f, spec.output_format)
    limit = _push!(nodes, IR.CopySign(limit_value, 1))
    output = _push!(nodes, IR.Select(infinity, limit, guarded))
    paths = [
        merge(
            horner,
            branch,
            (;
                coefficients,
                coordinate = square,
                result = q,
                argument,
                magnitude,
                central_argument,
                tail_argument,
                wide,
                reciprocal,
                reduction_format,
                reconstruction_coordinate = argument,
                reconstruction = kernel,
                tail_value,
                negated,
                selected,
                output_conversion = converted,
                output_source = restored,
                pi2,
                pi2_node,
                range_roots = (restored, findall(n -> n isa IR.Const, nodes)...),
                range_choices = Dict(
                    argument => (branch.tail ? tail_argument : central_argument),
                    selected => (branch.tail ? tail_value : kernel),
                ),
                range_aliases = Dict(
                    zero_select => restored,
                    guarded => restored,
                    output => restored,
                ),
            ),
        ) for branch in geometry.branches
    ]
    return (;
        program = IR.Program(nodes; output),
        precision,
        paths,
        coefficient_nodes = cs,
        pi2_node,
        pi2,
        limit_value,
        geometry,
        reduction_format,
    )
end

"""
    atan_polynomial_plan(spec, coefficients, pi2; precision=nothing,
                         internal_format=spec.output_format, evaluation=:separate)

Build an uncertified bounded atan evaluator. Ascending coefficients describe q
in `r*q(r²)`. For |x|≤1, r=|x|; otherwise r is a rounded floating reciprocal
and reconstruction subtracts the kernel from the stored pi2 constant. Reciprocal
precision widens automatically to preserve the input conversion and coordinate
precision, with at least binary64 precision. Every operation and lazy branch is
explicit in IR. Floating interfaces and a bounded signed domain are required.
"""
function atan_polynomial_plan(
    spec::FunctionSpec,
    coefficients,
    pi2;
    precision::Union{Nothing, PolynomialPrecision} = nothing,
    internal_format::PolynomialFormat = precision === nothing ? spec.output_format :
                                        precision.coordinate_format,
    evaluation::Symbol = :separate,
)
    cs = collect(coefficients)
    precision === nothing && (
        precision = PolynomialPrecision(
            internal_format;
            coefficient_formats = fill(internal_format, length(cs)),
            stage_formats = fill(internal_format, length(cs)),
        )
    )
    internal_format == precision.coordinate_format ||
        throw(ArgumentError("internal format must match coordinate precision"))
    layout = _atan_layout(spec, cs, pi2, precision, evaluation)
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "atan_polynomial_horner",
            "transformation" => "atan",
            "evaluation" => string(evaluation),
        ),
    )
end

function _atan_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing atan evaluator"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported atan metadata dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "atan proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    count = length(plan.precision.coefficient_formats)
    skeleton = _atan_layout(
        plan.spec,
        fill(0, count),
        0,
        plan.precision,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    ids = skeleton.coefficient_nodes
    length(plan.program.nodes) == length(skeleton.program.nodes) ||
        throw(ArgumentError("incomplete atan graph"))
    constants = [plan.program.nodes[i] for i in ids]
    all(zip(constants, plan.precision.coefficient_formats)) do (n, f)
        n isa IR.Const && n.format == f
    end || throw(ArgumentError("unsupported atan coefficient storage"))
    coefficients = [_polynomial_value(n.bits, n.format) for n in constants]
    constant = plan.program.nodes[skeleton.pi2_node]
    constant isa IR.Const && constant.format == plan.precision.coordinate_format ||
        throw(ArgumentError("unsupported pi/2 storage"))
    pi2 = _polynomial_value(constant.bits, constant.format)
    layout = _atan_layout(
        plan.spec,
        coefficients,
        pi2,
        plan.precision,
        Symbol(plan.settings["evaluation"]),
    )
    layout.precision == plan.precision ||
        throw(ArgumentError("precision metadata exceeds degree"))
    nodes = collect(layout.program.nodes)
    for (i, n) in zip(ids, constants)
        nodes[i] = n
    end
    nodes[layout.pi2_node] = constant
    _program_data(IR.Program(nodes; output = layout.program.output)) ==
    _program_data(plan.program) ||
        throw(ArgumentError("executed graph differs from the supported atan evaluator"))
    return layout
end

function _reformat_atan(plan, precision)
    old = _atan_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    old_path = first(old.paths)
    new = _atan_layout(
        plan.spec,
        old_path.coefficients,
        old.pi2,
        precision,
        Symbol(plan.settings["evaluation"]),
    )
    nodes = collect(new.program.nodes)
    for (source, target) in zip(old.coefficient_nodes, new.coefficient_nodes)
        nodes[target] = plan.program.nodes[source]
    end
    nodes[new.pi2_node] = plan.program.nodes[old.pi2_node]
    return PlanArtifact(
        plan.spec;
        program = IR.Program(nodes; output = new.program.output),
        precision = new.precision,
        settings = plan.settings,
    )
end

function _pi2_bounds(precision)
    Sollya.with_session(Sollya.Session(; precision)) do
        Sollya.with_objects() do keep
            Sollya.bounds(keep(Sollya.enclosure(keep(Sollya.sollya("pi/2")), 0)))
        end
    end
end

function _certified_atan(
    spec,
    domain,
    degree,
    internal_format,
    evaluation,
    generation_precision,
    proof_precision,
    accuracy,
    max_refinements;
    precision_layout,
    candidate_ready,
)
    geometry = _atan_geometry(spec)
    count = (degree + 1) ÷ 2
    precision_layout === nothing && (
        precision_layout = PolynomialPrecision(
            internal_format;
            coefficient_formats = fill(internal_format, count),
            stage_formats = fill(internal_format, count),
        )
    )
    settings = Dict(
        "degree" => string(degree),
        "generation_precision" => string(generation_precision),
    )
    candidate = try
        coefficients =
            geometry.accepted_domain == (0, 0) ? fill(_q(0), count) :
            _generated_odd_coefficients(
                spec,
                (-_q(1), _q(1)),
                degree,
                precision_layout.coefficient_formats[1:count],
                generation_precision,
            )
        pi2 = sum(_pi2_bounds(generation_precision)) / 2
        atan_polynomial_plan(
            spec,
            coefficients,
            pi2;
            precision = precision_layout,
            evaluation,
        )
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Atan generation failed: " * sprint(showerror, err);
            settings,
        )
    end
    plan = PlanArtifact(
        spec;
        program = candidate.program,
        precision = candidate.precision,
        settings = merge(candidate.settings, settings),
    )
    candidate_ready(plan)
    return _certify_atan(plan; precision = proof_precision, accuracy, max_refinements)
end

function _atan_arithmetic(plan, path, ranges, rho)
    xbound = _interval_magnitude(ranges[path.argument])
    radius = path.argument_domain[2]
    eta_x =
        path.tail ? get(rho, path.reciprocal, _q(0)) + get(rho, path.tail_argument, _q(0)) :
        get(rho, path.central_argument, _q(0))
    # The wide input conversion is exact by construction. Avoid counting an
    # aliased argument node twice when conversion to its format was elided.
    path.tail &&
        path.tail_argument == path.reciprocal &&
        (eta_x = get(rho, path.reciprocal, _q(0)))
    eta_z = eta_x * (xbound + radius) + get(rho, path.coordinate, _q(0))
    cq, vq, loading = _polynomial_arithmetic(
        plan.program,
        merge(path, (; coordinate_formation_error = eta_z)),
        ranges,
        rho,
    )
    exact_q = _singleton(path.coefficients[end])
    for c in reverse(path.coefficients[1:(end - 1)])
        exact_q = _interval_add(_interval_mul(exact_q, path.domain), _singleton(c))
    end
    coordinate = xbound * cq + eta_x * _interval_magnitude(exact_q)
    arithmetic = xbound * (vq + loading) + rho[path.reconstruction]
    return coordinate, arithmetic
end

function _atan_path_certificate(plan, path, norm, pi2_bounds, constant_error)
    ranges, rho = _polynomial_ranges(plan.program, path)
    coordinate, arithmetic = _atan_arithmetic(plan, path, ranges, rho)
    # atan(r) lies in [0,pi/4]. The complete kernel error bounds
    # its rounded reconstruction, tightening subsequent tail/output ranges.
    kernel_error = norm[2] + coordinate + arithmetic
    lo = max(ranges[path.reconstruction][1], -kernel_error)
    hi = min(ranges[path.reconstruction][2], pi2_bounds[2] / 2 + kernel_error)
    lo <= hi || throw(ArgumentError("inconsistent atan kernel range"))
    f = IR.format(plan.program, path.reconstruction)
    enclosure = (
        _polynomial_value(_polynomial_round(lo, f; mode = :down), f),
        _polynomial_value(_polynomial_round(hi, f; mode = :up), f),
    )
    ranges, rho = _polynomial_ranges(
        plan.program,
        path;
        range_overrides = Dict(path.reconstruction => enclosure),
    )
    if path.tail
        arithmetic +=
            constant_error +
            rho[path.tail_value] +
            (path.negated === nothing ? _q(0) : rho[path.negated])
    end
    output = path.output_conversion == path.selected ? _q(0) : rho[path.output_conversion]
    bounds = Tuple(
        _node_bound(i, IR.format(plan.program, i), range) for
        (i, range) in sort!(collect(ranges); by = first)
    )
    return PathCertificate(
        path.input_domain,
        true,
        norm,
        coordinate,
        arithmetic,
        output,
        norm[2] + coordinate + arithmetic + output,
        bounds,
    )
end

function _certify_atan(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "atan_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _atan_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
        return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
    end
    certificates = PathCertificate[]
    limit_error = _q(0)
    try
        pi2_bounds = _pi2_bounds(precision)
        constant_error = maximum(abs(layout.pi2 - q) for q in pi2_bounds)
        limit = abs(
            _polynomial_value(
                _polynomial_round(layout.pi2, plan.spec.output_format),
                plan.spec.output_format,
            ),
        )
        limit_error = maximum(abs(limit - q) for q in pi2_bounds)
        settings["pi2_error_bound"] = _rational_text(constant_error)
        settings["infinity_error_bound"] = _rational_text(limit_error)
        numeric = [p for p in layout.paths if p.input_domain != (0, 0)]
        if !isempty(numeric)
            Sollya.with_session(Sollya.Session(; precision)) do
                Sollya.with_objects() do keep
                    p = keep(
                        _stored_polynomial(_odd_expansion(first(numeric).coefficients)),
                    )
                    f = keep(Sollya.sollya("atan(x)"))
                    interval = keep(Sollya.interval(0, 1))
                    Sollya.bounds(interval) == (0, 1) ||
                        throw(ArgumentError("native proof domain enlargement"))
                    tightness = _q(accuracy)
                    for refinement = 0:max_refinements
                        raw = _polynomial_norm(p, f, interval, tightness)
                        0 <= raw[1] <= raw[2] ||
                            throw(ArgumentError("invalid atan norm enclosure"))
                        # The full reduced interval can enlarge a contract's
                        # argument set; only its upper endpoint transfers.
                        norm = (_q(0), raw[2])
                        certificates = [
                            _atan_path_certificate(
                                plan,
                                path,
                                norm,
                                pi2_bounds,
                                constant_error,
                            ) for path in numeric
                        ]
                        upper = maximum((c.total for c in certificates); init = limit_error)
                        lower = maximum(
                            (c.total - raw[2] + raw[1] for c in certificates);
                            init = limit_error,
                        )
                        lower <= plan.spec.absolute_error < upper || break
                        tightness /= 4
                    end
                end
            end
        end
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(plan, :proof_failed, sprint(showerror, err); settings)
    end
    total = maximum((p.total for p in certificates); init = limit_error)
    status = total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    return CertificationResult(
        plan,
        status,
        total,
        Tuple(certificates),
        nothing,
        settings,
        status == :certified ?
        "Audited central/tail coverage, reciprocal rounding, stored pi/2 and complete evaluator bounds meet the target" :
        "Conservative atan evaluator or infinity bound exceeds the target",
    )
end
