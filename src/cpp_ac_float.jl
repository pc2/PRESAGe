const _CPP_FLOAT_BACKENDS = (:auto, :native, :ac_std_float)
function _resolved_float_backend(p::IR.Program, mode::Symbol)
    mode in _CPP_FLOAT_BACKENDS ||
        throw(ArgumentError("float_backend must be auto, native or ac_std_float"))
    custom(f) =
        f isa FloatFormat && f ∉ (IEEE16, IEEE32, IEEE64) ||
        f isa IR.UIntFormat && f.width > 64
    needs_ac = any(custom, p.types) || any(t -> custom(t.format), p.tables)
    mode == :native &&
        needs_ac &&
        throw(
            ArgumentError(
                "native backend cannot represent custom floats or wide unsigned words",
            ),
        )
    mode != :auto && return mode
    return needs_ac ? :ac_std_float : :native
end
function _cpp_ac_type(f::FloatFormat, backend)
    8BigInt(cld(_width(f), 8)) <= typemax(Cint) && f.exponent_bits <= 30 || throw(
        ArgumentError("AC CPU format widths must fit C int; exponent bits must be ≤ 30"),
    )
    return "ac_std_float<$(_width(f)),$(f.exponent_bits)>"
end
function _cpp_ac_type(f::IR.UIntFormat, backend)
    f.width <= typemax(Cint) || throw(ArgumentError("AC unsigned CPU width must fit C int"))
    return f.width <= 64 ? "std::uint64_t" : "ac_int<$(f.width),false>"
end
_cpp_ac_type(f, backend) = _cpp_type(f, backend)
_cpp_ac_word(bits, type) =
    bits <= typemax(UInt64) ? "$type($(_cpp_hex(bits)))" :
    "ac_word<$type>(\"$(string(bits;base=16))\")"
function _cpp_ac_constant(bits, f, backend)
    f isa FixedFormat && return _cpp_constant(bits, f, backend)
    f == Bool && return bits == 0 ? "false" : "true"
    raw = _cpp_ac_word(bits, f isa FloatFormat ? _cpp_storage(f) : _cpp_ac_type(f, backend))
    return f isa FloatFormat ? "ac_float_from_bits<$(_cpp_ac_type(f,backend))>($raw)" : raw
end
function _cpp_ac_expr(p, i, backend)
    n, f = p.nodes[i], p.types[i]
    call(j) = "n$j()"
    if n isa Union{IR.Convert, IR.Quantize, IR.ScalePow2}
        source = p.types[n.source]
        if f isa FloatFormat && source isa FloatFormat
            return n isa IR.ScalePow2 ?
                   "ac_float_scale<$(_cpp_ac_type(f,backend)),$(n.exponent)>($(call(n.source)))" :
                   "ac_float_convert<$(_cpp_ac_type(f,backend))>($(call(n.source)))"
        elseif source isa FixedFormat && f isa FloatFormat
            backend == :portable &&
                return "float_from_fixed<$(_cpp_ac_type(f,backend))>($(call(n.source)),$(_fraction(source)),$(_cpp_mode(n.rounding)))"
            return "ac_float_from_fixed<$(_cpp_ac_type(f,backend)),$(source.width),$(source.integer_bits),$(source.signed),$(_cpp_mode(n.rounding))>($(call(n.source)))"
        elseif source isa FloatFormat && f isa FixedFormat
            if backend == :portable
                scale = n isa IR.ScalePow2 ? n.exponent : 0
                return "fixed_from_float<$(_cpp_type(f))>($(call(n.source)),$(f.width),$(_fraction(f)),$(f.signed),$(_cpp_mode(n.rounding)),$(_cpp_overflow(f.overflow)),$scale)"
            end
            integer =
                n isa IR.ScalePow2 ? BigInt(f.integer_bits) - n.exponent : f.integer_bits
            abs(integer) <= _VENDOR_WIDTH_LIMIT || throw(
                ArgumentError(
                    "AC float-to-fixed scale exceeds the 4096-bit CPU scale limit",
                ),
            )
            return "ac_float_to_fixed<$(_cpp_type(f,backend)),$(f.width),$integer,$(f.signed),$(_cpp_mode(n.rounding)),$(_cpp_overflow(f.overflow))>($(call(n.source)))"
        end
    end
    if f isa FixedFormat &&
       n isa Union{IR.Mul, IR.Add, IR.FMA, IR.Convert, IR.Quantize, IR.ScalePow2}
        return backend == :portable ? _cpp_fixed_expr(p, i) :
               _cpp_vendor_expr(p, i, backend)
    elseif n isa IR.Input
        return _cpp_decode_bits("input", f, backend, :ac_std_float)
    elseif n isa IR.Const
        return _cpp_ac_constant(n.bits, f, backend)
    elseif n isa IR.TableLoad
        word = "load(table$(n.table),$(call(n.index)))"
        return f isa FloatFormat ? "ac_float_from_bits<$(_cpp_ac_type(f,backend))>($word)" :
               word
    elseif n isa Union{IR.Mul, IR.Add}
        op = n isa IR.Mul ? "mult" : "add"
        return "canonical($(call(n.a)).template $op<AC_RND_CONV,false>($(call(n.b))))"
    elseif n isa IR.FMA
        return "canonical($(call(n.a)).template fma<AC_RND_CONV,false>($(call(n.b)),$(call(n.c))))"
    elseif n isa IR.FloatMantissa
        return "normalize_float($(call(n.source))).mantissa"
    elseif n isa IR.FloatReciprocal
        one = _cpp_ac_constant(round_ieee(1, f), f, backend)
        return "canonical($one.template div<AC_RND_CONV,false>($(call(n.source))))"
    elseif n isa IR.FloatExponent
        return "$(_cpp_type(f,backend))(input_exponent<1>($(call(n.source))))"
    elseif n isa IR.RootArgument
        return "root_argument<$(_cpp_ac_type(f,backend)),$(n.divisor)>($(call(n.source)))"
    elseif n isa IR.ScaleByInputExponent
        source = p.types[n.source]
        if source isa FloatFormat || backend != :portable
            input = p.types[n.input]
            bound = (BigInt(1) << (input.exponent_bits - 1)) + input.fraction_bits + 2
            bound +=
                source isa FloatFormat ?
                (BigInt(1) << (source.exponent_bits - 1)) + source.fraction_bits :
                source.width
            ndigits(bound; base = 2) + 1 <= 30 || throw(
                ArgumentError("AC reconstruction needs exponent headroom within 30 bits"),
            )
        end
        if source isa FixedFormat
            if backend == :portable
                exponent = "($(n.multiplier) * input_exponent<$(n.divisor)>($(call(n.input))))"
                return "float_from_fixed<$(_cpp_ac_type(f,backend))>($(call(n.source)),std::int64_t($(_fraction(source)))-$exponent,0)"
            end
            return "ac_fixed_reconstruct<$(_cpp_ac_type(f,backend)),$(source.width),$(source.integer_bits),$(source.signed),$(n.multiplier),$(n.divisor)>($(call(n.source)),$(call(n.input)))"
        end
        return "ac_float_reconstruct<$(_cpp_ac_type(f,backend)),$(n.multiplier),$(n.divisor)>($(call(n.source)),$(call(n.input)))"
    elseif n isa IR.ScaleByExponent
        source, ef = p.types[n.source], p.types[n.exponent]
        ef.width <= 32 || throw(ArgumentError("CPU dynamic exponents must fit C int"))
        if source isa FloatFormat || backend != :portable
            source_bound =
                source isa FloatFormat ?
                (BigInt(1) << (source.exponent_bits - 1)) + source.fraction_bits :
                BigInt(source.width)
            bound = (BigInt(1) << (ef.width - 1)) + source_bound + 2
            ndigits(bound; base = 2) + 1 <= 30 || throw(
                ArgumentError("AC dynamic scaling needs exponent headroom within 30 bits"),
            )
        end
        units =
            backend == :portable ? call(n.exponent) :
            "hls_units<$(ef.width),true>($(call(n.exponent)))"
        exponent =
            backend == :portable ? "static_cast<std::int64_t>($units)" :
            "integer_cast<std::int64_t>($units)"
        if source isa FixedFormat
            if backend == :portable
                return "float_from_fixed<$(_cpp_ac_type(f,backend))>($(call(n.source)),std::int64_t($(_fraction(source)))-$exponent,0)"
            end
            return "ac_fixed_scale_by<$(_cpp_ac_type(f,backend)),$(source.width),$(source.integer_bits),$(source.signed),$(ef.width)>($(call(n.source)),$exponent)"
        end
        return "ac_float_scale_by<$(_cpp_ac_type(f,backend)),$(ef.width)>($(call(n.source)),$exponent)"
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
        p.types[n.source] isa FixedFormat &&
            return _cpp_fixed_bitcast(p, n, backend, _cpp_ac_type(f, backend))
        return f isa FloatFormat ?
               "ac_float_from_bits<$(_cpp_ac_type(f,backend))>($(call(n.source)))" :
               "$(_cpp_ac_type(f,backend))(FloatBits<$(_cpp_ac_type(p.types[n.source],backend))>::bits($(call(n.source))))"
    elseif n isa IR.ExtractBits
        return "ac_word_cast<$(_cpp_ac_type(f,backend))>(($(call(n.source)) >> $(n.offset)) & $(_cpp_ac_constant(IR.mask(f),f,backend)))"
    elseif n isa IR.BitOp
        op = Dict(
            :bitand => "&",
            :bitor => "|",
            :bitxor => "^",
            :shiftleft => "<<",
            :shiftright => ">>",
        )[n.operation]
        shift = n.operation in (:shiftleft, :shiftright)
        right = shift && p.types[n.b].width > 64 ? "$(call(n.b)).to_int()" : call(n.b)
        expression = "$(_cpp_ac_type(f,backend))(($(call(n.a)) $op $right) & $(_cpp_ac_constant(IR.mask(f),f,backend)))"
        return shift ?
               "($(call(n.b)) >= $(f.width) ? $(_cpp_ac_type(f,backend))(0) : $expression)" :
               expression
    elseif n isa IR.Classify
        if p.types[n.source] isa FixedFormat
            return _cpp_expr(p, i, backend)
        end
        source = call(n.source)
        return n.kind == :nan ? "$source.isnan()" :
               n.kind == :infinity ? "$source.isinf()" :
               n.kind == :finite ? "$source.isfinite()" :
               n.kind == :negative ? "$source.signbit()" : "(!$source)"
    end
    throw(ArgumentError("unsupported AC floating emitter node"))
end

function _emit_cpp_ac(io, p; name, backend)
    ns = _cpp_name(name)
    foreach(f -> _cpp_ac_type(f, backend), p.types)
    foreach(t -> _cpp_ac_type(t.format, backend), p.tables)
    for n in p.nodes
        hasfield(typeof(n), :rounding) &&
            n.format isa FloatFormat &&
            n.rounding != :nearest_even &&
            !(n isa Union{IR.Convert, IR.Quantize} && p.types[n.source] isa FixedFormat) &&
            throw(
                ArgumentError(
                    "AC floating operations currently require nearest-even rounding",
                ),
            )
        n isa IR.ScalePow2 &&
            n.format isa FloatFormat &&
            n.format.exponent_bits == 30 &&
            throw(
                ArgumentError("AC floating scaling needs exponent headroom below 30 bits"),
            )
    end
    expressions = [_cpp_ac_expr(p, i, backend) for i in eachindex(p.nodes)]
    infmt, outfmt = p.types[p.input], p.types[p.output]
    intype, outtype = _cpp_storage(infmt), _cpp_storage(outfmt)
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
#include <ac_std_float.h>
#if defined(__FAST_MATH__)
#error "PRESAGe requires strict floating semantics"
#endif
$(_has_fixed(p) ? "#include <gmpxx.h>\n#include <algorithm>" : "")
$(_has_fixed(p) && backend != :portable ? _cpp_vendor_include(backend) : "")
namespace $ns {
$(read(joinpath(@__DIR__,"cpp_float_traits.hpp"),String))
$(read(joinpath(@__DIR__,"cpp_reduction.hpp"),String))
$(read(joinpath(@__DIR__,"cpp_ac_float.hpp"),String))
$(_has_fixed(p) ? read(joinpath(@__DIR__,"cpp_fixed.hpp"),String) : "")
$(_has_fixed(p) && backend != :portable ? read(joinpath(@__DIR__,"cpp_vendor.hpp"),String) : "")
template<class T,class Index,std::size_t N> T load(const T (&table)[N],const Index& index) {
    if (index>=N) throw std::out_of_range("table index");
    if constexpr (std::is_integral_v<Index>) return table[index];
    else return table[index.to_uint64()];
}
struct Context {
    $intype input;
    explicit Context($intype bits) : input(bits) {
        $(infmt isa FixedFormat ? "checked_fixed_bits(input,$(infmt.width));" : (_width(infmt) % 8 != 0 || _width(infmt) < 64 && _width(infmt) ∉ (16,32)) ? "if ((input >> $(_width(infmt))) != 0) throw std::invalid_argument(\"bits exceed floating format width\");" : "")
    }
""",
    )
    for (i, table) in enumerate(p.tables)
        f = table.format
        type = f isa FloatFormat ? _cpp_storage(f) : _cpp_ac_type(f, backend)
        values = (
            f isa FloatFormat ? _cpp_ac_word(v, type) : _cpp_ac_constant(v, f, backend) for
            v in table.values
        )
        println(io, "    inline static const $type table$i[] = {", join(values, ","), "};")
    end
    for (i, f) in enumerate(p.types)
        println(io, "    bool ready$i = false; $(_cpp_ac_type(f,backend)) value$i{};")
        println(
            io,
            "    $(_cpp_ac_type(f,backend)) n$i() { if (!ready$i) { value$i = $(expressions[i]); ready$i = true; } return value$i; }",
        )
        if f isa FixedFormat
            units =
                backend == :portable ? "integer(value$i)" :
                "hls_units<$(f.width),$(f.signed)>(value$i)"
            println(
                io,
                "    Big bits$i() const { if (!ready$i) return Big(0); Big raw = $units; if (raw<0) raw += Big(1)<<$(f.width); return raw; }",
            )
        end
    end
    println(
        io,
        """
    $outtype output_bits() { return $(_cpp_encode_bits("n$(p.output)()",outfmt,backend,:ac_std_float)); }
};
inline $outtype evaluate_bits($intype bits) { Context context{bits}; return context.output_bits(); }
inline $(_cpp_ac_type(outfmt,backend)) evaluate($(_cpp_ac_type(infmt,backend)) x) {
    Context context{$(_cpp_encode_bits("x",infmt,backend,:ac_std_float))};
    return context.n$(p.output)();
}
} // namespace $ns
""",
    )
    return nothing
end
