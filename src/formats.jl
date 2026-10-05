"""Binary floating format with IEEE exponent encoding, subnormals and fraction bits M."""
struct FloatFormat
    exponent_bits::Int
    fraction_bits::Int
    function FloatFormat(E::Integer, M::Integer)
        2 <= E <= 11 && 1 <= M <= 52 && 1 + E + M <= 64 ||
            throw(ArgumentError("require 2 ≤ E ≤ 11, 1 ≤ M ≤ 52 and total width ≤ 64"))
        new(Int(E), Int(M))
    end
end

"""Fixed format metadata; I includes the sign bit. Arithmetic operations are not yet provided."""
struct FixedFormat
    width::Int
    integer_bits::Int
    signed::Bool
    rounding::Symbol
    overflow::Symbol
    function FixedFormat(W::Integer, I::Integer; signed::Bool=true,
                         rounding::Symbol=:nearest_even, overflow::Symbol=:reject)
        1 <= I <= W || throw(ArgumentError("require 1 ≤ I ≤ W"))
        rounding in (:nearest_even, :toward_zero, :up, :down) ||
            throw(ArgumentError("unsupported rounding"))
        overflow in (:reject, :saturate, :wrap) || throw(ArgumentError("unsupported overflow"))
        new(Int(W), Int(I), signed, rounding, overflow)
    end
end

const IEEE16 = FloatFormat(5, 10)
const IEEE32 = FloatFormat(8, 23)
const IEEE64 = FloatFormat(11, 52)
_width(f::FloatFormat) = 1 + f.exponent_bits + f.fraction_bits
_bias(f::FloatFormat) = (1 << (f.exponent_bits - 1)) - 1
_emin(f::FloatFormat) = 1 - _bias(f)
_emax(f::FloatFormat) = _bias(f)
_sign(f::FloatFormat) = UInt64(1) << (_width(f) - 1)
_inf(f::FloatFormat) = ((UInt64(1) << f.exponent_bits) - 1) << f.fraction_bits
_nan(f::FloatFormat) = _inf(f) | (UInt64(1) << (f.fraction_bits - 1))
_wordmask(f::FloatFormat) = typemax(UInt64) >> (64 - _width(f))
hex_bits(bits::Integer, f::FloatFormat) = "0x" * string(UInt64(bits); base=16, pad=cld(_width(f), 4))
_q(x::Union{Integer,Rational}) = Rational{BigInt}(x)
_pow2(e::Int) = e >= 0 ? (BigInt(1) << e) // BigInt(1) : BigInt(1) // (BigInt(1) << -e)

struct DecodedFloat
    kind::Symbol
    negative::Bool
    value::Union{Nothing,Rational{BigInt}}
end

"""Decode the bit pattern exactly, keeping signed zero separate from rational zero."""
function decode_ieee(bits::Integer, f::FloatFormat)
    0 <= bits <= _wordmask(f) || throw(ArgumentError("bits exceed format width"))
    word = UInt64(bits)
    negative = word & _sign(f) != 0
    fraction = word & ((UInt64(1) << f.fraction_bits) - 1)
    exponent = (word >> f.fraction_bits) & ((UInt64(1) << f.exponent_bits) - 1)
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

function _increment(q::BigInt, remainder::BigInt, divisor::BigInt, mode::Symbol, negative::Bool)
    mode in (:nearest_even, :toward_zero, :up, :down) || throw(ArgumentError("unsupported rounding"))
    iszero(remainder) && return false
    mode == :nearest_even && return 2remainder > divisor || (2remainder == divisor && isodd(q))
    return (mode == :up && !negative) || (mode == :down && negative)
end

function _overflow(f::FloatFormat, negative::Bool, mode::Symbol)
    infinity = mode == :nearest_even || (mode == :up && !negative) || (mode == :down && negative)
    return (negative ? _sign(f) : UInt64(0)) | (infinity ? _inf(f) : _inf(f) - 1)
end

function _pack(q::BigInt, quantum::Int, f::FloatFormat, negative::Bool, mode::Symbol)
    sign = negative ? _sign(f) : UInt64(0)
    iszero(q) && return sign
    # The only possible carry after rounding increases the binade by one.
    if q >= BigInt(1) << (f.fraction_bits + 1)
        q >>= 1
        quantum += 1
    end
    exponent = quantum + f.fraction_bits
    exponent > _emax(f) && return _overflow(f, negative, mode)
    if q < BigInt(1) << f.fraction_bits
        return sign | UInt64(q) # Subnormal, including rounding up from underflow.
    end
    return sign | (UInt64(exponent + _bias(f)) << f.fraction_bits) |
           UInt64(q - (BigInt(1) << f.fraction_bits))
end

"""Round a rational directly to encoded IEEE bits, without an intermediate float."""
function round_ieee(value::Union{Integer,Rational}, f::FloatFormat;
                    mode::Symbol=:nearest_even, zero_sign::Bool=false)
    mode in (:nearest_even, :toward_zero, :up, :down) || throw(ArgumentError("unsupported rounding"))
    v = _q(value)
    negative = v < 0 || (iszero(v) && zero_sign)
    iszero(v) && return negative ? _sign(f) : UInt64(0)
    n, d = abs(numerator(v)), denominator(v)
    e = ndigits(n; base=2) - ndigits(d; base=2)
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
function round_dyadic(m::Integer, e::Integer, f::FloatFormat;
                      mode::Symbol=:nearest_even, zero_sign::Bool=false)
    mode in (:nearest_even, :toward_zero, :up, :down) || throw(ArgumentError("unsupported rounding"))
    negative = m < 0 || (iszero(m) && zero_sign)
    iszero(m) && return negative ? _sign(f) : UInt64(0)
    n = abs(BigInt(m))
    bits = ndigits(n; base=2)
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
