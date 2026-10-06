function _check_lut_spec(spec)
    spec.input_format == spec.output_format == IEEE16 && spec.domain === nothing || throw(
        ArgumentError(
            "LUT certificates require matching binary16 interfaces and an all-finite domain",
        ),
    )
end
function _lut_plan(spec, words)
    _check_lut_spec(spec)
    length(words) == 65536 || throw(ArgumentError("a binary16 LUT needs all 65536 entries"))
    program = IR.Program(
        [IR.Input(IEEE16), IR.BitCast(1, IR.UIntFormat(16)), IR.TableLoad(1, 2)];
        tables = [IR.Table(IEEE16, words)],
    )
    return PlanArtifact(spec; program, settings = Dict("kernel" => "binary16_lut"))
end
struct _LUTProofFailure <: Exception
    status::Symbol
    reason::String
end
function _lut_references(spec, stored; config, backend)
    words = Vector{UInt64}(undef, 65536)
    maximum_error = _q(0)
    with_oracle(spec; config, backend) do oracle
        for word = UInt64(0):UInt64(65535)
            ref = reference(oracle, word)
            x = decode_ieee(word, IEEE16)
            finite = x.kind in (:finite, :zero)
            ref.bits !== nothing && ref.status in (:resolved, :special, :domain_error) ||
                throw(
                    _LUTProofFailure(
                        :proof_failed,
                        "$(hex_bits(word,IEEE16)): $(ref.status): $(ref.detail)",
                    ),
                )
            actual = stored === nothing ? ref.bits : stored[Int(word) + 1]
            actual == ref.bits || throw(
                _LUTProofFailure(
                    :proof_failed,
                    "Stored entry at $(hex_bits(word,IEEE16)) differs from the resolved nearest-even reference",
                ),
            )
            words[Int(word) + 1] = actual
            finite || continue
            y = decode_ieee(actual, IEEE16)
            ref.status != :domain_error && y.kind in (:finite, :zero) || throw(
                _LUTProofFailure(
                    :unsupported_domain,
                    "Finite input $(hex_bits(word,IEEE16)) has no finite mathematical error contract",
                ),
            )
            error = if ref.enclosure === nothing
                ref.status == :special || throw(
                    _LUTProofFailure(
                        :proof_failed,
                        "Finite reference at $(hex_bits(word,IEEE16)) has no error enclosure",
                    ),
                )
                _q(0) # Established exact primitive zero/unit cases.
            else
                lo, hi = ref.enclosure
                lo.kind == hi.kind == :finite || throw(
                    _LUTProofFailure(
                        :proof_failed,
                        "Nonfinite reference enclosure at $(hex_bits(word,IEEE16))",
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
function _lut_settings(config, backend)
    Dict(
        "method" => "binary16_exhaustive_lut",
        "reference_backend" => string(backend),
        "initial_precision" => string(config.initial_precision),
        "max_precision" => string(config.max_precision),
    )
end
function _lut_result(plan, bound, settings)
    maxfinite = decode_ieee(_inf(IEEE16) - 1, IEEE16).value
    path = PathCertificate(
        (-maxfinite, maxfinite),
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
        "All 65536 entries match resolved nearest-even references; finite errors meet the target" :
        "Exhaustive finite-input error enclosure exceeds the target"
    return CertificationResult(plan, status, bound, (path,), nothing, settings, reason)
end

"""
    certified_lut(spec; config=OracleConfig(), backend=:mpfr)

Generate and certify a full binary16 LUT from adaptive nearest-even references.
Every finite input must have a finite result and an error enclosure or an
established exact primitive value. Nonfinite inputs follow the shared policy.
Unresolved references abort generation. Storage is 65536 × 16 bits (128 KiB).
"""
function certified_lut(
    spec::FunctionSpec;
    config::OracleConfig = OracleConfig(),
    backend::Symbol = :mpfr,
)
    settings = _lut_settings(config, backend)
    empty = PlanArtifact(spec)
    try
        _check_lut_spec(spec)
        words, bound = _lut_references(spec, nothing; config, backend)
        return _lut_result(_lut_plan(spec, words), bound, settings)
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

"""Recertify every stored LUT entry and audit the complete raw-index lookup graph."""
function certify_lut(
    plan::PlanArtifact;
    config::OracleConfig = OracleConfig(),
    backend::Symbol = :mpfr,
)
    settings = _lut_settings(config, backend)
    try
        _check_lut_spec(plan.spec)
        p = plan.program
        p !== nothing &&
            length(p.tables) == 1 &&
            isempty(plan.segments) &&
            plan.dispatch === nothing || throw(ArgumentError("unsupported LUT program"))
        table = only(p.tables)
        table.format == IEEE16 || throw(ArgumentError("unsupported LUT storage format"))
        canonical = _lut_plan(plan.spec, collect(table.values))
        _program_data(canonical.program) == _program_data(p) ||
            throw(ArgumentError("executed graph differs from the supported raw-index LUT"))
        _, bound = _lut_references(plan.spec, table.values; config, backend)
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
