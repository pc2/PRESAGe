const _KERNEL_BACKENDS = (:ap_fixed, :ac_fixed)
const _KERNEL_TOOLCHAINS = (:generic, :vitis, :oneapi)

function _kernel_type(f::IR.UIntFormat, backend)
    1 <= f.width <= _VENDOR_WIDTH_LIMIT ||
        throw(ArgumentError("kernel unsigned width exceeds the 4096-bit vendor limit"))
    return backend == :ap_fixed ? "ap_uint<$(f.width)>" : "ac_int<$(f.width),false>"
end
_kernel_type(f::FixedFormat, backend) = _cpp_type(f, backend)
_kernel_type(::Type{Bool}, backend) = "bool"
_kernel_type(::FloatFormat, backend) = throw(
    ArgumentError("kernel emission currently requires fixed input, output and arithmetic"),
)

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
    width = f.width
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
    elseif n isa Union{IR.Mul, IR.Add, IR.FMA, IR.Convert, IR.Quantize, IR.ScalePow2}
        return _cpp_vendor_expr(
            p,
            i,
            backend;
            call,
            quantizer = "quantize",
            reinterpret = "copy_bits",
        )
    elseif n isa IR.Compare
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
        return "copy_bits<$(_kernel_type(f,backend)),$(f.width)>($(call(n.source)))"
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
        return n.kind == :finite ? "true" :
               n.kind == :negative ? "($(call(n.source)) < 0)" :
               n.kind == :zero ? "($(call(n.source)) == 0)" : "false"
    elseif n isa Union{IR.Select, IR.Guard}
        return "" # Emit explicitly to retain lazy branches and rejection order.
    end
    throw(ArgumentError("unsupported kernel node $(typeof(n))"))
end

function _kernel_table(io, number, t, backend, toolchain)
    rows, chunks = cld(length(t.values), t.banks), cld(t.format.width, 64)
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
            "{$(_kernel_chunks(index <= length(t.values) ? t.values[index] : 0,t.format.width))}"
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
        println(io, "        $type result = 0;")
        for bank = 0:(t.banks - 1)
            println(
                io,
                "        if (bank == $bank) result = from_chunks<$type,$(t.format.width)>(table[$bank][row]);",
            )
        end
        println(io, "        return result;")
    else
        println(
            io,
            "        return from_chunks<$type,$(t.format.width)>(table[bank][row]);",
        )
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

"""Emit a C++17 vendor fixed kernel with exact IR semantics and explicit rejection status.

`toolchain=:generic` uses the supplied public headers. `:vitis` and `:oneapi`
select vendor include paths and guarded memory hints; actual synthesis needs
the corresponding vendor compiler. Floating graphs are explicitly unsupported.
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
    inword = _kernel_type(IR.UIntFormat(inputformat.width), backend)
    outword = _kernel_type(IR.UIntFormat(outputformat.width), backend)
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
// PRESAGe fixed kernel; backend=$backend, toolchain=$toolchain.
namespace $ns {
$(read(joinpath(@__DIR__, "cpp_kernel.hpp"), String))
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
        println(io, "    bool ready$i = false; $(_kernel_type(f,backend)) value$i = 0;")
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
    Result result = evaluate(copy_bits<Input,$(inputformat.width)>(bits));
    return {copy_bits<OutputBits,$(outputformat.width)>(result.value), result.status};
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

"""Emit a host byte-stream adapter for a fixed kernel. `--status` adds one status byte per output."""
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
    infmt isa FixedFormat && outfmt isa FixedFormat ||
        throw(ArgumentError("kernel harness requires fixed interfaces"))
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
            if (byte == $(inbytes-1) && (unsigned(c) >> $(infmt.width-8(inbytes-1))) != 0) {
                std::cerr << "nonzero input padding\\n"; return 3;
            }
            for (int bit = 0; bit < 8 && byte * 8 + bit < $(infmt.width); ++bit)
                input[byte * 8 + bit] = (unsigned(c) >> bit) & 1U;
        }
        BitsResult result = evaluate_bits(input);
        if (!statuses && !result.valid()) {
            std::cerr << "PRESAGe kernel rejected input, status=" << unsigned(result.status) << '\\n'; return 1;
        }
        if (statuses) std::cout.put(static_cast<char>(result.status));
        for (int byte = 0; byte < $outbytes; ++byte) {
            unsigned c = 0;
            for (int bit = 0; bit < 8 && byte * 8 + bit < $(outfmt.width); ++bit)
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
