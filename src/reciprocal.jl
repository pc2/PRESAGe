function _reciprocal_geometry(spec)
    _primitive(spec.expression) == :recip ||
        throw(ArgumentError("reciprocal transformation requires 1/x"))
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("reciprocal reduction requires floating input and output"))
    spec.domain !== nothing ||
        throw(ArgumentError("reciprocal reduction requires an explicit bounded domain"))
    spec.domain[2] < 0 ||
        spec.domain[1] > 0 ||
        throw(ArgumentError("reciprocal domain must lie strictly on one side of zero"))
    domain = _polynomial_domain(spec)
    magnitude = (min(abs(domain[1]), abs(domain[2])), max(abs(domain[1]), abs(domain[2])))
    f = spec.input_format
    exponents = map(magnitude) do x
        last(normalize_float(round_ieee(x, f), f))
    end
    # The proof covers the whole mantissa interval, without enumerating exponents.
    scale_exponents = (-exponents[2], -exponents[1])
    scale_domain = map(_pow2, scale_exponents)
    return (;
        input_domain = domain,
        domain = (_q(1), _q(2)),
        mantissa_domain = (_q(1), _q(2) - _pow2(-f.fraction_bits)),
        exponents,
        scale_exponents,
        scale_domain,
        reconstruction_bound = scale_domain[2],
        negative = domain[2] < 0,
    )
end

function _reciprocal_layout(spec, coefficients, precision, evaluation)
    geometry = _reciprocal_geometry(spec)
    1 <= length(coefficients) <= 33 ||
        throw(ArgumentError("reciprocal kernel degree must be in 0:32"))
    precision = _precision_prefix(precision, length(coefficients))
    f, fc = precision.coordinate_format, precision.coefficient_formats
    coefficients = [
        _polynomial_value(_polynomial_round(_q(c), format), format) for
        (c, format) in zip(coefficients, fc)
    ]
    nodes = IR.Node[IR.Input(spec.input_format)]
    mantissa = _push!(nodes, IR.FloatMantissa(1))
    coordinate = _precision_convert!(nodes, mantissa, spec.input_format, f)
    cs = [_push!(nodes, IR.constant(c, format)) for (c, format) in zip(coefficients, fc)]
    horner = _precision_horner!(nodes, coordinate, cs, precision, evaluation)
    reconstruction =
        _push!(nodes, IR.ScaleByInputExponent(horner.final, 1, -1, spec.output_format))
    restored = _push!(nodes, IR.CopySign(reconstruction, 1))
    output = _polynomial_guard!(nodes, restored, spec)
    path = merge(
        horner,
        geometry,
        (;
            coefficients,
            mantissa,
            coordinate,
            result = horner.final,
            reconstruction,
            output_source = restored,
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
    reciprocal_polynomial_plan(spec, coefficients; precision=nothing,
                               internal_format=spec.output_format, evaluation=:separate)

Build an uncertified `copysign(round(p(m)*2^-e),x)` evaluator for `1/x`, with exact
`abs(x)=m*2^e` normalization, including subnormal inputs. Coefficients describe
`p(m)` in ascending order. Input/output must be floating, and the explicit
bounded domain must lie strictly on one side of zero. Reconstruction rounds
directly from the last fixed/floating Horner stage to the output format.
"""
function reciprocal_polynomial_plan(
    spec::FunctionSpec,
    coefficients;
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
    layout = _reciprocal_layout(spec, cs, precision, evaluation)
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "reciprocal_polynomial_horner",
            "transformation" => "reciprocal",
            "evaluation" => string(evaluation),
        ),
    )
end

function _reciprocal_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing reciprocal evaluator"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported reciprocal dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "reciprocal proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    precision = plan.precision
    offset = precision.coordinate_format == plan.spec.input_format ? 2 : 3
    count = length(precision.coefficient_formats)
    length(plan.program.nodes) >= offset + count ||
        throw(ArgumentError("missing reciprocal coefficients"))
    constants = plan.program.nodes[(offset + 1):(offset + count)]
    all(zip(constants, precision.coefficient_formats)) do (n, f)
        n isa IR.Const && n.format == f
    end || throw(ArgumentError("unsupported reciprocal coefficient storage"))
    coefficients = [
        _polynomial_value(n.bits, f) for
        (n, f) in zip(constants, precision.coefficient_formats)
    ]
    layout = _reciprocal_layout(
        plan.spec,
        coefficients,
        precision,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    layout.precision == precision ||
        throw(ArgumentError("precision metadata exceeds the kernel degree"))
    nodes = collect(layout.program.nodes)
    for (i, n) in zip(layout.coefficient_nodes, constants)
        nodes[i] = n
    end
    canonical = IR.Program(nodes; output = layout.program.output)
    _program_data(canonical) == _program_data(plan.program) || throw(
        ArgumentError("executed graph differs from the supported reciprocal evaluator"),
    )
    return layout
end

function _reformat_reciprocal(plan, precision)
    old = _reciprocal_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    new = _reciprocal_layout(
        plan.spec,
        only(old.paths).coefficients,
        precision,
        Symbol(plan.settings["evaluation"]),
    )
    nodes = collect(new.program.nodes)
    for (source, target) in zip(old.coefficient_nodes, new.coefficient_nodes)
        nodes[target] = plan.program.nodes[source]
    end
    return PlanArtifact(
        plan.spec;
        program = IR.Program(nodes; output = new.program.output),
        precision = new.precision,
        settings = plan.settings,
    )
end

function _certified_reciprocal(
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
    geometry = _reciprocal_geometry(spec)
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
        coefficients = _generated_polynomial_coefficients(
            spec,
            geometry.domain,
            degree,
            _precision_prefix(precision_layout, degree + 1).coefficient_formats,
            generation_precision,
        )
        reciprocal_polynomial_plan(
            spec,
            coefficients;
            internal_format,
            precision = precision_layout,
            evaluation,
        )
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Reciprocal coefficient generation failed: " * sprint(showerror, err);
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
    return _certify_reciprocal(plan; precision = proof_precision, accuracy, max_refinements)
end

function _certify_reciprocal(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "reciprocal_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _reciprocal_audit(plan)
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
    certificate = try
        ranges, rho =
            _polynomial_ranges(plan.program, path; stop_before = path.reconstruction)
        # Since 1/m is positive, replacing a computed p by |p| cannot increase
        # its error: ||p|-1/m| ≤ |p-1/m|. Sign copying is exact, even when a
        # conservative Horner interval extends below zero.
        kernel_coordinate, kernel_arithmetic, _ =
            _polynomial_arithmetic(plan.program, path, ranges, rho)
        coordinate = kernel_coordinate * path.reconstruction_bound
        arithmetic = kernel_arithmetic * path.reconstruction_bound
        output = _q(0)
        norm = Sollya.with_session(Sollya.Session(; precision)) do
            Sollya.with_objects() do keep
                p = keep(_stored_polynomial(path.coefficients))
                f = keep(Sollya.sollya("1/x"))
                interval = keep(Sollya.interval(path.domain...))
                Sollya.bounds(interval) == path.domain ||
                    throw(ArgumentError("native proof domain enlargement"))
                tightness = _q(accuracy)
                bound = (_q(0), _q(0))
                for refinement = 0:max_refinements
                    raw = _polynomial_norm(p, f, interval, tightness)
                    0 <= raw[1] <= raw[2] ||
                        throw(ArgumentError("invalid reciprocal norm enclosure"))
                    # The certified function image plus the complete kernel
                    # error bounds the last rounded Horner value. This removes
                    # cancellation lost by interval Horner before reconstruction.
                    error = raw[2] + kernel_coordinate + kernel_arithmetic
                    lo = max(ranges[path.final][1], _q(1) / 2 - error)
                    hi = min(ranges[path.final][2], _q(1) + error)
                    lo <= hi ||
                        throw(ArgumentError("inconsistent reciprocal kernel range"))
                    format = IR.format(plan.program, path.final)
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
                    )
                    output = rho[path.reconstruction]
                    # [1,2] and the largest exponent scale can enlarge the
                    # accepted domain. Their lower norm endpoint is therefore
                    # not a lower bound on the original contract's error.
                    bound = (_q(0), raw[2] * path.reconstruction_bound)
                    raw[1] * path.reconstruction_bound + coordinate + arithmetic + output <=
                    plan.spec.absolute_error <
                    bound[2] + coordinate + arithmetic + output || break
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
        "Exact magnitude normalization, audited mantissa kernel and reconstructed evaluator bound meet the target" :
        "Conservative reciprocal evaluator bound exceeds the target",
    )
end
