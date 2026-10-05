_cpp_type(f::FloatFormat) = f == IEEE32 ? "float" : f == IEEE64 ? "double" :
    throw(ArgumentError("CPU emitter supports binary32/binary64 only"))
_cpp_type(::IR.UIntFormat) = "std::uint64_t"
_cpp_type(::Type{Bool}) = "bool"
_cpp_storage(f::FloatFormat) = f == IEEE32 ? "std::uint32_t" : f == IEEE64 ? "std::uint64_t" :
    throw(ArgumentError("unsupported CPU format"))
_cpp_hex(bits) = "0x"*string(UInt64(bits);base=16)*"ULL"
function _cpp_name(name::AbstractString)
    occursin(r"^[A-Za-z][A-Za-z_0-9]*$",name) || throw(ArgumentError("name must be a simple identifier"))
    occursin("__",name) && throw(ArgumentError("reserved identifier"))
    return "presage_"*name
end
function _cpp_constant(bits,f)
    f isa FixedFormat && return _cpp_fixed_constant(bits,f)
    f isa FloatFormat && return "std::bit_cast<$(_cpp_type(f))>(static_cast<$(_cpp_storage(f))>($(_cpp_hex(bits))))"
    f == Bool && return bits == 0 ? "false" : "true"
    return _cpp_hex(bits)
end

function _cpp_expr(p,i)
    n,f = p.nodes[i],IR.format(p,i)
    call(j) = "n$j()"
    if n isa Union{IR.Mul,IR.Add,IR.FMA,IR.Convert,IR.Quantize,IR.ScalePow2} &&
        (f isa FixedFormat || n isa Union{IR.Convert,IR.Quantize} && IR.format(p,n.source) isa FixedFormat)
        return _cpp_fixed_expr(p,i)
    end
    if n isa IR.Input
        return "std::bit_cast<$(_cpp_type(f))>(input)"
    elseif n isa IR.Const
        return _cpp_constant(n.bits,f)
    elseif n isa IR.TableLoad
        word = "load(table$(n.table),$(call(n.index)))"
        return f isa FloatFormat ? "std::bit_cast<$(_cpp_type(f))>(static_cast<$(_cpp_storage(f))>($word))" : word
    elseif n isa Union{IR.Mul,IR.Add}
        op = n isa IR.Mul ? "*" : "+"
        return "canonical(static_cast<$(_cpp_type(f))>($(call(n.a)) $op $(call(n.b))))"
    elseif n isa IR.FMA
        return "canonical(std::fma($(call(n.a)),$(call(n.b)),$(call(n.c))))"
    elseif n isa Union{IR.Convert,IR.Quantize}
        return "canonical(static_cast<$(_cpp_type(f))>($(call(n.source))))"
    elseif n isa IR.ScalePow2
        return "canonical(std::ldexp($(call(n.source)),$(n.exponent)))"
    elseif n isa IR.Compare
        op = Dict(:eq=>"==",:ne=>"!=",:lt=>"<",:le=>"<=",:gt=>">",:ge=>">=")[n.predicate]
        return "($(call(n.a)) $op $(call(n.b)))"
    elseif n isa IR.Select
        return "($(call(n.condition)) ? $(call(n.yes)) : $(call(n.no)))"
    elseif n isa IR.BitCast
        if f isa FloatFormat
            return "std::bit_cast<$(_cpp_type(f))>(static_cast<$(_cpp_storage(f))>($(call(n.source))))"
        end
        return "static_cast<std::uint64_t>(std::bit_cast<$(_cpp_storage(IR.format(p,n.source)))>($(call(n.source))))"
    elseif n isa IR.ExtractBits
        return "(($(call(n.source)) >> $(n.offset)) & $(_cpp_hex(IR.mask(f))))"
    elseif n isa IR.BitOp
        op = Dict(:bitand=>"&",:bitor=>"|",:bitxor=>"^",:shiftleft=>"<<",:shiftright=>">>")[n.operation]
        expr = "(($(call(n.a)) $op $(call(n.b))) & $(_cpp_hex(IR.mask(f))))"
        return n.operation in (:shiftleft,:shiftright) ? "($(call(n.b)) >= $(f.width) ? 0ULL : $expr)" : expr
    elseif n isa IR.Classify
        source = call(n.source)
        if IR.format(p,n.source) isa FixedFormat
            expression = n.kind == :finite ? "true" : n.kind == :negative ? "(value < 0)" :
                n.kind == :zero ? "(value == 0)" : "false"
            return "([&]() { [[maybe_unused]] auto value = $source; return $expression; }())"
        end
        return n.kind == :nan ? "std::isnan($source)" : n.kind == :infinity ? "std::isinf($source)" :
            n.kind == :finite ? "std::isfinite($source)" : n.kind == :negative ? "std::signbit($source)" :
            "($source == 0)"
    end
    throw(ArgumentError("unsupported emitter node"))
end

"""Emit a portable C++20 header, preserving explicit separate operations and FMA."""
function emit_cpp(io::IO,p::IR.Program;name::AbstractString="evaluator")
    ns = _cpp_name(name)
    foreach(_cpp_type,p.types)
    foreach(t -> _cpp_type(t.format),p.tables)
    for n in p.nodes
        hasfield(typeof(n),:rounding) && n.rounding != :nearest_even && n.format isa FloatFormat &&
            !(n isa Union{IR.Convert,IR.Quantize} && IR.format(p,n.source) isa FixedFormat) &&
            throw(ArgumentError("CPU emitter currently supports nearest-even rounding only"))
    end
    all(f -> !(f isa FixedFormat) || f.width <= typemax(Cint),p.types) ||
        throw(ArgumentError("fixed format exceeds CPU index range"))
    inputformat,outputformat = IR.format(p,p.input),IR.format(p)
    inputtype,outputtype = _cpp_storage(inputformat),_cpp_storage(outputformat)
    println(io,"""
    #pragma once
    #include <bit>
    #include <cstdint>
    #include <cstddef>
    #include <cmath>
    #include <cfenv>
    #include <limits>
    #include <stdexcept>
    $(_has_fixed(p) ? "#include <gmpxx.h>\n#include <type_traits>\n#include <algorithm>" : "")
    namespace $ns {
    static_assert(std::numeric_limits<float>::is_iec559 && std::numeric_limits<float>::digits == 24);
    static_assert(std::numeric_limits<double>::is_iec559 && std::numeric_limits<double>::digits == 53);
    #if defined(__FAST_MATH__)
    #error "PRESAGe requires strict floating semantics"
    #endif
    inline float canonical(float x) {
        return std::isnan(x) ? std::bit_cast<float>(std::uint32_t{0x7fc00000}) : x;
    }
    inline double canonical(double x) {
        return std::isnan(x) ? std::bit_cast<double>(std::uint64_t{0x7ff8000000000000ULL}) : x;
    }
    $(_has_fixed(p) ? read(joinpath(@__DIR__,"cpp_fixed.hpp"),String) : "")
    template<class T,std::size_t N>
    inline T load(const T (&table)[N],std::uint64_t index) {
        if (index >= N) throw std::out_of_range("PRESAGe table index");
        return table[index];
    }
    struct Context {
        $inputtype input;
    """)
    for (i,t) in enumerate(p.tables)
        if t.format isa FixedFormat
            qualifier = t.format.width > 126 ? "const" : "constexpr"
            println(io,"    inline static $qualifier $(_cpp_type(t.format)) table$i[] = {",
                join((_cpp_fixed_constant(v,t.format) for v in t.values),","),"};")
        else
            println(io,"    inline static constexpr std::uint64_t table$i[] = {",join(_cpp_hex.(t.values),","),"};")
        end
    end
    for (i,f) in enumerate(p.types)
        println(io,"    bool ready$i = false; $(_cpp_type(f)) value$i{};")
    end
    for (i,f) in enumerate(p.types)
        println(io,"    $(_cpp_type(f)) n$i() {\n        if (!ready$i) { value$i = $(_cpp_expr(p,i)); ready$i = true; }\n        return value$i;\n    }")
    end
    println(io,"""
    };
    inline $outputtype evaluate_bits($inputtype bits) {
        if (std::fegetround() != FE_TONEAREST) throw std::runtime_error("PRESAGe requires FE_TONEAREST");
        Context context{bits};
        return std::bit_cast<$outputtype>(context.n$(p.output)());
    }
    inline $(_cpp_type(outputformat)) evaluate($(_cpp_type(inputformat)) x) {
        return std::bit_cast<$(_cpp_type(outputformat))>(evaluate_bits(std::bit_cast<$inputtype>(x)));
    }
    } // namespace $ns
    """)
    return nothing
end
emit_cpp(path::AbstractString,p::IR.Program;kwargs...) = open(io -> emit_cpp(io,p;kwargs...),path,"w")

"""Small little-endian binary CPU harness. Truncated input words fail explicitly."""
function emit_harness(io::IO,p::IR.Program;name::AbstractString="evaluator",header::AbstractString="evaluator.hpp")
    occursin(r"^[A-Za-z0-9_.-]+$",header) || throw(ArgumentError("header must be a simple filename"))
    ns = _cpp_name(name)
    inbytes,outbytes = div(_width(IR.format(p,p.input)),8),div(_width(IR.format(p)),8)
    intype = _cpp_storage(IR.format(p,p.input))
    firstload = findfirst(n -> n isa IR.TableLoad,p.nodes)
    index = firstload === nothing ? nothing : p.nodes[firstload].index
    observed = index === nothing ? "std::numeric_limits<std::uint64_t>::max()" :
        "(context.ready$index ? context.value$index : std::numeric_limits<std::uint64_t>::max())"
    println(io,"""
    #include "$header"
    #include <iostream>
    #include <string>
    int main(int argc,char** argv) {
        const bool trace = argc == 2 && std::string(argv[1]) == "--trace-index";
        if (argc > 1 && !trace) { std::cerr << "expected --trace-index\\n"; return 1; }
        std::fesetround(FE_TONEAREST);
        try {
            while (true) {
                std::uint64_t word = 0;
                for (int k=0;k<$inbytes;++k) {
                    int byte = std::cin.get();
                    if (byte == EOF) {
                        if (k == 0 && std::cin.eof() && !std::cin.bad()) {
                            std::cout.flush();
                            if (!std::cout) throw std::runtime_error("output write failed");
                            return 0;
                        }
                        throw std::runtime_error("truncated input word");
                    }
                    word |= std::uint64_t(static_cast<unsigned char>(byte)) << (8*k);
                }
                $(ns)::Context context{static_cast<$intype>(word)};
                auto result = std::bit_cast<$(_cpp_storage(IR.format(p)))>(context.n$(p.output)());
                for (int k=0;k<$outbytes;++k) std::cout.put(static_cast<char>((result >> (8*k)) & 0xff));
                if (trace) {
                    std::uint64_t index = $observed;
                    for (int k=0;k<8;++k) std::cout.put(static_cast<char>((index >> (8*k)) & 0xff));
                }
                if (!std::cout) throw std::runtime_error("output write failed");
            }
        } catch (const std::exception& error) {
            std::cerr << error.what() << '\\n';
            return 1;
        }
    }
    """)
end
emit_harness(path::AbstractString,p::IR.Program;kwargs...) = open(io -> emit_harness(io,p;kwargs...),path,"w")
