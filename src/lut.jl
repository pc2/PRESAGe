struct _LUTProofFailure <: Exception
    status::Symbol
    reason::String
end

function _lut_entry_limit(value)
    _resource_integer(value, "lut_max_entries"; positive = true) <= typemax(Int) ||
        throw(ArgumentError("lut_max_entries must fit Int"))
    return Int(value)
end

function _lut_availability(spec, max_entries)
    limit = _lut_entry_limit(max_entries)
    width = _width(spec.input_format)
    # Compare widths before shifting: even an enormous declared input cannot
    # cause a large allocation during availability checks.
    available = width < ndigits(limit; base = 2)
    return (;
        available,
        reason = available ? "Full input table fits the $limit-entry generation limit" :
                 "A $width-bit input requires more than the $limit-entry LUT generation limit",
    )
end

function _check_lut_spec(spec; max_entries = 65536)
    availability = _lut_availability(spec, max_entries)
    availability.available || throw(ArgumentError(availability.reason))
    _polynomial_domain(spec) # Includes empty representable-domain checks.
    return Int(1) << _width(spec.input_format)
end

function _lut_plan(spec, words; max_entries = 65536)
    entries = _check_lut_spec(spec; max_entries)
    length(words) == entries ||
        throw(ArgumentError("a full LUT needs all $entries input encodings"))
    nodes = IR.Node[
        IR.Input(spec.input_format),
        IR.BitCast(1, IR.UIntFormat(_width(spec.input_format))),
        IR.TableLoad(1, 2),
    ]
    # Bounded contracts use the same exact guards as polynomial evaluators.
    # Fixed outputs reject nonfinites; unbounded floating LUTs store the
    # reference oracle's established primitive special values directly.
    output = if spec.domain !== nothing || spec.output_format isa FixedFormat
        _polynomial_guard!(nodes, 3, spec)
    else
        3
    end
    program = IR.Program(nodes; output, tables = [IR.Table(spec.output_format, words)])
    return PlanArtifact(spec; program, settings = Dict("kernel" => "full_lut"))
end

_lut_backend(spec, backend) =
    backend == :auto ? (_primitive(spec.expression) === nothing ? :sollya : :mpfr) : backend
_lut_placeholder(f::FloatFormat) = _nan(f)
_lut_placeholder(::FixedFormat) = BigInt(0)

function _lut_references(spec, stored; config, backend, max_entries)
    entries = _check_lut_spec(spec; max_entries)
    words = Vector{IR.Word}(undef, entries)
    maximum_error = _q(0)
    with_oracle(spec; config, backend) do oracle
        for index = 0:(entries - 1)
            word = BigInt(index)
            x = _decode_input(word, spec.input_format)
            finite = x.kind in (:finite, :zero)
            covered =
                finite &&
                (spec.domain === nothing || spec.domain[1] <= x.value <= spec.domain[2])
            guarded =
                !covered && (spec.domain !== nothing || spec.output_format isa FixedFormat)
            ref = guarded ? nothing : reference(oracle, word)
            expected = if guarded
                _lut_placeholder(spec.output_format)
            else
                ref.bits !== nothing &&
                    ref.status in (:resolved, :special, :domain_error) || throw(
                    _LUTProofFailure(
                        :proof_failed,
                        "$(hex_bits(word,spec.input_format)): $(ref.status): $(ref.detail)",
                    ),
                )
                ref.bits
            end
            actual = stored === nothing ? expected : stored[index + 1]
            actual == expected || throw(
                _LUTProofFailure(
                    :proof_failed,
                    "Stored entry at $(hex_bits(word,spec.input_format)) differs from the resolved reference or guarded placeholder",
                ),
            )
            words[index + 1] = actual
            covered || continue
            y = _decode_input(actual, spec.output_format)
            ref.status != :domain_error && y.kind in (:finite, :zero) || throw(
                _LUTProofFailure(
                    :unsupported_domain,
                    "Finite input $(hex_bits(word,spec.input_format)) has no finite mathematical error contract",
                ),
            )
            error = if ref.enclosure === nothing
                # Exact primitive identities still incur fixed rounding or
                # saturation error. Do not assume the stored value is exact.
                exact = if iszero(x.value) && oracle.primitive in _ODD_ZERO
                    _q(0)
                elseif iszero(x.value) && oracle.primitive in (:exp, :erfc, :cos, :cosh)
                    _q(1)
                elseif oracle.polynomial &&
                       ref.status == :resolved &&
                       ref.detail == "exact rational value"
                    expression = Sollya.substitute(oracle.expression, x.value)
                    try
                        Sollya.exact_rational(expression)
                    finally
                        close(expression)
                    end
                else
                    throw(
                        _LUTProofFailure(
                            :proof_failed,
                            "Finite reference has no error enclosure or established exact identity",
                        ),
                    )
                end
                abs(y.value - exact)
            else
                lo, hi = ref.enclosure
                lo.kind == hi.kind == :finite || throw(
                    _LUTProofFailure(
                        :proof_failed,
                        "Nonfinite reference enclosure at $(hex_bits(word,spec.input_format))",
                    ),
                )
                max(
                    abs(y.value - lo.significand * _pow2(lo.exponent)),
                    abs(y.value - hi.significand * _pow2(hi.exponent)),
                )
            end
            maximum_error = max(maximum_error, error)
        end
    end
    return words, maximum_error
end

function _lut_settings(config, backend, entries, max_entries)
    Dict(
        "method" => "exhaustive_lut",
        "reference_backend" => string(backend),
        "entries" => string(entries),
        "max_entries" => string(max_entries),
        "initial_precision" => string(config.initial_precision),
        "max_precision" => string(config.max_precision),
    )
end

function _lut_result(plan, bound, settings)
    path = PathCertificate(
        _polynomial_domain(plan.spec),
        true,
        (_q(0), bound),
        _q(0),
        _q(0),
        _q(0),
        bound,
        (),
    )
    status = bound <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    reason =
        status == :certified ?
        "All $(settings["entries"]) input encodings audited; finite errors in the contract meet the target" :
        "Exhaustive finite-input error enclosure exceeds the target"
    return CertificationResult(plan, status, bound, (path,), nothing, settings, reason)
end

"""
    certified_lut(spec; config=OracleConfig(), backend=:auto, max_entries=65536)

Generate and certify a full raw-index table for a small fixed or floating input,
with any supported output format. Adaptive directed references resolve every
covered finite input; the complete table and exact guards are audited. Bounded
floating outputs return canonical NaN outside the domain; fixed outputs reject.
Finite poles, invalid mathematical arguments and unresolved references fail the
certificate. The entry limit is checked before allocation. The automatic oracle
uses MPFR for primitives and Sollya for compositions.
"""
function certified_lut(
    spec::FunctionSpec;
    config::OracleConfig = OracleConfig(),
    backend::Symbol = :auto,
    max_entries::Integer = 65536,
)
    limit = _lut_entry_limit(max_entries)
    backend = _lut_backend(spec, backend)
    empty = PlanArtifact(spec)
    settings = Dict("method" => "exhaustive_lut", "reference_backend" => string(backend))
    try
        entries = _check_lut_spec(spec; max_entries = limit)
        settings = _lut_settings(config, backend, entries, limit)
        words, bound = _lut_references(spec, nothing; config, backend, max_entries = limit)
        return _lut_result(_lut_plan(spec, words; max_entries = limit), bound, settings)
    catch err
        err isa _LUTProofFailure &&
            return _certificate_failure(empty, err.status, err.reason; settings)
        err isa ArgumentError && return _certificate_failure(
            empty,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
        rethrow()
    end
end

"""Recertify every table entry and audit the complete raw-index graph and domain guards."""
function certify_lut(
    plan::PlanArtifact;
    config::OracleConfig = OracleConfig(),
    backend::Symbol = :auto,
    max_entries::Integer = 65536,
)
    limit = _lut_entry_limit(max_entries)
    backend = _lut_backend(plan.spec, backend)
    settings = Dict("method" => "exhaustive_lut", "reference_backend" => string(backend))
    try
        entries = _check_lut_spec(plan.spec; max_entries = limit)
        settings = _lut_settings(config, backend, entries, limit)
        p = plan.program
        p !== nothing &&
            length(p.tables) == 1 &&
            isempty(plan.segments) &&
            plan.dispatch === nothing &&
            plan.precision === nothing || throw(ArgumentError("unsupported LUT program"))
        table = only(p.tables)
        table.format == plan.spec.output_format ||
            throw(ArgumentError("unsupported LUT storage format"))
        canonical = _lut_plan(plan.spec, collect(table.values); max_entries = limit)
        _program_data(canonical.program) == _program_data(p) || throw(
            ArgumentError(
                "executed graph differs from the supported guarded raw-index LUT",
            ),
        )
        _, bound =
            _lut_references(plan.spec, table.values; config, backend, max_entries = limit)
        return _lut_result(plan, bound, settings)
    catch err
        err isa _LUTProofFailure &&
            return _certificate_failure(plan, err.status, err.reason; settings)
        err isa ArgumentError && return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
        rethrow()
    end
end
