const _KERNEL_BACKENDS = (:ap_fixed, :ac_fixed)
const _KERNEL_TOOLCHAINS = (:generic, :vitis, :oneapi)

function _kernel_type(f::IR.UIntFormat, backend)
    1 <= f.width <= _VENDOR_WIDTH_LIMIT ||
        throw(ArgumentError("kernel unsigned width exceeds the 4096-bit vendor limit"))
    return backend == :ap_fixed ? "ap_uint<$(f.width)>" : "ac_int<$(f.width),false>"
end
_kernel_type(f::FixedFormat, backend) = _cpp_type(f, backend)
_kernel_type(::Type{Bool}, backend) = "bool"
function _kernel_type(f::FloatFormat, backend)
    word = _kernel_type(IR.UIntFormat(_width(f)), backend)
    return "EncodedFloat<$word,$(f.exponent_bits),$(f.fraction_bits)>"
end
_kernel_width(f::Union{FixedFormat, FloatFormat}) = _width(f)
_kernel_width(f::IR.UIntFormat) = f.width
_kernel_width(::Type{Bool}) = 1

function _kernel_has_float_arithmetic(p)
    return any(eachindex(p.nodes)) do i
        n = p.nodes[i]
        n isa IR.FloatReciprocal ||
            n isa Union{IR.Mul, IR.Add, IR.FMA} && IR.format(p, i) isa FloatFormat
    end
end

function _kernel_float_arithmetic(n, f, backend)
    backend == :ac_fixed ||
        throw(ArgumentError("floating kernel arithmetic requires the ac_fixed backend"))
    (n isa IR.FloatReciprocal || n.rounding == :nearest_even) ||
        throw(ArgumentError("AC floating kernel arithmetic requires nearest-even rounding"))
    f.exponent_bits <= 30 ||
        throw(ArgumentError("AC floating arithmetic exponent fields must fit 30 bits"))
    # Reserve headroom for AC's product/FMA accumulator and rounding temporaries.
    2BigInt(f.fraction_bits + 1) + 12 <= _VENDOR_WIDTH_LIMIT ||
        throw(ArgumentError("AC floating arithmetic work widths exceed the 4096-bit limit"))
    return nothing
end

function _kernel_scale_limit(source, output)
    # Beyond this magnitude, even an extreme finite source overflows or falls
    # below half the smallest output subnormal. E <= 62 keeps the sum in Int64.
    source_bound =
        source isa FloatFormat ? BigInt(_bias(source)) + source.fraction_bits :
        BigInt(source.width)
    return source_bound + _bias(output) + output.fraction_bits + 2
end

function _kernel_scale_expr(
    source,
    output,
    backend,
    mode,
    value,
    scale;
    type = f -> _kernel_type(f, backend),
)
    type = type(output)
    return source isa FixedFormat ?
           "fixed_scale<$type,$(source.width),$(source.integer_bits),$(source.signed),$mode>($value,$scale)" :
           "float_scale<$type,$mode>($value,$scale)"
end

function _kernel_chunks(bits, width)
    return join(
        (
            "0x$(string((BigInt(bits) >> k) & typemax(UInt64);base=16))ULL" for
            k = 0:64:(width - 1)
        ),
        ", ",
    )
end

function _kernel_validate(p, backend, toolchain)
    backend in _KERNEL_BACKENDS ||
        throw(ArgumentError("kernel backend must be ap_fixed or ac_fixed"))
    toolchain in _KERNEL_TOOLCHAINS ||
        throw(ArgumentError("kernel toolchain must be generic, vitis or oneapi"))
    toolchain == :vitis &&
        backend != :ap_fixed &&
        throw(ArgumentError("vitis kernels require ap_fixed"))
    toolchain == :oneapi &&
        backend != :ac_fixed &&
        throw(ArgumentError("oneapi kernels require ac_fixed"))
    foreach(f -> _kernel_type(f, backend), p.types)
    for n in p.nodes
        if n isa Union{IR.Convert, IR.Quantize, IR.ScalePow2} &&
           n.format isa FixedFormat &&
           IR.format(p, n.source) isa FloatFormat
            n.format.width < _VENDOR_WIDTH_LIMIT || throw(
                ArgumentError(
                    "float-to-fixed conversion needs a guard bit within the 4096-bit vendor limit",
                ),
            )
        end
    end
    for t in p.tables
        _kernel_type(t.format, backend)
        length(t.values) <= typemax(Cint) ||
            throw(ArgumentError("kernel table exceeds the C int index range"))
        t.banks <= min(length(t.values), _VENDOR_WIDTH_LIMIT) || throw(
            ArgumentError("kernel table banks must not exceed its entry count or 4096"),
        )
        toolchain == :oneapi &&
            !ispow2(t.banks) &&
            throw(ArgumentError("oneapi table banks must be a power of two"))
    end
    return nothing
end

function _kernel_expr(
    p,
    i,
    backend;
    call = j -> "arg$j",
    type = f -> _kernel_type(f, backend),
    vendor_type = _vendor_type,
    scale_name = "scale",
)
    n, f = p.nodes[i], IR.format(p, i)
    if n isa IR.Input
        return "input"
    elseif n isa IR.Const
        return _cpp_value_name(p, i)
    elseif n isa IR.TableLoad
        return "load$(n.table)($(call(n.index)), status)"
    elseif n isa Union{IR.Convert, IR.Quantize, IR.ScalePow2}
        source = IR.format(p, n.source)
        scale = n isa IR.ScalePow2 ? n.exponent : 0
        mode = _cpp_mode(n.rounding)
        if source isa FloatFormat && f isa FixedFormat
            return "float_to_fixed<$(type(f)),$(f.width),$(f.integer_bits),$(f.signed),$mode,$(_cpp_overflow(f.overflow)),$scale>($(call(n.source)),status)"
        elseif source isa FixedFormat && f isa FloatFormat
            return "fixed_to_float<$(type(f)),$(source.width),$(source.integer_bits),$(source.signed),$mode,$scale>($(call(n.source)))"
        elseif source isa FloatFormat && f isa FloatFormat
            return "float_convert<$(type(f)),$mode,$scale>($(call(n.source)))"
        end
        return _cpp_vendor_expr(
            p,
            i,
            backend;
            call,
            quantizer = "kernel_quantize",
            reinterpret = "copy_bits",
            type = vendor_type,
            outtype = type,
            status = "status",
        )
    elseif n isa Union{IR.Mul, IR.Add, IR.FMA}
        if f isa FloatFormat
            _kernel_float_arithmetic(n, f, backend)
            operation =
                n isa IR.Add ? "float_add" : n isa IR.Mul ? "float_mul" : "float_fma"
            return "$operation($(join(call.(IR.refs(n)),",")))"
        end
        return _cpp_vendor_expr(
            p,
            i,
            backend;
            call,
            quantizer = "kernel_quantize",
            reinterpret = "copy_bits",
            type = vendor_type,
            outtype = type,
            status = "status",
        )
    elseif n isa Union{IR.FloatMantissa, IR.RootArgument}
        divisor = n isa IR.RootArgument ? n.divisor : 1
        return "normalized_argument<$(type(f)),$divisor>($(call(n.source)),status)"
    elseif n isa IR.FloatExponent
        return "float_exponent<$(type(f))>($(call(n.source)),status)"
    elseif n isa IR.FloatReciprocal
        _kernel_float_arithmetic(n, f, backend)
        return "float_reciprocal($(call(n.source)))"
    elseif n isa IR.ScaleByInputExponent
        return _kernel_scale_expr(
            IR.format(p, n.source),
            f,
            backend,
            _cpp_mode(n.rounding),
            call(n.source),
            "$(n.multiplier) * $scale_name";
            type,
        )
    elseif n isa IR.ScaleByExponent
        source, exponent = IR.format(p, n.source), IR.format(p, n.exponent)
        scale = "bounded_exponent<$(exponent.width),$(_kernel_scale_limit(source,f))LL>($(call(n.exponent)))"
        return _kernel_scale_expr(
            source,
            f,
            backend,
            _cpp_mode(n.rounding),
            call(n.source),
            scale;
            type,
        )
    elseif n isa IR.Compare
        if IR.format(p, n.a) isa FloatFormat
            predicate = findfirst(==(n.predicate), (:eq, :ne, :lt, :le, :gt, :ge)) - 1
            return "float_compare<$predicate>($(call(n.a)),$(call(n.b)))"
        end
        op = Dict(
            :eq => "==",
            :ne => "!=",
            :lt => "<",
            :le => "<=",
            :gt => ">",
            :ge => ">=",
        )[n.predicate]
        return "($(call(n.a)) $op $(call(n.b)))"
    elseif n isa IR.BitCast
        return "copy_bits<$(type(f)),$(_kernel_width(f))>($(call(n.source)))"
    elseif n isa IR.ExtractBits
        return "$(type(f))($(call(n.source)) >> $(n.offset))"
    elseif n isa IR.UIntAdd
        return "$(type(f))($(call(n.a)) + $(call(n.b)))"
    elseif n isa IR.BitOp
        op = Dict(
            :bitand => "&",
            :bitor => "|",
            :bitxor => "^",
            :shiftleft => "<<",
            :shiftright => ">>",
        )[n.operation]
        if n.operation in (:shiftleft, :shiftright)
            return "($(call(n.b)) >= $(f.width) ? $(type(f))(0) : $(type(f))($(call(n.a)) $op $(call(n.b)).to_uint()))"
        end
        return "$(type(f))($(call(n.a)) $op $(call(n.b)))"
    elseif n isa IR.Classify
        if IR.format(p, n.source) isa FloatFormat
            method = Dict(
                :finite => "is_finite",
                :negative => "negative",
                :zero => "is_zero",
                :nan => "is_nan",
                :infinity => "is_infinite",
            )[n.kind]
            return "$(call(n.source)).$method()"
        end
        return n.kind == :finite ? "true" :
               n.kind == :negative ? "($(call(n.source)) < 0)" :
               n.kind == :zero ? "($(call(n.source)) == 0)" : "false"
    elseif n isa IR.CopySign
        return "float_copy_sign($(call(n.source)),$(call(n.sign)))"
    elseif n isa Union{IR.Select, IR.Guard}
        return "" # Emit explicitly to retain lazy branches and rejection order.
    end
    throw(ArgumentError("unsupported kernel node $(typeof(n))"))
end

function _kernel_table(
    io,
    number,
    t,
    backend,
    toolchain;
    type = f -> _kernel_type(f, backend),
)
    width = _kernel_width(t.format)
    rows = cld(length(t.values), t.banks)
    word_type = type(IR.UIntFormat(width))
    type = type(t.format)
    load = source -> "copy_bits<$type, $width>($source)"
    println(io, "inline constexpr unsigned table$(number)_banks = $(t.banks);")
    println(io, "inline constexpr bool table$(number)_unroll = $(t.unroll);")
    println(
        io,
        "template<class Index> inline $type load$number(const Index& index, Status& status) {",
    )
    println(
        io,
        "    if (index >= $(length(t.values))) { status = Status::table_index_rejected; return $type(0); }",
    )
    if toolchain == :oneapi
        println(io, "#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)")
        println(
            io,
            "    [[intel::numbanks($(t.banks)), intel::max_replicates(1), intel::fpga_memory]]",
        )
        println(io, "#endif")
    end
    println(io, "    static const $word_type table[$(t.banks)][$rows] = {")
    for bank = 1:(t.banks)
        values = map(bank:(t.banks):(rows * t.banks)) do index
            bits = index <= length(t.values) ? t.values[index] : 0
            literal = _kernel_chunks(bits, width)
            return width <= 64 ? "$word_type($literal)" :
                   "from_chunks<$word_type, $width>({$literal})"
        end
        println(io, "        {")
        for value in values
            println(io, "            $value,")
        end
        println(io, "        },")
    end
    println(io, "    };")
    if toolchain == :vitis
        println(io, "#if defined(__SYNTHESIS__)")
        println(io, "#pragma HLS array_partition variable=table complete dim=1")
        println(io, "#endif")
    end
    if t.banks == 1
        println(io, "    unsigned row = index.to_uint();")
        println(io, "    return $(load("table[0][row]"));")
    elseif t.unroll
        println(io, "    unsigned row = index.to_uint() / $(t.banks);")
        println(io, "    unsigned bank = index.to_uint() % $(t.banks);")
        println(io, "    $type result = $type(0);")
        for bank = 0:(t.banks - 1)
            println(io, "    if (bank == $bank) result = $(load("table[$bank][row]"));")
        end
        println(io, "    return result;")
    else
        println(io, "    unsigned row = index.to_uint() / $(t.banks);")
        println(io, "    unsigned bank = index.to_uint() % $(t.banks);")
        println(io, "    return $(load("table[bank][row]"));")
    end
    println(io, "}\n")
end

function _kernel_support(io, body; name, backend, toolchain)
    files = ["cpp_policies.hpp", "cpp_kernel.hpp", "cpp_kernel_float.hpp"]
    backend == :ac_fixed && push!(files, "cpp_kernel_ac_float.hpp")
    prelude =
        "// presage:helper UInt\n" *
        "template <int Width> using UInt = $(backend == :ap_fixed ? "ap_uint<Width>" : "ac_int<Width, false>");\n"
    return _cpp_emit_header(io, body, files; name, target = :kernel, toolchain, prelude)
end

function _kernel_emit_constant(io, p, i, types)
    n, f = p.nodes[i], IR.format(p, i)
    name, type = _cpp_value_name(p, i), _cpp_alias!(types, f)
    if f == Bool
        println(io, "inline constexpr bool $name = $(n.bits != 0);")
    else
        width = _kernel_width(f)
        println(io, "inline const $type $name = from_chunks<$type, $width>(")
        println(io, "    {$(_kernel_chunks(n.bits, width))});")
    end
end

"""Emit a C++17 evaluator using official vendor arithmetic and explicit rejection status.

The header includes only the arithmetic helpers needed by its emitted operations.
`trace=true` adds optional intermediate-value instrumentation for conformance tests.
`toolchain=:generic` uses public headers; `:vitis` and `:oneapi` select vendor
include paths and guarded memory hints. AC floating arithmetic is nearest-even.
"""
function emit_kernel(
    io::IO,
    p::IR.Program;
    name::AbstractString = "evaluator",
    backend::Symbol = :ac_fixed,
    toolchain::Symbol = :generic,
    trace::Bool = false,
)
    ns = _cpp_name(name)
    _kernel_validate(p, backend, toolchain)
    # Validate every node before writing, including unreachable operations.
    foreach(i -> _kernel_expr(p, i, backend), eachindex(p.nodes))
    flow, scopes = _cpp_flow(p)
    reachable = _cpp_reachable(flow)
    tables = _cpp_used_tables(p, reachable)
    types = _CppTypes(backend)
    type = f -> _cpp_alias!(types, f)
    vendor_type = (args...) -> _cpp_vendor_alias!(types, args...)
    foreach(i -> type(p.types[i]), trace ? eachindex(p.types) : sort!(collect(reachable)))
    foreach(i -> type(p.tables[i].format), sort!(collect(tables)))
    foreach(
        i -> type(IR.UIntFormat(_kernel_width(p.tables[i].format))),
        sort!(collect(tables)),
    )
    expressions = [
        i in reachable ?
        _kernel_expr(
            p,
            i,
            backend;
            call = j -> _cpp_value_name(p, j),
            type,
            vendor_type,
            scale_name = "scale_$i",
        ) : "" for i in eachindex(p.nodes)
    ]
    inputformat, outputformat = IR.format(p, p.input), IR.format(p)
    intype, outtype = type(inputformat), type(outputformat)
    inword, outword = type(IR.UIntFormat(_kernel_width(inputformat))),
    type(IR.UIntFormat(_kernel_width(outputformat)))
    body_io = IOBuffer()
    println(body_io, "\n// PRESAGe evaluator; backend=$backend, toolchain=$toolchain.")
    println(body_io, "namespace $ns {\nusing namespace $(ns)_support;\n")
    for (alias, definition) in types.declarations
        println(body_io, "using $alias = $(replace(definition, r",\s*" => ", "));")
    end
    println(
        body_io,
        """

using Input = $intype;
using Output = $outtype;
using InputBits = $inword;
using OutputBits = $outword;

struct Result {
    Output value;
    Status status;
    bool valid() const { return status == Status::ok; }
};
struct BitsResult {
    OutputBits bits;
    Status status;
    bool valid() const { return status == Status::ok; }
};
""",
    )
    for (i, t) in enumerate(p.tables)
        i in tables || continue
        _kernel_table(body_io, i, t, backend, toolchain; type)
    end
    for i in sort!(collect(flow.constants))
        _kernel_emit_constant(body_io, p, i, types)
    end
    if trace
        println(body_io, "\nstruct Trace {")
        for (i, f) in enumerate(p.types)
            println(
                body_io,
                "    bool visited$i = false; $(type(f)) value$i = $(type(f))(0);",
            )
        end
        println(body_io, "};")
    end
    println(
        body_io,
        "\ninline Result evaluate([[maybe_unused]] const Input& input$(trace ? ", Trace* trace = nullptr" : "")) {",
    )
    println(body_io, "    [[maybe_unused]] Status status = Status::ok;")
    for i in sort!(collect(flow.cached))
        println(body_io, "    bool computed_$(_cpp_value_name(p, i)) = false;")
    end
    _cpp_render_block(body_io, flow, 1, scopes, expressions, types, "    ", trace)
    println(body_io, "    return {$(_cpp_value_name(p, p.output)), status};\n}")
    println(
        body_io,
        """

inline BitsResult evaluate_bits(const InputBits& bits) {
    Result result = evaluate(copy_bits<Input, $(_kernel_width(inputformat))>(bits));
    return {copy_bits<OutputBits, $(_kernel_width(outputformat))>(result.value), result.status};
}
} // namespace $ns
""",
    )
    body = String(take!(body_io))
    _kernel_support(io, body; name, backend, toolchain)
    return nothing
end

function emit_kernel(io::IO, plan::PlanArtifact; kwargs...)
    plan.program === nothing && throw(ArgumentError("plan has no evaluator"))
    return emit_kernel(io, plan.program; kwargs...)
end

# Render before opening the destination: unsupported graphs leave the file intact.
function emit_kernel(
    path::AbstractString,
    p;
    name = "evaluator",
    backend = :ac_fixed,
    toolchain = :generic,
    trace = false,
)
    text = sprint(io -> emit_kernel(io, p; name, backend, toolchain, trace))
    write(path, text)
    return nothing
end

"""Emit a host byte-stream adapter for a kernel. `--status` adds one status byte per output."""
function emit_kernel_harness(
    io::IO,
    p::IR.Program;
    name::AbstractString = "evaluator",
    header::AbstractString = "evaluator.hpp",
)
    occursin(r"^[A-Za-z0-9_.-]+$", header) ||
        throw(ArgumentError("header must be a simple filename"))
    ns = _cpp_name(name)
    infmt, outfmt = IR.format(p, p.input), IR.format(p)
    inwidth, outwidth = _kernel_width(infmt), _kernel_width(outfmt)
    inbytes, outbytes = _word_bytes(infmt), _word_bytes(outfmt)
    println(
        io,
        """
#include <iostream>
#include <cstring>
#include "$header"
int main(int argc, char** argv) {
    using namespace $ns;
    bool statuses = argc == 2 && std::strcmp(argv[1], "--status") == 0;
    if (argc != 1 && !statuses) { std::cerr << "Usage: evaluator [--status]\\n"; return 3; }
    while (true) {
        InputBits input = 0;
        for (int byte = 0; byte < $inbytes; ++byte) {
            int c = std::cin.get();
            if (c == std::char_traits<char>::eof()) {
                if (byte == 0 && std::cin.eof() && !std::cin.bad()) {
                    std::cout.flush(); return std::cout ? 0 : 3;
                }
                std::cerr << "truncated or unreadable input word\\n"; return 3;
            }
            if (byte == $(inbytes-1) && (unsigned(c) >> $(inwidth-8(inbytes-1))) != 0) {
                std::cerr << "nonzero input padding\\n"; return 3;
            }
            for (int bit = 0; bit < 8 && byte * 8 + bit < $inwidth; ++bit)
                input[byte * 8 + bit] = (unsigned(c) >> bit) & 1U;
        }
        BitsResult result = evaluate_bits(input);
        if (!statuses && !result.valid()) {
            std::cerr << "PRESAGe kernel rejected input, status=" << unsigned(result.status) << '\\n'; return 1;
        }
        if (statuses) std::cout.put(static_cast<char>(result.status));
        for (int byte = 0; byte < $outbytes; ++byte) {
            unsigned c = 0;
            for (int bit = 0; bit < 8 && byte * 8 + bit < $outwidth; ++bit)
                if (result.bits[byte * 8 + bit]) c |= 1U << bit;
            std::cout.put(static_cast<char>(c));
        }
        if (!std::cout) { std::cerr << "output write failed\\n"; return 3; }
    }
}
""",
    )
    return nothing
end
function emit_kernel_harness(path::AbstractString, p::IR.Program; kwargs...)
    text = sprint(io -> emit_kernel_harness(io, p; kwargs...))
    write(path, text)
    return nothing
end
