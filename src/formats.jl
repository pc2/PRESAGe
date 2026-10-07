"""Binary floating format with IEEE exponent encoding, subnormals and fraction bits M."""
struct FloatFormat
    exponent_bits::Int
    fraction_bits::Int
    function FloatFormat(E::Integer, M::Integer)
        2 <= E <= 8sizeof(Int) - 2 &&
            1 <= M &&
            BigInt(1) + E + M <= typemax(Int) &&
            BigInt(M) + (BigInt(1) << (E - 1)) <= typemax(Int) || throw(
            ArgumentError(
                "require E ≥ 2 and M ≥ 1 with widths and exponents representable as Int",
            ),
        )
        new(Int(E), Int(M))
    end
end

"""Binary fixed format; I includes the sign bit, and W-I is the fractional width."""
struct FixedFormat
    width::Int
    integer_bits::Int
    signed::Bool
    rounding::Symbol
    overflow::Symbol
    function FixedFormat(
        W::Integer,
        I::Integer;
        signed::Bool = true,
        rounding::Symbol = :nearest_even,
        overflow::Symbol = :reject,
    )
        1 <= I <= W || throw(ArgumentError("require 1 ≤ I ≤ W"))
        rounding in (:nearest_even, :toward_zero, :up, :down) ||
            throw(ArgumentError("unsupported rounding"))
        overflow in (:reject, :saturate, :wrap) ||
            throw(ArgumentError("unsupported overflow"))
        new(Int(W), Int(I), signed, rounding, overflow)
    end
end

const IEEE16 = FloatFormat(5, 10)
const IEEE32 = FloatFormat(8, 23)
const IEEE64 = FloatFormat(11, 52)
const IEEE128 = FloatFormat(15, 112)
const IEEE256 = FloatFormat(19, 236)
_width(f::FloatFormat) = 1 + f.exponent_bits + f.fraction_bits
_bias(f::FloatFormat) = (1 << (f.exponent_bits - 1)) - 1
_emin(f::FloatFormat) = 1 - _bias(f)
_emax(f::FloatFormat) = _bias(f)
_float_word(bits, f::FloatFormat) = _width(f) <= 64 ? UInt64(bits) : BigInt(bits)
_word_mask(width::Int) =
    width <= 64 ? typemax(UInt64) >> (64 - width) : (BigInt(1) << width) - 1
_sign(f::FloatFormat) = _float_word(1, f) << (_width(f) - 1)
_inf(f::FloatFormat) = _float_word(_word_mask(f.exponent_bits), f) << f.fraction_bits
_nan(f::FloatFormat) = _inf(f) | (_float_word(1, f) << (f.fraction_bits - 1))
_wordmask(f::FloatFormat) = _word_mask(_width(f))
function hex_bits(bits::Integer, f::FloatFormat)
    0 <= bits <= _wordmask(f) || throw(ArgumentError("bits exceed format width"))
    return "0x" * string(bits; base = 16, pad = cld(_width(f), 4))
end
_q(x::Union{Integer, Rational}) = Rational{BigInt}(x)
_pow2(e::Int) = e >= 0 ? (BigInt(1) << e) // BigInt(1) : BigInt(1) // (BigInt(1) << -e)

struct DecodedFloat
    kind::Symbol
    negative::Bool
    value::Union{Nothing, Rational{BigInt}}
end

"""Decode the bit pattern exactly, keeping signed zero separate from rational zero."""
function decode_ieee(bits::Integer, f::FloatFormat)
    0 <= bits <= _wordmask(f) || throw(ArgumentError("bits exceed format width"))
    word = _float_word(bits, f)
    negative = word & _sign(f) != 0
    fraction = word & _word_mask(f.fraction_bits)
    exponent = (word >> f.fraction_bits) & _word_mask(f.exponent_bits)
    if exponent == (1 << f.exponent_bits) - 1
        return DecodedFloat(fraction == 0 ? :infinity : :nan, negative, nothing)
    elseif exponent == 0 && fraction == 0
        return DecodedFloat(:zero, negative, _q(0))
    end
    mantissa = BigInt(fraction) + (exponent == 0 ? 0 : BigInt(1) << f.fraction_bits)
    power = (exponent == 0 ? _emin(f) : Int(exponent) - _bias(f)) - f.fraction_bits
    value = mantissa * _pow2(power)
    return DecodedFloat(:finite, negative, negative ? -value : value)
end

"""
    normalize_float(bits, format)

Decode a finite nonzero floating word as `abs(x) = m * 2^e`, with `1 ≤ m < 2`.
Return `(mantissa_bits, exponent)`. The mantissa uses the input format and is
exact, including for subnormals and words wider than 64 bits. Zeros, infinities
and NaNs have no such decomposition and throw `DomainError`.
"""
function normalize_float(bits::Integer, f::FloatFormat)
    0 <= bits <= _wordmask(f) || throw(ArgumentError("bits exceed format width"))
    word = _float_word(bits, f)
    fraction = word & _word_mask(f.fraction_bits)
    field = Int((word >> f.fraction_bits) & _word_mask(f.exponent_bits))
    field == (1 << f.exponent_bits) - 1 &&
        throw(DomainError(bits, "normalization requires a finite nonzero input"))
    exponent = field - _bias(f)
    if field == 0
        iszero(fraction) &&
            throw(DomainError(bits, "normalization requires a finite nonzero input"))
        shift = f.fraction_bits - (ndigits(fraction; base = 2) - 1)
        fraction = (fraction << shift) & _word_mask(f.fraction_bits)
        exponent = _emin(f) - shift
    end
    mantissa = (_float_word(_bias(f), f) << f.fraction_bits) | fraction
    return (mantissa, exponent)
end

"""Split an exponent as `e=divisor*q+r`, using floor division and `0≤r<divisor`."""
function split_exponent(exponent::Integer, divisor::Integer = 2)
    divisor >= 1 || throw(ArgumentError("exponent divisor must be positive"))
    return fldmod(exponent, divisor)
end

_root_argument_format(f, divisor) =
    FloatFormat(max(f.exponent_bits, divisor == 3 ? 3 : 2), f.fraction_bits)

function _root_argument(bits, f, divisor = 2)
    divisor in (2, 3) || throw(ArgumentError("root divisor must be 2 or 3"))
    mantissa, exponent = normalize_float(bits, f)
    _, remainder = split_exponent(exponent, divisor)
    out = _root_argument_format(f, divisor)
    fraction = _float_word(mantissa & _word_mask(f.fraction_bits), out)
    return (_float_word(_bias(out) + remainder, out) << out.fraction_bits) | fraction
end

function _increment(
    q::BigInt,
    remainder::BigInt,
    divisor::BigInt,
    mode::Symbol,
    negative::Bool,
)
    mode in (:nearest_even, :toward_zero, :up, :down) ||
        throw(ArgumentError("unsupported rounding"))
    iszero(remainder) && return false
    mode == :nearest_even &&
        return 2remainder > divisor || (2remainder == divisor && isodd(q))
    return (mode == :up && !negative) || (mode == :down && negative)
end

function _overflow(f::FloatFormat, negative::Bool, mode::Symbol)
    infinity =
        mode == :nearest_even || (mode == :up && !negative) || (mode == :down && negative)
    return (negative ? _sign(f) : _float_word(0, f)) | (infinity ? _inf(f) : _inf(f) - 1)
end

function _pack(q::BigInt, quantum::Int, f::FloatFormat, negative::Bool, mode::Symbol)
    sign = negative ? _sign(f) : _float_word(0, f)
    iszero(q) && return sign
    # The only possible carry after rounding increases the binade by one.
    if q >= BigInt(1) << (f.fraction_bits + 1)
        q >>= 1
        quantum += 1
    end
    exponent = quantum + f.fraction_bits
    exponent > _emax(f) && return _overflow(f, negative, mode)
    if q < BigInt(1) << f.fraction_bits
        return sign | _float_word(q, f) # Subnormal, including rounding up from underflow.
    end
    return sign |
           (_float_word(exponent + _bias(f), f) << f.fraction_bits) |
           _float_word(q - (BigInt(1) << f.fraction_bits), f)
end

"""Round a rational directly to encoded IEEE bits, without an intermediate float."""
function round_ieee(
    value::Union{Integer, Rational},
    f::FloatFormat;
    mode::Symbol = :nearest_even,
    zero_sign::Bool = false,
)
    mode in (:nearest_even, :toward_zero, :up, :down) ||
        throw(ArgumentError("unsupported rounding"))
    v = _q(value)
    negative = v < 0 || (iszero(v) && zero_sign)
    iszero(v) && return negative ? _sign(f) : _float_word(0, f)
    n, d = abs(numerator(v)), denominator(v)
    e = ndigits(n; base = 2) - ndigits(d; base = 2)
    (e >= 0 ? n < d << e : n << -e < d) && (e -= 1)
    e > _emax(f) && return _overflow(f, negative, mode)
    quantum = max(_emin(f) - f.fraction_bits, e - f.fraction_bits)
    quantum >= 0 ? (d <<= quantum) : (n <<= -quantum)
    q, r = divrem(n, d)
    _increment(q, r, d, mode, negative) && (q += 1)
    return _pack(q, quantum, f, negative, mode)
end

"""
Round m*2^e exactly. Very large exponents do not allocate huge powers of two;
this is also the reference endpoint rounder for native MPFR/Sollya bounds.
"""
function round_dyadic(
    m::Integer,
    e::Integer,
    f::FloatFormat;
    mode::Symbol = :nearest_even,
    zero_sign::Bool = false,
)
    mode in (:nearest_even, :toward_zero, :up, :down) ||
        throw(ArgumentError("unsupported rounding"))
    negative = m < 0 || (iszero(m) && zero_sign)
    iszero(m) && return negative ? _sign(f) : _float_word(0, f)
    n = abs(BigInt(m))
    bits = ndigits(n; base = 2)
    binade = BigInt(e) + bits - 1
    binade > _emax(f) && return _overflow(f, negative, mode)
    quantum = Int(max(_emin(f) - f.fraction_bits, binade - f.fraction_bits))
    shift = BigInt(e) - quantum
    if shift >= 0
        q = n << Int(shift) # Bounded by the output significand width.
    elseif -shift > bits
        q = BigInt((mode == :up && !negative) || (mode == :down && negative))
    else
        divisor = BigInt(1) << Int(-shift)
        q, r = divrem(n, divisor)
        _increment(q, r, divisor, mode, negative) && (q += 1)
    end
    return _pack(q, quantum, f, negative, mode)
end
