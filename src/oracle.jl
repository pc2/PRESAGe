"""Adaptive enclosure settings; exhausting max_precision returns :unresolved."""
struct OracleConfig
    initial_precision::Int
    max_precision::Int
    growth::Int
    function OracleConfig(;
        initial_precision::Integer = 256,
        max_precision::Integer = 4096,
        growth::Integer = 2,
    )
        12 <= initial_precision <= max_precision <= typemax(Cint) || throw(
            ArgumentError("require 12 ≤ initial_precision ≤ max_precision ≤ Cint maximum"),
        )
        growth >= 2 || throw(ArgumentError("precision growth must be at least two"))
        new(Int(initial_precision), Int(max_precision), Int(growth))
    end
end

"""Exact native endpoint m*2^e; avoids allocating a huge rational at extreme exponents."""
struct DyadicBound
    significand::BigInt
    exponent::Int
    kind::Symbol
    negative::Bool
end
DyadicBound(m::Integer, e::Integer; negative::Bool = m < 0) =
    DyadicBound(BigInt(m), Int(e), :finite, negative)
_infinite_bound(negative) = DyadicBound(BigInt(0), 0, :infinity, negative)
function _round_bound(b::DyadicBound, f::FloatFormat)
    b.kind == :infinity && return _inf(f) | (b.negative ? _sign(f) : UInt64(0))
    return round_dyadic(b.significand, b.exponent, f; zero_sign = b.negative)
end
function _round_bound(b::DyadicBound, f::FixedFormat)
    b.kind == :finite || throw(DomainError(b, "fixed output requires a finite result"))
    return _round_fixed_dyadic(b.significand, b.exponent, f, f.rounding)
end

"""
Reference result. :resolved/:special have output bits. :domain_error has NaN bits
only for floating output. :overflow/:nonfinite_output/:unresolved/:outside_domain
and :evaluation_failed have no bits. Enclosures are exact binary
endpoints, not rounded display decimals. Precision zero means no numerical
enclosure was needed or obtained.
"""
struct ReferenceResult
    status::Symbol
    bits::Union{Nothing, UInt64, BigInt}
    enclosure::Union{Nothing, Tuple{DyadicBound, DyadicBound}}
    precision::Int
    backend::Symbol
    detail::String
end
_result(status, bits, backend, detail = "") =
    ReferenceResult(status, bits, nothing, 0, backend, detail)

const _MPFR_PRIMITIVES = (
    :erf,
    :erfc,
    :exp,
    :expm1,
    :log,
    :log1p,
    :log2,
    :log10,
    :sqrt,
    :sin,
    :cos,
    :tan,
    :asin,
    :acos,
    :atan,
    :sinh,
    :cosh,
    :tanh,
    :asinh,
    :acosh,
    :atanh,
    :recip,
    :rsqrt,
    :cbrt,
)
const _ODD_ZERO = (
    :erf,
    :expm1,
    :sin,
    :tan,
    :asin,
    :atan,
    :sinh,
    :tanh,
    :asinh,
    :atanh,
    :log1p,
    :sqrt,
    :cbrt,
)
function _primitive(expression::String)
    text = replace(expression, r"\s+" => "")
    text == "1/x" && return :recip
    text == "1/sqrt(x)" && return :rsqrt
    for name in _MPFR_PRIMITIVES
        text == "$name(x)" && return name
    end
    return nothing
end

# Sollya decimal literals are rounded during parsing. Replace decimal/scientific
# numbers by exact rationals before parsing, leaving names and binary/hex tokens
# intact. The saved FunctionSpec retains the user's mathematical expression.
function _exact_expression(text::String)
    tokens =
        r"0[xX][0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?(?:[pP][+-]?\d+)?|[A-Za-z_][A-Za-z_0-9]*|(?:\d+\.\d*|\.\d+|\d+)(?:[eEbB][+-]?\d+)?"
    return replace(
        text,
        tokens => function (token)
            startswith(lowercase(token), "0x") && return token
            isletter(first(token)) || first(token) == '_' ? (return token) : nothing
            occursin(r"[bB]", token) && return token
            occursin(r"[.eE]", token) || return token
            parts = split(lowercase(token), 'e')
            power = length(parts) == 2 ? parse(Int, parts[2]) : 0
            abs(power) <= 16384 ||
                throw(ArgumentError("decimal exponent exceeds supported literal size"))
            decimal = split(parts[1], '.'; keepempty = true)
            fraction = length(decimal) == 2 ? decimal[2] : ""
            digits = decimal[1] * fraction
            n = parse(BigInt, digits)
            power -= length(fraction)
            q =
                power >= 0 ? (n * BigInt(10)^power) // BigInt(1) : n // BigInt(10)^(-power)
            return "($(numerator(q))/$(denominator(q)))"
        end,
    )
end

"""Compiled process-local oracle; close it to release its Sollya expression."""
mutable struct ReferenceOracle
    spec::FunctionSpec
    config::OracleConfig
    backend::Symbol
    primitive::Union{Nothing, Symbol}
    expression::Union{Nothing, Sollya.SollyaObject}
    polynomial::Bool
    opened::Bool
    native_handle::Ptr{Cvoid}
    native_function::Ptr{Cvoid}
end

function ReferenceOracle(
    spec::FunctionSpec;
    config::OracleConfig = OracleConfig(),
    backend::Symbol = :sollya,
)
    backend in (:sollya, :mpfr) || throw(ArgumentError("backend must be :sollya or :mpfr"))
    config.max_precision >= _input_precision(spec.input_format) ||
        throw(ArgumentError("max precision cannot exactly represent the input significand"))
    primitive = _primitive(spec.expression)
    backend == :mpfr &&
        primitive === nothing &&
        throw(
            ArgumentError(
                "direct MPFR backend supports primitives only; use Sollya for compositions",
            ),
        )
    expr, polynomial = nothing, false
    if backend == :sollya
        expr =
            Sollya.with_session(Sollya.Session(; precision = config.initial_precision)) do
                Sollya.sollya(_exact_expression(spec.expression))
            end
        try
            Sollya.isfunction(expr) ||
                throw(ArgumentError("expression must be a mathematical function"))
            try
                Sollya.degree(expr)
                polynomial = true
            catch error
                error isa Sollya.SollyaError || rethrow()
            end
        catch
            close(expr)
            rethrow()
        end
    end
    handle, fn = Ptr{Cvoid}(C_NULL), Ptr{Cvoid}(C_NULL)
    if backend == :mpfr && primitive != :recip
        handle = Libdl.dlopen(Base.MPFR.libmpfr)
        name = primitive == :rsqrt ? :mpfr_rec_sqrt : Symbol(:mpfr_, primitive)
        try
            fn = Libdl.dlsym(handle, name)
        catch
            Libdl.dlclose(handle)
            rethrow()
        end
    end
    return ReferenceOracle(
        spec,
        config,
        backend,
        primitive,
        expr,
        polynomial,
        true,
        handle,
        fn,
    )
end
function Base.close(o::ReferenceOracle)
    o.expression === nothing || close(o.expression)
    if o.native_handle != C_NULL
        Libdl.dlclose(o.native_handle)
        o.native_handle = C_NULL
        o.native_function = C_NULL
    end
    o.opened = false
    return nothing
end
Base.isopen(o::ReferenceOracle) = o.opened
function with_oracle(f::F, spec::FunctionSpec; kwargs...) where {F}
    o = ReferenceOracle(spec; kwargs...)
    try
        return f(o)
    finally
        close(o)
    end
end

function _exceptional(o::ReferenceOracle, x::DecodedFloat)
    s, p, b = o.spec, o.primitive, o.backend
    f = s.output_format
    f isa FixedFormat && return _exceptional_fixed(o, x)
    sign = x.negative ? _sign(f) : UInt64(0)
    x.kind == :nan && return _result(:special, _nan(f), b, "canonical quiet NaN")
    if x.kind == :infinity
        if p == :erf || p == :tanh
            return _result(:special, round_ieee(x.negative ? -1 : 1, f), b)
        elseif p == :erfc
            return _result(:special, round_ieee(x.negative ? 2 : 0, f), b)
        elseif p == :exp
            return _result(:special, x.negative ? UInt64(0) : _inf(f), b)
        elseif p == :expm1
            return _result(:special, x.negative ? round_ieee(-1, f) : _inf(f), b)
        elseif p == :recip
            return _result(:special, sign, b)
        elseif p in (:sinh, :asinh, :cbrt)
            return _result(:special, _inf(f) | sign, b)
        elseif p == :cosh
            return _result(:special, _inf(f), b)
        elseif p in (:log, :log1p, :log2, :log10, :sqrt, :acosh, :rsqrt)
            x.negative &&
                return _result(:domain_error, _nan(f), b, "invalid primitive argument")
            return _result(:special, p == :rsqrt ? UInt64(0) : _inf(f), b)
        elseif p in (:sin, :cos, :tan, :asin, :acos, :atanh)
            return _result(:domain_error, _nan(f), b, "invalid infinite argument")
        end
        return _result(:unresolved, nothing, b, "no established infinite-input identity")
    end
    q = x.value
    if s.domain !== nothing && !(s.domain[1] <= q <= s.domain[2])
        return _result(:outside_domain, nothing, b, "input outside declared domain")
    end
    invalid =
        (p in (:log, :log2, :log10, :sqrt, :rsqrt) && q < 0) ||
        (p == :log1p && q < -1) ||
        (p in (:asin, :acos, :atanh) && abs(q) > 1) ||
        (p == :acosh && q < 1)
    invalid && return _result(:domain_error, _nan(f), b, "invalid primitive argument")
    if iszero(q)
        if p in _ODD_ZERO
            return _result(:special, sign, b, "exact zero")
        elseif p in (:exp, :erfc, :cos, :cosh)
            return _result(:special, round_ieee(1, f), b, "exact unit value")
        elseif p in (:log, :log2, :log10)
            return _result(:special, _inf(f) | _sign(f), b, "logarithmic pole")
        elseif p in (:recip, :rsqrt)
            return _result(:special, _inf(f) | sign, b, "reciprocal pole")
        end
    end
    p == :log1p &&
        q == -1 &&
        return _result(:special, _inf(f) | _sign(f), b, "logarithmic pole")
    p == :atanh &&
        abs(q) == 1 &&
        return _result(:special, _inf(f) | sign, b, "hyperbolic pole")
    return nothing
end

function _fixed_exact_result(status, q, o, detail = "")
    try
        return _result(status, round_fixed(q, o.spec.output_format), o.backend, detail)
    catch error
        error isa OverflowError || rethrow()
        return _result(
            :overflow,
            nothing,
            o.backend,
            "rounded result exceeds fixed output range",
        )
    end
end

function _exceptional_fixed(o, x)
    p, b, f = o.primitive, o.backend, o.spec.output_format
    x.kind == :nan &&
        return _result(:nonfinite_output, nothing, b, "fixed output cannot encode NaN")
    if x.kind == :infinity
        q = if p in (:erf, :tanh)
            x.negative ? -1 : 1
        elseif p == :erfc
            x.negative ? 2 : 0
        elseif p == :exp && x.negative
            0
        elseif p == :expm1 && x.negative
            -1
        elseif p == :recip || p == :rsqrt && !x.negative
            0
        else
            nothing
        end
        q === nothing || return _fixed_exact_result(:special, q, o)
        invalid =
            p in (:sin, :cos, :tan, :asin, :acos, :atanh) ||
            x.negative && p in (:log, :log1p, :log2, :log10, :sqrt, :acosh, :rsqrt)
        invalid && return _result(:domain_error, nothing, b, "invalid infinite argument")
        p in (
            :exp,
            :expm1,
            :sinh,
            :cosh,
            :asinh,
            :cbrt,
            :log,
            :log1p,
            :log2,
            :log10,
            :sqrt,
            :acosh,
        ) && return _result(
            :nonfinite_output,
            nothing,
            b,
            "fixed output cannot encode infinity",
        )
        return _result(:unresolved, nothing, b, "no established infinite-input identity")
    end
    q = x.value
    s = o.spec
    s.domain !== nothing &&
        !(s.domain[1] <= q <= s.domain[2]) &&
        return _result(:outside_domain, nothing, b, "input outside declared domain")
    invalid =
        (p in (:log, :log2, :log10, :sqrt, :rsqrt) && q < 0) ||
        (p == :log1p && q < -1) ||
        (p in (:asin, :acos, :atanh) && abs(q) > 1) ||
        (p == :acosh && q < 1)
    invalid && return _result(:domain_error, nothing, b, "invalid primitive argument")
    if iszero(q)
        p in _ODD_ZERO && return _fixed_exact_result(:special, 0, o, "exact zero")
        p in (:exp, :erfc, :cos, :cosh) &&
            return _fixed_exact_result(:special, 1, o, "exact unit value")
        p in (:log, :log2, :log10, :recip, :rsqrt) && return _result(
            :nonfinite_output,
            nothing,
            b,
            "fixed output cannot encode a pole",
        )
    end
    (p == :log1p && q == -1 || p == :atanh && abs(q) == 1) &&
        return _result(:nonfinite_output, nothing, b, "fixed output cannot encode a pole")
    return nothing
end

function _sollya_bound(obj::Sollya.SollyaObject)
    text = strip(Sollya.expression(obj; display = :dyadic))
    text in ("infty", "-infty") && return _infinite_bound(startswith(text, '-'))
    matchvalue = match(r"^(-?\d+)(?:b([+-]?\d+))?$", text)
    matchvalue === nothing &&
        throw(Sollya.SollyaError(:reference, "non-dyadic endpoint: $text"))
    m = parse(BigInt, matchvalue[1])
    e = matchvalue[2] === nothing ? 0 : parse(Int, matchvalue[2])
    return DyadicBound(m, e; negative = startswith(text, '-'))
end

function _sollya_bounds(o::ReferenceOracle, x::Rational{BigInt}, precision::Int)
    Sollya.with_session(Sollya.Session(; precision)) do
        range = Sollya.enclosure(o.expression, x)
        try
            lo = Sollya.infimum(range)
            try
                hi = Sollya.supremum(range)
                try
                    return (_sollya_bound(lo), _sollya_bound(hi))
                finally
                    close(hi)
                end
            finally
                close(lo)
            end
        finally
            close(range)
        end
    end
end

function _mpfr_bound(value::BigFloat)
    isnan(value) &&
        throw(ArgumentError("MPFR returned NaN for a validated finite argument"))
    isinf(value) && return _infinite_bound(signbit(value))
    m = BigInt()
    e = ccall(
        (:mpfr_get_z_2exp, Base.MPFR.libmpfr),
        Clong,
        (Ref{BigInt}, Ref{BigFloat}),
        m,
        value,
    )
    return DyadicBound(m, e; negative = signbit(value))
end

# These objects and calls use Julia's own GMP/MPFR ABI. Never pass them to
# Sollya's separately loaded GMP/MPFR. No global rounding or precision is changed.
function _mpfr_bounds(o::ReferenceOracle, x::Rational{BigInt}, precision::Int)
    input = BigFloat(x; precision) # Float/fixed input is dyadic, exact at this precision.
    lo, hi = BigFloat(0; precision), BigFloat(0; precision)
    if o.primitive == :recip
        ccall(
            (:mpfr_ui_div, Base.MPFR.libmpfr),
            Cint,
            (Ref{BigFloat}, Culong, Ref{BigFloat}, Cint),
            lo,
            1,
            input,
            3,
        )
        ccall(
            (:mpfr_ui_div, Base.MPFR.libmpfr),
            Cint,
            (Ref{BigFloat}, Culong, Ref{BigFloat}, Cint),
            hi,
            1,
            input,
            2,
        )
    else
        fn = o.native_function
        ccall(fn, Cint, (Ref{BigFloat}, Ref{BigFloat}, Cint), lo, input, 3)
        ccall(fn, Cint, (Ref{BigFloat}, Ref{BigFloat}, Cint), hi, input, 2)
    end
    return (_mpfr_bound(lo), _mpfr_bound(hi))
end

function _enclosure_round(enclosure, f::FloatFormat, config)
    lo, hi = _round_bound(enclosure[1], f), _round_bound(enclosure[2], f)
    return lo == hi ? (:resolved, lo) : (:unresolved, nothing)
end
function _fixed_bound_units(b, f, limit)
    b.kind == :finite || return nothing
    shift = BigInt(b.exponent) + _fraction(f)
    n = abs(b.significand)
    iszero(n) && return BigInt(0)
    shift >= 0 && shift + ndigits(n; base = 2) > limit && return nothing
    if shift >= 0
        value = n << Int(shift)
    elseif -shift > ndigits(n; base = 2)
        value = BigInt(
            (f.rounding == :up && b.significand > 0) ||
            (f.rounding == :down && b.significand < 0),
        )
    else
        divisor = BigInt(1) << Int(-shift)
        value, remainder = divrem(n, divisor)
        _increment(value, remainder, divisor, f.rounding, b.significand < 0) && (value += 1)
    end
    return b.significand < 0 ? -value : value
end
function _enclosure_round(enclosure, f::FixedFormat, config)
    a, b = enclosure
    if a.kind == b.kind == :finite &&
       a.significand == b.significand &&
       a.exponent == b.exponent
        try
            return (:resolved, _round_bound(a, f))
        catch error
            error isa OverflowError || rethrow()
            return (:overflow, nothing)
        end
    end
    # Wrap is periodic. Agreement of wrapped endpoints alone is insufficient;
    # prove equality of the unbounded quantized integers before applying wrap.
    limit = max(config.max_precision, f.width) + 2
    lo, hi = _fixed_bound_units(a, f, limit), _fixed_bound_units(b, f, limit)
    lower, upper = _fixed_limits(f)
    if lo !== nothing && hi !== nothing
        if f.overflow == :reject && (hi < lower || lo > upper)
            return (:overflow, nothing)
        end
        f.overflow == :saturate &&
            ((lo, hi) = (clamp(lo, lower, upper), clamp(hi, lower, upper)))
        if lo == hi
            try
                return (:resolved, _fixed_pack(lo, f))
            catch error
                error isa OverflowError || rethrow()
                return (:overflow, nothing)
            end
        end
    elseif f.overflow != :wrap
        # Reject/saturate are monotone even at enormous exponents. Round each
        # bound with a reject format to classify the side without huge shifts.
        strict =
            FixedFormat(f.width, f.integer_bits; signed = f.signed, rounding = f.rounding)
        side(x) =
            if x.kind != :finite
                :unknown
            else
                try
                    _round_bound(x, strict)
                    :inside
                catch error
                    error isa OverflowError || rethrow()
                    x.significand < 0 ? :below : :above
                end
            end
        sa, sb = side(a), side(b)
        if sa == :above || sb == :below
            direction = sa == :above ? :above : :below
            return f.overflow == :reject ? (:overflow, nothing) :
                   (:resolved, _fixed_pack(direction == :below ? lower : upper, f))
        end
    end
    return (:unresolved, nothing)
end

function _adaptive(
    bounds_at,
    f::Union{FloatFormat, FixedFormat},
    config::OracleConfig,
    start::Int,
    backend::Symbol,
)
    p = start
    while true
        enclosure = try
            bounds_at(p)
        catch error
            error isa Sollya.SollyaError || rethrow()
            return ReferenceResult(
                :evaluation_failed,
                nothing,
                nothing,
                p,
                backend,
                sprint(showerror, error),
            )
        end
        status, bits = _enclosure_round(enclosure, f, config)
        status != :unresolved && return ReferenceResult(
            status,
            bits,
            enclosure,
            p,
            backend,
            status == :resolved ? "enclosure endpoints agree" :
            "rounded result exceeds fixed output range",
        )
        p == config.max_precision && return ReferenceResult(
            :unresolved,
            nothing,
            enclosure,
            p,
            backend,
            "precision limit; endpoints round differently",
        )
        p = Int(min(BigInt(config.max_precision), BigInt(p) * config.growth))
    end
end

"""Resolve exact input bits using adaptive enclosures, never by low precision point evaluation."""
function reference(o::ReferenceOracle, bits::Integer)
    isopen(o) || throw(ArgumentError("oracle is closed"))
    x = _decode_input(bits, o.spec.input_format)
    special = _exceptional(o, x)
    special === nothing || return special
    start = max(o.config.initial_precision, _input_precision(o.spec.input_format))
    try
        if o.backend == :sollya && o.polynomial
            # Exact polynomial evaluation handles rational zero and midpoint ties.
            # Non-polynomial identities need explicit proofs, not heuristic equality.
            exact = Sollya.substitute(o.expression, x.value)
            try
                q = try
                    Sollya.exact_rational(exact)
                catch error
                    # Degree alone permits irrational coefficients/constants.
                    # Failure to prove rationality is not an evaluation failure.
                    error isa Sollya.SollyaError && error.operation == :exact_rational || rethrow()
                    nothing
                end
                if q !== nothing
                    return o.spec.output_format isa FixedFormat ?
                           _fixed_exact_result(:resolved, q, o, "exact rational value") :
                           _result(
                        :resolved,
                        round_ieee(q, o.spec.output_format),
                        o.backend,
                        "exact rational value",
                    )
                end
            finally
                close(exact)
            end
        end
        bounds_at =
            o.backend == :sollya ? p -> _sollya_bounds(o, x.value, p) :
            p -> _mpfr_bounds(o, x.value, p)
        return _adaptive(bounds_at, o.spec.output_format, o.config, start, o.backend)
    catch error
        error isa Sollya.SollyaError || rethrow()
        return _result(:evaluation_failed, nothing, o.backend, sprint(showerror, error))
    end
end

reference(spec::FunctionSpec, bits::Integer; kwargs...) =
    with_oracle(spec; kwargs...) do oracle
        reference(oracle, bits)
    end
