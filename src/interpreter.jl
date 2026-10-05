struct _FloatValue
    format::FloatFormat
    bits::UInt64
end
_decoded(v::_FloatValue) = decode_ieee(v.bits,v.format)
_float(bits,f) = _FloatValue(f,UInt64(bits))
_invalid(f) = _float(_nan(f),f)
_infinite(f,negative) = _float(_inf(f)|(negative ? _sign(f) : UInt64(0)),f)

function _add(a::_FloatValue,b::_FloatValue,f,mode)
    x,y = _decoded(a),_decoded(b)
    (x.kind == :nan || y.kind == :nan) && return _invalid(f)
    if x.kind == :infinity || y.kind == :infinity
        x.kind == y.kind && x.negative != y.negative && return _invalid(f)
        return _infinite(f,x.kind == :infinity ? x.negative : y.negative)
    end
    zero_sign = x.kind == y.kind == :zero && x.negative == y.negative ? x.negative : mode == :down
    return _float(round_ieee(x.value+y.value,f;mode,zero_sign),f)
end
function _mul(a::_FloatValue,b::_FloatValue,f,mode)
    x,y = _decoded(a),_decoded(b)
    (x.kind == :nan || y.kind == :nan) && return _invalid(f)
    negative = xor(x.negative,y.negative)
    if x.kind == :infinity || y.kind == :infinity
        (x.kind == :zero || y.kind == :zero) && return _invalid(f)
        return _infinite(f,negative)
    end
    return _float(round_ieee(x.value*y.value,f;mode,zero_sign=negative),f)
end
function _fma(a::_FloatValue,b::_FloatValue,c::_FloatValue,f,mode)
    x,y,z = _decoded(a),_decoded(b),_decoded(c)
    any(d -> d.kind == :nan,(x,y,z)) && return _invalid(f)
    negative = xor(x.negative,y.negative)
    if x.kind == :infinity || y.kind == :infinity
        (x.kind == :zero || y.kind == :zero) && return _invalid(f)
        z.kind == :infinity && negative != z.negative && return _invalid(f)
        return _infinite(f,negative)
    end
    z.kind == :infinity && return _infinite(f,z.negative)
    product = x.value*y.value
    zero_sign = iszero(product) && z.kind == :zero && negative == z.negative ? negative : mode == :down
    return _float(round_ieee(product+z.value,f;mode,zero_sign),f)
end
function _convert(v::_FloatValue,f,mode)
    x = _decoded(v)
    x.kind == :nan && return _invalid(f)
    x.kind == :infinity && return _infinite(f,x.negative)
    return _float(round_ieee(x.value,f;mode,zero_sign=x.negative),f)
end
function _scale(v::_FloatValue,e,f,mode)
    x = _decoded(v)
    x.kind == :nan && return _invalid(f)
    x.kind == :infinity && return _infinite(f,x.negative)
    q = x.value
    power = BigInt(e) - (ndigits(denominator(q);base=2)-1)
    return _float(round_dyadic(numerator(q),power,f;mode,zero_sign=x.negative),f)
end
function _compare(predicate,a,b)
    if a isa _FloatValue
        x,y = _decoded(a),_decoded(b)
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
    bits::UInt64
    values::Dict{Int,Any}
end

function _interpret(p::IR.Program,bits::Integer,trace::Bool)
    inputformat = IR.format(p,p.input)
    decode_ieee(bits,inputformat) # Validate width before executing anything.
    values = Dict{Int,Any}()
    function visit(index::Int)
        haskey(values,index) && return values[index]
        n,f = p.nodes[index],IR.format(p,index)
        v = if n isa IR.Input
            _float(bits,f)
        elseif n isa IR.Const
            f isa FloatFormat ? _float(n.bits,f) : f == Bool ? n.bits != 0 : n.bits
        elseif n isa IR.TableLoad
            row = visit(n.index)
            table = p.tables[n.table]
            row < length(table.values) || throw(BoundsError(table.values,row))
            word = table.values[Int(row)+1]
            f isa FloatFormat ? _float(word,f) : word
        elseif n isa IR.Mul
            _mul(visit(n.a),visit(n.b),f,n.rounding)
        elseif n isa IR.Add
            _add(visit(n.a),visit(n.b),f,n.rounding)
        elseif n isa IR.FMA
            _fma(visit(n.a),visit(n.b),visit(n.c),f,n.rounding)
        elseif n isa Union{IR.Convert,IR.Quantize}
            _convert(visit(n.source),f,n.rounding)
        elseif n isa IR.ScalePow2
            _scale(visit(n.source),n.exponent,f,n.rounding)
        elseif n isa IR.Compare
            _compare(n.predicate,visit(n.a),visit(n.b))
        elseif n isa IR.Select
            visit(visit(n.condition) ? n.yes : n.no)
        elseif n isa IR.BitCast
            source = visit(n.source)
            f isa FloatFormat ? _float(source,f) : source.bits
        elseif n isa IR.ExtractBits
            (visit(n.source) >> n.offset) & IR.mask(f)
        elseif n isa IR.BitOp
            a,b = visit(n.a),visit(n.b)
            result = n.operation == :bitand ? a & b : n.operation == :bitor ? a | b :
                n.operation == :bitxor ? xor(a,b) : b >= f.width ? UInt64(0) :
                n.operation == :shiftleft ? a << Int(b) : a >> Int(b)
            result & IR.mask(f)
        elseif n isa IR.Classify
            x = _decoded(visit(n.source))
            n.kind == :negative ? x.negative : n.kind == :finite ? x.kind in (:zero,:finite) : x.kind == n.kind
        else
            throw(ArgumentError("unsupported interpreter node"))
        end
        values[index] = v
        return v
    end
    result = visit(p.output).bits
    return trace ? EvaluationTrace(result,values) : result
end
"""Execute the IR with exact integer/rational rounding and lazy Select branches."""
evaluate_bits(p::IR.Program,bits::Integer) = _interpret(p,bits,false)
interpret_trace(p::IR.Program,bits::Integer) = _interpret(p,bits,true)
