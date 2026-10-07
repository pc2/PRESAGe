_type_data(f::FloatFormat) = _format_data(f)
_type_data(f::FixedFormat) = _format_data(f)
_type_data(f::IR.UIntFormat) = "uint($(f.width))"
_type_data(::Type{Bool}) = "bool"
function _read_ir_type(text::AbstractString)
    text == "bool" && return Bool
    parts = match(r"^uint\((\d+)\)$", text)
    return parts === nothing ? _read_format(text) : IR.UIntFormat(parse(Int, parts[1]))
end
_read_ir_type(d::AbstractDict) = _read_format(d)
_ir_hex(bits) = "0x" * string(bits; base = 16)
function _read_ir_bits(text::AbstractString)
    occursin(r"^0x[0-9a-fA-F]+$", text) || throw(ArgumentError("expected hexadecimal bits"))
    bits = parse(BigInt, text[3:end]; base = 16)
    return bits <= typemax(UInt64) ? UInt64(bits) : bits
end
function _node_data(n::IR.Node)
    d = Dict{String, Any}("op" => string(nameof(typeof(n))))
    for field in fieldnames(typeof(n))
        value = getfield(n, field)
        field == :divisor &&
            (
                (n isa IR.ScaleByInputExponent && value == 1) ||
                (n isa IR.RootArgument && value == 2)
            ) &&
            continue
        d[string(field)] =
            field == :format ? _type_data(value) :
            field == :bits ? _ir_hex(value) : value isa Symbol ? string(value) : value
    end
    return d
end
const _IR_NODES = Dict(
    string(nameof(t)) => t for t in (
        IR.Input,
        IR.Const,
        IR.TableLoad,
        IR.Mul,
        IR.Add,
        IR.FMA,
        IR.Convert,
        IR.Quantize,
        IR.Compare,
        IR.Select,
        IR.Guard,
        IR.BitCast,
        IR.ExtractBits,
        IR.BitOp,
        IR.ScalePow2,
        IR.FloatMantissa,
        IR.FloatExponent,
        IR.FloatReciprocal,
        IR.RootArgument,
        IR.ScaleByInputExponent,
        IR.ScaleByExponent,
        IR.CopySign,
        IR.Classify,
    )
)
function _read_node(d)
    t = get(_IR_NODES, d["op"], nothing)
    t === nothing && throw(ArgumentError("unsupported IR operation"))
    args = Any[]
    for field in fieldnames(t)
        field == :rounding && continue
        value =
            field == :divisor ? get(d, "divisor", t == IR.RootArgument ? 2 : 1) :
            d[string(field)]
        push!(
            args,
            field == :format ? _read_ir_type(value) :
            field == :bits ? _read_ir_bits(value) :
            field in (:predicate, :operation, :kind) ? Symbol(value) : value,
        )
    end
    return hasfield(t, :rounding) ? t(args...; rounding = Symbol(d["rounding"])) :
           t(args...)
end
function _program_data(p::IR.Program)
    d = Dict{String, Any}("output" => p.output, "nodes" => _node_data.(collect(p.nodes)))
    if !isempty(p.tables)
        d["tables"] = [
            begin
                table = Dict{String, Any}(
                    "format" => _type_data(t.format),
                    "values" => _ir_hex.(collect(t.values)),
                )
                t.banks == 1 || (table["banks"] = t.banks)
                t.unroll && (table["unroll"] = true)
                table
            end for t in p.tables
        ]
    end
    return d
end
function _read_program(d)
    tables = [
        IR.Table(
            _read_ir_type(t["format"]),
            _read_ir_bits.(t["values"]);
            banks = get(t, "banks", 1),
            unroll = get(t, "unroll", false),
        ) for t in get(d, "tables", [])
    ]
    return IR.Program(_read_node.(d["nodes"]); tables, output = d["output"])
end
