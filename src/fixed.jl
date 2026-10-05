_fraction(f::FixedFormat) = f.width-f.integer_bits
_fixed_mask(f::FixedFormat) = (BigInt(1)<<f.width)-1
function _fixed_limits(f::FixedFormat)
    f.signed && return (-(BigInt(1)<<(f.width-1)),(BigInt(1)<<(f.width-1))-1)
    return (BigInt(0),_fixed_mask(f))
end
function _fixed_units(bits::Integer,f::FixedFormat)
    0 <= bits <= _fixed_mask(f) || throw(ArgumentError("bits exceed fixed format width"))
    word = BigInt(bits)
    return f.signed && word >= BigInt(1)<<(f.width-1) ? word-(BigInt(1)<<f.width) : word
end
"""Decode a two's-complement (or unsigned) fixed word to an exact rational."""
decode_fixed(bits::Integer,f::FixedFormat) = _fixed_units(bits,f)*_pow2(-_fraction(f))
function _fixed_pack(units::Integer,f::FixedFormat)
    lo,hi = _fixed_limits(f)
    q = BigInt(units)
    if !(lo <= q <= hi)
        f.overflow == :reject && throw(OverflowError("fixed result exceeds declared format"))
        f.overflow == :saturate && (q = clamp(q,lo,hi))
    end
    return mod(q,BigInt(1)<<f.width)
end
function _rounded_integer(q::Rational{BigInt},mode::Symbol)
    n,d = abs(numerator(q)),denominator(q)
    v,r = divrem(n,d)
    _increment(v,r,d,mode,q<0) && (v+=1)
    return q < 0 ? -v : v
end
"""Round directly into a fixed word, with explicit tie and overflow semantics."""
function round_fixed(value::Union{Integer,Rational},f::FixedFormat;mode::Symbol=f.rounding)
    return _fixed_pack(_rounded_integer(_q(value)*_pow2(_fraction(f)),mode),f)
end
function _round_fixed_dyadic(m::Integer,e::Integer,f::FixedFormat,mode::Symbol)
    mode in (:nearest_even,:toward_zero,:up,:down) || throw(ArgumentError("unsupported rounding"))
    n = abs(BigInt(m))
    iszero(n) && return BigInt(0)
    shift = BigInt(e)+_fraction(f)
    if shift >= 0 && shift+ndigits(n;base=2) > f.width
        f.overflow == :reject && throw(OverflowError("fixed result exceeds declared format"))
        if f.overflow == :saturate
            lo,hi = _fixed_limits(f)
            return _fixed_pack(m < 0 ? lo : hi,f)
        elseif shift >= f.width
            return BigInt(0)
        end
        n &= _fixed_mask(f)
    end
    q = if shift >= 0
        n << Int(shift)
    elseif -shift > ndigits(n;base=2)
        BigInt((mode == :up && m>0) || (mode == :down && m<0))
    else
        d = BigInt(1)<<Int(-shift)
        v,r = divrem(n,d)
        _increment(v,r,d,mode,m<0) && (v+=1)
        v
    end
    return _fixed_pack(m < 0 ? -q : q,f)
end
hex_bits(bits::Integer,f::FixedFormat) = "0x"*string(BigInt(bits);base=16,pad=cld(f.width,4))
