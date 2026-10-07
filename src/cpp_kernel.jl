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

function _kernel_scale_limit(source, output)
    # Beyond this magnitude, even an extreme finite source overflows or falls
    # below half the smallest output subnormal. E <= 62 keeps the sum in Int64.
    source_bound =
        source isa FloatFormat ? BigInt(_bias(source)) + source.fraction_bits :
        BigInt(source.width)
    return source_bound + _bias(output) + output.fraction_bits + 2
end

function _kernel_scale_expr(source, output, backend, mode, value, scale)
    type = _kernel_type(output, backend)
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
        ",",
    )
end

function _kernel_constant(bits, f, backend)
    f == Bool && return bits == 0 ? "false" : "true"
    width = _kernel_width(f)
    return "([]() { const unsigned long long words[] = {$(_kernel_chunks(bits,width))}; return from_chunks<$(_kernel_type(f,backend)),$width>(words); }())"
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

function _kernel_expr(p, i, backend)
    n, f = p.nodes[i], IR.format(p, i)
    call(j) = "arg$j"
    if n isa IR.Input
        return "input"
    elseif n isa IR.Const
        return _kernel_constant(n.bits, f, backend)
    elseif n isa IR.TableLoad
        return "load$(n.table)($(call(n.index)))"
    elseif n isa Union{IR.Convert, IR.Quantize, IR.ScalePow2}
        source = IR.format(p, n.source)
        scale = n isa IR.ScalePow2 ? n.exponent : 0
        mode = _cpp_mode(n.rounding)
        if source isa FloatFormat && f isa FixedFormat
            return "float_to_fixed<$(_kernel_type(f,backend)),$(f.width),$(f.integer_bits),$(f.signed),$mode,$(_cpp_overflow(f.overflow)),$scale>($(call(n.source)),status)"
        elseif source isa FixedFormat && f isa FloatFormat
            return "fixed_to_float<$(_kernel_type(f,backend)),$(source.width),$(source.integer_bits),$(source.signed),$mode,$scale>($(call(n.source)))"
        elseif source isa FloatFormat && f isa FloatFormat
            return "float_convert<$(_kernel_type(f,backend)),$mode,$scale>($(call(n.source)))"
        end
        return _cpp_vendor_expr(
            p,
            i,
            backend;
            call,
            quantizer = "quantize",
            reinterpret = "copy_bits",
        )
    elseif n isa Union{IR.Mul, IR.Add, IR.FMA}
        f isa FixedFormat || throw(
            ArgumentError(
                "floating arithmetic is not supported by the kernel emitter; use fixed internal arithmetic",
            ),
        )
        return _cpp_vendor_expr(
            p,
            i,
            backend;
            call,
            quantizer = "quantize",
            reinterpret = "copy_bits",
        )
    elseif n isa Union{IR.FloatMantissa, IR.RootArgument}
        divisor = n isa IR.RootArgument ? n.divisor : 1
        return "normalized_argument<$(_kernel_type(f,backend)),$divisor>($(call(n.source)),status)"
    elseif n isa IR.FloatExponent
        return "float_exponent<$(_kernel_type(f,backend))>($(call(n.source)),status)"
    elseif n isa IR.ScaleByInputExponent
        return _kernel_scale_expr(
            IR.format(p, n.source),
            f,
            backend,
            _cpp_mode(n.rounding),
            call(n.source),
            "$(n.multiplier) * scale",
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
            scale,
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
        return "copy_bits<$(_kernel_type(f,backend)),$(_kernel_width(f))>($(call(n.source)))"
    elseif n isa IR.ExtractBits
        return "$(_kernel_type(f,backend))($(call(n.source)) >> $(n.offset))"
    elseif n isa IR.BitOp
        op = Dict(
            :bitand => "&",
            :bitor => "|",
            :bitxor => "^",
            :shiftleft => "<<",
            :shiftright => ">>",
        )[n.operation]
        if n.operation in (:shiftleft, :shiftright)
            return "($(call(n.b)) >= $(f.width) ? $(_kernel_type(f,backend))(0) : $(_kernel_type(f,backend))($(call(n.a)) $op $(call(n.b)).to_uint()))"
        end
        return "$(_kernel_type(f,backend))($(call(n.a)) $op $(call(n.b)))"
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

function _kernel_table(io, number, t, backend, toolchain)
    width = _kernel_width(t.format)
    rows, chunks = cld(length(t.values), t.banks), cld(width, 64)
    type = _kernel_type(t.format, backend)
    println(io, "    static constexpr unsigned table$(number)_banks = $(t.banks);")
    println(io, "    static constexpr bool table$(number)_unroll = $(t.unroll);")
    println(io, "    template<class Index> $type load$number(const Index& index) {")
    println(
        io,
        "        if (index >= $(length(t.values))) { status = Status::table_index_rejected; return $type(0); }",
    )
    if toolchain == :oneapi
        println(io, "#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)")
        println(
            io,
            "        [[intel::numbanks($(t.banks)), intel::max_replicates(1), intel::fpga_memory]]",
        )
        println(io, "#endif")
    end
    println(
        io,
        "        static const unsigned long long table[$(t.banks)][$rows][$chunks] = {",
    )
    for bank = 1:(t.banks)
        values = [
            "{$(_kernel_chunks(index <= length(t.values) ? t.values[index] : 0,width))}"
            for index = bank:(t.banks):(rows * t.banks)
        ]
        println(io, "            {", join(values, ","), "},")
    end
    println(io, "        };")
    if toolchain == :vitis
        println(io, "#if defined(__SYNTHESIS__)")
        println(io, "#pragma HLS array_partition variable=table complete dim=1")
        println(io, "#pragma HLS array_partition variable=table complete dim=3")
        println(io, "#endif")
    end
    println(io, "        unsigned row = index.to_uint() / $(t.banks);")
    println(io, "        unsigned bank = index.to_uint() % $(t.banks);")
    if t.unroll
        println(io, "        $type result = $type(0);")
        for bank = 0:(t.banks - 1)
            println(
                io,
                "        if (bank == $bank) result = from_chunks<$type,$width>(table[$bank][row]);",
            )
        end
        println(io, "        return result;")
    else
        println(io, "        return from_chunks<$type,$width>(table[bank][row]);")
    end
    println(io, "    }")
end

function _kernel_node(io, p, i, expression, backend)
    n, f = p.nodes[i], IR.format(p, i)
    type = _kernel_type(f, backend)
    println(io, "    $type n$i() {")
    println(io, "        if (status != Status::ok || ready$i) return value$i;")
    if n isa Union{IR.Select, IR.Guard}
        println(io, "        bool condition = n$(n.condition)();")
        println(io, "        if (status != Status::ok) return value$i;")
        if n isa IR.Select
            println(io, "        value$i = condition ? n$(n.yes)() : n$(n.no)();")
        else
            println(
                io,
                "        if (!condition) { status = Status::domain_rejected; return value$i; }",
            )
            println(io, "        value$i = n$(n.source)();")
        end
    elseif n isa IR.ScaleByInputExponent
        # The interpreter normalizes the input before visiting the source.
        println(io, "        auto arg$(n.input) = n$(n.input)();")
        println(io, "        if (status != Status::ok) return value$i;")
        println(
            io,
            "        long long scale = input_exponent<$(n.divisor)>(arg$(n.input),status);",
        )
        println(io, "        if (status != Status::ok) return value$i;")
        if n.source != n.input
            println(io, "        auto arg$(n.source) = n$(n.source)();")
            println(io, "        if (status != Status::ok) return value$i;")
        end
        println(io, "        value$i = $expression;")
    else
        for ref in unique(IR.refs(n))
            println(io, "        [[maybe_unused]] auto arg$ref = n$ref();")
            println(io, "        if (status != Status::ok) return value$i;")
        end
        println(io, "        value$i = $expression;")
    end
    println(io, "        if (status == Status::ok) ready$i = true;")
    println(io, "        return value$i;")
    println(io, "    }")
end

"""Emit a C++17 vendor fixed kernel with encoded floating interfaces and explicit rejection status.

`toolchain=:generic` uses the supplied public headers. `:vitis` and `:oneapi`
select vendor include paths and guarded memory hints; actual synthesis needs
the corresponding vendor compiler. Fixed arithmetic, IEEE conversions/branches,
normalization and exponent reconstruction are supported. Floating arithmetic is
explicitly unsupported.
"""
function emit_kernel(
    io::IO,
    p::IR.Program;
    name::AbstractString = "evaluator",
    backend::Symbol = :ac_fixed,
    toolchain::Symbol = :generic,
)
    ns = _cpp_name(name)
    _kernel_validate(p, backend, toolchain)
    expressions = [_kernel_expr(p, i, backend) for i in eachindex(p.nodes)]
    inputformat, outputformat = IR.format(p, p.input), IR.format(p)
    intype, outtype =
        _kernel_type(inputformat, backend), _kernel_type(outputformat, backend)
    inputwidth, outputwidth = _kernel_width(inputformat), _kernel_width(outputformat)
    inword = _kernel_type(IR.UIntFormat(inputwidth), backend)
    outword = _kernel_type(IR.UIntFormat(outputwidth), backend)
    include = if toolchain == :oneapi
        """
#if defined(__INTEL_LLVM_COMPILER)
#include <sycl/ext/intel/ac_types/ac_fixed.hpp>
#include <sycl/ext/intel/ac_types/ac_int.hpp>
#else
#include <ac_fixed.h>
#endif
"""
    else
        _cpp_vendor_include(backend; context = "kernel")
    end
    println(
        io,
        """
#pragma once
#include <cstddef>
$include
// PRESAGe fixed arithmetic kernel; backend=$backend, toolchain=$toolchain.
namespace $ns {
template<int Width> using UInt = $(backend == :ap_fixed ? "ap_uint<Width>" : "ac_int<Width,false>");
$(read(joinpath(@__DIR__, "cpp_kernel.hpp"), String))
$(any(f -> f isa FloatFormat,p.types) || any(t -> t.format isa FloatFormat,p.tables) ? read(joinpath(@__DIR__, "cpp_kernel_float.hpp"), String) : "")
using Input = $intype;
using Output = $outtype;
using InputBits = $inword;
using OutputBits = $outword;
struct Result { Output value; Status status; bool valid() const { return status == Status::ok; } };
struct BitsResult { OutputBits bits; Status status; bool valid() const { return status == Status::ok; } };
struct Context {
    Input input;
    Status status = Status::ok;
    explicit Context(const Input& value) : input(value) {}
    template<class Out,class Wide,int Width,bool Signed,int Mode,int Overflow,class Source>
    Out quantize(const Source& source) {
        return kernel_quantize<Out,Wide,Width,Signed,Mode,Overflow>(source,status);
    }
""",
    )
    for (i, t) in enumerate(p.tables)
        _kernel_table(io, i, t, backend, toolchain)
    end
    for (i, f) in enumerate(p.types)
        println(
            io,
            "    bool ready$i = false; $(_kernel_type(f,backend)) value$i = $(_kernel_type(f,backend))(0);",
        )
    end
    for i in eachindex(p.nodes)
        _kernel_node(io, p, i, expressions[i], backend)
    end
    println(
        io,
        """
};
inline Result evaluate(const Input& input) {
    Context context(input);
    Output value = context.n$(p.output)();
    return {context.status == Status::ok ? value : Output(0), context.status};
}
inline BitsResult evaluate_bits(const InputBits& bits) {
    Result result = evaluate(copy_bits<Input,$inputwidth>(bits));
    return {copy_bits<OutputBits,$outputwidth>(result.value), result.status};
}
} // namespace $ns
""",
    )
    return nothing
end

function emit_kernel(io::IO, plan::PlanArtifact; kwargs...)
    plan.program === nothing && throw(ArgumentError("plan has no evaluator"))
    return emit_kernel(io, plan.program; kwargs...)
end

# Render before opening a destination: unsupported graphs leave existing files intact.
function emit_kernel(path::AbstractString, p; kwargs...)
    text = sprint(io -> emit_kernel(io, p; kwargs...))
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
