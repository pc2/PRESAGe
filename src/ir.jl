"""Typed arithmetic DAG. References are one-based node/table indices."""
module IR
using ..PRESAGe: FloatFormat, FixedFormat, _wordmask, round_ieee, round_fixed, _fixed_mask

export UIntFormat, Node, Input, Const, Table, TableLoad, Mul, Add, FMA, Convert,
       Quantize, Compare, Select, BitCast, ExtractBits, BitOp, ScalePow2,
       Classify, Guard, Program, constant, format

struct UIntFormat
    width::Int
    function UIntFormat(width::Integer)
        1 <= width <= 64 || throw(ArgumentError("unsigned width must be in 1:64"))
        new(Int(width))
    end
end
const ArithmeticFormat = Union{FloatFormat,FixedFormat}
const Type = Union{ArithmeticFormat,UIntFormat,Core.Type{Bool}}
const Word = Union{UInt64,BigInt}
mask(f::UIntFormat) = typemax(UInt64) >> (64-f.width)
mask(f::FloatFormat) = _wordmask(f)
mask(f::FixedFormat) = _fixed_mask(f)
mask(::Core.Type{Bool}) = UInt64(1)
_default_rounding(::FloatFormat) = :nearest_even
_default_rounding(f::FixedFormat) = f.rounding
_word(bits,f) = f isa FixedFormat ? BigInt(bits) : UInt64(bits)
_rounding(mode) = mode in (:nearest_even,:toward_zero,:up,:down) ? mode :
    throw(ArgumentError("unsupported rounding mode"))

abstract type Node end
struct Input <: Node
    format::ArithmeticFormat
end
struct Const <: Node
    format::Type
    bits::Word
    function Const(f::Type, bits::Integer)
        0 <= bits <= mask(f) || throw(ArgumentError("constant exceeds format width"))
        new(f,_word(bits,f))
    end
end
constant(value::Union{Integer,Rational}, f::FloatFormat; rounding::Symbol=:nearest_even) =
    Const(f,round_ieee(value,f;mode=rounding))
constant(value::Union{Integer,Rational},f::FixedFormat;rounding::Symbol=f.rounding) =
    Const(f,round_fixed(value,f;mode=rounding))

"""Stored bit payloads. Banks/unroll describe future table implementation choices."""
struct Table
    format::Union{ArithmeticFormat,UIntFormat}
    values::Tuple{Vararg{Word}}
    banks::Int
    unroll::Bool
    function Table(f::Union{ArithmeticFormat,UIntFormat}, values; banks::Integer=1,unroll::Bool=false)
        isempty(values) && throw(ArgumentError("empty table"))
        banks >= 1 || throw(ArgumentError("banks must be positive"))
        all(v -> v isa Integer && 0 <= v <= mask(f),values) || throw(ArgumentError("invalid table bits"))
        new(f,Tuple(_word(v,f) for v in values),Int(banks),unroll)
    end
end
struct TableLoad <: Node
    table::Int
    index::Int # zero-based table index, carried by an unsigned node
end
for name in (:Mul,:Add)
    @eval struct $name <: Node
        a::Int
        b::Int
        format::ArithmeticFormat
        rounding::Symbol
        $name(a::Integer,b::Integer,f::ArithmeticFormat;rounding::Symbol=_default_rounding(f)) =
            new(Int(a),Int(b),f,_rounding(rounding))
    end
end
struct FMA <: Node
    a::Int
    b::Int
    c::Int
    format::ArithmeticFormat
    rounding::Symbol
    FMA(a::Integer,b::Integer,c::Integer,f::ArithmeticFormat;rounding::Symbol=_default_rounding(f)) =
        new(Int(a),Int(b),Int(c),f,_rounding(rounding))
end
for name in (:Convert,:Quantize)
    @eval struct $name <: Node
        source::Int
        format::ArithmeticFormat
        rounding::Symbol
        $name(source::Integer,f::ArithmeticFormat;rounding::Symbol=_default_rounding(f)) =
            new(Int(source),f,_rounding(rounding))
    end
end
struct Compare <: Node
    predicate::Symbol
    a::Int
    b::Int
end
struct Select <: Node
    condition::Int
    yes::Int
    no::Int
end
"""Reject a false domain condition; evaluate the source only when true."""
struct Guard <: Node
    condition::Int
    source::Int
end
struct BitCast <: Node
    source::Int
    format::Union{FloatFormat,UIntFormat}
end
struct ExtractBits <: Node
    source::Int
    offset::Int
    width::Int
end
struct BitOp <: Node
    operation::Symbol
    a::Int
    b::Int
end
struct ScalePow2 <: Node
    source::Int
    exponent::Int
    format::ArithmeticFormat
    rounding::Symbol
    function ScalePow2(source::Integer,exponent::Integer,f::ArithmeticFormat;rounding::Symbol=_default_rounding(f))
        typemin(Cint) <= exponent <= typemax(Cint) || throw(ArgumentError("scale exponent exceeds C int range"))
        new(Int(source),Int(exponent),f,_rounding(rounding))
    end
end
struct Classify <: Node
    kind::Symbol
    source::Int
end

_width(f::FloatFormat) = 1+f.exponent_bits+f.fraction_bits
_width(f::FixedFormat) = f.width
_width(f::UIntFormat) = f.width
refs(::Union{Input,Const}) = ()
refs(n::Union{Mul,Add,Compare,BitOp}) = (n.a,n.b)
refs(n::FMA) = (n.a,n.b,n.c)
refs(n::Select) = (n.condition,n.yes,n.no)
refs(n::Guard) = (n.condition,n.source)
refs(n::Union{Convert,Quantize,BitCast,ExtractBits,ScalePow2,Classify}) = (n.source,)
refs(n::TableLoad) = (n.index,)

function _type(n::Node, types, tables)
    n isa Union{Input,Const} && return n.format
    if n isa TableLoad
        1 <= n.table <= length(tables) || throw(ArgumentError("invalid table reference"))
        types[n.index] isa UIntFormat || throw(ArgumentError("table index must be unsigned"))
        return tables[n.table].format
    elseif n isa Union{Mul,Add,FMA}
        if n.format isa FixedFormat
            all(i -> types[i] isa FixedFormat,refs(n)) || throw(ArgumentError("fixed operands required"))
            n.rounding == n.format.rounding || throw(ArgumentError("fixed rounding must match its format"))
        else
            all(i -> types[i] == n.format,refs(n)) || throw(ArgumentError("arithmetic needs explicit operand conversions"))
        end
        return n.format
    elseif n isa Union{Convert,Quantize,ScalePow2}
        types[n.source] isa ArithmeticFormat || throw(ArgumentError("arithmetic source required"))
        n.format isa FixedFormat && n.rounding != n.format.rounding &&
            throw(ArgumentError("fixed rounding must match its format"))
        n isa ScalePow2 && n.format isa FloatFormat && types[n.source] != n.format &&
            throw(ArgumentError("scale needs an explicit format conversion"))
        return n.format
    elseif n isa Compare
        n.predicate in (:eq,:ne,:lt,:le,:gt,:ge) || throw(ArgumentError("invalid comparison"))
        types[n.a] == types[n.b] || throw(ArgumentError("comparison types differ"))
        types[n.a] == Bool && n.predicate ∉ (:eq,:ne) && throw(ArgumentError("Boolean comparisons support eq/ne"))
        return Bool
    elseif n isa Select
        types[n.condition] == Bool || throw(ArgumentError("select condition must be Boolean"))
        types[n.yes] == types[n.no] || throw(ArgumentError("select branch types differ"))
        return types[n.yes]
    elseif n isa Guard
        types[n.condition] == Bool || throw(ArgumentError("guard condition must be Boolean"))
        types[n.source] isa ArithmeticFormat || throw(ArgumentError("guard needs an arithmetic source"))
        return types[n.source]
    elseif n isa BitCast
        source = types[n.source]
        source isa Union{FloatFormat,UIntFormat} && _width(source) == _width(n.format) || throw(ArgumentError("bitcast widths differ"))
        (source isa FloatFormat) != (n.format isa FloatFormat) || throw(ArgumentError("bitcast needs float/unsigned types"))
        return n.format
    elseif n isa ExtractBits
        f = types[n.source]
        f isa UIntFormat && 0 <= n.offset && 1 <= n.width && n.offset+n.width <= f.width ||
            throw(ArgumentError("invalid bit extraction"))
        return UIntFormat(n.width)
    elseif n isa BitOp
        a,b = types[n.a],types[n.b]
        a isa UIntFormat && b isa UIntFormat || throw(ArgumentError("bit operations need unsigned operands"))
        n.operation in (:bitand,:bitor,:bitxor,:shiftleft,:shiftright) || throw(ArgumentError("invalid bit operation"))
        n.operation in (:shiftleft,:shiftright) || a == b || throw(ArgumentError("bit operand widths differ"))
        return a
    elseif n isa Classify
        types[n.source] isa ArithmeticFormat || throw(ArgumentError("classification needs an arithmetic value"))
        n.kind in (:nan,:infinity,:finite,:zero,:negative) || throw(ArgumentError("invalid classification"))
        return Bool
    end
    throw(ArgumentError("unsupported IR node"))
end

"""Validated immutable DAG with one float/fixed input and float/fixed output."""
struct Program
    nodes::Tuple{Vararg{Node}}
    tables::Tuple{Vararg{Table}}
    output::Int
    input::Int
    types::Tuple{Vararg{Type}}
    function Program(nodes;output::Integer=length(nodes),tables=Table[])
        ns,ts = Tuple(nodes),Tuple(tables)
        1 <= output <= length(ns) || throw(ArgumentError("invalid output reference"))
        types = Type[]
        inputs = Int[]
        for (i,n) in enumerate(ns)
            n isa Node || throw(ArgumentError("expected an IR node"))
            all(r -> 1 <= r < i,refs(n)) || throw(ArgumentError("references must point to earlier nodes"))
            n isa Input && push!(inputs,i)
            push!(types,_type(n,types,ts))
        end
        length(inputs) == 1 || throw(ArgumentError("program needs exactly one input"))
        types[output] isa ArithmeticFormat || throw(ArgumentError("output must be floating or fixed"))
        new(ns,ts,Int(output),only(inputs),Tuple(types))
    end
end
format(p::Program,i::Integer=p.output) = p.types[i]
end
