const _ERFC_SCALED_EXPRESSION = "exp(x*x)*erfc(x)"

function _erfc_geometry(spec)
    _primitive(spec.expression) == :erfc ||
        throw(ArgumentError("erfc transformation requires erfc(x)"))
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("erfc reconstruction requires floating interfaces"))
    spec.domain !== nothing ||
        throw(ArgumentError("erfc reconstruction requires an explicit bounded domain"))
    domain = _polynomial_domain(spec)
    successor = decode_ieee(round_ieee(1, spec.input_format) + 1, spec.input_format).value
    tiny = decode_ieee(1, spec.input_format).value
    branches = NamedTuple[]
    for (kind, lo, hi) in (
        (:negative_tail, domain[1], min(domain[2], -successor)),
        (:negative_central, max(domain[1], -_q(1)), min(domain[2], -tiny)),
        (:positive_central, max(domain[1], _q(0)), min(domain[2], _q(1))),
        (:positive_tail, max(domain[1], successor), domain[2]),
    )
        lo <= hi || continue
        tail = kind in (:negative_tail, :positive_tail)
        negative = hi < 0
        push!(
            branches,
            (;
                kind,
                tail,
                negative,
                input_domain = (lo, hi),
                magnitude_domain = negative ? (-hi, -lo) : (lo, hi),
            ),
        )
    end
    radius = _interval_magnitude(domain)
    width = max(3, ndigits(ceil(BigInt, 2radius^2 + 4); base = 2) + 1)
    return (;
        accepted_domain = domain,
        branches,
        radius,
        exponent_format = FixedFormat(width, width),
        zero_only = domain == (0, 0),
    )
end

function _erfc_normalization(geometry, format)
    domain = (_q(1), max(_q(2), geometry.radius))
    center = _polynomial_value(round_ieee(sum(domain) / 2, format), format)
    radius = maximum(abs(x - center) for x in domain)
    exponent = -_polynomial_binade(radius)
    radius * _pow2(exponent) > 1 && (exponent -= 1)
    typemin(Cint) <= exponent <= typemax(Cint) ||
        throw(ArgumentError("erfc normalization exponent exceeds C int range"))
    return (;
        center,
        exponent,
        domain = map(x -> (x - center) * _pow2(exponent), domain),
        argument_domain = domain,
    )
end

function _erfc_layout(
    spec,
    central_coefficients,
    scaled_coefficients,
    exp_coefficients,
    log2,
    inverse_log2,
    precision,
    evaluation,
)
    geometry = _erfc_geometry(spec)
    count = length(exp_coefficients)
    length(central_coefficients) == length(scaled_coefficients) == count &&
        1 <= count <= 33 || throw(
        ArgumentError("erfc kernels require three equal coefficient lists of length 1:33"),
    )
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported evaluation"))
    precision = _precision_prefix(precision, count)
    f = precision.coordinate_format
    f isa FixedFormat &&
        !f.signed &&
        throw(ArgumentError("erfc kernels require signed coordinates"))
    base = _exp_reduction_format(spec, precision)
    reduction_format = FloatFormat(
        max(
            base.exponent_bits,
            spec.input_format.exponent_bits + 1,
            spec.output_format.exponent_bits + 1,
        ),
        base.fraction_bits,
    )
    normalization = _erfc_normalization(geometry, reduction_format)
    stored(cs) = [
        _polynomial_value(_polynomial_round(_q(c), cf), cf) for
        (c, cf) in zip(cs, precision.coefficient_formats)
    ]
    central_coefficients, scaled_coefficients, exp_coefficients =
        stored(central_coefficients), stored(scaled_coefficients), stored(exp_coefficients)
    log2 = _polynomial_value(round_ieee(_q(log2), reduction_format), reduction_format)
    inverse_log2 =
        _polynomial_value(round_ieee(_q(inverse_log2), reduction_format), reduction_format)
    nodes = IR.Node[IR.Input(spec.input_format)]
    zero_constant = _push!(nodes, IR.constant(0, spec.input_format))
    magnitude = _push!(nodes, IR.CopySign(1, zero_constant))
    one = _push!(nodes, IR.constant(1, spec.input_format))
    is_tail = _push!(nodes, IR.Compare(:gt, magnitude, one))
    negative = _push!(nodes, IR.Classify(:negative, 1))
    wide = _precision_convert!(nodes, magnitude, spec.input_format, reduction_format)
    central_coordinate = _precision_convert!(nodes, magnitude, spec.input_format, f)
    central_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(central_coefficients, precision.coefficient_formats)
    ]
    central_horner =
        _precision_horner!(nodes, central_coordinate, central_nodes, precision, evaluation)
    central_wide = _precision_convert!(
        nodes,
        central_horner.final,
        precision.stage_formats[1],
        reduction_format,
    )
    center_node = _push!(nodes, IR.constant(-normalization.center, reduction_format))
    shifted = _push!(nodes, IR.Add(wide, center_node, reduction_format))
    normalized =
        _push!(nodes, IR.ScalePow2(shifted, normalization.exponent, reduction_format))
    scaled_coordinate = _precision_convert!(nodes, normalized, reduction_format, f)
    scaled_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(scaled_coefficients, precision.coefficient_formats)
    ]
    scaled_horner =
        _precision_horner!(nodes, scaled_coordinate, scaled_nodes, precision, evaluation)
    scaled_wide = _precision_convert!(
        nodes,
        scaled_horner.final,
        precision.stage_formats[1],
        reduction_format,
    )

    square = _push!(nodes, IR.Mul(wide, wide, reduction_format))
    minus_one = _push!(nodes, IR.constant(-1, reduction_format))
    negative_square = _push!(nodes, IR.Mul(square, minus_one, reduction_format))
    inverse_node = _push!(nodes, IR.constant(inverse_log2, reduction_format))
    selection_product =
        _push!(nodes, IR.Mul(negative_square, inverse_node, reduction_format))
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
        _push!(
            nodes,
            IR.FMA(exponent_value, negative_log2_node, negative_square, reduction_format),
        ) : _push!(nodes, IR.Add(negative_square, product, reduction_format))
    exp_coordinate = _precision_convert!(nodes, residual, reduction_format, f)
    exp_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(exp_coefficients, precision.coefficient_formats)
    ]
    exp_horner = _precision_horner!(nodes, exp_coordinate, exp_nodes, precision, evaluation)
    exp_wide = _precision_convert!(
        nodes,
        exp_horner.final,
        precision.stage_formats[1],
        reduction_format,
    )
    multiplied = _push!(nodes, IR.Mul(scaled_wide, exp_wide, reduction_format))
    tail_value = _push!(nodes, IR.ScaleByExponent(multiplied, exponent, reduction_format))
    selected = _push!(nodes, IR.Select(is_tail, tail_value, central_wide))
    two = _push!(nodes, IR.constant(2, reduction_format))
    negated =
        evaluation == :separate ?
        _push!(nodes, IR.Mul(selected, minus_one, reduction_format)) : nothing
    reflected =
        negated === nothing ?
        _push!(nodes, IR.FMA(minus_one, selected, two, reduction_format)) :
        _push!(nodes, IR.Add(two, negated, reduction_format))
    signed = _push!(nodes, IR.Select(negative, reflected, selected))
    converted = _precision_convert!(nodes, signed, reduction_format, spec.output_format)
    zero = _push!(nodes, IR.Classify(:zero, 1))
    zero_value = _push!(nodes, IR.constant(1, spec.output_format))
    zero_select = _push!(nodes, IR.Select(zero, zero_value, converted))
    guarded = _polynomial_guard!(nodes, zero_select, spec)
    infinity = _push!(nodes, IR.Classify(:infinity, 1))
    zero_limit = _push!(nodes, IR.constant(0, spec.output_format))
    two_limit = _push!(nodes, IR.constant(2, spec.output_format))
    limit = _push!(nodes, IR.Select(negative, two_limit, zero_limit))
    output = _push!(nodes, IR.Select(infinity, limit, guarded))
    common = (;
        magnitude,
        wide,
        reduction_format,
        square,
        negative_square,
        inverse_log2,
        inverse_node,
        selection_product,
        exponent_node = exponent,
        exponent_value,
        exponent_format = geometry.exponent_format,
        log2,
        log2_node,
        negative_log2_node,
        product,
        residual,
        multiplied,
        tail_value,
        selected,
        negated,
        reflected,
        signed,
        output_conversion = converted,
        output_source = converted,
        central_wide,
        scaled_wide,
        exp_wide,
        shifted,
        normalized,
        normalization,
        range_aliases = Dict(
            zero_select => converted,
            guarded => converted,
            output => converted,
        ),
    )
    roots = (converted, findall(n -> n isa IR.Const, nodes)...)
    paths = [
        merge(
            branch.tail ? exp_horner : central_horner,
            branch,
            common,
            (;
                coefficients = branch.tail ? exp_coefficients : central_coefficients,
                coordinate = branch.tail ? exp_coordinate : central_coordinate,
                domain = branch.tail ? (_q(-1 // 2), _q(1 // 2)) : (_q(0), _q(1)),
                result = branch.tail ? exp_wide : central_wide,
                output_node = multiplied,
                scaled_kernel = merge(
                    scaled_horner,
                    (;
                        coefficients = scaled_coefficients,
                        coordinate = scaled_coordinate,
                        result = scaled_wide,
                        domain = normalization.domain,
                    ),
                ),
                range_choices = Dict(
                    selected => (branch.tail ? tail_value : central_wide),
                    signed => (branch.negative ? reflected : selected),
                ),
                range_roots = branch.tail ?
                              (roots..., exp_coordinate, scaled_coordinate) :
                              (roots..., central_coordinate),
            ),
        ) for branch in geometry.branches
    ]
    return (;
        program = IR.Program(nodes; output),
        precision,
        paths,
        geometry,
        normalization,
        central_coefficients,
        scaled_coefficients,
        exp_coefficients,
        coefficient_nodes = (central_nodes..., scaled_nodes..., exp_nodes...),
        central_nodes,
        scaled_nodes,
        exp_nodes,
        log2_node,
        inverse_node,
        negative_log2_node,
    )
end

"""
    erfc_polynomial_plan(spec, central_coefficients, scaled_coefficients,
                         exp_coefficients, log2, inverse_log2; precision=nothing,
                         internal_format=spec.output_format, evaluation=:separate)

Build an uncertified bounded erfc evaluator with floating interfaces. Three equal
ascending coefficient lists describe erfc(a) on [0,1], normalized exp(a²)*erfc(a)
on the positive tail, and reduced exp(r) on [-1/2,1/2]. Form the rounded square
and residual in a widened floating format, multiply both tail kernels and scale
by 2^k before output rounding. Negative inputs reconstruct 2-erfc(abs(x)).
Zeros and infinity limits are exact lazy branches. Normalization is derived from
the contract; every operation, stored constant and branch is explicit in IR.
"""
function erfc_polynomial_plan(
    spec::FunctionSpec,
    central_coefficients,
    scaled_coefficients,
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
    layout = _erfc_layout(
        spec,
        collect(central_coefficients),
        collect(scaled_coefficients),
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
            "kernel" => "erfc_polynomial_horner",
            "transformation" => "erfc",
            "evaluation" => string(evaluation),
        ),
    )
end

function _erfc_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing erfc evaluator"))
    get(plan.settings, "transformation", "") == "erfc" ||
        throw(ArgumentError("invalid erfc transformation"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported erfc metadata dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "erfc proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    zeros = fill(0, length(plan.precision.coefficient_formats))
    skeleton = _erfc_layout(
        plan.spec,
        zeros,
        zeros,
        zeros,
        0,
        0,
        plan.precision,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    length(plan.program.nodes) == length(skeleton.program.nodes) ||
        throw(ArgumentError("incomplete erfc graph"))
    ids = (
        skeleton.coefficient_nodes...,
        skeleton.log2_node,
        skeleton.inverse_node,
        skeleton.negative_log2_node,
    )
    all(ids) do i
        n = plan.program.nodes[i]
        n isa IR.Const && n.format == IR.format(skeleton.program, i)
    end || throw(ArgumentError("unsupported erfc constant storage"))
    value(i) = _polynomial_value(plan.program.nodes[i].bits, plan.program.nodes[i].format)
    log2, inverse = value(skeleton.log2_node), value(skeleton.inverse_node)
    value(skeleton.negative_log2_node) == -log2 ||
        throw(ArgumentError("inconsistent erfc reduction constants"))
    layout = _erfc_layout(
        plan.spec,
        value.(skeleton.central_nodes),
        value.(skeleton.scaled_nodes),
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
    _program_data(plan.program) ||
        throw(ArgumentError("executed graph differs from the supported erfc evaluator"))
    return layout
end

function _reformat_erfc(plan, precision)
    old = _erfc_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    path = first(old.paths)
    new = _erfc_layout(
        plan.spec,
        old.central_coefficients,
        old.scaled_coefficients,
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

function _certified_erfc(
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
    geometry = _erfc_geometry(spec)
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
        zeros = fill(_q(0), degree + 1)
        dummy =
            _erfc_layout(spec, zeros, zeros, zeros, 0, 0, precision_layout, evaluation)
        generate(expression, domain; normalization = nothing) = begin
            kernel_spec = FunctionSpec(
                expression;
                input_format = spec.input_format,
                output_format = spec.output_format,
                domain,
                absolute_error = spec.absolute_error,
            )
            cs = _generated_polynomial_coefficients(
                kernel_spec,
                domain,
                degree,
                precision_layout.coefficient_formats,
                generation_precision;
                normalization,
            )
            append!(cs, fill(_q(0), degree + 1 - length(cs)))
            cs
        end
        central =
            any(p -> !p.tail, geometry.branches) && !geometry.zero_only ?
            generate("erfc(x)", (_q(0), _q(1))) : copy(zeros)
        has_tail = any(p -> p.tail, geometry.branches)
        scaled =
            has_tail ?
            generate(
                _ERFC_SCALED_EXPRESSION,
                dummy.normalization.domain;
                normalization = dummy.normalization,
            ) : copy(zeros)
        exp = has_tail ? generate("exp(x)", (_q(-1 // 2), _q(1 // 2))) : copy(zeros)
        bounds = has_tail ? _log2_bounds(generation_precision) : (_q(1), _q(1))
        erfc_polynomial_plan(
            spec,
            central,
            scaled,
            exp,
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
            "Erfc generation failed: " * sprint(showerror, err);
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
    return _certify_erfc(plan; precision = proof_precision, accuracy, max_refinements)
end

function _erfc_scaled_image(keep, domain)
    # exp(a²)*erfc(a) = 2/sqrt(pi) * integral(exp(-t²-2a*t), t=0..inf).
    # For a>0 this is positive and strictly decreasing. Directed point
    # enclosures therefore bound the whole interval without interval dependency
    # between exp(a²) and erfc(a).
    lo = _hyperbolic_image(keep, _ERFC_SCALED_EXPRESSION, (domain[2], domain[2]))[1]
    hi = _hyperbolic_image(keep, _ERFC_SCALED_EXPRESSION, (domain[1], domain[1]))[2]
    0 < lo <= hi || throw(ArgumentError("invalid scaled erfc image"))
    return (lo, hi)
end

function _erfc_tail_certificate(plan, path, keep, log2_bounds, accuracy, max_refinements)
    pre_ranges, pre_rho =
        _polynomial_ranges(plan.program, path; stop_before = path.residual)
    reduction = _exp_reduction_bounds(
        plan,
        path,
        log2_bounds;
        selection_domain = pre_ranges[path.negative_square],
        selection_error = pre_rho[path.square],
    )
    path = reduction.path
    scaled_kernel = path.scaled_kernel
    eta =
        _pow2(path.normalization.exponent) * reduction.rho[path.shifted] +
        reduction.rho[path.normalized] +
        (
            scaled_kernel.coordinate == path.normalized ? _q(0) :
            reduction.rho[scaled_kernel.coordinate]
        )
    scaled_kernel = merge(scaled_kernel, (; coordinate_formation_error = eta))
    cscaled, vscaled, load_scaled =
        _polynomial_arithmetic(plan.program, scaled_kernel, reduction.ranges, reduction.rho)
    cexp, vexp, load_exp =
        _polynomial_arithmetic(plan.program, path, reduction.ranges, reduction.rho)
    vscaled += load_scaled
    vexp += load_exp
    phi = keep(_stored_polynomial(scaled_kernel.coefficients))
    phi_function = _normalized_function(
        keep,
        _ERFC_SCALED_EXPRESSION,
        path.normalization.center,
        path.normalization.exponent,
    )
    phi_interval = keep(Sollya.interval(scaled_kernel.domain...))
    Sollya.bounds(phi_interval) == scaled_kernel.domain ||
        throw(ArgumentError("native scaled erfc proof domain enlargement"))
    phi_image = _erfc_scaled_image(keep, path.magnitude_domain)
    ep = keep(_stored_polynomial(path.coefficients))
    ef = keep(Sollya.sollya("exp(x)"))
    ei = keep(Sollya.interval(path.domain...))
    Sollya.bounds(ei) == path.domain ||
        throw(ArgumentError("native exp proof domain enlargement"))
    exp_image = Sollya.bounds(keep(Sollya.enclosure(ef, ei)))
    scale = path.scale_upper
    tightness = _q(accuracy)
    certificate = nothing
    for refinement = 0:max_refinements
        np, ne = _polynomial_norm(phi, phi_function, phi_interval, tightness),
        _polynomial_norm(ep, ef, ei, tightness)
        all(n -> 0 <= n[1] <= n[2], (np, ne)) ||
            throw(ArgumentError("invalid erfc tail norm enclosure"))
        range_overrides = Dict{Int, _Interval}()
        for (kernel, image, error) in (
            (scaled_kernel, phi_image, np[2] + cscaled + vscaled),
            (path, exp_image, ne[2] + cexp + vexp),
        )
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
            range_overrides,
            exact_overrides = reduction.exact_overrides,
        )
        phi_bound = _interval_magnitude(ranges[path.scaled_wide])
        exp_bound = exp_image[2]
        # product difference = exact exp * phi error + actual phi * exp error.
        norm = scale * (exp_bound * np[2] + phi_bound * ne[2])
        coordinate = scale * (exp_bound * cscaled + phi_bound * cexp)
        arithmetic =
            scale * (exp_bound * vscaled + phi_bound * vexp + rho[path.multiplied]) +
            rho[path.tail_value]
        if path.negative
            arithmetic +=
                rho[path.reflected] + (path.negated === nothing ? _q(0) : rho[path.negated])
        end
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
        scale * (exp_bound * np[1] + phi_bound * ne[1]) +
        coordinate +
        arithmetic +
        output <=
        plan.spec.absolute_error <
        total || break
        tightness /= 4
    end
    return certificate
end

function _certify_erfc(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "erfc_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _erfc_audit(plan)
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
        "Audited erfc zero and infinity limits are exact",
    )
    certificates = try
        log2_bounds =
            any(p -> p.tail, layout.paths) ? _log2_bounds(precision) : (_q(1), _q(1))
        Sollya.with_session(Sollya.Session(; precision)) do
            Sollya.with_objects() do keep
                map(layout.paths) do path
                    path.tail && return _erfc_tail_certificate(
                        plan,
                        path,
                        keep,
                        log2_bounds,
                        accuracy,
                        max_refinements,
                    )
                    ranges, rho = _polynomial_ranges(plan.program, path)
                    coordinate, arithmetic, loading =
                        _polynomial_arithmetic(plan.program, path, ranges, rho)
                    arithmetic += loading
                    path.negative && (
                        arithmetic +=
                            rho[path.reflected] +
                            (path.negated === nothing ? _q(0) : rho[path.negated])
                    )
                    output = get(rho, path.output_conversion, _q(0))
                    p = keep(_stored_polynomial(path.coefficients))
                    f = keep(Sollya.sollya("erfc(x)"))
                    interval = keep(Sollya.interval(path.domain...))
                    Sollya.bounds(interval) == path.domain || throw(
                        ArgumentError("native central erfc proof domain enlargement"),
                    )
                    norm, tightness = (_q(0), _q(0)), _q(accuracy)
                    for refinement = 0:max_refinements
                        norm = _polynomial_norm(p, f, interval, tightness)
                        0 <= norm[1] <= norm[2] ||
                            throw(ArgumentError("invalid central erfc norm enclosure"))
                        norm[1] + coordinate + arithmetic + output <=
                        plan.spec.absolute_error <
                        norm[2] + coordinate + arithmetic + output || break
                        tightness /= 4
                    end
                    total = norm[2] + coordinate + arithmetic + output
                    bounds = Tuple(
                        _node_bound(i, IR.format(plan.program, i), range) for
                        (i, range) in sort!(collect(ranges); by = first)
                    )
                    PathCertificate(
                        path.input_domain,
                        true,
                        (_q(0), norm[2]),
                        coordinate,
                        arithmetic,
                        output,
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
        "Audited scaled erfc tail, square, exponential reconstruction and reflection meet the target" :
        "Conservative erfc evaluator bound exceeds the target",
    )
end
