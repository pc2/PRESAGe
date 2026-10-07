function _check_generated_coefficients(coefficients, format)
    for (i, coefficient) in enumerate(coefficients)
        stored = try
            f = format isa Union{Tuple, AbstractVector} ? format[i] : format
            _polynomial_value(_polynomial_round(coefficient, f), f)
        catch err
            err isa Union{ArgumentError, OverflowError} || rethrow()
            throw(ArgumentError("coefficient of x^$(i - 1) exceeds its storage format"))
        end
        stored == coefficient || throw(
            ArgumentError(
                "coefficient of x^$(i - 1) is not exactly representable in its storage format",
            ),
        )
    end
    return coefficients
end

function _generated_polynomial_coefficients(
    spec,
    domain,
    degree,
    format,
    precision;
    normalization = nothing,
)
    _primitive(spec.expression) == :cbrt &&
        spec.domain !== nothing &&
        spec.domain[1] < 0 &&
        throw(ArgumentError("signed cbrt domains require transformation=:cbrt"))
    Sollya.with_session(Sollya.Session(; precision)) do
        Sollya.with_objects() do keep
            f =
                normalization === nothing ?
                keep(Sollya.sollya(_exact_expression(spec.expression))) :
                _normalized_function(
                    keep,
                    spec.expression,
                    normalization.center,
                    normalization.exponent,
                )
            Sollya.isfunction(f) ||
                throw(ArgumentError("expression must be a mathematical function"))
            interval = keep(Sollya.interval(domain...))
            Sollya.bounds(interval) == domain || throw(
                ArgumentError("native domain enlargement; increase generation precision"),
            )
            image = keep(Sollya.enclosure(f, interval))
            lower, upper = Sollya.bounds(image) # Require a finite function image.
            if domain[1] == domain[2]
                # Remez/fpminimax need a nondegenerate interval. A point enclosure
                # supplies a constant candidate; its error is still certified.
                f0 = format isa Union{Tuple, AbstractVector} ? first(format) : format
                word = _polynomial_round((lower + upper) / 2, f0)
                return [_polynomial_value(word, f0)]
            end
            # An exact polynomial that already fits needs no approximation search.
            exact = try
                Sollya.degree(f) <= degree ?
                _check_generated_coefficients(Sollya.coefficients(f), format) : nothing
            catch err
                err isa Union{Sollya.SollyaError, ArgumentError} || rethrow()
                nothing
            end
            exact === nothing || return exact
            formats =
                format isa Union{Tuple, AbstractVector} ? collect(format) :
                fill(format, degree + 1)
            arithmetic = first(formats) isa FixedFormat ? :fixed : :floating
            bits = [f isa FixedFormat ? _fraction(f) : f.fraction_bits + 1 for f in formats]
            polynomial = keep(
                Sollya.fpminimax(f, degree, bits, interval; error = :absolute, arithmetic),
            )
            coefficients = Sollya.coefficients(polynomial)
            length(coefficients) <= degree + 1 ||
                throw(ArgumentError("generated polynomial exceeds the requested degree"))
            return _check_generated_coefficients(coefficients, format)
        end
    end
end

"""
    certified_polynomial(spec; degree, internal_format=spec.output_format, precision=nothing,
                         segments=1, transformation=:none, evaluation=:separate, generation_precision=256,
                         proof_precision=256, accuracy=1//1024, max_refinements=2)

Generate and certify one bounded polynomial evaluator without supplied coefficients.
The contract requires an explicit finite domain. Degree is an upper limit in `0:32`.
Coefficients and Horner stages default to `internal_format`. Supply a
`PolynomialPrecision` to choose coefficient storage and stage formats separately;
its coordinate format becomes the internal default. Fixed formats require nearest-even
rounding and rejected overflow. Input and output formats remain independent.
For `transformation=:sinh` or `:cosh`, degree d (0:15) describes both central
q(a²) and reduced exp p(r); the central original degrees are 2d+1 and 2d.
Floating interfaces and an explicit bounded domain are required. The complete
certificate includes both half-scaled exponential terms and reconstruction.
For `transformation=:erfc`, degree 0:32 describes central erfc, a normalized
scaled positive tail and reduced exp. Three coefficient banks share storage
formats and three Horner graphs share stage formats. Floating interfaces and
an explicit bounded domain are required; square and reconstruction errors are
included in the certificate.
For `transformation=:sin` or `:cos`, degree d (0:15) describes two parity
kernels of original degrees 2d+1 and 2d. Floating bounded interfaces, proved
integer quadrant selection and complete residual/kernel/output bounds are required.
For `transformation=:asin` or `:acos`, degree d (0:32) describes a shared
asin parity kernel of original degree 2d+1 and an exponent-split sqrt kernel
of degree d. Floating interfaces and a bounded interval inside [-1,1] are
required; endpoint coordinates, composition and stored pi errors are certified.

Sollya coefficient formats use fixed fractional bits or floating significand bits;
generated coefficients must also fit the selected storage range exactly. Generation
and proof precision are independent; `accuracy` controls norm tightness, not the
error target. Decimal/scientific literals retain exact rational semantics.

Returns a `CertificationResult`, including the stored plan when generation
succeeds, even if its bound exceeds the budget or certification fails. Numerical
generation failures return `generation_failed` with a contract-only plan and reason.
Invalid settings or empty representable domains throw `ArgumentError`.
Singleton input domains use a constant from a certified point enclosure.
With `segments=2,4,…,64`, generate normalized coefficient tables and certify
every dispatch branch, including rounded coordinate formation. Internal fixed
formats must then be signed. Empty representable branches are rejected.
This is one synchronous attempt; it performs no search and sets no wall-time limit.
With `transformation=:odd`, generate `x*q(x²)` for bounded sin, sinh, atan or erf.
The requested degree is an odd original-function degree in `1:31`; precision
lists describe the `(degree+1)÷2` coefficients/stages of q. Only one kernel is
supported. Its proof includes square and reconstruction rounding and exact zeros.
With `transformation=:sqrt` or `:rsqrt`, generate a kernel on `[1,4]`, split
`e=2q+r` using floor division, and reconstruct directly into the floating output.
The bounded nonnegative contract covers positive finite inputs numerically;
zeros in the contract and positive infinity use exact lazy branches.
With `transformation=:cbrt`, split `e=3q+r`, generate the positive kernel on
`[1,8]`, and restore the original sign. Bounded signed intervals, signed zeros
and signed infinities are supported through audited identities and lazy branches.
With `transformation=:exp`, prove rounded integer exponent selection and a
residual in `[-1/2,1/2]`, then scale the final Horner value directly to the output.
With `transformation=:atan`, use one shared odd kernel on `[0,1]`, with
exact central/tail dispatch, a rounded reciprocal and stored pi/2 reconstruction.
With `transformation=:log`, the kernel approximates log(m) on `[1,2]` and
reconstructs `log(m)+e*log(2)` with the stored constant and all rounding certified.
With `transformation=:reciprocal`, generate `1/m` on `[1,2]` and reconstruct
with the exact input exponent. Floating interfaces and a bounded domain strictly
on one side of zero are required. Fixed/floating stages round directly into the
output during reconstruction, whose rounding and error scaling are certified.
"""
function certified_polynomial(
    spec::FunctionSpec;
    degree::Integer,
    segments::Integer = 1,
    transformation::Symbol = :none,
    precision::Union{Nothing, PolynomialPrecision} = nothing,
    internal_format::Union{FloatFormat, FixedFormat} = precision === nothing ?
                                                       spec.output_format :
                                                       precision.coordinate_format,
    evaluation::Symbol = :separate,
    generation_precision::Integer = 256,
    proof_precision::Integer = 256,
    accuracy::Union{Integer, Rational} = 1 // 1024,
    max_refinements::Integer = 2,
)
    domain = _validate_polynomial_request(
        spec,
        degree,
        internal_format,
        evaluation,
        generation_precision,
        proof_precision,
        accuracy,
        max_refinements,
    )
    _validate_transformation(transformation, degree, segments)
    transformation == :odd && _validate_odd_spec(spec)
    transformation == :atan && _atan_geometry(spec)
    transformation == :exp && _exp_geometry(spec)
    transformation == :erfc && _erfc_geometry(spec)
    transformation in (:sin, :cos) && _periodic_geometry(spec, transformation)
    transformation in (:asin, :acos) && _inverse_trig_geometry(spec, transformation)
    transformation in (:sinh, :cosh) && _hyperbolic_geometry(spec, transformation)
    transformation == :log && _log_geometry(spec)
    transformation == :reciprocal && _reciprocal_geometry(spec)
    transformation in (:sqrt, :rsqrt, :cbrt) && _root_geometry(spec, transformation)
    _validate_segment_request(spec, segments, internal_format)
    _validate_precision_request(
        precision,
        _coefficient_degree(degree, transformation),
        internal_format,
    )
    return _certified_polynomial(
        spec,
        domain,
        Int(degree),
        internal_format,
        evaluation,
        Int(generation_precision),
        Int(proof_precision),
        _q(accuracy),
        Int(max_refinements);
        segments = Int(segments),
        precision_layout = precision,
        transformation,
    )
end

function _validate_precision_request(precision, degree, format)
    precision === nothing && return nothing
    format == precision.coordinate_format ||
        throw(ArgumentError("internal format must match the precision coordinate format"))
    length(precision.coefficient_formats) >= degree + 1 ||
        throw(ArgumentError("precision layout is shorter than the requested degree"))
    for f in precision.coefficient_formats
        bits = f isa FixedFormat ? _fraction(f) : f.fraction_bits + 1
        typemin(Cint) <= bits <= typemax(Cint) ||
            throw(ArgumentError("coefficient precision must fit a C int"))
    end
    return nothing
end

function _validate_segment_request(spec, segments, format)
    _validate_segment_count(segments)
    if segments > 1
        format isa FixedFormat &&
            !format.signed &&
            throw(ArgumentError("normalized coordinates require signed fixed internals"))
        _segmented_domains(spec, segments)
    end
    return nothing
end

function _validate_polynomial_request(
    spec,
    degree,
    internal_format,
    evaluation,
    generation_precision,
    proof_precision,
    accuracy,
    max_refinements,
)
    spec.domain === nothing &&
        throw(ArgumentError("bounded polynomial generation requires an explicit domain"))
    all((spec.input_format, internal_format, spec.output_format)) do format
        !(format isa FixedFormat) ||
            (format.rounding == :nearest_even && format.overflow == :reject)
    end || throw(
        ArgumentError(
            "polynomial generation requires nearest-even rounding and rejected fixed overflow",
        ),
    )
    _validate_polynomial_settings(
        degree,
        internal_format,
        evaluation,
        generation_precision,
        proof_precision,
        accuracy,
        max_refinements,
    )
    return _polynomial_domain(spec)
end

function _validate_polynomial_settings(
    degree,
    internal_format,
    evaluation,
    generation_precision,
    proof_precision,
    accuracy,
    max_refinements,
)
    0 <= degree <= 32 || throw(ArgumentError("degree must be in 0:32"))
    evaluation in (:separate, :fma) ||
        throw(ArgumentError("evaluation must be :separate or :fma"))
    internal_format isa FixedFormat &&
        !(
            internal_format.rounding == :nearest_even &&
            internal_format.overflow == :reject
        ) &&
        throw(
            ArgumentError(
                "internal fixed formats require nearest-even rounding and rejected overflow",
            ),
        )
    12 <= generation_precision <= typemax(Cint) ||
        throw(ArgumentError("generation precision must be in 12:$(typemax(Cint))"))
    64 <= proof_precision <= typemax(Cint) ||
        throw(ArgumentError("proof precision must be in 64:$(typemax(Cint))"))
    0 < accuracy < 1 || throw(ArgumentError("norm accuracy must be between zero and one"))
    0 <= max_refinements <= 8 || throw(ArgumentError("refinements must be in 0:8"))
    bits =
        internal_format isa FixedFormat ? _fraction(internal_format) :
        internal_format.fraction_bits + 1
    typemin(Cint) <= bits <= typemax(Cint) ||
        throw(ArgumentError("coefficient precision must fit a C int"))
    return nothing
end

function _certified_polynomial(
    spec,
    domain,
    degree,
    internal_format,
    evaluation,
    generation_precision,
    proof_precision,
    accuracy,
    max_refinements;
    segments = 1,
    precision_layout = nothing,
    transformation = :none,
    candidate_ready = identity,
)
    transformation == :odd && return _certified_odd(
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
    transformation == :atan && return _certified_atan(
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
    transformation in (:sinh, :cosh) && return _certified_hyperbolic(
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
    transformation in (:asin, :acos) && return _certified_inverse_trig(
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
    transformation in (:sin, :cos) && return _certified_periodic(
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
    transformation == :erfc && return _certified_erfc(
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
    transformation == :exp && return _certified_exp(
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
    transformation == :log && return _certified_log(
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
    transformation == :reciprocal && return _certified_reciprocal(
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
    transformation in (:sqrt, :rsqrt, :cbrt) && return _certified_root(
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
    settings = Dict(
        "degree" => string(degree),
        "generation_precision" => string(generation_precision),
        "evaluation" => string(evaluation),
    )
    segments > 1 && (settings["segments"] = string(segments))
    candidate = try
        storage =
            precision_layout === nothing ? internal_format :
            _precision_prefix(precision_layout, degree + 1).coefficient_formats
        if segments == 1
            coefficients = _generated_polynomial_coefficients(
                spec,
                domain,
                Int(degree),
                storage,
                Int(generation_precision),
            )
            polynomial_plan(
                spec,
                coefficients;
                internal_format,
                evaluation,
                precision = precision_layout,
            )
        else
            geometry = _segment_geometry(spec, segments, internal_format)
            rows = [
                _generated_polynomial_coefficients(
                    spec,
                    geometry.normalized_domains[i],
                    degree,
                    storage,
                    generation_precision;
                    normalization = (
                        center = geometry.centers[i],
                        exponent = geometry.exponent,
                    ),
                ) for i = 1:segments
            ]
            segmented_polynomial_plan(
                spec,
                rows;
                internal_format,
                evaluation,
                precision = precision_layout,
            )
        end
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(
            PlanArtifact(spec; settings),
            :generation_failed,
            "Coefficient generation failed: " * sprint(showerror, err);
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
        segments = candidate.segments,
        precision = candidate.precision,
        settings = merge(candidate.settings, settings),
    )
    candidate_ready(plan)
    return certify_polynomial(plan; precision = proof_precision, accuracy, max_refinements)
end
