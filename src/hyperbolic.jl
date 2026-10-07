function _hyperbolic_geometry(spec, transformation = _primitive(spec.expression))
    transformation in (:sinh, :cosh) && _primitive(spec.expression) == transformation ||
        throw(
            ArgumentError("hyperbolic transformation requires matching sinh(x) or cosh(x)"),
        )
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("hyperbolic reconstruction requires floating interfaces"))
    spec.domain !== nothing || throw(
        ArgumentError("hyperbolic reconstruction requires an explicit bounded domain"),
    )
    domain = _polynomial_domain(spec)
    successor = decode_ieee(round_ieee(1, spec.input_format) + 1, spec.input_format).value
    branches = NamedTuple[]
    for (kind, lo, hi) in (
        (:negative_tail, domain[1], min(domain[2], -successor)),
        (:central, max(domain[1], -_q(1)), min(domain[2], _q(1))),
        (:positive_tail, max(domain[1], successor), domain[2]),
    )
        lo <= hi || continue
        magnitude_domain =
            (lo <= 0 <= hi ? _q(0) : min(abs(lo), abs(hi)), max(abs(lo), abs(hi)))
        tail = kind != :central
        push!(
            branches,
            (;
                kind,
                tail,
                input_domain = (lo, hi),
                magnitude_domain,
                domain = tail ? (_q(-1 // 2), _q(1 // 2)) :
                         _odd_square_domain(magnitude_domain),
                negative = lo < 0 && hi <= 0,
                both_signs = lo < 0 < hi,
            ),
        )
    end
    width = max(3, ndigits(ceil(BigInt, 2 * _interval_magnitude(domain) + 4); base = 2) + 1)
    return (;
        transformation,
        accepted_domain = domain,
        branches,
        exponent_format = FixedFormat(width, width),
        zero_only = domain == (0, 0),
    )
end

function _hyperbolic_layout(
    spec,
    central_coefficients,
    exp_coefficients,
    log2,
    inverse_log2,
    precision,
    evaluation,
)
    geometry = _hyperbolic_geometry(spec)
    count = length(exp_coefficients)
    length(central_coefficients) == count && 1 <= count <= 16 || throw(
        ArgumentError("hyperbolic kernels require two equal lists of 1:16 coefficients"),
    )
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported evaluation"))
    precision = _precision_prefix(precision, count)
    f = precision.coordinate_format
    f isa FixedFormat &&
        !f.signed &&
        throw(ArgumentError("hyperbolic kernels require signed coordinates"))
    base = _exp_reduction_format(spec, precision)
    # Reconstruction has extra exponent range: exp(a)/2 can be finite even
    # when exp(a) is not representable in the output format.
    reduction_format = FloatFormat(
        max(base.exponent_bits, spec.output_format.exponent_bits + 1),
        base.fraction_bits,
    )
    stored(cs) = [
        _polynomial_value(_polynomial_round(_q(c), cf), cf) for
        (c, cf) in zip(cs, precision.coefficient_formats)
    ]
    central_coefficients, exp_coefficients =
        stored(central_coefficients), stored(exp_coefficients)
    log2 = _polynomial_value(round_ieee(_q(log2), reduction_format), reduction_format)
    inverse_log2 =
        _polynomial_value(round_ieee(_q(inverse_log2), reduction_format), reduction_format)
    nodes = IR.Node[IR.Input(spec.input_format)]
    zero_constant = _push!(nodes, IR.constant(0, spec.input_format))
    magnitude = _push!(nodes, IR.CopySign(1, zero_constant))
    one = _push!(nodes, IR.constant(1, spec.input_format))
    is_tail = _push!(nodes, IR.Compare(:gt, magnitude, one))
    wide = _precision_convert!(nodes, magnitude, spec.input_format, reduction_format)
    argument = _precision_convert!(nodes, magnitude, spec.input_format, f)
    square = _push!(nodes, IR.Mul(argument, argument, f))
    central_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(central_coefficients, precision.coefficient_formats)
    ]
    central_horner = _precision_horner!(nodes, square, central_nodes, precision, evaluation)
    q = _precision_convert!(nodes, central_horner.final, precision.stage_formats[1], f)
    central = geometry.transformation == :sinh ? _push!(nodes, IR.Mul(argument, q, f)) : q
    central_wide = _precision_convert!(nodes, central, f, reduction_format)

    inverse_node = _push!(nodes, IR.constant(inverse_log2, reduction_format))
    selection_product = _push!(nodes, IR.Mul(wide, inverse_node, reduction_format))
    exponent = _push!(nodes, IR.Convert(selection_product, geometry.exponent_format))
    exponent_value = _push!(nodes, IR.Convert(exponent, reduction_format))
    log2_node = _push!(nodes, IR.constant(log2, reduction_format))
    negative_log2_node = _push!(nodes, IR.constant(-log2, reduction_format))
    product =
        evaluation == :separate ?
        _push!(nodes, IR.Mul(exponent_value, negative_log2_node, reduction_format)) :
        nothing
    residual =
        product === nothing ?
        _push!(nodes, IR.FMA(exponent_value, negative_log2_node, wide, reduction_format)) :
        _push!(nodes, IR.Add(wide, product, reduction_format))
    minus_one = _push!(nodes, IR.constant(-1, reduction_format))
    negative_residual = _push!(nodes, IR.Mul(residual, minus_one, reduction_format))
    coordinate = _precision_convert!(nodes, residual, reduction_format, f)
    negative_coordinate = _precision_convert!(nodes, negative_residual, reduction_format, f)
    integer_minus_one = _push!(nodes, IR.constant(-1, geometry.exponent_format))
    positive_exponent =
        _push!(nodes, IR.Add(exponent, integer_minus_one, geometry.exponent_format))
    negative_exponent =
        _push!(nodes, IR.Mul(exponent, integer_minus_one, geometry.exponent_format))
    negative_exponent = _push!(
        nodes,
        IR.Add(negative_exponent, integer_minus_one, geometry.exponent_format),
    )
    exp_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(exp_coefficients, precision.coefficient_formats)
    ]
    positive_horner =
        _precision_horner!(nodes, coordinate, exp_nodes, precision, evaluation)
    negative_horner =
        _precision_horner!(nodes, negative_coordinate, exp_nodes, precision, evaluation)
    positive_scaled = _push!(
        nodes,
        IR.ScaleByExponent(positive_horner.final, positive_exponent, reduction_format),
    )
    negative_scaled = _push!(
        nodes,
        IR.ScaleByExponent(negative_horner.final, negative_exponent, reduction_format),
    )
    correction =
        geometry.transformation == :sinh ?
        _push!(nodes, IR.Mul(negative_scaled, minus_one, reduction_format)) :
        negative_scaled
    reconstructed = _push!(nodes, IR.Add(positive_scaled, correction, reduction_format))
    selected = _push!(nodes, IR.Select(is_tail, reconstructed, central_wide))
    converted = _precision_convert!(nodes, selected, reduction_format, spec.output_format)
    restored =
        geometry.transformation == :sinh ? _push!(nodes, IR.CopySign(converted, 1)) :
        converted
    zero = _push!(nodes, IR.Classify(:zero, 1))
    zero_value =
        geometry.transformation == :sinh ?
        _push!(nodes, IR.Convert(1, spec.output_format)) :
        _push!(nodes, IR.constant(1, spec.output_format))
    zero_select = _push!(nodes, IR.Select(zero, zero_value, restored))
    guarded = _polynomial_guard!(nodes, zero_select, spec)
    infinity = _push!(nodes, IR.Classify(:infinity, 1))
    positive_infinity =
        _push!(nodes, IR.Const(spec.output_format, _inf(spec.output_format)))
    limit =
        geometry.transformation == :sinh ?
        _push!(nodes, IR.CopySign(positive_infinity, 1)) : positive_infinity
    output = _push!(nodes, IR.Select(infinity, limit, guarded))
    common = (;
        magnitude,
        argument,
        square,
        central,
        central_wide,
        wide,
        reduction_format,
        inverse_log2,
        inverse_node,
        selection_product,
        exponent_node = exponent,
        exponent_value,
        log2,
        log2_node,
        negative_log2_node,
        product,
        residual,
        negative_residual,
        exponent_format = geometry.exponent_format,
        positive_scaled,
        negative_scaled,
        correction,
        reconstructed,
        selected,
        output_conversion = converted,
        output_source = restored,
        range_roots = (restored, findall(n -> n isa IR.Const, nodes)...),
        range_aliases = Dict(
            zero_select => restored,
            guarded => restored,
            output => restored,
        ),
    )
    paths = [
        merge(
            branch.tail ? positive_horner : central_horner,
            branch,
            common,
            (;
                coefficients = branch.tail ? exp_coefficients : central_coefficients,
                coordinate = branch.tail ? coordinate : square,
                result = branch.tail ? positive_horner.final : q,
                output_node = positive_scaled,
                negative_kernel = merge(
                    negative_horner,
                    (;
                        coefficients = exp_coefficients,
                        coordinate = negative_coordinate,
                        result = negative_horner.final,
                        domain = (_q(-1 // 2), _q(1 // 2)),
                    ),
                ),
                range_choices = Dict(
                    selected => (branch.tail ? reconstructed : central_wide),
                ),
                range_roots = branch.tail ?
                              (common.range_roots..., coordinate, negative_coordinate) :
                              (common.range_roots..., argument),
            ),
        ) for branch in geometry.branches
    ]
    return (;
        program = IR.Program(nodes; output),
        precision,
        paths,
        geometry,
        coefficient_nodes = (central_nodes..., exp_nodes...),
        central_nodes,
        exp_nodes,
        central_coefficients,
        exp_coefficients,
        log2_node,
        inverse_node,
        negative_log2_node,
    )
end

"""
    hyperbolic_polynomial_plan(spec, central_coefficients, exp_coefficients,
                              log2, inverse_log2; precision=nothing,
                              internal_format=spec.output_format, evaluation=:separate)

Build an uncertified bounded sinh/cosh evaluator with floating interfaces.
Equal ascending coefficient lists describe central q(x²) and reduced exp(r).
For |x|≤1 evaluate |x|*q(x²) for sinh or q(x²) for cosh. Otherwise form
r=|x|-k*log2 and combine 2^(k-1)*p(r) with 2^(-k-1)*p(-r), in a widened
floating format, before the output conversion. Sinh restores the input sign.
Lazy zero, infinity and domain branches are explicit. Degree denotes the degree
of each kernel (0:15); central sinh/cosh degrees are 2d+1 and 2d respectively.
"""
function hyperbolic_polynomial_plan(
    spec::FunctionSpec,
    central_coefficients,
    exp_coefficients,
    log2,
    inverse_log2;
    precision::Union{Nothing, PolynomialPrecision} = nothing,
    internal_format::PolynomialFormat = precision === nothing ? spec.output_format :
                                        precision.coordinate_format,
    evaluation::Symbol = :separate,
)
    precision === nothing && (
        precision = PolynomialPrecision(
            internal_format;
            coefficient_formats = fill(internal_format, length(exp_coefficients)),
            stage_formats = fill(internal_format, length(exp_coefficients)),
        )
    )
    internal_format == precision.coordinate_format ||
        throw(ArgumentError("internal format must match coordinate precision"))
    layout = _hyperbolic_layout(
        spec,
        collect(central_coefficients),
        collect(exp_coefficients),
        log2,
        inverse_log2,
        precision,
        evaluation,
    )
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "hyperbolic_polynomial_horner",
            "transformation" => string(layout.geometry.transformation),
            "evaluation" => string(evaluation),
        ),
    )
end

function _hyperbolic_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing hyperbolic evaluator"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported hyperbolic metadata dispatch"))
    _hyperbolic_geometry(plan.spec, Symbol(get(plan.settings, "transformation", "")))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "hyperbolic proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    zeros = fill(0, length(plan.precision.coefficient_formats))
    skeleton = _hyperbolic_layout(
        plan.spec,
        zeros,
        zeros,
        0,
        0,
        plan.precision,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    length(plan.program.nodes) == length(skeleton.program.nodes) ||
        throw(ArgumentError("incomplete hyperbolic graph"))
    ids = (
        skeleton.coefficient_nodes...,
        skeleton.log2_node,
        skeleton.inverse_node,
        skeleton.negative_log2_node,
    )
    all(ids) do i
        n = plan.program.nodes[i]
        n isa IR.Const && n.format == IR.format(skeleton.program, i)
    end || throw(ArgumentError("unsupported hyperbolic constant storage"))
    value(i) = _polynomial_value(plan.program.nodes[i].bits, plan.program.nodes[i].format)
    log2, inverse = value(skeleton.log2_node), value(skeleton.inverse_node)
    value(skeleton.negative_log2_node) == -log2 ||
        throw(ArgumentError("inconsistent hyperbolic reduction constants"))
    layout = _hyperbolic_layout(
        plan.spec,
        value.(skeleton.central_nodes),
        value.(skeleton.exp_nodes),
        log2,
        inverse,
        plan.precision,
        Symbol(plan.settings["evaluation"]),
    )
    layout.precision == plan.precision ||
        throw(ArgumentError("precision metadata exceeds degree"))
    nodes = collect(layout.program.nodes)
    for i in ids
        nodes[i] = plan.program.nodes[i]
    end
    _program_data(IR.Program(nodes; output = layout.program.output)) ==
    _program_data(plan.program) || throw(
        ArgumentError("executed graph differs from the supported hyperbolic evaluator"),
    )
    return layout
end

function _reformat_hyperbolic(plan, precision)
    old = _hyperbolic_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    path = first(old.paths)
    new = _hyperbolic_layout(
        plan.spec,
        old.central_coefficients,
        old.exp_coefficients,
        path.log2,
        path.inverse_log2,
        precision,
        Symbol(plan.settings["evaluation"]),
    )
    nodes = collect(new.program.nodes)
    for (source, target) in zip(
        (old.coefficient_nodes..., old.log2_node, old.inverse_node, old.negative_log2_node),
        (new.coefficient_nodes..., new.log2_node, new.inverse_node, new.negative_log2_node),
    )
        nodes[target] = plan.program.nodes[source]
    end
    return PlanArtifact(
        plan.spec;
        program = IR.Program(nodes; output = new.program.output),
        precision = new.precision,
        settings = plan.settings,
    )
end

function _certified_hyperbolic(
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
    geometry = _hyperbolic_geometry(spec)
    precision_layout === nothing && (
        precision_layout = PolynomialPrecision(
            internal_format;
            coefficient_formats = fill(internal_format, degree + 1),
            stage_formats = fill(internal_format, degree + 1),
        )
    )
    settings = Dict(
        "degree" => string(degree),
        "generation_precision" => string(generation_precision),
    )
    candidate = try
        parity = geometry.transformation == :sinh ? 1 : 0
        # Taylor coefficients are exact rationals before storage quantization.
        # Certification uses the actual stored expanded polynomial, not a quotient.
        central = [1 // factorial(BigInt(2j + parity)) for j = 0:degree]
        exp_spec = FunctionSpec(
            "exp(x)";
            input_format = spec.input_format,
            output_format = spec.output_format,
            domain = (-1 // 2, 1 // 2),
            absolute_error = spec.absolute_error,
        )
        tail =
            any(b -> b.tail, geometry.branches) ?
            _generated_polynomial_coefficients(
                exp_spec,
                (_q(-1 // 2), _q(1 // 2)),
                degree,
                _precision_prefix(precision_layout, degree + 1).coefficient_formats,
                generation_precision,
            ) : [_q(0)]
        append!(tail, fill(_q(0), degree + 1 - length(tail)))
        bounds =
            any(b -> b.tail, geometry.branches) ? _log2_bounds(generation_precision) :
            (_q(1), _q(1))
        hyperbolic_polynomial_plan(
            spec,
            central,
            tail,
            sum(bounds) / 2,
            (inv(bounds[2]) + inv(bounds[1])) / 2;
            precision = precision_layout,
            evaluation,
        )
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Hyperbolic generation failed: " * sprint(showerror, err);
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
    return _certify_hyperbolic(plan; precision = proof_precision, accuracy, max_refinements)
end

function _hyperbolic_central_bounds(plan, path)
    ranges, rho = _polynomial_ranges(plan.program, path)
    eta_x = get(rho, path.argument, _q(0))
    xbound = _interval_magnitude(ranges[path.argument])
    radius = path.magnitude_domain[2]
    eta_z = eta_x * (xbound + radius) + get(rho, path.coordinate, _q(0))
    coordinate, arithmetic, loading = _polynomial_arithmetic(
        plan.program,
        merge(path, (; coordinate_formation_error = eta_z)),
        ranges,
        rho,
    )
    if _primitive(plan.spec.expression) == :sinh
        exact_q = _singleton(path.coefficients[end])
        for c in reverse(path.coefficients[1:(end - 1)])
            exact_q = _interval_add(_interval_mul(exact_q, path.domain), _singleton(c))
        end
        coordinate = xbound * coordinate + eta_x * _interval_magnitude(exact_q)
        arithmetic = xbound * (arithmetic + loading) + rho[path.central]
    else
        arithmetic += loading
    end
    path.central_wide == path.central || (arithmetic += rho[path.central_wide])
    return (;
        ranges,
        rho,
        coordinate,
        arithmetic,
        output = get(rho, path.output_conversion, _q(0)),
    )
end

function _hyperbolic_expansion(coefficients, sinh)
    expanded = fill(_q(0), 2length(coefficients) - (sinh ? 0 : 1))
    expanded[(sinh ? 2 : 1):2:end] .= coefficients
    return expanded
end

function _hyperbolic_image(keep, expression, domain)
    interval = keep(Sollya.interval(domain...))
    Sollya.bounds(interval) == domain ||
        throw(ArgumentError("native proof domain enlargement"))
    return Sollya.bounds(keep(Sollya.enclosure(keep(Sollya.sollya(expression)), interval)))
end

function _hyperbolic_tail_certificate(
    plan,
    path,
    keep,
    log2_bounds,
    accuracy,
    max_refinements,
)
    reduction = _exp_reduction_bounds(plan, path, log2_bounds; exponent_headroom = 2)
    path = reduction.path
    kmin, kmax = path.exponents
    positive_scale, negative_scale = _pow2(Int(kmax - 1)), _pow2(Int(-kmin - 1))
    scale_uppers =
        Dict(path.positive_scaled => positive_scale, path.negative_scaled => negative_scale)
    path = merge(path, (; scale_uppers))
    cpos, vpos, _ =
        _polynomial_arithmetic(plan.program, path, reduction.ranges, reduction.rho)
    negative_kernel = merge(
        path.negative_kernel,
        (; coordinate_formation_error = path.coordinate_formation_error),
    )
    cneg, vneg, _ = _polynomial_arithmetic(
        plan.program,
        negative_kernel,
        reduction.ranges,
        reduction.rho,
    )
    coordinate = positive_scale * cpos + negative_scale * cneg
    evaluation = positive_scale * vpos + negative_scale * vneg
    polynomial = keep(_stored_polynomial(path.coefficients))
    function_object = keep(Sollya.sollya("exp(x)"))
    interval = keep(Sollya.interval(path.domain...))
    Sollya.bounds(interval) == path.domain ||
        throw(ArgumentError("native proof domain enlargement"))
    image = Sollya.bounds(keep(Sollya.enclosure(function_object, interval)))
    function_image = _hyperbolic_image(keep, plan.spec.expression, path.magnitude_domain)
    tightness = _q(accuracy)
    certificate = nothing
    for refinement = 0:max_refinements
        raw = _polynomial_norm(polynomial, function_object, interval, tightness)
        0 <= raw[1] <= raw[2] ||
            throw(ArgumentError("invalid hyperbolic exp norm enclosure"))
        range_overrides = Dict{Int, _Interval}()
        for (kernel, c, v) in ((path, cpos, vpos), (negative_kernel, cneg, vneg))
            error = raw[2] + c + v
            format = IR.format(plan.program, kernel.final)
            range_overrides[kernel.final] = (
                _polynomial_value(
                    _polynomial_round(image[1] - error, format; mode = :down),
                    format,
                ),
                _polynomial_value(
                    _polynomial_round(image[2] + error, format; mode = :up),
                    format,
                ),
            )
        end
        ranges, rho = _polynomial_ranges(
            plan.program,
            path;
            stop_before = path.reconstructed,
            range_overrides,
            exact_overrides = reduction.exact_overrides,
        )
        scaled_rounding =
            rho[path.positive_scaled] +
            rho[path.negative_scaled] +
            (path.correction == path.negative_scaled ? _q(0) : rho[path.correction])
        norm = (positive_scale + negative_scale) * raw[2]
        before_add = norm + coordinate + evaluation + scaled_rounding
        # Monotonic function enclosure plus the proved two-term errors retains
        # their correlation at reconstruction, including the subtraction.
        exact_overrides = merge(
            reduction.exact_overrides,
            Dict(
                path.reconstructed =>
                    (function_image[1] - before_add, function_image[2] + before_add),
            ),
        )
        ranges, rho =
            _polynomial_ranges(plan.program, path; range_overrides, exact_overrides)
        arithmetic = evaluation + scaled_rounding + rho[path.reconstructed]
        output = get(rho, path.output_conversion, _q(0))
        total = norm + coordinate + arithmetic + output
        bounds = Tuple(
            _node_bound(i, IR.format(plan.program, i), range) for
            (i, range) in sort!(collect(ranges); by = first)
        )
        certificate = PathCertificate(
            path.input_domain,
            true,
            (_q(0), norm),
            coordinate,
            arithmetic,
            output,
            total,
            bounds,
        )
        (positive_scale + negative_scale) * raw[1] + coordinate + arithmetic + output <=
        plan.spec.absolute_error <
        total || break
        tightness /= 4
    end
    return certificate
end

function _certify_hyperbolic(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "hyperbolic_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _hyperbolic_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
        return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
    end
    layout.geometry.zero_only && return CertificationResult(
        plan,
        :certified,
        _q(0),
        (),
        nothing,
        settings,
        "Audited hyperbolic zero and infinity branches are exact",
    )
    certificates = try
        log2_bounds =
            any(b -> b.tail, layout.paths) ? _log2_bounds(precision) : (_q(1), _q(1))
        Sollya.with_session(Sollya.Session(; precision)) do
            Sollya.with_objects() do keep
                map(layout.paths) do path
                    path.tail && return _hyperbolic_tail_certificate(
                        plan,
                        path,
                        keep,
                        log2_bounds,
                        accuracy,
                        max_refinements,
                    )
                    bound = _hyperbolic_central_bounds(plan, path)
                    polynomial = keep(
                        _stored_polynomial(
                            _hyperbolic_expansion(
                                path.coefficients,
                                layout.geometry.transformation == :sinh,
                            ),
                        ),
                    )
                    f = keep(Sollya.sollya(plan.spec.expression))
                    interval = keep(Sollya.interval(0, path.magnitude_domain[2]))
                    Sollya.bounds(interval) == (0, path.magnitude_domain[2]) ||
                        throw(ArgumentError("native proof domain enlargement"))
                    norm, tightness = (_q(0), _q(0)), _q(accuracy)
                    for refinement = 0:max_refinements
                        norm = _polynomial_norm(polynomial, f, interval, tightness)
                        0 <= norm[1] <= norm[2] || throw(
                            ArgumentError("invalid central hyperbolic norm enclosure"),
                        )
                        norm[1] + bound.coordinate + bound.arithmetic + bound.output <=
                        plan.spec.absolute_error <
                        norm[2] + bound.coordinate + bound.arithmetic + bound.output ||
                            break
                        tightness /= 4
                    end
                    # The positive norm interval may enlarge a clipped branch.
                    norm = (_q(0), norm[2])
                    total = norm[2] + bound.coordinate + bound.arithmetic + bound.output
                    bounds = Tuple(
                        _node_bound(i, IR.format(plan.program, i), range) for
                        (i, range) in sort!(collect(bound.ranges); by = first)
                    )
                    PathCertificate(
                        path.input_domain,
                        true,
                        norm,
                        bound.coordinate,
                        bound.arithmetic,
                        bound.output,
                        total,
                        bounds,
                    )
                end
            end
        end
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(plan, :proof_failed, sprint(showerror, err); settings)
    end
    total = maximum(p.total for p in certificates)
    status = total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    return CertificationResult(
        plan,
        status,
        total,
        Tuple(certificates),
        nothing,
        settings,
        status == :certified ?
        "Audited central parity kernels and both scaled exponential terms meet the target" :
        "Conservative hyperbolic evaluator bound exceeds the target",
    )
end
