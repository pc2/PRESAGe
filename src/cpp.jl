_cpp_type(f::FloatFormat) =
    f == IEEE16 ? "Half" :
    f == IEEE32 ? "float" :
    f == IEEE64 ? "double" :
    throw(ArgumentError("CPU emitter supports binary16/binary32/binary64 only"))
_cpp_type(::IR.UIntFormat) = "std::uint64_t"
_cpp_type(::Type{Bool}) = "bool"
_cpp_storage(f::FloatFormat) =
    _width(f) <= 16 ? "std::uint16_t" :
    _width(f) <= 32 ? "std::uint32_t" :
    _width(f) <= 64 ? "std::uint64_t" : "ac_int<$(8cld(_width(f),8)),false>"
_cpp_storage(f::FixedFormat) = f.width <= 64 ? "std::uint64_t" : "Big"
function _cpp_decode_bits(expression, f, backend, float_backend = :native)
    f isa FloatFormat &&
        float_backend == :ac_std_float &&
        return "ac_float_from_bits<$(_cpp_ac_type(f,backend))>($expression)"
    f isa FloatFormat && return "std::bit_cast<$(_cpp_type(f))>($expression)"
    backend != :portable &&
        return "hls_from_bits<$(_cpp_type(f,backend)),$(f.width)>($expression)"
    return "integer_cast<$(_cpp_type(f))>(fixed_units_from_bits($expression,$(f.width),$(f.signed)))"
end
function _cpp_encode_bits(expression, f, backend, float_backend = :native)
    f isa FloatFormat &&
        float_backend == :ac_std_float &&
        return "FloatBits<$(_cpp_ac_type(f,backend))>::bits($expression)"
    f isa FloatFormat && return "std::bit_cast<$(_cpp_storage(f))>($expression)"
    units =
        backend == :portable ? "integer($expression)" :
        "hls_units<$(f.width),$(f.signed)>($expression)"
    return "fixed_bits_from_units<$(_cpp_storage(f))>($units,$(f.width),$(f.signed))"
end
_cpp_hex(bits) = "0x" * string(UInt64(bits); base = 16) * "ULL"
function _cpp_name(name::AbstractString)
    occursin(r"^[A-Za-z][A-Za-z_0-9]*$", name) ||
        throw(ArgumentError("name must be a simple identifier"))
    occursin("__", name) && throw(ArgumentError("reserved identifier"))
    return "presage_" * name
end
function _cpp_constant(bits, f, backend = :portable)
    f isa FixedFormat && return backend == :portable ? _cpp_fixed_constant(bits, f) :
           _cpp_vendor_constant(bits, f, backend)
    f isa FloatFormat &&
        return "std::bit_cast<$(_cpp_type(f))>(static_cast<$(_cpp_storage(f))>($(_cpp_hex(bits))))"
    f == Bool && return bits == 0 ? "false" : "true"
    return _cpp_hex(bits)
end

function _cpp_expr(p, i, backend = :portable)
    n, f = p.nodes[i], IR.format(p, i)
    f == IEEE16 &&
        n isa Union{IR.Mul, IR.Add, IR.FMA, IR.ScalePow2} &&
        throw(
            ArgumentError(
                "binary16 CPU support covers interfaces and conversions; use fixed, binary32 or binary64 arithmetic",
            ),
        )
    call(j) = "n$j()"
    if n isa Union{IR.Mul, IR.Add, IR.FMA, IR.Convert, IR.Quantize, IR.ScalePow2} && (
        f isa FixedFormat ||
        n isa Union{IR.Convert, IR.Quantize} && IR.format(p, n.source) isa FixedFormat
    )
        return backend == :portable ? _cpp_fixed_expr(p, i) :
               _cpp_vendor_expr(p, i, backend)
    end
    if n isa IR.Input
        return _cpp_decode_bits("input", f, backend)
    elseif n isa IR.Const
        return _cpp_constant(n.bits, f, backend)
    elseif n isa IR.TableLoad
        word = "load(table$(n.table),$(call(n.index)))"
        return f isa FloatFormat ?
               "std::bit_cast<$(_cpp_type(f))>(static_cast<$(_cpp_storage(f))>($word))" :
               word
    elseif n isa Union{IR.Mul, IR.Add}
        op = n isa IR.Mul ? "*" : "+"
        return "canonical(static_cast<$(_cpp_type(f))>($(call(n.a)) $op $(call(n.b))))"
    elseif n isa IR.FMA
        return "canonical(std::fma($(call(n.a)),$(call(n.b)),$(call(n.c))))"
    elseif n isa Union{IR.Convert, IR.Quantize}
        return "canonical(static_cast<$(_cpp_type(f))>($(call(n.source))))"
    elseif n isa IR.ScalePow2
        return "canonical(std::ldexp($(call(n.source)),$(n.exponent)))"
    elseif n isa IR.FloatMantissa
        return "normalize_float($(call(n.source))).mantissa"
    elseif n isa IR.ScaleByInputExponent
        exponent = "($(n.multiplier) * normalize_float($(call(n.input))).exponent)"
        source = IR.format(p, n.source)
        if source isa FixedFormat
            units =
                backend == :portable ? call(n.source) :
                "hls_units<$(source.width),$(source.signed)>($(call(n.source)))"
            return "float_from_fixed<$(_cpp_type(f))>($units,std::int64_t($(_fraction(source)))-$exponent,0)"
        end
        return "canonical(static_cast<$(_cpp_type(f))>(std::ldexp(static_cast<double>($(call(n.source))),static_cast<int>($exponent))))"
    elseif n isa IR.CopySign
        return "copy_float_sign($(call(n.source)),$(call(n.sign)))"
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
    elseif n isa IR.Select
        return "($(call(n.condition)) ? $(call(n.yes)) : $(call(n.no)))"
    elseif n isa IR.Guard
        return "([&]() { if (!$(call(n.condition))) throw std::domain_error(\"input outside declared domain\"); return $(call(n.source)); }())"
    elseif n isa IR.BitCast
        if f isa FloatFormat
            return "std::bit_cast<$(_cpp_type(f))>(static_cast<$(_cpp_storage(f))>($(call(n.source))))"
        end
        return "static_cast<std::uint64_t>(std::bit_cast<$(_cpp_storage(IR.format(p,n.source)))>($(call(n.source))))"
    elseif n isa IR.ExtractBits
        return "(($(call(n.source)) >> $(n.offset)) & $(_cpp_hex(IR.mask(f))))"
    elseif n isa IR.BitOp
        op = Dict(
            :bitand => "&",
            :bitor => "|",
            :bitxor => "^",
            :shiftleft => "<<",
            :shiftright => ">>",
        )[n.operation]
        expr = "(($(call(n.a)) $op $(call(n.b))) & $(_cpp_hex(IR.mask(f))))"
        return n.operation in (:shiftleft, :shiftright) ?
               "($(call(n.b)) >= $(f.width) ? 0ULL : $expr)" : expr
    elseif n isa IR.Classify
        source = call(n.source)
        if IR.format(p, n.source) isa FixedFormat
            expression =
                n.kind == :finite ? "true" :
                n.kind == :negative ? "(value < 0)" :
                n.kind == :zero ? "(value == 0)" : "false"
            return "([&]() { [[maybe_unused]] auto value = $source; return $expression; }())"
        end
        if IR.format(p, n.source) == IEEE16
            raw = "($source.bits)"
            return n.kind == :nan ? "(($raw & 0x7fff) > 0x7c00)" :
                   n.kind == :infinity ? "(($raw & 0x7fff) == 0x7c00)" :
                   n.kind == :finite ? "(($raw & 0x7c00) != 0x7c00)" :
                   n.kind == :negative ? "(($raw & 0x8000) != 0)" : "(($raw & 0x7fff) == 0)"
        end
        return n.kind == :nan ? "std::isnan($source)" :
               n.kind == :infinity ? "std::isinf($source)" :
               n.kind == :finite ? "std::isfinite($source)" :
               n.kind == :negative ? "std::signbit($source)" : "($source == 0)"
    end
    throw(ArgumentError("unsupported emitter node"))
end

"""Emit C++20 with portable, ap_fixed or ac_fixed arithmetic and explicit rounding."""
function emit_cpp(
    io::IO,
    p::IR.Program;
    name::AbstractString = "evaluator",
    backend::Symbol = :portable,
    float_backend::Symbol = :auto,
)
    backend in _CPP_BACKENDS ||
        throw(ArgumentError("backend must be portable, ap_fixed or ac_fixed"))
    _resolved_float_backend(p, float_backend) == :ac_std_float &&
        return _emit_cpp_ac(io, p; name, backend)
    ns = _cpp_name(name)
    foreach(f -> _cpp_type(f, backend), p.types)
    foreach(t -> _cpp_type(t.format, backend), p.tables)
    # Validate all expressions before writing the header, including native widths.
    expressions = [_cpp_expr(p, i, backend) for i in eachindex(p.nodes)]
    for n in p.nodes
        hasfield(typeof(n), :rounding) &&
            n.rounding != :nearest_even &&
            n.format isa FloatFormat &&
            !(
                n isa Union{IR.Convert, IR.Quantize} &&
                IR.format(p, n.source) isa FixedFormat
            ) &&
            throw(
                ArgumentError("CPU emitter currently supports nearest-even rounding only"),
            )
    end
    all(f -> !(f isa FixedFormat) || f.width <= typemax(Cint), p.types) ||
        throw(ArgumentError("fixed format exceeds CPU index range"))
    inputformat, outputformat = IR.format(p, p.input), IR.format(p)
    inputtype, outputtype = _cpp_storage(inputformat), _cpp_storage(outputformat)
    rounding_check =
        any(f -> f isa FloatFormat, p.types) && any(
            n ->
                n isa Union{
                    IR.Mul,
                    IR.Add,
                    IR.FMA,
                    IR.Convert,
                    IR.Quantize,
                    IR.ScalePow2,
                    IR.ScaleByInputExponent,
                },
            p.nodes,
        ) ?
        "if (std::fegetround() != FE_TONEAREST) throw std::runtime_error(\"PRESAGe requires FE_TONEAREST\");" :
        ""
    println(
        io,
        """
#pragma once
#include <bit>
#include <cstdint>
#include <cstddef>
#include <cmath>
#include <cfenv>
#include <limits>
#include <stdexcept>
#include <type_traits>
$(_has_fixed(p) ? "#include <gmpxx.h>\n#include <type_traits>\n#include <algorithm>" : "")
$(_has_fixed(p) && backend != :portable ? _cpp_vendor_include(backend) : "")
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
$(any(==(IEEE16),p.types) || any(t -> t.format == IEEE16,p.tables) ? read(joinpath(@__DIR__,"cpp_half.hpp"),String) : "")
$(read(joinpath(@__DIR__,"cpp_float_traits.hpp"),String))
$(read(joinpath(@__DIR__,"cpp_reduction.hpp"),String))
$(_has_fixed(p) ? read(joinpath(@__DIR__,"cpp_fixed.hpp"),String) : "")
$(_has_fixed(p) && backend != :portable ? read(joinpath(@__DIR__,"cpp_vendor.hpp"),String) : "")
template<class T,std::size_t N>
inline T load(const T (&table)[N],std::uint64_t index) {
    if (index >= N) throw std::out_of_range("PRESAGe table index");
    return table[index];
}
struct Context {
    $inputtype input;
    explicit Context($inputtype bits) : input(bits) {
        $(inputformat isa FixedFormat ? "checked_fixed_bits(input,$(inputformat.width));" : "")
    }
""",
    )
    for (i, t) in enumerate(p.tables)
        if t.format isa FixedFormat
            qualifier = backend != :portable || t.format.width > 126 ? "const" : "constexpr"
            println(
                io,
                "    inline static $qualifier $(_cpp_type(t.format,backend)) table$i[] = {",
                join((_cpp_constant(v, t.format, backend) for v in t.values), ","),
                "};",
            )
        else
            println(
                io,
                "    inline static constexpr $(t.format isa FloatFormat ? _cpp_storage(t.format) : "std::uint64_t") table$i[] = {",
                join(_cpp_hex.(collect(t.values)), ","),
                "};",
            )
        end
    end
    for (i, f) in enumerate(p.types)
        println(io, "    bool ready$i = false; $(_cpp_type(f,backend)) value$i{};")
    end
    println(
        io,
        "    $outputtype output_bits() { return $(_cpp_encode_bits("n$(p.output)()",outputformat,backend)); }",
    )
    for (i, f) in enumerate(p.types)
        println(
            io,
            "    $(_cpp_type(f,backend)) n$i() {\n        if (!ready$i) { value$i = $(expressions[i]); ready$i = true; }\n        return value$i;\n    }",
        )
        if f isa FixedFormat
            units =
                backend == :portable ? "integer(value$i)" :
                "hls_units<$(f.width),$(f.signed)>(value$i)"
            println(
                io,
                "    Big bits$i() const {\n        if (!ready$i) return Big(0);\n        Big raw = $units;\n        if (raw < 0) raw += Big(1) << $(f.width);\n        return raw;\n    }",
            )
        end
    end
    println(
        io,
        """
};
inline $outputtype evaluate_bits($inputtype bits) {
    $rounding_check
    Context context{bits};
    return context.output_bits();
}
inline $(_cpp_type(outputformat,backend)) evaluate($(_cpp_type(inputformat,backend)) x) {
    $rounding_check
    Context context{$(_cpp_encode_bits("x",inputformat,backend))};
    return context.n$(p.output)();
}
} // namespace $ns
""",
    )
    return nothing
end
emit_cpp(path::AbstractString, p::IR.Program; kwargs...) =
    open(io -> emit_cpp(io, p; kwargs...), path, "w")

"""Small little-endian binary CPU harness. Truncated input words fail explicitly."""
function emit_harness(
    io::IO,
    p::IR.Program;
    name::AbstractString = "evaluator",
    header::AbstractString = "evaluator.hpp",
)
    occursin(r"^[A-Za-z0-9_.-]+$", header) ||
        throw(ArgumentError("header must be a simple filename"))
    ns = _cpp_name(name)
    infmt, outfmt = IR.format(p, p.input), IR.format(p)
    inbytes, outbytes = _word_bytes(infmt), _word_bytes(outfmt)
    intype = _cpp_storage(infmt)
    inputword = infmt isa FixedFormat && infmt.width > 64 ? "$(ns)::Big" : intype
    outputbyte =
        outfmt isa FixedFormat && outfmt.width > 64 ?
        "static_cast<char>($(ns)::Big((result >> (8*k)) & 0xff).get_ui())" :
        outfmt isa FloatFormat && _width(outfmt) > 64 ?
        "static_cast<char>(static_cast<ac_int<8,false>>(result >> (8*k)).to_uint())" :
        "static_cast<char>((result >> (8*k)) & 0xff)"
    firstload = findfirst(n -> n isa IR.TableLoad, p.nodes)
    index = firstload === nothing ? nothing : p.nodes[firstload].index
    indexword =
        index === nothing ? "" :
        p.types[index].width > 64 ? "context.value$index.to_uint64()" :
        "context.value$index"
    observed =
        index === nothing ? "std::numeric_limits<std::uint64_t>::max()" :
        "(context.ready$index ? $indexword : std::numeric_limits<std::uint64_t>::max())"
    fixed_trace = IOBuffer()
    for (i, f) in enumerate(p.types)
        f isa FixedFormat || continue
        println(
            fixed_trace,
            """
{
    std::cout.put(context.ready$i ? 1 : 0);
    auto raw = context.bits$i();
    for (int byte=0;byte<$(cld(f.width,8));++byte) {
        unsigned value = 0;
        for (int bit=0;bit<8;++bit)
            if (mpz_tstbit(raw.get_mpz_t(),8*byte+bit)) value |= 1U << bit;
        std::cout.put(static_cast<char>(value));
    }
}
""",
        )
    end
    println(
        io,
        """
#include "$header"
#include <iostream>
#include <string>
int main(int argc,char** argv) {
    const bool trace = argc == 2 && std::string(argv[1]) == "--trace-index";
    const bool fixed_trace = argc == 2 && std::string(argv[1]) == "--trace-fixed";
    if (argc > 1 && !trace && !fixed_trace) { std::cerr << "expected --trace-index or --trace-fixed\\n"; return 1; }
    std::fesetround(FE_TONEAREST);
    try {
        while (true) {
            $inputword word = 0;
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
                word |= static_cast<$inputword>(static_cast<unsigned int>(byte)) << (8*k);
            }
            $(ns)::Context context{word};
            auto result = context.output_bits();
            for (int k=0;k<$outbytes;++k) std::cout.put($outputbyte);
            if (trace || fixed_trace) {
                std::uint64_t index = $observed;
                for (int k=0;k<8;++k) std::cout.put(static_cast<char>((index >> (8*k)) & 0xff));
            }
            if (fixed_trace) {
                $(String(take!(fixed_trace)))
            }
            if (!std::cout) throw std::runtime_error("output write failed");
        }
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\\n';
        return 1;
    }
}
""",
    )
end
emit_harness(path::AbstractString, p::IR.Program; kwargs...) =
    open(io -> emit_harness(io, p; kwargs...), path, "w")
