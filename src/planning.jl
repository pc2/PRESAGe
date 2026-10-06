function _check_generated_coefficients(coefficients, format)
    for (i, coefficient) in enumerate(coefficients)
        stored = try
            _polynomial_value(_polynomial_round(coefficient, format), format)
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

function _generated_polynomial_coefficients(spec, domain, degree, format, precision)
    Sollya.with_session(Sollya.Session(; precision)) do
        Sollya.with_objects() do keep
            f = keep(Sollya.sollya(_exact_expression(spec.expression)))
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
                word = _polynomial_round((lower + upper) / 2, format)
                return [_polynomial_value(word, format)]
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
            arithmetic = format isa FixedFormat ? :fixed : :floating
            bits = format isa FixedFormat ? _fraction(format) : format.fraction_bits + 1
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
    certified_polynomial(spec; degree, internal_format=spec.output_format,
                         evaluation=:separate, generation_precision=256,
                         proof_precision=256, accuracy=1//1024, max_refinements=2)

Generate and certify one bounded polynomial evaluator without supplied coefficients.
The contract requires an explicit finite domain. Degree is an upper limit in `0:32`; coefficients
and Horner stages share `internal_format`. Fixed formats require nearest-even
rounding and rejected overflow. Input and output formats remain independent.

Sollya coefficient formats use fixed fractional bits or floating significand bits;
generated coefficients must also fit the selected storage range exactly. Generation
and proof precision are independent; `accuracy` controls norm tightness, not the
error target. Decimal/scientific literals retain exact rational semantics.

Returns a `CertificationResult`, including the stored plan when generation
succeeds, even if its bound exceeds the budget or certification fails. Numerical
generation failures return `generation_failed` with a contract-only plan and reason.
Invalid settings or empty representable domains throw `ArgumentError`.
Singleton input domains use a constant from a certified point enclosure.
This is one synchronous attempt; it performs no search and sets no wall-time limit.
"""
function certified_polynomial(
    spec::FunctionSpec;
    degree::Integer,
    internal_format::Union{FloatFormat, FixedFormat} = spec.output_format,
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
    return _certified_polynomial(
        spec,
        domain,
        Int(degree),
        internal_format,
        evaluation,
        Int(generation_precision),
        Int(proof_precision),
        _q(accuracy),
        Int(max_refinements),
    )
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
    candidate_ready = identity,
)
    settings = Dict(
        "degree" => string(degree),
        "generation_precision" => string(generation_precision),
        "evaluation" => string(evaluation),
    )
    coefficients = try
        _generated_polynomial_coefficients(
            spec,
            domain,
            Int(degree),
            internal_format,
            Int(generation_precision),
        )
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
    candidate = polynomial_plan(spec, coefficients; internal_format, evaluation)
    plan = PlanArtifact(
        spec;
        program = candidate.program,
        settings = merge(candidate.settings, settings),
    )
    candidate_ready(plan)
    return certify_polynomial(plan; precision = proof_precision, accuracy, max_refinements)
end
