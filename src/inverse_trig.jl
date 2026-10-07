function _inverse_trig_geometry(spec, transformation = _primitive(spec.expression))
    transformation in (:asin, :acos) && _primitive(spec.expression) == transformation ||
        throw(
            ArgumentError(
                "inverse trig transformation requires matching asin(x) or acos(x)",
            ),
        )
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("inverse trig reconstruction requires floating interfaces"))
    spec.domain !== nothing && -1 <= spec.domain[1] <= spec.domain[2] <= 1 || throw(
        ArgumentError(
            "inverse trig reconstruction requires a bounded domain inside [-1,1]",
        ),
    )
    domain = _polynomial_domain(spec)
    f = spec.input_format
    half = round_ieee(1 // 2, f)
    next_half = decode_ieee(half + 1, f).value
    previous_one = decode_ieee(round_ieee(1, f) - 1, f).value
    tiny = decode_ieee(1, f).value
    branches = NamedTuple[]
    for (kind, lo, hi, tail, special) in (
        (:negative_endpoint, -_q(1), -_q(1), false, true),
        (:negative_tail, -previous_one, -next_half, true, false),
        (:negative_central, -_q(1 // 2), -tiny, false, false),
        (:zero, _q(0), _q(0), false, true),
        (:positive_central, tiny, _q(1 // 2), false, false),
        (:positive_tail, next_half, previous_one, true, false),
        (:positive_endpoint, _q(1), _q(1), false, true),
    )
        lo, hi = max(lo, domain[1]), min(hi, domain[2])
        lo <= hi || continue
        negative = hi < 0
        magnitude_domain = negative ? (-hi, -lo) : (lo, hi)
        t_domain =
            tail ? ((1 - magnitude_domain[2]) / 2, (1 - magnitude_domain[1]) / 2) : nothing
        push!(
            branches,
            (;
                kind,
                tail,
                special,
                negative,
                input_domain = (lo, hi),
                magnitude_domain,
                t_domain,
            ),
        )
    end
    return (; transformation, accepted_domain = domain, branches)
end

function _inverse_trig_layout(
    spec,
    asin_coefficients,
    sqrt_coefficients,
    pi2,
    precision,
    evaluation,
)
    geometry = _inverse_trig_geometry(spec)
    count = length(asin_coefficients)
    length(sqrt_coefficients) == count && 1 <= count <= 33 || throw(
        ArgumentError("inverse trig kernels require two equal lists of 1:33 coefficients"),
    )
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported evaluation"))
    precision = _precision_prefix(precision, count)
    f = precision.coordinate_format
    f isa FixedFormat &&
        !f.signed &&
        throw(ArgumentError("inverse trig coordinates must be signed"))
    red = _atan_reduction_format(spec, precision)
    stored(cs) = [
        _polynomial_value(_polynomial_round(_q(c), cf), cf) for
        (c, cf) in zip(cs, precision.coefficient_formats)
    ]
    asin_coefficients, sqrt_coefficients =
        stored(asin_coefficients), stored(sqrt_coefficients)
    pi2 = _polynomial_value(round_ieee(_q(pi2), red), red)
    nodes = IR.Node[IR.Input(spec.input_format)]
    zero_constant = _push!(nodes, IR.constant(0, spec.input_format))
    magnitude = _push!(nodes, IR.CopySign(1, zero_constant))
    half = _push!(nodes, IR.constant(1 // 2, spec.input_format))
    is_tail = _push!(nodes, IR.Compare(:gt, magnitude, half))
    one_input = _push!(nodes, IR.constant(1, spec.input_format))
    is_endpoint = _push!(nodes, IR.Compare(:eq, magnitude, one_input))
    negative = _push!(nodes, IR.Classify(:negative, 1))
    wide = _precision_convert!(nodes, magnitude, spec.input_format, red)
    one = _push!(nodes, IR.constant(1, red))
    minus_one = _push!(nodes, IR.constant(-1, red))
    negated_magnitude = _push!(nodes, IR.Mul(wide, minus_one, red))
    gap = _push!(nodes, IR.Add(one, negated_magnitude, red))
    t = _push!(nodes, IR.ScalePow2(gap, -1, red))
    mantissa = _push!(nodes, IR.RootArgument(t))
    root_coordinate = _precision_convert!(nodes, mantissa, _root_argument_format(red, 2), f)
    sqrt_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(sqrt_coefficients, precision.coefficient_formats)
    ]
    root_horner =
        _precision_horner!(nodes, root_coordinate, sqrt_nodes, precision, evaluation)
    root_value =
        _push!(nodes, IR.ScaleByInputExponent(root_horner.final, t, 1, red; divisor = 2))
    tail_argument = _precision_convert!(nodes, root_value, red, f)
    central_argument = _precision_convert!(nodes, magnitude, spec.input_format, f)
    argument = _push!(nodes, IR.Select(is_tail, tail_argument, central_argument))
    square = _push!(nodes, IR.Mul(argument, argument, f))
    asin_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(asin_coefficients, precision.coefficient_formats)
    ]
    asin_horner = _precision_horner!(nodes, square, asin_nodes, precision, evaluation)
    q = _precision_convert!(nodes, asin_horner.final, precision.stage_formats[1], f)
    kernel = _push!(nodes, IR.Mul(argument, q, f))
    kernel_wide = _precision_convert!(nodes, kernel, f, red)
    doubled = _push!(nodes, IR.ScalePow2(kernel_wide, 1, red))
    pi2_node = _push!(nodes, IR.constant(pi2, red))
    pi_node = _push!(nodes, IR.ScalePow2(pi2_node, 1, red))
    function subtract(source, constant)
        product =
            evaluation == :separate ? _push!(nodes, IR.Mul(source, minus_one, red)) :
            nothing
        value =
            product === nothing ? _push!(nodes, IR.FMA(source, minus_one, constant, red)) :
            _push!(nodes, IR.Add(constant, product, red))
        return (; value, product)
    end
    is_asin = geometry.transformation == :asin
    central_minus = is_asin ? nothing : subtract(kernel_wide, pi2_node)
    central_plus = is_asin ? nothing : _push!(nodes, IR.Add(pi2_node, kernel_wide, red))
    central =
        is_asin ? kernel_wide :
        _push!(nodes, IR.Select(negative, central_plus, central_minus.value))
    tail_subtraction = subtract(doubled, is_asin ? pi2_node : pi_node)
    tail =
        is_asin ? tail_subtraction.value :
        _push!(nodes, IR.Select(negative, tail_subtraction.value, doubled))
    selected = _push!(nodes, IR.Select(is_tail, tail, central))
    signed = is_asin ? _push!(nodes, IR.CopySign(selected, 1)) : selected
    converted = _precision_convert!(nodes, signed, red, spec.output_format)
    zero_output = _push!(nodes, IR.constant(0, spec.output_format))
    pi2_output = _push!(nodes, IR.Convert(pi2_node, spec.output_format))
    pi_output = _push!(nodes, IR.Convert(pi_node, spec.output_format))
    endpoint_signed = is_asin ? _push!(nodes, IR.CopySign(pi2_node, 1)) : nothing
    endpoint_value =
        is_asin ? _push!(nodes, IR.Convert(endpoint_signed, spec.output_format)) :
        _push!(nodes, IR.Select(negative, pi_output, zero_output))
    endpoint_select = _push!(nodes, IR.Select(is_endpoint, endpoint_value, converted))
    zero = _push!(nodes, IR.Classify(:zero, 1))
    zero_value = is_asin ? _push!(nodes, IR.Convert(1, spec.output_format)) : pi2_output
    zero_select = _push!(nodes, IR.Select(zero, zero_value, endpoint_select))
    output = _polynomial_guard!(nodes, zero_select, spec)
    constant_ids = findall(
        n ->
            n isa IR.Const &&
                n.format isa PolynomialFormat &&
                !(
                    n.format isa FloatFormat &&
                    decode_ieee(n.bits, n.format).value === nothing
                ),
        nodes,
    )
    common = (;
        magnitude,
        wide,
        negated_magnitude,
        gap,
        t,
        mantissa,
        root_coordinate,
        root_value,
        tail_argument,
        central_argument,
        argument,
        square,
        q,
        kernel,
        kernel_wide,
        doubled,
        pi2,
        pi2_node,
        pi_node,
        central,
        central_minus,
        central_plus,
        tail,
        tail_subtraction,
        selected,
        signed,
        converted,
        zero_value,
        endpoint_value,
        pi2_output,
        pi_output,
        reduction_format = red,
        coefficients = asin_coefficients,
        coordinate = square,
        domain = (_q(0), _q(1 // 4)),
        result = q,
        reconstruction_coordinate = argument,
    )
    paths = map(geometry.branches) do branch
        if branch.special
            source = branch.kind == :zero ? zero_value : endpoint_value
            choices = Dict{Int, Int}()
            !is_asin &&
                branch.kind != :zero &&
                (choices[endpoint_value] = branch.negative ? pi_output : zero_output)
            conversion =
                !is_asin && branch.kind != :zero ?
                (branch.negative ? pi_output : zero_output) : source
            merge(
                common,
                branch,
                (;
                    result = source,
                    output_conversion = conversion,
                    output_source = source,
                    range_roots = (source, magnitude, constant_ids...),
                    range_choices = choices,
                    range_aliases = Dict(
                        endpoint_select => source,
                        zero_select => source,
                        output => source,
                    ),
                ),
            )
        else
            root_geometry =
                branch.tail ?
                _root_geometry(
                    FunctionSpec(
                        "sqrt(x)";
                        input_format = red,
                        output_format = red,
                        domain = branch.t_domain,
                    ),
                    :sqrt,
                ) : nothing
            root_kernel = merge(
                root_horner,
                (;
                    coefficients = sqrt_coefficients,
                    coordinate = root_coordinate,
                    domain = (_q(1), _q(4)),
                    result = root_horner.final,
                ),
            )
            choices = Dict(
                argument => branch.tail ? tail_argument : central_argument,
                selected => branch.tail ? tail : central,
            )
            if !is_asin
                choices[central] = branch.negative ? central_plus : central_minus.value
                choices[tail] = branch.negative ? tail_subtraction.value : doubled
            end
            constant_factor =
                is_asin ? (branch.tail ? 1 : 0) :
                (branch.tail ? (branch.negative ? 2 : 0) : 1)
            merge(
                asin_horner,
                common,
                branch,
                (;
                    root_geometry,
                    root_kernel,
                    mantissa_domain = branch.tail ? root_geometry.mantissa_domain : nothing,
                    scale_domain = branch.tail ? root_geometry.scale_domain : nothing,
                    scale_exponents = branch.tail ? root_geometry.scale_exponents : nothing,
                    reconstruction_bound = branch.tail ? _q(2) : _q(1),
                    constant_factor,
                    output_conversion = converted,
                    output_source = converted,
                    range_roots = (converted, argument, square, constant_ids...),
                    range_choices = choices,
                    range_aliases = Dict(
                        endpoint_select => converted,
                        zero_select => converted,
                        output => converted,
                    ),
                ),
            )
        end
    end
    return (;
        program = IR.Program(nodes; output),
        precision,
        paths,
        geometry,
        asin_coefficients,
        sqrt_coefficients,
        asin_nodes,
        sqrt_nodes,
        coefficient_nodes = (asin_nodes..., sqrt_nodes...),
        pi2_node,
        pi2,
        reduction_format = red,
    )
end

"""
    inverse_trig_polynomial_plan(spec, asin_coefficients, sqrt_coefficients, pi2;
        precision=nothing, internal_format=spec.output_format, evaluation=:separate)

Build an uncertified bounded asin/acos evaluator on a domain inside [-1,1]. Two
ascending lists describe q in r*q(r²) on [0,1/2] and sqrt(m) on [1,4]. At |x|>1/2,
form exact t=(1-|x|)/2, use exponent-split polynomial sqrt(t), then reconstruct
from asin(sqrt(t)). Acos uses 2*asin(sqrt(t)) near +1. Endpoints and zeros are lazy;
stored pi/2, root, kernel and reconstruction errors require a complete certificate.
"""
function inverse_trig_polynomial_plan(
    spec::FunctionSpec,
    asin_coefficients,
    sqrt_coefficients,
    pi2;
    precision::Union{Nothing, PolynomialPrecision} = nothing,
    internal_format::PolynomialFormat = precision === nothing ? spec.output_format :
                                        precision.coordinate_format,
    evaluation::Symbol = :separate,
)
    precision === nothing && (
        precision = PolynomialPrecision(
            internal_format;
            coefficient_formats = fill(internal_format, length(asin_coefficients)),
            stage_formats = fill(internal_format, length(asin_coefficients)),
        )
    )
    internal_format == precision.coordinate_format ||
        throw(ArgumentError("internal format must match coordinate precision"))
    layout = _inverse_trig_layout(
        spec,
        collect(asin_coefficients),
        collect(sqrt_coefficients),
        pi2,
        precision,
        evaluation,
    )
    PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "inverse_trig_polynomial_horner",
            "transformation" => string(layout.geometry.transformation),
            "evaluation" => string(evaluation),
        ),
    )
end

function _inverse_trig_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing inverse trig evaluator"))
    get(plan.settings, "transformation", "") == string(_primitive(plan.spec.expression)) ||
        throw(ArgumentError("invalid inverse trig transformation"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported inverse trig metadata dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "inverse trig proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    zeros = fill(0, length(plan.precision.coefficient_formats))
    evaluation = Symbol(get(plan.settings, "evaluation", ""))
    skeleton = _inverse_trig_layout(plan.spec, zeros, zeros, 0, plan.precision, evaluation)
    length(plan.program.nodes) == length(skeleton.program.nodes) ||
        throw(ArgumentError("incomplete inverse trig graph"))
    ids = (skeleton.coefficient_nodes..., skeleton.pi2_node)
    all(ids) do i
        n = plan.program.nodes[i]
        n isa IR.Const && n.format == IR.format(skeleton.program, i)
    end || throw(ArgumentError("unsupported inverse trig constant storage"))
    value(i) = _polynomial_value(plan.program.nodes[i].bits, plan.program.nodes[i].format)
    layout = _inverse_trig_layout(
        plan.spec,
        value.(skeleton.asin_nodes),
        value.(skeleton.sqrt_nodes),
        value(skeleton.pi2_node),
        plan.precision,
        evaluation,
    )
    layout.precision == plan.precision ||
        throw(ArgumentError("precision metadata exceeds degree"))
    nodes = collect(layout.program.nodes)
    for i in ids
        nodes[i] = plan.program.nodes[i]
    end
    _program_data(IR.Program(nodes; output = layout.program.output)) ==
    _program_data(plan.program) || throw(
        ArgumentError("executed graph differs from the supported inverse trig evaluator"),
    )
    return layout
end

function _reformat_inverse_trig(plan, precision)
    old = _inverse_trig_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    new = _inverse_trig_layout(
        plan.spec,
        old.asin_coefficients,
        old.sqrt_coefficients,
        old.pi2,
        precision,
        Symbol(plan.settings["evaluation"]),
    )
    nodes = collect(new.program.nodes)
    for (source, target) in zip(
        (old.coefficient_nodes..., old.pi2_node),
        (new.coefficient_nodes..., new.pi2_node),
    )
        nodes[target] = plan.program.nodes[source]
    end
    PlanArtifact(
        plan.spec;
        program = IR.Program(nodes; output = new.program.output),
        precision = new.precision,
        settings = plan.settings,
    )
end

function _certified_inverse_trig(
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
    precision_layout === nothing && (
        precision_layout = PolynomialPrecision(
            internal_format;
            coefficient_formats = fill(internal_format, degree + 1),
            stage_formats = fill(internal_format, degree + 1),
        )
    )
    precision_layout = _precision_prefix(precision_layout, degree + 1)
    settings = Dict(
        "degree" => string(degree),
        "generation_precision" => string(generation_precision),
    )
    candidate = try
        geometry = _inverse_trig_geometry(spec)
        asin_cs = [binomial(big(2j), j) // (big(4)^j * (2j + 1)) for j = 0:degree]
        sqrt_cs = if any(p -> p.tail, geometry.branches)
            cs = _generated_polynomial_coefficients(
                FunctionSpec(
                    "sqrt(x)";
                    input_format = spec.input_format,
                    output_format = spec.output_format,
                    domain = (1, 4),
                    absolute_error = spec.absolute_error,
                ),
                (_q(1), _q(4)),
                degree,
                precision_layout.coefficient_formats,
                generation_precision,
            )
            append!(cs, fill(_q(0), degree + 1 - length(cs)))
            cs
        else
            fill(_q(0), degree + 1)
        end
        bounds = _pi2_bounds(generation_precision)
        inverse_trig_polynomial_plan(
            spec,
            asin_cs,
            sqrt_cs,
            sum(bounds) / 2;
            precision = precision_layout,
            evaluation,
        )
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Inverse trig generation failed: " * sprint(showerror, err);
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
    _certify_inverse_trig(plan; precision = proof_precision, accuracy, max_refinements)
end

function _inverse_trig_special_certificate(plan, path, pi2_error)
    ranges, rho = _polynomial_ranges(plan.program, path)
    is_asin = _primitive(plan.spec.expression) == :asin
    factor =
        path.kind == :zero ? (is_asin ? 0 : 1) : (is_asin ? 1 : (path.negative ? 2 : 0))
    norm = (_q(0), factor * pi2_error)
    arithmetic = factor == 2 ? get(rho, path.pi_node, _q(0)) : _q(0)
    output = get(rho, path.output_conversion, _q(0))
    bounds = Tuple(
        _node_bound(i, IR.format(plan.program, i), range) for
        (i, range) in sort!(collect(ranges); by = first)
    )
    PathCertificate(
        path.input_domain,
        true,
        norm,
        _q(0),
        arithmetic,
        output,
        norm[2] + arithmetic + output,
        bounds,
    )
end

function _inverse_trig_path_certificate(plan, path, asin_norm, sqrt_norm, pi2_error, keep)
    ranges, rho = _polynomial_ranges(plan.program, path; stop_before = path.argument)
    eta_n, eta_c, eta_v = _q(0), _q(0), _q(0)
    overrides = Dict{Int, _Interval}()
    if path.tail
        rho[path.wide] ==
        rho[path.negated_magnitude] ==
        rho[path.gap] ==
        rho[path.t] ==
        0 || throw(ArgumentError("endpoint root coordinate (1-abs(x))/2 must be exact"))
        ranges[path.t] == path.t_domain ||
            throw(ArgumentError("endpoint coordinate range mismatch"))
        croot, vroot, load =
            _polynomial_arithmetic(plan.program, path.root_kernel, ranges, rho)
        scale = path.root_geometry.scale_domain[2]
        eta_n = scale * sqrt_norm[2]
        eta_c = scale * croot
        eta_v =
            scale * (vroot + load) +
            rho[path.root_value] +
            (path.tail_argument == path.root_value ? _q(0) : rho[path.tail_argument])
        image = _hyperbolic_image(keep, "sqrt(x)", path.t_domain)
        bound =
            eta_n + eta_c + eta_v -
            (path.tail_argument == path.root_value ? _q(0) : rho[path.tail_argument])
        root_range = (image[1] - bound, image[2] + bound)
        format = IR.format(plan.program, path.root_value)
        overrides[path.root_value] = (
            _polynomial_value(
                _polynomial_round(root_range[1], format; mode = :down),
                format,
            ),
            _polynomial_value(_polynomial_round(root_range[2], format; mode = :up), format),
        )
    else
        eta_c = path.central_argument == path.magnitude ? _q(0) : rho[path.central_argument]
    end
    ranges, rho = _polynomial_ranges(plan.program, path; range_overrides = overrides)
    if path.tail
        # Recompute local root reconstruction/cast bounds with the tighter root range.
        croot, vroot, load =
            _polynomial_arithmetic(plan.program, path.root_kernel, ranges, rho)
        eta_v =
            path.root_geometry.scale_domain[2] * (vroot + load) +
            rho[path.root_value] +
            (path.tail_argument == path.root_value ? _q(0) : rho[path.tail_argument])
    end
    argument_bound = _interval_magnitude(ranges[path.argument])
    zero_coordinate = merge(path, (; coordinate_formation_error = _q(0)))
    c0, v, loading = _polynomial_arithmetic(plan.program, zero_coordinate, ranges, rho)
    c1, _, _ = _polynomial_arithmetic(
        plan.program,
        merge(path, (; coordinate_formation_error = _q(1))),
        ranges,
        rho,
    )
    slope_z = c1 - c0
    exact_q = _singleton(path.coefficients[end])
    for coefficient in reverse(path.coefficients[1:(end - 1)])
        exact_q =
            _interval_add(_interval_mul(exact_q, path.domain), _singleton(coefficient))
    end
    slope_r =
        argument_bound * slope_z * (argument_bound + 1 // 2) + _interval_magnitude(exact_q)
    factor = path.reconstruction_bound
    norm = (
        _q(0),
        factor * (asin_norm[2] + slope_r * eta_n) + path.constant_factor * pi2_error,
    )
    coordinate = factor * (argument_bound * c0 + slope_r * eta_c)
    arithmetic =
        factor * (
            argument_bound * (v + loading) +
            argument_bound * slope_z * rho[path.square] +
            slope_r * eta_v +
            rho[path.kernel] +
            (path.kernel_wide == path.kernel ? _q(0) : rho[path.kernel_wide])
        )
    if path.tail
        arithmetic += rho[path.doubled]
        if _primitive(plan.spec.expression) == :asin || path.negative
            arithmetic +=
                rho[path.tail_subtraction.value] + (
                    path.tail_subtraction.product === nothing ? _q(0) :
                    rho[path.tail_subtraction.product]
                )
        end
        path.constant_factor == 2 && (arithmetic += rho[path.pi_node])
    elseif _primitive(plan.spec.expression) == :acos
        arithmetic +=
            path.negative ? rho[path.central_plus] :
            rho[path.central_minus.value] + (
                path.central_minus.product === nothing ? _q(0) :
                rho[path.central_minus.product]
            )
    end
    output = get(rho, path.output_conversion, _q(0))
    bounds = Tuple(
        _node_bound(i, IR.format(plan.program, i), range) for
        (i, range) in sort!(collect(ranges); by = first)
    )
    PathCertificate(
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

function _certify_inverse_trig(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "inverse_trig_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _inverse_trig_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
        return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
    end
    certificates = try
        pi2_bounds = _pi2_bounds(precision)
        pi2_error = maximum(abs(layout.pi2 - p) for p in pi2_bounds)
        settings["pi2_error_bound"] = _rational_text(pi2_error)
        Sollya.with_session(Sollya.Session(; precision)) do
            Sollya.with_objects() do keep
                numeric = any(p -> !p.special, layout.paths)
                tails = any(p -> p.tail, layout.paths)
                asin_p =
                    numeric ?
                    keep(_stored_polynomial(_odd_expansion(layout.asin_coefficients))) :
                    nothing
                asin_f = numeric ? keep(Sollya.sollya("asin(x)")) : nothing
                asin_domain = numeric ? keep(Sollya.interval(0, 1 // 2)) : nothing
                sqrt_p =
                    tails ? keep(_stored_polynomial(layout.sqrt_coefficients)) : nothing
                sqrt_f = tails ? keep(Sollya.sollya("sqrt(x)")) : nothing
                sqrt_domain = tails ? keep(Sollya.interval(1, 4)) : nothing
                tightness = _q(accuracy)
                result = PathCertificate[]
                for refinement = 0:max_refinements
                    asin_norm =
                        numeric ?
                        _polynomial_norm(asin_p, asin_f, asin_domain, tightness) :
                        (_q(0), _q(0))
                    sqrt_norm =
                        tails ?
                        _polynomial_norm(sqrt_p, sqrt_f, sqrt_domain, tightness) :
                        (_q(0), _q(0))
                    all(n -> 0 <= n[1] <= n[2], (asin_norm, sqrt_norm)) || throw(
                        ArgumentError("invalid inverse trig kernel norm enclosure"),
                    )
                    result = [
                        p.special ?
                        _inverse_trig_special_certificate(plan, p, pi2_error) :
                        _inverse_trig_path_certificate(
                            plan,
                            p,
                            asin_norm,
                            sqrt_norm,
                            pi2_error,
                            keep,
                        ) for p in layout.paths
                    ]
                    maximum(c.total for c in result) <= plan.spec.absolute_error &&
                        break
                    tightness /= 4
                end
                result
            end
        end
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(plan, :proof_failed, sprint(showerror, err); settings)
    end
    total = maximum(p.total for p in certificates)
    status = total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    CertificationResult(
        plan,
        status,
        total,
        Tuple(certificates),
        nothing,
        settings,
        status == :certified ?
        "Audited endpoint coordinates, composed root/asin kernels and reconstruction meet the target" :
        "Conservative inverse trig evaluator bound exceeds the target",
    )
end
