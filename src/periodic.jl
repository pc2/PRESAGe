function _periodic_geometry(spec, transformation = _primitive(spec.expression))
    transformation in (:sin, :cos) && _primitive(spec.expression) == transformation ||
        throw(ArgumentError("periodic transformation requires matching sin(x) or cos(x)"))
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("periodic reduction requires floating interfaces"))
    spec.domain !== nothing ||
        throw(ArgumentError("periodic reduction requires an explicit bounded domain"))
    domain = _polynomial_domain(spec)
    # C is audited below to be less than one. Leave room for rounding x*C.
    width = max(3, ndigits(ceil(BigInt, _interval_magnitude(domain) + 2); base = 2) + 1)
    return (;
        transformation,
        accepted_domain = domain,
        quadrant_format = FixedFormat(width, width),
        zero_only = domain == (0, 0),
    )
end

function _periodic_layout(
    spec,
    sin_coefficients,
    cos_coefficients,
    pi2,
    inverse_pi2,
    precision,
    evaluation,
)
    geometry = _periodic_geometry(spec)
    count = length(sin_coefficients)
    length(cos_coefficients) == count && 1 <= count <= 16 || throw(
        ArgumentError("periodic kernels require two equal lists of 1:16 coefficients"),
    )
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported evaluation"))
    precision = _precision_prefix(precision, count)
    f = precision.coordinate_format
    f isa FixedFormat &&
        !f.signed &&
        throw(ArgumentError("periodic kernels require signed coordinates"))
    reduction_format = _exp_reduction_format(spec, precision)
    stored(cs) = [
        _polynomial_value(_polynomial_round(_q(c), cf), cf) for
        (c, cf) in zip(cs, precision.coefficient_formats)
    ]
    sin_coefficients, cos_coefficients = stored(sin_coefficients), stored(cos_coefficients)
    pi2 = _polynomial_value(round_ieee(_q(pi2), reduction_format), reduction_format)
    inverse_pi2 =
        _polynomial_value(round_ieee(_q(inverse_pi2), reduction_format), reduction_format)
    nodes = IR.Node[IR.Input(spec.input_format)]
    wide = _precision_convert!(nodes, 1, spec.input_format, reduction_format)
    inverse_node = _push!(nodes, IR.constant(inverse_pi2, reduction_format))
    selection_product = _push!(nodes, IR.Mul(wide, inverse_node, reduction_format))
    quadrant_node = _push!(nodes, IR.Convert(selection_product, geometry.quadrant_format))
    quadrant_value = _push!(nodes, IR.Convert(quadrant_node, reduction_format))
    pi2_node = _push!(nodes, IR.constant(pi2, reduction_format))
    negative_pi2_node = _push!(nodes, IR.constant(-pi2, reduction_format))
    product =
        evaluation == :separate ?
        _push!(nodes, IR.Mul(quadrant_value, negative_pi2_node, reduction_format)) : nothing
    residual =
        product === nothing ?
        _push!(nodes, IR.FMA(quadrant_value, negative_pi2_node, wide, reduction_format)) :
        _push!(nodes, IR.Add(wide, product, reduction_format))
    argument = _precision_convert!(nodes, residual, reduction_format, f)
    square = _push!(nodes, IR.Mul(argument, argument, f))
    sin_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(sin_coefficients, precision.coefficient_formats)
    ]
    sin_horner = _precision_horner!(nodes, square, sin_nodes, precision, evaluation)
    sin_q = _precision_convert!(nodes, sin_horner.final, precision.stage_formats[1], f)
    sin_result = _push!(nodes, IR.Mul(argument, sin_q, f))
    sin_wide = _precision_convert!(nodes, sin_result, f, reduction_format)
    cos_nodes = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(cos_coefficients, precision.coefficient_formats)
    ]
    cos_horner = _precision_horner!(nodes, square, cos_nodes, precision, evaluation)
    cos_wide = _precision_convert!(
        nodes,
        cos_horner.final,
        precision.stage_formats[1],
        reduction_format,
    )
    raw = _push!(
        nodes,
        IR.BitCast(quadrant_node, IR.UIntFormat(geometry.quadrant_format.width)),
    )
    quadrant_bits = _push!(nodes, IR.ExtractBits(raw, 0, 2))
    zero_bits = _push!(nodes, IR.Const(IR.UIntFormat(1), 0))
    odd_bit = _push!(nodes, IR.ExtractBits(quadrant_bits, 0, 1))
    high_bit = _push!(nodes, IR.ExtractBits(quadrant_bits, 1, 1))
    is_odd = _push!(nodes, IR.Compare(:ne, odd_bit, zero_bits))
    high = _push!(nodes, IR.Compare(:ne, high_bit, zero_bits))
    is_sin = geometry.transformation == :sin
    selected = _push!(
        nodes,
        IR.Select(is_odd, is_sin ? cos_wide : sin_wide, is_sin ? sin_wide : cos_wide),
    )
    negative = is_sin ? high : _push!(nodes, IR.Compare(:ne, is_odd, high))
    minus_one = _push!(nodes, IR.constant(-1, reduction_format))
    negated = _push!(nodes, IR.Mul(selected, minus_one, reduction_format))
    signed = _push!(nodes, IR.Select(negative, negated, selected))
    converted = _precision_convert!(nodes, signed, reduction_format, spec.output_format)
    zero = _push!(nodes, IR.Classify(:zero, 1))
    zero_value =
        is_sin ? _push!(nodes, IR.Convert(1, spec.output_format)) :
        _push!(nodes, IR.constant(1, spec.output_format))
    zero_select = _push!(nodes, IR.Select(zero, zero_value, converted))
    output = _polynomial_guard!(nodes, zero_select, spec)
    common = (;
        input_domain = geometry.accepted_domain,
        wide,
        inverse_pi2,
        inverse_node,
        selection_product,
        quadrant_node,
        quadrant_value,
        quadrant_bits,
        quadrant_format = geometry.quadrant_format,
        pi2,
        pi2_node,
        negative_pi2_node,
        product,
        residual,
        argument,
        square,
        reduction_format,
        selected,
        negated,
        signed,
        output_conversion = converted,
        output_source = converted,
        range_aliases = Dict(zero_select => converted, output => converted),
    )
    roots = (
        converted,
        argument,
        square,
        quadrant_value,
        findall(n -> n isa IR.Const, nodes)...,
    )
    paths = map(0:3) do quadrant
        sin_kernel = is_sin ? iseven(quadrant) : isodd(quadrant)
        negative_sign = is_sin ? quadrant >= 2 : quadrant in (1, 2)
        chosen = sin_kernel ? sin_wide : cos_wide
        merge(
            sin_kernel ? sin_horner : cos_horner,
            common,
            sin_kernel ? (; reconstruction_coordinate = argument) : (;),
            (;
                quadrant,
                sin_kernel,
                negative_sign,
                coefficients = sin_kernel ? sin_coefficients : cos_coefficients,
                coordinate = square,
                domain = (_q(0), _q(1)),
                result = sin_kernel ? sin_q : cos_wide,
                kernel_wide = chosen,
                reconstruction = sin_result,
                range_choices = Dict(
                    selected => chosen,
                    signed => negative_sign ? negated : selected,
                ),
                range_roots = roots,
            ),
        )
    end
    return (;
        program = IR.Program(nodes; output),
        precision,
        paths,
        geometry,
        sin_coefficients,
        cos_coefficients,
        sin_nodes,
        cos_nodes,
        coefficient_nodes = (sin_nodes..., cos_nodes...),
        pi2_node,
        inverse_node,
        negative_pi2_node,
    )
end

"""
    periodic_polynomial_plan(spec, sin_coefficients, cos_coefficients, pi2, inverse_pi2;
                             precision=nothing, internal_format=spec.output_format,
                             evaluation=:separate)

Build an uncertified bounded sin/cos evaluator with floating interfaces. Two equal
ascending coefficient lists describe sin(r)=r*q(r²) and cos(r)=p(r²). Select an
integer k by nearest-even rounding of x*stored(2/pi), form r=x-k*stored(pi/2),
and restore the function with exact k modulo four and sign selection. The proof
must establish the ideal residual in [-1,1] and account for all rounding errors.
Sin preserves signed zeros; cos returns one. NaNs, infinities and excluded finite
inputs return canonical quiet NaN before reduction.
"""
function periodic_polynomial_plan(
    spec::FunctionSpec,
    sin_coefficients,
    cos_coefficients,
    pi2,
    inverse_pi2;
    precision::Union{Nothing, PolynomialPrecision} = nothing,
    internal_format::PolynomialFormat = precision === nothing ? spec.output_format :
                                        precision.coordinate_format,
    evaluation::Symbol = :separate,
)
    precision === nothing && (
        precision = PolynomialPrecision(
            internal_format;
            coefficient_formats = fill(internal_format, length(sin_coefficients)),
            stage_formats = fill(internal_format, length(sin_coefficients)),
        )
    )
    internal_format == precision.coordinate_format ||
        throw(ArgumentError("internal format must match coordinate precision"))
    layout = _periodic_layout(
        spec,
        collect(sin_coefficients),
        collect(cos_coefficients),
        pi2,
        inverse_pi2,
        precision,
        evaluation,
    )
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "periodic_polynomial_horner",
            "transformation" => string(layout.geometry.transformation),
            "evaluation" => string(evaluation),
        ),
    )
end

function _periodic_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing periodic evaluator"))
    get(plan.settings, "transformation", "") == string(_primitive(plan.spec.expression)) ||
        throw(ArgumentError("invalid periodic transformation"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported periodic metadata dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "periodic proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    zeros = fill(0, length(plan.precision.coefficient_formats))
    evaluation = Symbol(get(plan.settings, "evaluation", ""))
    skeleton = _periodic_layout(plan.spec, zeros, zeros, 0, 0, plan.precision, evaluation)
    length(plan.program.nodes) == length(skeleton.program.nodes) ||
        throw(ArgumentError("incomplete periodic graph"))
    ids = (
        skeleton.coefficient_nodes...,
        skeleton.pi2_node,
        skeleton.inverse_node,
        skeleton.negative_pi2_node,
    )
    all(ids) do i
        n = plan.program.nodes[i]
        n isa IR.Const && n.format == IR.format(skeleton.program, i)
    end || throw(ArgumentError("unsupported periodic constant storage"))
    value(i) = _polynomial_value(plan.program.nodes[i].bits, plan.program.nodes[i].format)
    pi2, inverse = value(skeleton.pi2_node), value(skeleton.inverse_node)
    value(skeleton.negative_pi2_node) == -pi2 ||
        throw(ArgumentError("inconsistent periodic reduction constants"))
    layout = _periodic_layout(
        plan.spec,
        value.(skeleton.sin_nodes),
        value.(skeleton.cos_nodes),
        pi2,
        inverse,
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
    _program_data(plan.program) ||
        throw(ArgumentError("executed graph differs from the supported periodic evaluator"))
    return layout
end

function _reformat_periodic(plan, precision)
    old = _periodic_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    path = first(old.paths)
    new = _periodic_layout(
        plan.spec,
        old.sin_coefficients,
        old.cos_coefficients,
        path.pi2,
        path.inverse_pi2,
        precision,
        Symbol(plan.settings["evaluation"]),
    )
    nodes = collect(new.program.nodes)
    for (source, target) in zip(
        (old.coefficient_nodes..., old.pi2_node, old.inverse_node, old.negative_pi2_node),
        (new.coefficient_nodes..., new.pi2_node, new.inverse_node, new.negative_pi2_node),
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

function _certified_periodic(
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
        # Alternating Taylor coefficients seed both parity kernels. The stored
        # coefficients receive a rigorous norm proof, independent of this seed.
        sin_cs = [(-1)^j // factorial(big(2j + 1)) for j = 0:degree]
        cos_cs = [(-1)^j // factorial(big(2j)) for j = 0:degree]
        bounds = _pi2_bounds(generation_precision)
        periodic_polynomial_plan(
            spec,
            sin_cs,
            cos_cs,
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
            "Periodic generation failed: " * sprint(showerror, err);
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
    return _certify_periodic(plan; precision = proof_precision, accuracy, max_refinements)
end

function _periodic_reduction_bounds(plan, path, pi2_bounds)
    0 < path.inverse_pi2 < 1 && path.pi2 > 0 ||
        throw(ArgumentError("invalid periodic reduction constants"))
    ranges, rho = _polynomial_ranges(plan.program, path; stop_before = path.residual)
    xbound = _interval_magnitude(path.input_domain)
    kbound = _interval_magnitude(ranges[path.quadrant_node])
    kerror = rho[path.quadrant_node] + rho[path.selection_product]
    # k need not equal round(x/(pi/2)) at a transition: every integer quadrant
    # identity holds. Prove r0=x-k*(true pi/2) is inside the kernel domain.
    ideal_radius =
        xbound * maximum(abs(1 - path.inverse_pi2 * p) for p in pi2_bounds) +
        kerror * pi2_bounds[2]
    ideal_radius <= 1 || throw(
        ArgumentError(
            "quadrant selection does not establish the reduced domain; increase reduction precision or narrow the input domain",
        ),
    )
    product_error = path.product === nothing ? _q(0) : rho[path.product]
    pre_radius =
        xbound * abs(1 - path.inverse_pi2 * path.pi2) +
        (kerror + rho[path.quadrant_value]) * abs(path.pi2) +
        product_error
    exact_overrides = Dict(path.residual => (-pre_radius, pre_radius))
    ranges, rho = _polynomial_ranges(plan.program, path; exact_overrides)
    constant_error = kbound * maximum(abs(path.pi2 - p) for p in pi2_bounds)
    eta =
        constant_error +
        abs(path.pi2) * rho[path.quadrant_value] +
        product_error +
        rho[path.residual] +
        (path.argument == path.residual ? _q(0) : rho[path.argument])
    return (; ranges, rho, constant_error, ideal_radius, eta)
end

function _periodic_path_certificate(plan, path, reduction, norm)
    ranges, rho = reduction.ranges, reduction.rho
    eta = reduction.eta
    rbound = _interval_magnitude(ranges[path.argument])
    eta_z = eta * (rbound + 1) + rho[path.square]
    c, v, load = _polynomial_arithmetic(
        plan.program,
        merge(path, (; coordinate_formation_error = eta_z)),
        ranges,
        rho,
    )
    if path.sin_kernel
        exact_q = _singleton(path.coefficients[end])
        for coefficient in reverse(path.coefficients[1:(end - 1)])
            exact_q =
                _interval_add(_interval_mul(exact_q, path.domain), _singleton(coefficient))
        end
        c = rbound * c + eta * _interval_magnitude(exact_q)
        v =
            rbound * (v + load) +
            rho[path.reconstruction] +
            (path.kernel_wide == path.reconstruction ? _q(0) : rho[path.kernel_wide])
    else
        v += load
    end
    path.negative_sign && (v += rho[path.negated])
    output = get(rho, path.output_conversion, _q(0))
    bounds = Tuple(
        _node_bound(i, IR.format(plan.program, i), range) for
        (i, range) in sort!(collect(ranges); by = first)
    )
    return PathCertificate(
        path.input_domain,
        true,
        norm,
        c,
        v,
        output,
        norm[2] + c + v + output,
        bounds,
    )
end

function _certify_periodic(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "periodic_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _periodic_audit(plan)
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
        "Audited periodic zero branch is exact",
    )
    certificates = try
        pi2_bounds = _pi2_bounds(precision)
        reductions = [
            _periodic_reduction_bounds(plan, path, pi2_bounds) for path in layout.paths
        ]
        settings["pi2_error_bound"] =
            _rational_text(maximum(r.constant_error for r in reductions))
        settings["ideal_residual_radius"] =
            _rational_text(maximum(r.ideal_radius for r in reductions))
        settings["residual_error_bound"] =
            _rational_text(maximum(r.eta for r in reductions))
        Sollya.with_session(Sollya.Session(; precision)) do
            Sollya.with_objects() do keep
                interval = keep(Sollya.interval(-1, 1))
                Sollya.bounds(interval) == (-1, 1) ||
                    throw(ArgumentError("native periodic proof domain enlargement"))
                norms = Dict{Bool, _Interval}()
                for sin_kernel in (true, false)
                    cs = sin_kernel ? layout.sin_coefficients : layout.cos_coefficients
                    p = keep(_stored_polynomial(_hyperbolic_expansion(cs, sin_kernel)))
                    f = keep(Sollya.sollya(sin_kernel ? "sin(x)" : "cos(x)"))
                    tightness = _q(accuracy)
                    for refinement = 0:max_refinements
                        norm = _polynomial_norm(p, f, interval, tightness)
                        0 <= norm[1] <= norm[2] || throw(
                            ArgumentError("invalid periodic kernel norm enclosure"),
                        )
                        norms[sin_kernel] = norm
                        affected = [
                            _periodic_path_certificate(plan, path, reduction, norm)
                            for
                            (path, reduction) in zip(layout.paths, reductions) if
                            path.sin_kernel == sin_kernel
                        ]
                        all(
                            c -> !(
                                norm[1] +
                                c.coordinate_error +
                                c.arithmetic_error +
                                c.output_rounding <=
                                plan.spec.absolute_error <
                                c.total
                            ),
                            affected,
                        ) && break
                        tightness /= 4
                    end
                end
                [
                    _periodic_path_certificate(
                        plan,
                        path,
                        reduction,
                        norms[path.sin_kernel],
                    ) for (path, reduction) in zip(layout.paths, reductions)
                ]
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
        "Audited periodic reduction, quadrant restoration and rounded kernels meet the target" :
        "Conservative periodic evaluator bound exceeds the target",
    )
end
