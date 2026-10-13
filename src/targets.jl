"""Emitter capabilities for a vendor toolchain, independent of resource costs."""
struct TargetProfile
    toolchain::Symbol
    backend::Symbol
    function TargetProfile(
        toolchain::Symbol;
        backend = toolchain == :vitis ? :ap_fixed : :ac_fixed,
    )
        toolchain in (:generic, :vitis, :oneapi) ||
            throw(ArgumentError("unknown target toolchain $toolchain"))
        backend in (:ap_fixed, :ac_fixed) || throw(ArgumentError("unknown target backend"))
        toolchain == :generic ||
            backend == (toolchain == :vitis ? :ap_fixed : :ac_fixed) ||
            throw(ArgumentError("target backend does not match toolchain"))
        new(toolchain, backend)
    end
end

const _INTEL_FLOAT_FORMATS = (
    (5, 10),
    (8, 7),
    (8, 10),
    (8, 17),
    (8, 23),
    (8, 26),
    (10, 35),
    (11, 44),
    (11, 52),
    (15, 63),
)

function _target_float_reason(target, format, operation, rounding = :nearest_even)
    rounding == :nearest_even || return "floating arithmetic requires nearest_even"
    format.exponent_bits <= 30 ||
        return "floating arithmetic exponent fields must fit 30 bits"
    2BigInt(format.fraction_bits + 1) + 12 <= _VENDOR_WIDTH_LIMIT ||
        return "floating arithmetic work widths exceed the 4096-bit limit"
    target.backend == :ap_fixed &&
        operation == :reciprocal &&
        return "floating reciprocal requires ac_fixed"
    if target.toolchain == :oneapi && operation != :fma
        (format.exponent_bits, format.fraction_bits) in _INTEL_FLOAT_FORMATS ||
            return "Intel ap_float does not support exponent_bits=$(format.exponent_bits), fraction_bits=$(format.fraction_bits)"
    end
    return nothing
end

"""Check the complete lowered evaluator against emitter and vendor constraints."""
function target_support(p::IR.Program, target::TargetProfile)
    try
        _kernel_validate(p, target.backend, target.toolchain)
        foreach(i -> _kernel_expr(p, i, target.backend), eachindex(p.nodes))
        return (supported = true, reasons = ())
    catch error
        error isa ArgumentError || rethrow()
        return (supported = false, reasons = (sprint(showerror, error),))
    end
end
function target_support(plan::PlanArtifact, target::TargetProfile)
    plan.program === nothing && throw(ArgumentError("plan has no evaluator"))
    return target_support(plan.program, target)
end

function _target_candidate_reason(request, target)
    target === nothing && return nothing
    get(request, :implementation, :polynomial) == :lut && return nothing
    degree = _coefficient_degree(request.degree, request.config.transformation)
    degree == 0 && return nothing
    format = request.internal_format
    format isa FloatFormat || return nothing
    operation = request.config.evaluation == :fma ? :fma : :mul
    precision = request.precision
    formats = precision === nothing ? (format,) : precision.stage_formats[1:degree]
    for f in formats
        reason = _target_float_reason(target, f, operation)
        reason === nothing || return reason
    end
    return nothing
end
