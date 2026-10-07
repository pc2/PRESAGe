struct FixedNodeBound
    node::Int
    format::FixedFormat
    range::_Interval
end
struct FloatNodeBound
    node::Int
    format::FloatFormat
    range::_Interval
end
_node_bound(node, f::FixedFormat, range) = FixedNodeBound(node, f, range)
_node_bound(node, f::FloatFormat, range) = FloatNodeBound(node, f, range)
struct PathCertificate
    domain::_Interval
    upper_inclusive::Bool
    approximation::_Interval
    coordinate_error::Rational{BigInt}
    arithmetic_error::Rational{BigInt}
    output_rounding::Rational{BigInt}
    total::Rational{BigInt}
    ranges::Tuple{Vararg{Union{FixedNodeBound, FloatNodeBound}}}
end
"""Uniform numerical result for the exact program in `plan`; sampled maxima are separate."""
struct CertificationResult
    plan::PlanArtifact
    status::Symbol
    total_bound::Union{Nothing, Rational{BigInt}}
    paths::Tuple{Vararg{PathCertificate}}
    tail_bound::Union{Nothing, Rational{BigInt}}
    settings::Dict{String, String}
    reason::String
end
function _certificate_failure(plan, status, reason; settings = Dict{String, String}())
    return CertificationResult(plan, status, nothing, (), nothing, settings, reason)
end
_quantizer_error(source::FixedFormat, target::FixedFormat) =
    _fraction(target) >= _fraction(source) ? _q(0) : _pow2(-_fraction(target) - 1)
function _float_rounding_bound(range, f::FloatFormat)
    magnitude = _interval_magnitude(range)
    all(q -> decode_ieee(round_ieee(q, f), f).value !== nothing, range) ||
        throw(OverflowError("floating range may overflow after rounding"))
    iszero(magnitude) && return _q(0)
    n, d = abs(numerator(magnitude)), denominator(magnitude)
    e = ndigits(n; base = 2) - ndigits(d; base = 2)
    (e >= 0 ? n < d << e : n << -e < d) && (e -= 1)
    return _pow2(max(e, _emin(f)) - f.fraction_bits - 1)
end
function _erf_audit(plan)
    interface = _check_fixed_erf_spec(plan.spec)
    plan.program !== nothing || throw(ArgumentError("missing evaluator program"))
    ss = plan.segments
    n = length(ss)
    1 <= n <= 64 && ispow2(n) || throw(ArgumentError("unsupported segmentation"))
    degree = length(first(ss).coefficients) - 1
    1 <= degree <= 32 && all(s -> length(s.coefficients) == degree + 1, ss) ||
        throw(ArgumentError("unsupported polynomial layout"))
    width = _q(4) / n
    all(i -> ss[i].lower == (i - 1) * width && ss[i].upper == i * width, 1:n) ||
        throw(ArgumentError("segments must cover [0,4] without gaps"))
    b = plan.dispatch
    b !== nothing &&
        b.magnitude_threshold == round_ieee(4, interface) &&
        b.comparison == :greater &&
        b.positive_tail == 1 &&
        b.negative_tail == -1 || throw(ArgumentError("unsupported tail dispatch"))
    get(plan.settings, "kernel", "") == "erf_fixed_horner" ||
        throw(ArgumentError("unsupported evaluator kernel"))
    fraction = parse(Int, plan.settings["fraction_bits"])
    coefficient_fraction = parse(Int, plan.settings["coefficient_fraction_bits"])
    0 <= fraction <= 256 && 0 <= coefficient_fraction <= 256 ||
        throw(ArgumentError("unsupported fractional widths"))
    fraction >= max(0, trailing_zeros(n) - 1) ||
        throw(ArgumentError("inexact segment centres"))
    evaluation = Symbol(plan.settings["evaluation"])
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported Horner arithmetic"))
    layout =
        _fixed_erf_layout(ss, fraction, coefficient_fraction, evaluation; spec = plan.spec)
    _program_data(layout.plan.program) == _program_data(plan.program) || throw(
        ArgumentError("executed graph differs from the supported fixed erf evaluator"),
    )
    for ranges in layout.ranges, (node, range) in ranges
        f = IR.format(plan.program, node)
        lo, hi = _fixed_limits(f)
        quantum = _pow2(-_fraction(f))
        lo * quantum <= range[1] <= range[2] <= hi * quantum ||
            throw(OverflowError("node $node may overflow"))
    end
    return layout
end
function _path_arithmetic(layout, row)
    p = layout.plan.program
    coefficients = layout.plan.segments[row].coefficients
    tbound = _interval_magnitude(layout.domain)
    eta = _pow2(-parse(Int, layout.plan.settings["fraction_bits"]) - 1)
    exact = _singleton(coefficients[end])
    actual = layout.ranges[row][layout.initial]
    arithmetic = abs(actual[1] - coefficients[end])
    coordinate = _q(0)
    for stage in layout.stages
        coordinate = tbound * coordinate + eta * _interval_magnitude(exact)
        rho = _quantizer_error(IR.format(p, stage.wide), IR.format(p, stage.result))
        if stage.productquantizer !== nothing
            rho += _quantizer_error(
                IR.format(p, stage.product),
                IR.format(p, stage.productquantizer),
            )
        end
        arithmetic = tbound * arithmetic + rho
        exact = _interval_add(
            _interval_mul(exact, layout.domain),
            _singleton(coefficients[stage.coefficient]),
        )
    end
    output = _float_rounding_bound(
        layout.ranges[row][layout.final],
        layout.plan.spec.output_format,
    )
    return coordinate, arithmetic, output
end
function _stored_polynomial(coefficients)
    text = join(
        ["($(_rational_text(c)))*x^$(k-1)" for (k, c) in enumerate(coefficients)],
        " + ",
    )
    p = Sollya.sollya(text)
    try
        actual = Sollya.coefficients(p)
        append!(actual, fill(_q(0), length(coefficients) - length(actual)))
        actual == coefficients ||
            throw(ArgumentError("native polynomial differs from stored coefficients"))
        return p
    catch
        close(p)
        rethrow()
    end
end

"""
    certify_erf(plan; precision=256, accuracy=1//1024, max_refinements=2)

Certify the supported fixed binary16 or binary32 erf graph on every finite input. Sollya
supnorm proves stored-polynomial error; exact rational range/error propagation
covers input quantisation, every arithmetic quantizer and output rounding.
Known oddness and monotonicity cover sign restoration and constant tails.
Graph or domain mismatches are unsupported, and proof failure never falls back
to samples. `accuracy` controls norm tightness, independently of the error target.
"""
function certify_erf(
    plan::PlanArtifact;
    precision::Integer = 256,
    accuracy::Union{Integer, Rational} = 1 // 1024,
    max_refinements::Integer = 2,
)
    precision >= 64 || throw(ArgumentError("proof precision must be at least 64"))
    0 < accuracy < 1 || throw(ArgumentError("norm accuracy must be between zero and one"))
    0 <= max_refinements <= 8 || throw(ArgumentError("refinements must be in 0:8"))
    settings = Dict(
        "method" => "erf_fixed_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _erf_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError} && return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
        err isa OverflowError && return _certificate_failure(
            plan,
            :proof_failed,
            sprint(showerror, err);
            settings,
        )
        rethrow()
    end
    paths = PathCertificate[]
    tail = nothing
    try
        Sollya.with_session(Sollya.Session(; precision)) do
            for row in eachindex(plan.segments)
                owned = Sollya.SollyaObject[]
                try
                    segment = plan.segments[row]
                    coordinate, arithmetic, output = _path_arithmetic(layout, row)
                    p = _stored_polynomial(segment.coefficients)
                    push!(owned, p)
                    f = Sollya.sollya("erf(x+($(_rational_text(layout.centers[row]))))")
                    push!(owned, f)
                    domain = Sollya.interval(layout.domain...)
                    push!(owned, domain)
                    Sollya.bounds(domain) == layout.domain ||
                        throw(ArgumentError("native domain enlargement"))
                    norm = (_q(0), _q(0))
                    tightness = _q(accuracy)
                    for refinement = 0:max_refinements
                        proof = Sollya.supnorm(
                            p,
                            f,
                            domain;
                            error = :absolute,
                            accuracy = tightness,
                        )
                        try
                            norm = Sollya.bounds(proof)
                        finally
                            close(proof)
                        end
                        0 <= norm[1] <= norm[2] ||
                            throw(ArgumentError("invalid polynomial norm enclosure"))
                        other = coordinate + arithmetic + output
                        norm[1] + other <= plan.spec.absolute_error < norm[2] + other ||
                            break
                        tightness /= 4
                    end
                    bounds = Tuple(
                        FixedNodeBound(node, IR.format(plan.program, node), range) for
                        (node, range) in sort!(collect(layout.ranges[row]); by = first)
                    )
                    push!(
                        paths,
                        PathCertificate(
                            (segment.lower, segment.upper),
                            row == length(plan.segments),
                            norm,
                            coordinate,
                            arithmetic,
                            output,
                            norm[2] + coordinate + arithmetic + output,
                            bounds,
                        ),
                    )
                finally
                    foreach(close, reverse(owned))
                end
            end
            f = Sollya.sollya("erf(x)")
            try
                endpoint = Sollya.enclosure(f, 4)
                try
                    lo, hi = Sollya.bounds(endpoint)
                    0 <= lo <= hi <= 1 || throw(ArgumentError("invalid erf tail enclosure"))
                    tail = 1 - lo
                finally
                    close(endpoint)
                end
            finally
                close(f)
            end
        end
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(plan, :proof_failed, sprint(showerror, err); settings)
    end
    total = max(tail, maximum(p.total for p in paths))
    status = total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    reason =
        status == :certified ? "All finite-input paths meet the absolute error target" :
        "Conservative uniform bound exceeds the target"
    return CertificationResult(plan, status, total, Tuple(paths), tail, settings, reason)
end

"""Bounded width search. Exhaustion reports search_limit, never mathematical infeasibility."""
function certified_erf(;
    spec::FunctionSpec = erf_spec(),
    implementation::Symbol = :auto,
    model::ImplementationModel = ImplementationModel(),
    degree::Integer = 9,
    segments::Integer = 4,
    initial_fraction_bits::Integer = spec.output_format.fraction_bits +
                                     ndigits(16degree - 1; base = 2),
    max_fraction_bits::Integer = spec.output_format.fraction_bits + 24,
    coefficient_fraction_bits = nothing,
    evaluation::Symbol = :separate,
    precision::Integer = 256,
    proof_precision::Integer = 256,
    accuracy::Union{Integer, Rational} = 1 // 1024,
)
    _check_fixed_erf_spec(spec)
    selected = select_implementation(spec; implementation, model)
    if selected == :lut
        config = OracleConfig(;
            initial_precision = proof_precision,
            max_precision = max(4096, proof_precision),
        )
        return certified_lut(spec; config)
    end
    1 <= degree <= 32 || throw(ArgumentError("degree must be in 1:32"))
    0 <= initial_fraction_bits <= max_fraction_bits <= 256 ||
        throw(ArgumentError("invalid width search bounds"))
    last = nothing
    attempts = 0
    for fraction = initial_fraction_bits:2:max_fraction_bits
        attempts += 1
        plan = try
            erf_fixed_candidate(;
                spec,
                degree,
                segments,
                fraction_bits = fraction,
                coefficient_fraction_bits = coefficient_fraction_bits === nothing ?
                                            fraction : coefficient_fraction_bits,
                evaluation,
                precision,
            )
        catch err
            err isa Sollya.SollyaError || rethrow()
            return _certificate_failure(
                PlanArtifact(spec),
                :proof_failed,
                "Coefficient generation failed: " * sprint(showerror, err),
            )
        end
        last = certify_erf(plan; precision = proof_precision, accuracy)
        last.status == :certified && return last
        last.status in (:unsupported_domain, :proof_failed) && return last
    end
    settings = merge(last.settings, Dict("search_attempts" => string(attempts)))
    return CertificationResult(
        last.plan,
        :search_limit,
        last.total_bound,
        last.paths,
        last.tail_bound,
        settings,
        "Width search exhausted: " * last.reason,
    )
end

function _certificate_data(result::CertificationResult)
    d = Dict{String, Any}(
        "schema" => "presage-certificate",
        "schema_version" => 2,
        "status" => string(result.status),
        "expression" => result.plan.spec.expression,
        "input_format" => _format_data(result.plan.spec.input_format),
        "output_format" => _format_data(result.plan.spec.output_format),
        "absolute_error" => _rational_text(result.plan.spec.absolute_error),
        "reason" => result.reason,
        "settings" => result.settings,
    )
    result.total_bound === nothing ||
        (d["total_bound"] = _rational_text(result.total_bound))
    result.plan.precision === nothing ||
        (d["precision"] = _precision_data(result.plan.precision))
    if !isempty(result.paths)
        d["paths"] = [
            Dict(
                "domain" => _rational_text.(collect(p.domain)),
                "upper_inclusive" => p.upper_inclusive,
                "approximation" => _rational_text.(collect(p.approximation)),
                "coordinate_error" => _rational_text(p.coordinate_error),
                "arithmetic_error" => _rational_text(p.arithmetic_error),
                "output_rounding" => _rational_text(p.output_rounding),
                "total" => _rational_text(p.total),
                "ranges" => [
                    Dict(
                        "node" => b.node,
                        "format" => _type_data(b.format),
                        "bounds" => _rational_text.(collect(b.range)),
                    ) for b in p.ranges
                ],
            ) for p in result.paths
        ]
        if get(result.settings, "method", "") in
           ("normalized_segmented_horner", "precision_polynomial_horner") &&
           !isempty(result.plan.segments)
            layout = _segmented_audit(result.plan)
            for (report, path, certificate) in zip(d["paths"], layout.paths, result.paths)
                coordinate = Dict{String, Any}(
                    "center" => _rational_text(path.center),
                    "scale_exponent" => path.exponent,
                    "ideal_domain" => _rational_text.(collect(path.domain)),
                    "node" => path.coordinate,
                )
                bound = findfirst(b -> b.node == path.coordinate, certificate.ranges)
                bound === nothing || (
                    coordinate["rounded_domain"] =
                        _rational_text.(collect(certificate.ranges[bound].range))
                )
                report["coordinate"] = coordinate
            end
        end
        d["coverage"] = if get(result.settings, "method", "") == "binary16_exhaustive_lut"
            Dict(
                "inputs" => "all 65536 binary16 encodings",
                "finite_inputs" => "resolved nearest-even output for every finite input",
                "nonfinite_inputs" => "shared primitive special-value policy",
                "table_bits" => 65536 * 16,
            )
        elseif get(result.settings, "method", "") in (
            "fixed_polynomial_horner",
            "floating_polynomial_horner",
            "normalized_segmented_horner",
            "precision_polynomial_horner",
            "odd_polynomial_horner",
            "reciprocal_polynomial_horner",
        )
            input = result.plan.spec.input_format
            output = result.plan.spec.output_format
            Dict(
                "input_domain" =>
                    _rational_text.([
                        first(result.paths).domain[1],
                        last(result.paths).domain[2],
                    ]),
                "inputs" =>
                    input isa FixedFormat ?
                    "all representable fixed inputs in the interval" :
                    "all representable finite floating inputs in the interval",
                "outside_domain" =>
                    result.plan.spec.domain === nothing ? "no excluded finite inputs" :
                    output isa FixedFormat ? "rejected before polynomial evaluation" :
                    "canonical quiet NaN before polynomial evaluation",
                "overflow" => "all reachable arithmetic nodes and output conversions bounded",
                "dispatch" =>
                    get(result.settings, "method", "") == "odd_polynomial_horner" ?
                    "single odd central kernel; exact zero branch" :
                    get(result.settings, "method", "") == "reciprocal_polynomial_horner" ?
                    "single mantissa kernel; exact exponent and sign reconstruction" :
                    !isempty(result.plan.segments) ?
                    "canonical input-format thresholds; adjacent representable path endpoints; both signed zeros share a path" :
                    "single Horner path",
            )
        else
            Dict(
                "central_magnitude" => ["0/1", "4/1"],
                "negative_inputs" => "exact odd sign restoration",
                "zeros" => "both signed zeros preserved",
                "infinities" => "signed unit values",
                "nan" => "canonical quiet NaN",
                "overflow" => "all fixed nodes and output conversions bounded",
            )
        end
        if get(result.settings, "method", "") == "odd_polynomial_horner"
            path = only(_odd_audit(result.plan).paths)
            d["transformation"] = Dict(
                "kind" => "odd",
                "polynomial" => "x*q(x*x)",
                "identity" =>
                    "established oddness and exact zero for " *
                    _odd_expression(result.plan.spec),
                "norm_domain" =>
                    _rational_text.([_q(0), _interval_magnitude(path.input_domain)]),
                "ideal_square_domain" => _rational_text.(collect(path.domain)),
                "square_node" => path.coordinate,
                "reconstruction_node" => path.reconstruction,
                "zeros" =>
                    result.plan.spec.input_format isa FloatFormat &&
                    result.plan.spec.output_format isa FloatFormat ?
                    "both floating zero signs preserved by the lazy zero branch" :
                    "exact zero output",
            )
        elseif get(result.settings, "method", "") == "reciprocal_polynomial_horner"
            path = only(_reciprocal_audit(result.plan).paths)
            d["transformation"] = Dict(
                "kind" => "reciprocal",
                "identity" => "abs(x)=m*2^e; 1/x=sign(x)*(1/m)*2^-e",
                "norm_domain" => _rational_text.(collect(path.domain)),
                "input_exponents" => collect(path.exponents),
                "maximum_error_scale" => _rational_text(path.reconstruction_bound),
                "normalization" => "exact for every finite nonzero input, including subnormals",
                "reconstruction_node" => path.reconstruction,
                "rounding" => "directly from the final Horner stage to the output format",
                "excluded_inputs" => "zeros, nonfinite values and inputs outside the bounded domain return canonical quiet NaN",
            )
        end
    end
    if get(result.settings, "method", "") == "root_polynomial_horner"
        path = only(_root_audit(result.plan).paths)
        kind = result.plan.settings["transformation"]
        cube = kind == "cbrt"
        d["coverage"] = Dict(
            "input_domain" => _rational_text.(collect(path.accepted_domain)),
            "inputs" =>
                cube ? "all representable finite inputs in the interval" :
                "all representable positive finite inputs in the interval",
            "zeros" =>
                kind == "rsqrt" ?
                "exact signed infinities when zero is in the contract" :
                "both signed zeros preserved when zero is in the contract",
            "positive_infinity" =>
                kind == "rsqrt" ? "positive zero" : "positive infinity",
            "invalid_inputs" =>
                cube ? "NaNs return canonical quiet NaN" :
                "negative finite inputs, negative infinity and NaNs return canonical quiet NaN",
            "outside_domain" => "finite inputs outside the bounded domain return canonical quiet NaN",
            "overflow" => "all reachable nonzero finite arithmetic nodes and output conversions bounded",
        )
        cube && (d["coverage"]["infinities"] = "both signed infinities preserved")
        d["transformation"] = Dict(
            "kind" => kind,
            "exponent_divisor" => path.divisor,
            "argument_format" => _format_data(path.argument_format),
            "identity" =>
                "abs(x)=m*2^e; e=$(path.divisor)q+r (floor division); t=m*2^r; " * (
                    cube ? "cbrt(x)=sign(x)*cbrt(t)*2^q" :
                    kind == "sqrt" ? "sqrt(x)=sqrt(t)*2^q" : "rsqrt(x)=rsqrt(t)*2^-q"
                ),
            "norm_domain" => _rational_text.(collect(path.domain)),
            "input_exponents" => collect(path.exponents),
            "maximum_error_scale" => _rational_text(path.reconstruction_bound),
            "normalization" => "exact for every finite nonzero magnitude, including subnormals",
            "reconstruction_node" => path.reconstruction,
            "rounding" => "directly from the final Horner stage to the output format",
            "zero_only" => path.zero_only,
        )
    end
    if get(result.settings, "method", "") == "log_polynomial_horner"
        path = only(_log_audit(result.plan).paths)
        d["coverage"] = Dict(
            "input_domain" => _rational_text.(collect(path.accepted_domain)),
            "inputs" => "all representable positive finite inputs in the interval",
            "zeros" => "both signed zeros return negative infinity when zero is in the contract",
            "one" => "exact positive zero when one is in the contract",
            "positive_infinity" => "positive infinity",
            "invalid_inputs" => "negative finite inputs, negative infinity and NaNs return canonical quiet NaN",
            "outside_domain" => "finite inputs outside the bounded domain return canonical quiet NaN",
            "overflow" => "all reachable positive finite arithmetic nodes and output conversions bounded",
        )
        d["transformation"] = Dict(
            "kind" => "log",
            "identity" => "x=m*2^e; log(x)=log(m)+e*log(2)",
            "norm_domain" => _rational_text.(collect(path.domain)),
            "input_exponents" => collect(path.exponents),
            "normalization" => "exact for every positive finite input, including subnormals",
            "stored_log2_node" => path.log2_node,
            "log2_error_bound" => get(result.settings, "log2_error_bound", "0/1"),
            "reconstruction_node" => path.reconstruction,
            "rounding" =>
                "explicit casts, " *
                result.plan.settings["evaluation"] *
                " reconstruction, and output conversion",
            "exceptional_only" => path.exceptional_only,
        )
    end
    if get(result.settings, "method", "") == "atan_polynomial_horner" &&
       result.total_bound !== nothing
        layout = _atan_audit(result.plan)
        d["coverage"] = Dict(
            "input_domain" => _rational_text.(collect(layout.geometry.accepted_domain)),
            "inputs" => "all representable finite inputs in the bounded signed interval",
            "dispatch" => "central for abs(x)<=1; reciprocal tail for abs(x)>1, compared in the input format",
            "zeros" => "both signed zeros preserved when included",
            "infinities" => "signed stored pi/2 limit, including its conversion and constant error",
            "invalid_inputs" => "NaNs and excluded finite inputs return canonical quiet NaN before kernel evaluation",
            "overflow" => "all reachable numerical branches and output conversions bounded",
        )
        d["transformation"] = Dict(
            "kind" => "atan",
            "identity" => "atan(x)=sign(x)*atan(abs(x)); atan(a)=pi/2-atan(1/a) for a>1",
            "norm_domain" => ["0/1", "1/1"],
            "kernel" => "r*q(r*r)",
            "reciprocal_format" => _format_data(layout.reduction_format),
            "pi2_node" => layout.pi2_node,
            "pi2_error_bound" => get(result.settings, "pi2_error_bound", ""),
            "infinity_error_bound" => get(result.settings, "infinity_error_bound", ""),
            "paths" => [
                Dict(
                    "kind" => string(p.kind),
                    "input_domain" => _rational_text.(collect(p.input_domain)),
                    "argument_domain" => _rational_text.(collect(p.argument_domain)),
                ) for p in layout.paths
            ],
        )
    end
    if get(result.settings, "method", "") == "exp_polynomial_horner" &&
       result.total_bound !== nothing
        path = only(_exp_audit(result.plan).paths)
        d["coverage"] = Dict(
            "input_domain" => _rational_text.(collect(path.input_domain)),
            "inputs" => "all representable finite inputs in the bounded signed interval",
            "zeros" => "both signed zeros return exact one when included",
            "infinities" => "positive infinity returns infinity; negative infinity returns positive zero",
            "invalid_inputs" => "NaNs and excluded finite inputs return canonical quiet NaN before reduction",
            "overflow" => "all reachable numerical operations and output scaling bounded",
        )
        d["transformation"] = Dict(
            "kind" => "exp",
            "identity" => "exp(x)=2^k*exp(x-k*log(2)) for integer k",
            "norm_domain" => _rational_text.(collect(path.domain)),
            "reduction_format" => _format_data(path.reduction_format),
            "exponent_node" => path.exponent_node,
            "exponent_format" => _format_data(path.exponent_format),
            "selection" => "nearest-even integer conversion of rounded x*stored inverse_log2",
            "stored_log2_node" => path.log2_node,
            "stored_inverse_log2_node" => path.inverse_node,
            "reconstruction_node" => path.output_node,
            "rounding" => "direct final-Horner scaling to the output format",
            "zero_only" => path.zero_only,
        )
    end
    result.tail_bound === nothing || (
        d["tail"] = Dict(
            "magnitude_lower" => "4/1",
            "comparison" => "greater",
            "absolute_error" => _rational_text(result.tail_bound),
            "argument" => "erf is monotone and bounded above by one",
        )
    )
    return d
end
"""Write the numerical proof report. Regenerate it whenever evaluator semantics change."""
write_certificate(io::IO, result::CertificationResult) =
    TOML.print(io, _certificate_data(result); sorted = true)
write_certificate(path::AbstractString, result::CertificationResult) =
    open(io -> write_certificate(io, result), path, "w")
