function _exp_geometry(spec)
    _primitive(spec.expression) == :exp ||
        throw(ArgumentError("exp transformation requires exp(x)"))
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("exp reduction requires floating interfaces"))
    spec.domain !== nothing ||
        throw(ArgumentError("exp reduction requires an explicit bounded domain"))
    input_domain = _polynomial_domain(spec)
    magnitude = _interval_magnitude(input_domain)
    width = max(2, ndigits(ceil(BigInt, 2magnitude + 2); base = 2) + 1)
    return (;
        input_domain,
        domain = (_q(-1 // 2), _q(1 // 2)),
        zero_only = input_domain == (0, 0),
        exponent_format = FixedFormat(width, width),
    )
end

function _exp_reduction_format(spec, precision)
    f = precision.coordinate_format
    return FloatFormat(
        max(11, spec.input_format.exponent_bits, f isa FloatFormat ? f.exponent_bits : 2),
        max(
            52,
            spec.input_format.fraction_bits,
            spec.output_format.fraction_bits,
            f isa FloatFormat ? f.fraction_bits : _fraction(f),
        ),
    )
end

function _exp_layout(spec, coefficients, log2, inverse_log2, precision, evaluation)
    geometry = _exp_geometry(spec)
    1 <= length(coefficients) <= 33 ||
        throw(ArgumentError("exp kernel degree must be in 0:32"))
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported evaluation"))
    precision = _precision_prefix(precision, length(coefficients))
    f = precision.coordinate_format
    f isa FixedFormat &&
        !f.signed &&
        throw(ArgumentError("exp residual requires signed coordinates"))
    reduction_format = _exp_reduction_format(spec, precision)
    coefficients = [
        _polynomial_value(_polynomial_round(_q(c), cf), cf) for
        (c, cf) in zip(coefficients, precision.coefficient_formats)
    ]
    log2 = _polynomial_value(round_ieee(_q(log2), reduction_format), reduction_format)
    inverse_log2 =
        _polynomial_value(round_ieee(_q(inverse_log2), reduction_format), reduction_format)
    nodes = IR.Node[IR.Input(spec.input_format)]
    wide = _precision_convert!(nodes, 1, spec.input_format, reduction_format)
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
    coordinate = _precision_convert!(nodes, residual, reduction_format, f)
    cs = [
        _push!(nodes, IR.constant(c, cf)) for
        (c, cf) in zip(coefficients, precision.coefficient_formats)
    ]
    horner = _precision_horner!(nodes, coordinate, cs, precision, evaluation)
    scaled = _push!(nodes, IR.ScaleByExponent(horner.final, exponent, spec.output_format))
    zero = _push!(nodes, IR.Classify(:zero, 1))
    one = _push!(nodes, IR.constant(1, spec.output_format))
    zero_select = _push!(nodes, IR.Select(zero, one, scaled))
    guarded = _polynomial_guard!(nodes, zero_select, spec)
    infinity = _push!(nodes, IR.Classify(:infinity, 1))
    negative = _push!(nodes, IR.Classify(:negative, 1))
    positive_infinity =
        _push!(nodes, IR.Const(spec.output_format, _inf(spec.output_format)))
    positive_zero = _push!(nodes, IR.constant(0, spec.output_format))
    limit = _push!(nodes, IR.Select(negative, positive_zero, positive_infinity))
    output = _push!(nodes, IR.Select(infinity, limit, guarded))
    path = merge(
        horner,
        geometry,
        (;
            coefficients,
            coordinate,
            wide,
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
            reduction_format,
            result = horner.final,
            output_node = scaled,
            output_source = scaled,
            range_roots = (scaled, findall(n -> n isa IR.Const, nodes)...),
            range_aliases = Dict(
                zero_select => scaled,
                guarded => scaled,
                output => scaled,
            ),
        ),
    )
    return (;
        program = IR.Program(nodes; output),
        precision,
        paths = [path],
        coefficient_nodes = cs,
        log2_node,
        inverse_node,
        negative_log2_node,
    )
end

"""
    exp_polynomial_plan(spec, coefficients, log2, inverse_log2; precision=nothing,
                        internal_format=spec.output_format, evaluation=:separate)

Build an uncertified bounded exp evaluator. Round x*inverse_log2 to a signed
integer k, form x-k*log2 in an automatically widened floating format, and evaluate
an ascending polynomial in the converted residual. Scale the final Horner value
directly by 2^k into the output, with one destination quantizer. Stored constants,
every operation and lazy zero/infinity/domain branches are explicit in IR.
The certificate validates the reduced domain; floating interfaces are required.
"""
function exp_polynomial_plan(
    spec::FunctionSpec,
    coefficients,
    log2,
    inverse_log2;
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
    layout = _exp_layout(spec, cs, log2, inverse_log2, precision, evaluation)
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "exp_polynomial_horner",
            "transformation" => "exp",
            "evaluation" => string(evaluation),
        ),
    )
end

function _exp_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing exp evaluator"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported exp metadata dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "exp proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    skeleton = _exp_layout(
        plan.spec,
        fill(0, length(plan.precision.coefficient_formats)),
        0,
        0,
        plan.precision,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    length(plan.program.nodes) == length(skeleton.program.nodes) ||
        throw(ArgumentError("incomplete exp graph"))
    ids = (
        skeleton.coefficient_nodes...,
        skeleton.log2_node,
        skeleton.inverse_node,
        skeleton.negative_log2_node,
    )
    all(ids) do i
        n = plan.program.nodes[i]
        n isa IR.Const && n.format == IR.format(skeleton.program, i)
    end || throw(ArgumentError("unsupported exp constant storage"))
    value(i) = _polynomial_value(plan.program.nodes[i].bits, plan.program.nodes[i].format)
    log2, inverse_log2 = value(skeleton.log2_node), value(skeleton.inverse_node)
    value(skeleton.negative_log2_node) == -log2 ||
        throw(ArgumentError("inconsistent exp reduction constants"))
    layout = _exp_layout(
        plan.spec,
        value.(skeleton.coefficient_nodes),
        log2,
        inverse_log2,
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
        throw(ArgumentError("executed graph differs from the supported exp evaluator"))
    return layout
end

function _reformat_exp(plan, precision)
    old = _exp_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    path = only(old.paths)
    new = _exp_layout(
        plan.spec,
        path.coefficients,
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

function _certified_exp(
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
    geometry = _exp_geometry(spec)
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
        coefficients =
            geometry.zero_only ? fill(_q(0), degree + 1) :
            _generated_polynomial_coefficients(
                spec,
                geometry.domain,
                degree,
                _precision_prefix(precision_layout, degree + 1).coefficient_formats,
                generation_precision,
            )
        bounds =
            geometry.zero_only ? (_q(1), _q(1)) : _log2_bounds(generation_precision)
        exp_polynomial_plan(
            spec,
            coefficients,
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
            "Exp generation failed: " * sprint(showerror, err);
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
    return _certify_exp(plan; precision = proof_precision, accuracy, max_refinements)
end

function _exp_reduction_bounds(plan, path, log2_bounds; exponent_headroom = 1)
    0 < path.inverse_log2 < 2 && path.log2 > 0 ||
        throw(ArgumentError("invalid exp reduction constants"))
    ranges, rho = _polynomial_ranges(plan.program, path; stop_before = path.residual)
    xbound = _interval_magnitude(path.input_domain)
    kbound = _interval_magnitude(ranges[path.exponent_node])
    kerror = rho[path.exponent_node] + rho[path.selection_product]
    ideal_radius =
        xbound * maximum(abs(1 - path.inverse_log2 * l) for l in log2_bounds) +
        kerror * log2_bounds[2]
    ideal_radius <= 1 // 2 ||
        throw(ArgumentError("exp exponent selection does not establish the reduced domain"))
    # Correlation between x and k bounds the exact residual before its rounding.
    # Rounded k conversion and a separate product add their own errors.
    product_error = path.product === nothing ? _q(0) : rho[path.product]
    pre_radius =
        xbound * abs(1 - path.inverse_log2 * path.log2) +
        (kerror + rho[path.exponent_value]) * abs(path.log2) +
        product_error
    exact_overrides = Dict(path.residual => (-pre_radius, pre_radius))
    exponents = map(q -> numerator(q), ranges[path.exponent_node])
    exponents[2] <= _emax(plan.spec.output_format) + exponent_headroom ||
        throw(OverflowError("exp reconstruction may overflow"))
    # A zero lower scale encloses arbitrarily deep underflow without allocating
    # 2^k at the negative endpoint. Cap an entirely tiny upper scale conservatively.
    scale_upper = _pow2(
        Int(
            max(
                exponents[2],
                _emin(plan.spec.output_format) - plan.spec.output_format.fraction_bits - 4,
            ),
        ),
    )
    bounded = merge(path, (; scale_upper, exponents))
    ranges, rho = _polynomial_ranges(
        plan.program,
        bounded;
        stop_before = path.output_node,
        exact_overrides,
    )
    constant_error = kbound * maximum(abs(path.log2 - l) for l in log2_bounds)
    eta =
        constant_error +
        abs(path.log2) * rho[path.exponent_value] +
        product_error +
        rho[path.residual] +
        (path.coordinate == path.residual ? _q(0) : rho[path.coordinate])
    return (;
        path = merge(bounded, (; coordinate_formation_error = eta)),
        ranges,
        rho,
        exact_overrides,
        constant_error,
        ideal_radius,
        pre_radius,
    )
end

function _certify_exp(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "exp_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _exp_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
        return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
    end
    path = only(layout.paths)
    path.zero_only && return CertificationResult(
        plan,
        :certified,
        _q(0),
        (),
        nothing,
        settings,
        "Audited zero and infinity branches are exact; no numerical kernel is reachable",
    )
    certificate = try
        reduction = _exp_reduction_bounds(plan, path, _log2_bounds(precision))
        path = reduction.path
        coordinate, arithmetic, _ =
            _polynomial_arithmetic(plan.program, path, reduction.ranges, reduction.rho)
        scale = path.scale_upper
        settings["log2_error_bound"] = _rational_text(reduction.constant_error)
        settings["ideal_residual_radius"] = _rational_text(reduction.ideal_radius)
        settings["residual_error_bound"] =
            _rational_text(path.coordinate_formation_error)
        settings["maximum_error_scale"] = _rational_text(scale)
        settings["minimum_exponent"], settings["maximum_exponent"] =
            string.(path.exponents)
        Sollya.with_session(Sollya.Session(; precision)) do
            Sollya.with_objects() do keep
                p = keep(_stored_polynomial(path.coefficients))
                f = keep(Sollya.sollya("exp(x)"))
                interval = keep(Sollya.interval(path.domain...))
                Sollya.bounds(interval) == path.domain ||
                    throw(ArgumentError("native proof domain enlargement"))
                image = Sollya.bounds(keep(Sollya.enclosure(f, interval)))
                tightness = _q(accuracy)
                certificate = nothing
                for refinement = 0:max_refinements
                    raw = _polynomial_norm(p, f, interval, tightness)
                    0 <= raw[1] <= raw[2] ||
                        throw(ArgumentError("invalid exp norm enclosure"))
                    error = raw[2] + coordinate + arithmetic
                    format = IR.format(plan.program, path.final)
                    lo = max(reduction.ranges[path.final][1], image[1] - error)
                    hi = min(reduction.ranges[path.final][2], image[2] + error)
                    enclosure = (
                        _polynomial_value(
                            _polynomial_round(lo, format; mode = :down),
                            format,
                        ),
                        _polynomial_value(
                            _polynomial_round(hi, format; mode = :up),
                            format,
                        ),
                    )
                    ranges, rho = _polynomial_ranges(
                        plan.program,
                        path;
                        range_overrides = Dict(path.final => enclosure),
                        exact_overrides = reduction.exact_overrides,
                    )
                    output = rho[path.output_node]
                    total = scale * (raw[2] + coordinate + arithmetic) + output
                    bounds = Tuple(
                        _node_bound(i, IR.format(plan.program, i), range) for
                        (i, range) in sort!(collect(ranges); by = first)
                    )
                    certificate = PathCertificate(
                        path.input_domain,
                        true,
                        (_q(0), scale * raw[2]),
                        scale * coordinate,
                        scale * arithmetic,
                        output,
                        total,
                        bounds,
                    )
                    scale * (raw[1] + coordinate + arithmetic) + output <=
                    plan.spec.absolute_error <
                    total || break
                    tightness /= 4
                end
                certificate
            end
        end
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(plan, :proof_failed, sprint(showerror, err); settings)
    end
    status =
        certificate.total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    return CertificationResult(
        plan,
        status,
        certificate.total,
        (certificate,),
        nothing,
        settings,
        status == :certified ?
        "Audited exponent selection, residual formation and direct exp reconstruction meet the target" :
        "Conservative exp evaluator bound exceeds the target",
    )
end
