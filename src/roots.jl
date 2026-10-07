const _ROOT_EXPRESSIONS =
    Dict(:sqrt => "sqrt(x)", :rsqrt => "1/sqrt(x)", :cbrt => "x^(1/3)")
_root_expression(transformation) = _ROOT_EXPRESSIONS[transformation]
_root_divisor(transformation) = transformation == :cbrt ? 3 : 2

function _root_geometry(spec, transformation)
    transformation in (:sqrt, :rsqrt, :cbrt) &&
        _primitive(spec.expression) == transformation ||
        throw(ArgumentError("root transformation must match sqrt(x), 1/sqrt(x) or cbrt(x)"))
    spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ||
        throw(ArgumentError("root reduction requires floating input and output"))
    spec.domain !== nothing ||
        throw(ArgumentError("root reduction requires an explicit bounded domain"))
    transformation == :cbrt ||
        spec.domain[1] >= 0 ||
        throw(ArgumentError("sqrt/rsqrt reduction requires a nonnegative domain"))
    domain = _polynomial_domain(spec)
    f, divisor = spec.input_format, _root_divisor(transformation)
    zero_only = domain == (0, 0)
    magnitude = if zero_only
        (_q(0), _q(0))
    elseif domain[1] <= 0 <= domain[2]
        (decode_ieee(1, f).value, max(abs(domain[1]), abs(domain[2])))
    else
        (min(abs(domain[1]), abs(domain[2])), max(abs(domain[1]), abs(domain[2])))
    end
    input_domain = transformation == :cbrt ? domain : magnitude
    exponents = zero_only ? (0, 0) : map(magnitude) do x
        last(normalize_float(round_ieee(x, f), f))
    end
    quotients = fld.(exponents, divisor)
    scale_exponents = transformation == :rsqrt ? (-quotients[2], -quotients[1]) : quotients
    scale_domain = map(_pow2, scale_exponents)
    return (;
        input_domain,
        accepted_domain = domain,
        zero_only,
        divisor,
        argument_format = _root_argument_format(f, divisor),
        domain = (_q(1), _pow2(divisor)),
        mantissa_domain = (_q(1), _pow2(divisor) - _pow2(divisor - 1 - f.fraction_bits)),
        exponents,
        quotients,
        scale_exponents,
        scale_domain,
        reconstruction_bound = scale_domain[2],
        negative = transformation == :cbrt && domain[1] < 0 && domain[2] <= 0,
        both_signs = transformation == :cbrt && domain[1] < 0 < domain[2],
    )
end

function _root_layout(spec, coefficients, precision, evaluation, transformation)
    geometry = _root_geometry(spec, transformation)
    1 <= length(coefficients) <= 33 ||
        throw(ArgumentError("root kernel degree must be in 0:32"))
    precision = _precision_prefix(precision, length(coefficients))
    f, fc = precision.coordinate_format, precision.coefficient_formats
    coefficients = [
        _polynomial_value(_polynomial_round(_q(c), format), format) for
        (c, format) in zip(coefficients, fc)
    ]
    nodes = IR.Node[IR.Input(spec.input_format)]
    mantissa = _push!(nodes, IR.RootArgument(1, geometry.divisor))
    coordinate = _precision_convert!(nodes, mantissa, geometry.argument_format, f)
    cs = [_push!(nodes, IR.constant(c, format)) for (c, format) in zip(coefficients, fc)]
    horner = _precision_horner!(nodes, coordinate, cs, precision, evaluation)
    multiplier = transformation == :rsqrt ? -1 : 1
    reconstruction = _push!(
        nodes,
        IR.ScaleByInputExponent(
            horner.final,
            1,
            multiplier,
            spec.output_format;
            divisor = geometry.divisor,
        ),
    )
    positive_zero = _push!(nodes, IR.constant(0, spec.output_format))
    positive = _push!(
        nodes,
        IR.CopySign(reconstruction, transformation == :cbrt ? 1 : positive_zero),
    )
    zero = _push!(nodes, IR.Classify(:zero, 1))
    infinity = _push!(nodes, IR.Const(spec.output_format, _inf(spec.output_format)))
    zero_result =
        transformation != :rsqrt ? _push!(nodes, IR.Convert(1, spec.output_format)) :
        _push!(nodes, IR.CopySign(infinity, 1))
    zero_select = _push!(nodes, IR.Select(zero, zero_result, positive))
    guarded = _polynomial_guard!(nodes, zero_select, spec)
    is_infinity = _push!(nodes, IR.Classify(:infinity, 1))
    negative = _push!(nodes, IR.Classify(:negative, 1))
    nan = _push!(nodes, IR.Const(spec.output_format, _nan(spec.output_format)))
    infinity_result =
        transformation == :cbrt ? _push!(nodes, IR.CopySign(infinity, 1)) :
        _push!(
            nodes,
            IR.Select(negative, nan, transformation == :sqrt ? infinity : positive_zero),
        )
    output = _push!(nodes, IR.Select(is_infinity, infinity_result, guarded))
    # The complete graph audit authorizes these aliases on nonzero finite
    # inputs. Exceptional branches are lazy and have exact, separately checked
    # outputs; they cannot be assigned a finite numerical error at the pole.
    range_roots = [
        positive
        [
            i for (i, n) in enumerate(nodes) if n isa IR.Const &&
            n.format isa Union{FixedFormat, FloatFormat} &&
            !(n.format isa FloatFormat && decode_ieee(n.bits, n.format).value === nothing)
        ]
    ]
    path = merge(
        horner,
        geometry,
        (;
            coefficients,
            mantissa,
            coordinate,
            result = horner.final,
            reconstruction,
            output_source = positive,
            range_roots,
            range_aliases = Dict(
                zero_select => positive,
                guarded => zero_select,
                output => guarded,
            ),
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
    root_polynomial_plan(spec, coefficients; transformation, precision=nothing,
                         internal_format=spec.output_format, evaluation=:separate)

Build an uncertified sqrt/rsqrt/cbrt evaluator from ascending reduced-kernel
coefficients: `[1,4]` for sqrt/rsqrt, `[1,8]` for cbrt. Split `e=divisor*q+r`
using floor division, form exact `t=m*2^r`, then scale directly into the output
by `2^q` (sqrt/cbrt) or `2^-q` (rsqrt). Cbrt restores the original sign and
accepts bounded signed domains; sqrt/rsqrt require nonnegative domains.
Floating interfaces are required. Zeros in the contract and infinities use
exact lazy branches; invalid and outside-domain finite inputs return NaN.
"""
function root_polynomial_plan(
    spec::FunctionSpec,
    coefficients;
    transformation::Symbol = something(_primitive(spec.expression), :none),
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
    layout = _root_layout(spec, cs, precision, evaluation, transformation)
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "root_polynomial_horner",
            "transformation" => string(transformation),
            "evaluation" => string(evaluation),
        ),
    )
end

function _root_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing root evaluator"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported root dispatch"))
    all(plan.program.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "root proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    precision = plan.precision
    transformation = Symbol(get(plan.settings, "transformation", ""))
    geometry = _root_geometry(plan.spec, transformation)
    offset = precision.coordinate_format == geometry.argument_format ? 2 : 3
    count = length(precision.coefficient_formats)
    length(plan.program.nodes) >= offset + count ||
        throw(ArgumentError("missing root coefficients"))
    constants = plan.program.nodes[(offset + 1):(offset + count)]
    all(zip(constants, precision.coefficient_formats)) do (n, f)
        n isa IR.Const && n.format == f
    end || throw(ArgumentError("unsupported root coefficient storage"))
    coefficients = [
        _polynomial_value(n.bits, f) for
        (n, f) in zip(constants, precision.coefficient_formats)
    ]
    layout = _root_layout(
        plan.spec,
        coefficients,
        precision,
        Symbol(get(plan.settings, "evaluation", "")),
        transformation,
    )
    layout.precision == precision ||
        throw(ArgumentError("precision metadata exceeds the kernel degree"))
    nodes = collect(layout.program.nodes)
    for (i, n) in zip(layout.coefficient_nodes, constants)
        nodes[i] = n
    end
    canonical = IR.Program(nodes; output = layout.program.output)
    _program_data(canonical) == _program_data(plan.program) ||
        throw(ArgumentError("executed graph differs from the supported root evaluator"))
    return layout
end

function _reformat_root(plan, precision)
    old = _root_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    new = _root_layout(
        plan.spec,
        only(old.paths).coefficients,
        precision,
        Symbol(plan.settings["evaluation"]),
        Symbol(plan.settings["transformation"]),
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

function _certified_root(
    spec,
    domain,
    degree,
    internal_format,
    evaluation,
    generation_precision,
    proof_precision,
    accuracy,
    max_refinements;
    transformation,
    precision_layout,
    candidate_ready,
)
    geometry = _root_geometry(spec, transformation)
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
            geometry.zero_only ? [_q(0)] :
            _generated_polynomial_coefficients(
                FunctionSpec(
                    _root_expression(transformation);
                    input_format = spec.input_format,
                    output_format = spec.output_format,
                    domain = geometry.domain,
                    absolute_error = spec.absolute_error,
                ),
                geometry.domain,
                degree,
                _precision_prefix(precision_layout, degree + 1).coefficient_formats,
                generation_precision,
            )
        root_polynomial_plan(
            spec,
            coefficients;
            transformation,
            internal_format,
            precision = precision_layout,
            evaluation,
        )
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Root coefficient generation failed: " * sprint(showerror, err);
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
    return _certify_root(plan; precision = proof_precision, accuracy, max_refinements)
end

function _certify_root(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "root_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _root_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError, OverflowError} || rethrow()
        return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
    end
    if only(layout.paths).zero_only
        return CertificationResult(
            plan,
            :certified,
            _q(0),
            (),
            nothing,
            settings,
            "Audited lazy zero and exceptional branches are exact; no numerical kernel is reachable",
        )
    end
    transformation = Symbol(plan.settings["transformation"])
    image = transformation == :rsqrt ? (_q(1) / 2, _q(1)) : (_q(1), _q(2))
    return _certify_reduced_kernel(
        plan,
        layout,
        settings,
        _root_expression(transformation),
        image;
        precision,
        accuracy,
        max_refinements,
    )
end
