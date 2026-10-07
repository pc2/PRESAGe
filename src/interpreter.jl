struct _FloatValue
    format::FloatFormat
    bits::Union{UInt64, BigInt}
end
struct _FixedValue
    format::FixedFormat
    bits::BigInt
end
_fixed(bits, f) = _FixedValue(f, BigInt(bits))
_value(v::_FixedValue) = decode_fixed(v.bits, v.format)
_stored(bits, f) = f isa FixedFormat ? _fixed(bits, f) : _float(bits, f)
_add(a::_FixedValue, b::_FixedValue, f::FixedFormat, mode) =
    _fixed(round_fixed(_value(a) + _value(b), f; mode), f)
_mul(a::_FixedValue, b::_FixedValue, f::FixedFormat, mode) =
    _fixed(round_fixed(_value(a) * _value(b), f; mode), f)
_fma(a::_FixedValue, b::_FixedValue, c::_FixedValue, f::FixedFormat, mode) =
    _fixed(round_fixed(_value(a) * _value(b) + _value(c), f; mode), f)
function _convert(v::_FloatValue, f::FixedFormat, mode)
    x = decode_ieee(v.bits, v.format)
    x.kind in (:zero, :finite) ||
        throw(DomainError(v.bits, "fixed conversion requires a finite value"))
    return _fixed(round_fixed(x.value, f; mode), f)
end
_convert(v::_FixedValue, f::FixedFormat, mode) = _fixed(round_fixed(_value(v), f; mode), f)
_convert(v::_FixedValue, f::FloatFormat, mode) = _float(round_ieee(_value(v), f; mode), f)
_scale(v::_FixedValue, e, f::FixedFormat, mode) = _fixed(
    _round_fixed_dyadic(
        _fixed_units(v.bits, v.format),
        BigInt(e) - _fraction(v.format),
        f,
        mode,
    ),
    f,
)
_scale(v::_FixedValue, e, f::FloatFormat, mode) = _float(
    round_dyadic(_fixed_units(v.bits, v.format), BigInt(e) - _fraction(v.format), f; mode),
    f,
)
function _scale(v::_FloatValue, e, f::FixedFormat, mode)
    x = decode_ieee(v.bits, v.format)
    x.kind in (:zero, :finite) ||
        throw(DomainError(v.bits, "fixed scaling requires a finite value"))
    q = x.value
    return _fixed(
        _round_fixed_dyadic(
            numerator(q),
            BigInt(e) - (ndigits(denominator(q); base = 2) - 1),
            f,
            mode,
        ),
        f,
    )
end
_decoded(v::_FloatValue) = decode_ieee(v.bits, v.format)
_float(bits, f) = _FloatValue(f, _float_word(bits, f))
_invalid(f) = _float(_nan(f), f)
_infinite(f, negative) = _float(_inf(f) | (negative ? _sign(f) : UInt64(0)), f)

function _add(a::_FloatValue, b::_FloatValue, f, mode)
    x, y = _decoded(a), _decoded(b)
    (x.kind == :nan || y.kind == :nan) && return _invalid(f)
    if x.kind == :infinity || y.kind == :infinity
        x.kind == y.kind && x.negative != y.negative && return _invalid(f)
        return _infinite(f, x.kind == :infinity ? x.negative : y.negative)
    end
    zero_sign =
        x.kind == y.kind == :zero && x.negative == y.negative ? x.negative : mode == :down
    return _float(round_ieee(x.value + y.value, f; mode, zero_sign), f)
end
function _mul(a::_FloatValue, b::_FloatValue, f, mode)
    x, y = _decoded(a), _decoded(b)
    (x.kind == :nan || y.kind == :nan) && return _invalid(f)
    negative = xor(x.negative, y.negative)
    if x.kind == :infinity || y.kind == :infinity
        (x.kind == :zero || y.kind == :zero) && return _invalid(f)
        return _infinite(f, negative)
    end
    return _float(round_ieee(x.value * y.value, f; mode, zero_sign = negative), f)
end
function _fma(a::_FloatValue, b::_FloatValue, c::_FloatValue, f, mode)
    x, y, z = _decoded(a), _decoded(b), _decoded(c)
    any(d -> d.kind == :nan, (x, y, z)) && return _invalid(f)
    negative = xor(x.negative, y.negative)
    if x.kind == :infinity || y.kind == :infinity
        (x.kind == :zero || y.kind == :zero) && return _invalid(f)
        z.kind == :infinity && negative != z.negative && return _invalid(f)
        return _infinite(f, negative)
    end
    z.kind == :infinity && return _infinite(f, z.negative)
    product = x.value * y.value
    zero_sign =
        iszero(product) && z.kind == :zero && negative == z.negative ? negative :
        mode == :down
    return _float(round_ieee(product + z.value, f; mode, zero_sign), f)
end
function _convert(v::_FloatValue, f, mode)
    x = _decoded(v)
    x.kind == :nan && return _invalid(f)
    x.kind == :infinity && return _infinite(f, x.negative)
    return _float(round_ieee(x.value, f; mode, zero_sign = x.negative), f)
end
function _scale(v::_FloatValue, e, f, mode)
    x = _decoded(v)
    x.kind == :nan && return _invalid(f)
    x.kind == :infinity && return _infinite(f, x.negative)
    q = x.value
    power = BigInt(e) - (ndigits(denominator(q); base = 2) - 1)
    return _float(round_dyadic(numerator(q), power, f; mode, zero_sign = x.negative), f)
end
function _compare(predicate, a, b)
    if a isa _FixedValue
        a, b = _value(a), _value(b)
    elseif a isa _FloatValue
        x, y = _decoded(a), _decoded(b)
        (x.kind == :nan || y.kind == :nan) && return predicate == :ne
        a = x.kind == :infinity ? (x.negative ? -Inf : Inf) : x.value
        b = y.kind == :infinity ? (y.negative ? -Inf : Inf) : y.value
    end
    predicate == :eq && return a == b
    predicate == :ne && return a != b
    predicate == :lt && return a < b
    predicate == :le && return a <= b
    predicate == :gt && return a > b
    return a >= b
end

"""Output bits and the values of nodes actually executed, including table indices."""
struct EvaluationTrace
    bits::Union{UInt64, BigInt}
    values::Dict{Int, Any}
end

function _interpret(p::IR.Program, bits::Integer, trace::Bool)
    inputformat = IR.format(p, p.input)
    0 <= bits <= _word_mask(_width(inputformat)) ||
        throw(ArgumentError("bits exceed input format width"))
    values = Dict{Int, Any}()
    function visit(index::Int)
        haskey(values, index) && return values[index]
        n, f = p.nodes[index], IR.format(p, index)
        v = if n isa IR.Input
            _stored(bits, f)
        elseif n isa IR.Const
            f isa Union{FloatFormat, FixedFormat} ? _stored(n.bits, f) :
            f == Bool ? n.bits != 0 : n.bits
        elseif n isa IR.TableLoad
            row = visit(n.index)
            table = p.tables[n.table]
            row < length(table.values) || throw(BoundsError(table.values, row))
            word = table.values[Int(row) + 1]
            f isa Union{FloatFormat, FixedFormat} ? _stored(word, f) : word
        elseif n isa IR.Mul
            _mul(visit(n.a), visit(n.b), f, n.rounding)
        elseif n isa IR.Add
            _add(visit(n.a), visit(n.b), f, n.rounding)
        elseif n isa IR.FMA
            _fma(visit(n.a), visit(n.b), visit(n.c), f, n.rounding)
        elseif n isa Union{IR.Convert, IR.Quantize}
            _convert(visit(n.source), f, n.rounding)
        elseif n isa IR.ScalePow2
            _scale(visit(n.source), n.exponent, f, n.rounding)
        elseif n isa IR.FloatMantissa
            mantissa, _ = normalize_float(visit(n.source).bits, f)
            _float(mantissa, f)
        elseif n isa IR.FloatReciprocal
            x = _decoded(visit(n.source))
            x.kind == :nan ? _invalid(f) :
            x.kind == :zero ? _infinite(f, x.negative) :
            x.kind == :infinity ? _float(x.negative ? _sign(f) : 0, f) :
            _float(round_ieee(inv(x.value), f; zero_sign = x.negative), f)
        elseif n isa IR.FloatExponent
            source = visit(n.source)
            _, exponent = normalize_float(source.bits, source.format)
            _fixed(round_fixed(exponent, f), f)
        elseif n isa IR.RootArgument
            source = visit(n.source)
            _float(_root_argument(source.bits, source.format, n.divisor), f)
        elseif n isa IR.ScaleByInputExponent
            input = visit(n.input)
            _, exponent = normalize_float(input.bits, input.format)
            quotient, _ = split_exponent(exponent, n.divisor)
            _scale(visit(n.source), n.multiplier * quotient, f, n.rounding)
        elseif n isa IR.ScaleByExponent
            _scale(visit(n.source), numerator(_value(visit(n.exponent))), f, n.rounding)
        elseif n isa IR.CopySign
            source, sign = visit(n.source), visit(n.sign)
            negative = sign.bits & _sign(sign.format) != 0
            _float((source.bits & ~_sign(f)) | (negative ? _sign(f) : 0), f)
        elseif n isa IR.Compare
            _compare(n.predicate, visit(n.a), visit(n.b))
        elseif n isa IR.Select
            visit(visit(n.condition) ? n.yes : n.no)
        elseif n isa IR.Guard
            visit(n.condition) || throw(DomainError(bits, "input outside declared domain"))
            visit(n.source)
        elseif n isa IR.BitCast
            source = visit(n.source)
            f isa FloatFormat ? _float(source, f) : source.bits
        elseif n isa IR.ExtractBits
            (visit(n.source) >> n.offset) & IR.mask(f)
        elseif n isa IR.BitOp
            a, b = visit(n.a), visit(n.b)
            result =
                n.operation == :bitand ? a & b :
                n.operation == :bitor ? a | b :
                n.operation == :bitxor ? xor(a, b) :
                b >= f.width ? UInt64(0) :
                n.operation == :shiftleft ? a << Int(b) : a >> Int(b)
            result & IR.mask(f)
        elseif n isa IR.Classify
            source = visit(n.source)
            if source isa _FixedValue
                n.kind == :negative ? _value(source) < 0 :
                n.kind == :finite ? true : n.kind == :zero ? iszero(source.bits) : false
            else
                x = _decoded(source)
                n.kind == :negative ? x.negative :
                n.kind == :finite ? x.kind in (:zero, :finite) : x.kind == n.kind
            end
        else
            throw(ArgumentError("unsupported interpreter node"))
        end
        values[index] = v
        return v
    end
    result = visit(p.output).bits
    return trace ? EvaluationTrace(result, values) : result
end
"""Execute the IR with exact integer/rational rounding and lazy Select branches."""
evaluate_bits(p::IR.Program, bits::Integer) = _interpret(p, bits, false)
interpret_trace(p::IR.Program, bits::Integer) = _interpret(p, bits, true)
