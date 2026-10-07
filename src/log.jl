function _log_geometry(spec)
    _primitive(spec.expression) == :log ||
        throw(ArgumentError("log transformation requires log(x)"))
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("log reduction requires floating input and output"))
    spec.domain !== nothing && spec.domain[1] >= 0 || throw(
        ArgumentError("log reduction requires an explicit nonnegative bounded domain"),
    )
    accepted_domain = _polynomial_domain(spec)
    exceptional_only = accepted_domain in ((0, 0), (1, 1))
    input_domain =
        exceptional_only ? accepted_domain :
        (
            max(accepted_domain[1], decode_ieee(1, spec.input_format).value),
            accepted_domain[2],
        )
    exponents =
        exceptional_only ? (0, 0) :
        map(input_domain) do x
            last(normalize_float(round_ieee(x, spec.input_format), spec.input_format))
        end
    return (;
        input_domain,
        accepted_domain,
        exceptional_only,
        exponents,
        domain = (_q(1), _q(2)),
        mantissa_domain = (_q(1), _q(2) - _pow2(-spec.input_format.fraction_bits)),
    )
end

function _log_layout(spec, coefficients, log2, precision, evaluation)
    geometry = _log_geometry(spec)
    1 <= length(coefficients) <= 33 ||
        throw(ArgumentError("log kernel degree must be in 0:32"))
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported evaluation"))
    precision = _precision_prefix(precision, length(coefficients))
    f, fc = precision.coordinate_format, precision.coefficient_formats
    coefficients = [
        _polynomial_value(_polynomial_round(_q(c), format), format) for
        (c, format) in zip(coefficients, fc)
    ]
    log2 = _polynomial_value(_polynomial_round(_q(log2), f), f)
    nodes = IR.Node[IR.Input(spec.input_format)]
    mantissa = _push!(nodes, IR.FloatMantissa(1))
    coordinate = _precision_convert!(nodes, mantissa, spec.input_format, f)
    cs = [_push!(nodes, IR.constant(c, format)) for (c, format) in zip(coefficients, fc)]
    horner = _precision_horner!(nodes, coordinate, cs, precision, evaluation)
    # Keep reconstruction in the coordinate format while individual Horner
    # stages are reduced. Every conversion and reconstruction operation is IR.
    kernel_value = _precision_convert!(nodes, horner.final, precision.stage_formats[1], f)
    exponent_node = _push!(nodes, IR.FloatExponent(1))
    exponent_value = _precision_convert!(
        nodes,
        exponent_node,
        _float_exponent_format(spec.input_format),
        f,
    )
    log2_node = _push!(nodes, IR.constant(log2, f))
    product =
        evaluation == :separate ? _push!(nodes, IR.Mul(exponent_value, log2_node, f)) :
        nothing
    reconstruction =
        product === nothing ?
        _push!(nodes, IR.FMA(exponent_value, log2_node, kernel_value, f)) :
        _push!(nodes, IR.Add(kernel_value, product, f))
    result = _precision_convert!(nodes, reconstruction, f, spec.output_format)
    zero = _push!(nodes, IR.Classify(:zero, 1))
    negative_infinity = _push!(
        nodes,
        IR.Const(spec.output_format, _inf(spec.output_format) | _sign(spec.output_format)),
    )
    one = _push!(nodes, IR.constant(1, spec.input_format))
    is_one = _push!(nodes, IR.Compare(:eq, 1, one))
    positive_zero = _push!(nodes, IR.constant(0, spec.output_format))
    one_select = _push!(nodes, IR.Select(is_one, positive_zero, result))
    zero_select = _push!(nodes, IR.Select(zero, negative_infinity, one_select))
    guarded = _polynomial_guard!(nodes, zero_select, spec)
    infinity = _push!(nodes, IR.Classify(:infinity, 1))
    negative = _push!(nodes, IR.Classify(:negative, 1))
    positive_infinity =
        _push!(nodes, IR.Const(spec.output_format, _inf(spec.output_format)))
    nan = _push!(nodes, IR.Const(spec.output_format, _nan(spec.output_format)))
    infinity_result = _push!(nodes, IR.Select(negative, nan, positive_infinity))
    output = _push!(nodes, IR.Select(infinity, infinity_result, guarded))
    aliases = Dict(
        one_select => result,
        zero_select => result,
        guarded => result,
        output => result,
    )
    path = merge(
        horner,
        geometry,
        (;
            coefficients,
            mantissa,
            coordinate,
            log2,
            log2_node,
            exponent_node,
            exponent_value,
            kernel_value,
            product,
            reconstruction,
            output_node = result,
            result = horner.final,
            output_source = result,
            range_roots = (result, findall(n -> n isa IR.Const, nodes)...),
            range_aliases = aliases,
        ),
    )
    return (;
        program = IR.Program(nodes; output),
        precision,
        paths = [path],
        coefficient_nodes = cs,
    )
end

"""
    log_polynomial_plan(spec, coefficients, log2; precision=nothing,
                        internal_format=spec.output_format, evaluation=:separate)

Build an uncertified log evaluator using exact `x=m*2^e` normalization and
`p(m)+e*log2`. Supply ascending polynomial coefficients and a stored approximation
of log(2). Reconstruction and constant storage use the coordinate format; the
certificate accounts for the stored constant, every cast, arithmetic operation
and output rounding. With `:fma`, reconstruction uses one fused multiply-add.
Floating interfaces and an explicit nonnegative bounded domain are required.
"""
function log_polynomial_plan(
    spec::FunctionSpec,
    coefficients,
    log2;
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
        throw(ArgumentError("internal format must match the precision coordinate format"))
    layout = _log_layout(spec, cs, log2, precision, evaluation)
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "log_polynomial_horner",
            "transformation" => "log",
            "evaluation" => string(evaluation),
        ),
    )
end

function _log_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing log evaluator"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported log dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "log proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    precision = plan.precision
    offset = precision.coordinate_format == plan.spec.input_format ? 2 : 3
    count = length(precision.coefficient_formats)
    length(plan.program.nodes) >= offset + count ||
        throw(ArgumentError("missing log coefficients"))
    constants = plan.program.nodes[(offset + 1):(offset + count)]
    all(zip(constants, precision.coefficient_formats)) do (n, f)
        n isa IR.Const && n.format == f
    end || throw(ArgumentError("unsupported log coefficient storage"))
    coefficients = [
        _polynomial_value(n.bits, f) for
        (n, f) in zip(constants, precision.coefficient_formats)
    ]
    # Derive the constant's position from the canonical structure, not metadata.
    skeleton = _log_layout(
        plan.spec,
        coefficients,
        0,
        precision,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    log2_node = only(skeleton.paths).log2_node
    length(plan.program.nodes) >= log2_node ||
        throw(ArgumentError("missing log(2) constant"))
    constant = plan.program.nodes[log2_node]
    constant isa IR.Const && constant.format == precision.coordinate_format ||
        throw(ArgumentError("unsupported log(2) storage"))
    log2 = _polynomial_value(constant.bits, constant.format)
    layout = _log_layout(
        plan.spec,
        coefficients,
        log2,
        precision,
        Symbol(plan.settings["evaluation"]),
    )
    layout.precision == precision ||
        throw(ArgumentError("precision metadata exceeds the kernel degree"))
    nodes = collect(layout.program.nodes)
    for (i, n) in zip(layout.coefficient_nodes, constants)
        nodes[i] = n
    end
    nodes[log2_node] = constant
    _program_data(IR.Program(nodes; output = layout.program.output)) ==
    _program_data(plan.program) ||
        throw(ArgumentError("executed graph differs from the supported log evaluator"))
    return layout
end

function _reformat_log(plan, precision)
    old = _log_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    path = only(old.paths)
    candidate = log_polynomial_plan(
        plan.spec,
        path.coefficients,
        path.log2;
        precision,
        evaluation = Symbol(plan.settings["evaluation"]),
    )
    new = _log_audit(candidate)
    nodes = collect(candidate.program.nodes)
    for (source, target) in zip(old.coefficient_nodes, new.coefficient_nodes)
        nodes[target] = plan.program.nodes[source]
    end
    nodes[only(new.paths).log2_node] = plan.program.nodes[path.log2_node]
    return PlanArtifact(
        plan.spec;
        program = IR.Program(nodes; output = candidate.program.output),
        precision = candidate.precision,
        settings = plan.settings,
    )
end

function _log2_bounds(precision)
    return Sollya.with_session(Sollya.Session(; precision)) do
        Sollya.with_objects() do keep
            f = keep(Sollya.sollya("log(x)"))
            Sollya.bounds(keep(Sollya.enclosure(f, 2)))
        end
    end
end

function _certified_log(
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
    geometry = _log_geometry(spec)
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
            geometry.exceptional_only ? fill(_q(0), degree + 1) :
            _generated_polynomial_coefficients(
                spec,
                geometry.domain,
                degree,
                _precision_prefix(precision_layout, degree + 1).coefficient_formats,
                generation_precision,
            )
        log2 =
            geometry.exceptional_only ? _q(0) : sum(_log2_bounds(generation_precision)) / 2
        log_polynomial_plan(
            spec,
            coefficients,
            log2;
            internal_format,
            precision = precision_layout,
            evaluation,
        )
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Log coefficient generation failed: " * sprint(showerror, err);
            settings = merge(
                settings,
                Dict(
                    "precision" => string(proof_precision),
                    "norm_accuracy" => _rational_text(_q(accuracy)),
                ),
            ),
        )
    end
    plan = PlanArtifact(
        spec;
        program = candidate.program,
        precision = candidate.precision,
        settings = merge(candidate.settings, settings),
    )
    candidate_ready(plan)
    return _certify_log(plan; precision = proof_precision, accuracy, max_refinements)
end

function _certify_log(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "log_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _log_audit(plan)
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
    path.exceptional_only && return CertificationResult(
        plan,
        :certified,
        _q(0),
        (),
        nothing,
        settings,
        "Audited zero/one and exceptional branches are exact; no numerical kernel is reachable",
    )
    certificate = try
        ranges, rho = _polynomial_ranges(
            plan.program,
            path;
            stop_before = path.kernel_value == path.final ? path.exponent_node :
                          path.kernel_value,
        )
        coordinate, kernel_arithmetic, _ =
            _polynomial_arithmetic(plan.program, path, ranges, rho)
        arithmetic, output = _q(0), _q(0)
        log2_bounds = _log2_bounds(precision)
        constant_error =
            maximum(abs(path.log2 - endpoint) for endpoint in log2_bounds) *
            maximum(abs, path.exponents)
        settings["log2_error_bound"] = _rational_text(constant_error)
        norm = Sollya.with_session(Sollya.Session(; precision)) do
            Sollya.with_objects() do keep
                p = keep(_stored_polynomial(path.coefficients))
                f = keep(Sollya.sollya("log(x)"))
                interval = keep(Sollya.interval(path.domain...))
                Sollya.bounds(interval) == path.domain ||
                    throw(ArgumentError("native proof domain enlargement"))
                tightness, bound = _q(accuracy), (_q(0), _q(0))
                for refinement = 0:max_refinements
                    raw = _polynomial_norm(p, f, interval, tightness)
                    0 <= raw[1] <= raw[2] ||
                        throw(ArgumentError("invalid log kernel norm enclosure"))
                    error = raw[2] + coordinate + kernel_arithmetic
                    format = IR.format(plan.program, path.final)
                    enclosure = (
                        _polynomial_value(
                            _polynomial_round(
                                max(ranges[path.final][1], -error),
                                format;
                                mode = :down,
                            ),
                            format,
                        ),
                        _polynomial_value(
                            _polynomial_round(
                                min(ranges[path.final][2], log2_bounds[2] + error),
                                format;
                                mode = :up,
                            ),
                            format,
                        ),
                    )
                    ranges, rho = _polynomial_ranges(
                        plan.program,
                        path;
                        range_overrides = Dict(path.final => enclosure),
                    )
                    # e*log(2) -> rounded(e)*L contributes e*(L-log(2))
                    # plus exponent-conversion error times the stored L.
                    # The kernel cast and reconstruction quantizers add once.
                    arithmetic =
                        kernel_arithmetic +
                        constant_error +
                        (path.kernel_value == path.final ? _q(0) : rho[path.kernel_value]) +
                        abs(path.log2) * get(rho, path.exponent_value, _q(0)) +
                        (path.product === nothing ? _q(0) : rho[path.product]) +
                        rho[path.reconstruction]
                    output =
                        path.output_node == path.reconstruction ? _q(0) :
                        rho[path.output_node]
                    bound = (_q(0), raw[2])
                    raw[1] + coordinate + arithmetic + output <=
                    plan.spec.absolute_error <
                    raw[2] + coordinate + arithmetic + output || break
                    tightness /= 4
                end
                bound
            end
        end
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
        "Exact normalization, stored log(2), reconstruction and output rounding meet the target" :
        "Conservative log reconstruction bound exceeds the target",
    )
end
