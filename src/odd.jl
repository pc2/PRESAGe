const _ODD_FUNCTIONS = ("sin(x)", "sinh(x)", "atan(x)", "erf(x)")
_odd_expression(spec) = replace(spec.expression, r"\s+" => "")
function _validate_odd_spec(spec)
    _odd_expression(spec) in _ODD_FUNCTIONS || throw(
        ArgumentError(
            "odd transformation supports sin(x), sinh(x), atan(x) and erf(x) by established identities",
        ),
    )
    spec.domain !== nothing ||
        throw(ArgumentError("odd transformation requires an explicit bounded domain"))
    return _polynomial_domain(spec)
end

function _validate_transformation(transformation, degree, segments)
    transformation in (:none, :odd, :reciprocal, :sqrt, :rsqrt, :cbrt, :log, :atan) ||
        throw(ArgumentError("unsupported polynomial transformation"))
    if transformation in (:odd, :atan)
        1 <= degree <= 31 && isodd(degree) ||
            throw(ArgumentError("odd polynomial degree must be odd and in 1:31"))
        segments == 1 ||
            throw(ArgumentError("odd transformation currently uses one central kernel"))
    elseif transformation in (:reciprocal, :sqrt, :rsqrt, :cbrt, :log)
        segments == 1 ||
            throw(ArgumentError("exponent reduction currently uses one mantissa kernel"))
    end
    return nothing
end
_coefficient_degree(degree, transformation) =
    transformation in (:odd, :atan) ? (degree - 1) ÷ 2 : degree
_executed_degree(plan, precision) =
    get(plan.settings, "transformation", "none") in ("odd", "atan") ?
    2length(precision.coefficient_formats) - 1 : length(precision.coefficient_formats) - 1

function _odd_square_domain(domain)
    lo, hi = domain
    return (lo <= 0 <= hi ? _q(0) : min(lo^2, hi^2), max(lo^2, hi^2))
end

function _odd_layout(spec, coefficients, precision, evaluation)
    domain = _validate_odd_spec(spec)
    count = length(coefficients)
    1 <= count <= 16 || throw(ArgumentError("odd kernels need 1:16 coefficients of q(x²)"))
    precision = _precision_prefix(precision, count)
    f, fc = precision.coordinate_format, precision.coefficient_formats
    coefficients = [
        _polynomial_value(_polynomial_round(_q(c), format), format) for
        (c, format) in zip(coefficients, fc)
    ]
    nodes = IR.Node[IR.Input(spec.input_format)]
    x = _precision_convert!(nodes, 1, spec.input_format, f)
    square = _push!(nodes, IR.Mul(x, x, f))
    cs = [_push!(nodes, IR.constant(c, format)) for (c, format) in zip(coefficients, fc)]
    horner = _precision_horner!(nodes, square, cs, precision, evaluation)
    q = _precision_convert!(nodes, horner.final, precision.stage_formats[1], f)
    reconstructed = _push!(nodes, IR.Mul(x, q, f))
    result = _precision_convert!(nodes, reconstructed, f, spec.output_format)
    zero = _push!(nodes, IR.Classify(:zero, 1))
    zero_value =
        spec.input_format isa FloatFormat && spec.output_format isa FloatFormat ?
        _push!(nodes, IR.Convert(1, spec.output_format)) :
        _push!(nodes, IR.constant(0, spec.output_format))
    zero_select = _push!(nodes, IR.Select(zero, zero_value, result))
    output = _polynomial_guard!(nodes, zero_select, spec)
    program = IR.Program(nodes; output)
    path = merge(
        horner,
        (;
            coefficients,
            coordinate = square,
            domain = _odd_square_domain(domain),
            input_domain = domain,
            result = q,
            output_source = zero_select,
            zero_select,
            exact_branches = Dict(zero_value => _singleton(_q(0))),
            reconstruction_coordinate = x,
            reconstruction = reconstructed,
            output_conversion = result,
            zero_value,
        ),
    )
    return (; program, precision, paths = [path], coefficient_nodes = cs)
end

"""
    odd_polynomial_plan(spec, coefficients; internal_format=spec.output_format,
                        precision=nothing, evaluation=:separate)

Build an uncertified bounded `x*q(x²)` evaluator. Coefficients are those of `q`
in ascending order (1:16 entries). Established odd identities are supported for
sin, sinh, atan and erf. Coordinate arithmetic also rounds the square and final
reconstruction product. An exact lazy zero branch preserves floating zero signs.
"""
function odd_polynomial_plan(
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
    layout = _odd_layout(spec, cs, precision, evaluation)
    return PlanArtifact(
        spec;
        program = layout.program,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "odd_polynomial_horner",
            "transformation" => "odd",
            "evaluation" => string(evaluation),
        ),
    )
end

function _odd_audit(plan)
    plan.program !== nothing && plan.precision !== nothing ||
        throw(ArgumentError("missing odd evaluator"))
    isempty(plan.segments) && plan.dispatch === nothing ||
        throw(ArgumentError("unsupported odd dispatch"))
    all(plan.program.types) do format
        !(format isa FixedFormat) ||
            (format.rounding == :nearest_even && format.overflow == :reject)
    end || throw(
        ArgumentError(
            "odd proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    precision = plan.precision
    offset = precision.coordinate_format == plan.spec.input_format ? 2 : 3
    count = length(precision.coefficient_formats)
    length(plan.program.nodes) >= offset + count ||
        throw(ArgumentError("missing odd coefficients"))
    constants = plan.program.nodes[(offset + 1):(offset + count)]
    all(zip(constants, precision.coefficient_formats)) do (n, format)
        n isa IR.Const && n.format == format
    end || throw(ArgumentError("unsupported odd coefficient storage"))
    coefficients = [
        _polynomial_value(n.bits, format) for
        (n, format) in zip(constants, precision.coefficient_formats)
    ]
    layout = _odd_layout(
        plan.spec,
        coefficients,
        precision,
        Symbol(get(plan.settings, "evaluation", "")),
    )
    nodes = collect(layout.program.nodes)
    for (i, n) in zip(layout.coefficient_nodes, constants)
        nodes[i] = n # Keep exact coefficient payloads, including negative zero.
    end
    canonical = IR.Program(nodes; output = layout.program.output)
    _program_data(canonical) == _program_data(plan.program) ||
        throw(ArgumentError("executed graph differs from the supported odd evaluator"))
    return layout
end

function _reformat_odd(plan, precision)
    old = _odd_audit(plan)
    old.precision.coordinate_format == precision.coordinate_format &&
        old.precision.coefficient_formats == precision.coefficient_formats ||
        throw(ArgumentError("coefficient formats require regeneration"))
    new = _odd_layout(
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

function _odd_expansion(coefficients)
    expanded = fill(_q(0), 2length(coefficients))
    expanded[2:2:end] .= coefficients
    return expanded
end

function _generated_odd_coefficients(spec, domain, degree, formats, precision)
    radius = _interval_magnitude(domain)
    iszero(radius) && return [_q(0)] # The exact zero branch is the whole contract.
    Sollya.with_session(Sollya.Session(; precision)) do
        Sollya.with_objects() do keep
            f = keep(Sollya.sollya(_odd_expression(spec)))
            interval = keep(Sollya.interval(-radius, radius))
            Sollya.bounds(interval) == (-radius, radius) || throw(
                ArgumentError("native domain enlargement; increase generation precision"),
            )
            Sollya.bounds(keep(Sollya.enclosure(f, interval)))
            bits = [
                format isa FixedFormat ? _fraction(format) : format.fraction_bits + 1
                for format in formats
            ]
            # A regular dense basis avoids the non-Haar sparse odd Remez system.
            # Project its polynomial onto odd powers, then certify that actual
            # stored polynomial directly against f. No f(sqrt(z))/sqrt(z) quotient.
            dense_bits = [bits[min(length(bits), k ÷ 2 + 1)] for k = 0:degree]
            polynomial = keep(
                Sollya.fpminimax(
                    f,
                    degree,
                    dense_bits,
                    interval;
                    error = :absolute,
                    arithmetic = first(formats) isa FixedFormat ? :fixed : :floating,
                ),
            )
            dense = Sollya.coefficients(polynomial)
            coefficients = [_q(k <= length(dense) ? dense[k] : 0) for k = 2:2:(degree + 1)]
            while length(coefficients) > 1 && iszero(last(coefficients))
                pop!(coefficients)
            end
            return _check_generated_coefficients(coefficients, formats)
        end
    end
end

function _certified_odd(
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
        coefficients = _generated_odd_coefficients(
            spec,
            domain,
            degree,
            precision_layout.coefficient_formats[1:count],
            generation_precision,
        )
        odd_polynomial_plan(spec, coefficients; precision = precision_layout, evaluation)
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Odd coefficient generation failed: " * sprint(showerror, err),
        )
    end
    plan = PlanArtifact(
        spec;
        program = candidate.program,
        precision = candidate.precision,
        settings = merge(candidate.settings, settings),
    )
    candidate_ready(plan)
    return _certify_odd(plan; precision = proof_precision, accuracy, max_refinements)
end

function _odd_zero_ranges(plan, path)
    ranges = Dict{Int, _Interval}(1 => _singleton(_q(0)))
    for (i, n) in enumerate(plan.program.nodes)
        n isa IR.Const && IR.format(plan.program, i) isa PolynomialFormat || continue
        f = IR.format(plan.program, i)
        f isa FloatFormat && decode_ieee(n.bits, f).value === nothing && continue
        ranges[i] = _singleton(_polynomial_value(n.bits, f))
    end
    for i in (path.zero_value, path.zero_select, plan.program.output)
        ranges[i] = _singleton(_q(0))
    end
    return ranges
end

function _certify_odd(plan; precision, accuracy, max_refinements)
    settings = Dict(
        "method" => "odd_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _odd_audit(plan)
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
        domain = path.input_domain
        radius = _interval_magnitude(domain)
        if iszero(radius)
            ranges = _odd_zero_ranges(plan, path)
            norm, coordinate, arithmetic, output = (_q(0), _q(0)), _q(0), _q(0), _q(0)
        else
            ranges, rho = _polynomial_ranges(plan.program, path)
            xbound = _interval_magnitude(ranges[path.reconstruction_coordinate])
            eta_x = get(rho, path.reconstruction_coordinate, _q(0))
            # A constant q has no executed square; unused IR nodes do not
            # contribute rounding or overflow requirements to the lazy evaluator.
            eta_z = eta_x * (xbound + radius) + get(rho, path.coordinate, _q(0))
            coordinate_q, arithmetic_q, loading_q = _polynomial_arithmetic(
                plan.program,
                merge(path, (; coordinate_formation_error = eta_z)),
                ranges,
                rho,
            )
            exact_q = _singleton(path.coefficients[end])
            for coefficient in reverse(path.coefficients[1:(end - 1)])
                exact_q = _interval_add(
                    _interval_mul(exact_q, path.domain),
                    _singleton(coefficient),
                )
            end
            coordinate = xbound * coordinate_q + eta_x * _interval_magnitude(exact_q)
            arithmetic = xbound * (arithmetic_q + loading_q) + rho[path.reconstruction]
            output =
                path.output_conversion == path.reconstruction ? _q(0) :
                rho[path.output_conversion]
            norm = Sollya.with_session(Sollya.Session(; precision)) do
                Sollya.with_objects() do keep
                    p = keep(_stored_polynomial(_odd_expansion(path.coefficients)))
                    f = keep(Sollya.sollya(_odd_expression(plan.spec)))
                    interval = keep(Sollya.interval(0, radius))
                    Sollya.bounds(interval) == (0, radius) ||
                        throw(ArgumentError("native proof domain enlargement"))
                    tightness = _q(accuracy)
                    bound = (_q(0), _q(0))
                    for refinement = 0:max_refinements
                        bound = _polynomial_norm(p, f, interval, tightness)
                        0 <= bound[1] <= bound[2] ||
                            throw(ArgumentError("invalid odd norm enclosure"))
                        bound[1] + coordinate + arithmetic + output <=
                        plan.spec.absolute_error <
                        bound[2] + coordinate + arithmetic + output || break
                        tightness /= 4
                    end
                    bound
                end
            end
        end
        bounds = Tuple(
            _node_bound(i, IR.format(plan.program, i), range) for
            (i, range) in sort!(collect(ranges); by = first)
        )
        PathCertificate(
            domain,
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
        "Established odd identity, complete graph audit and uniform evaluator bound meet the target" :
        "Conservative odd evaluator bound exceeds the target",
    )
end
