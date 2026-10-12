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
function _cpp_decode_bits(
    expression,
    f,
    backend,
    float_backend = :native;
    type = f ->
        float_backend == :ac_std_float ? _cpp_ac_type(f, backend) : _cpp_type(f, backend),
)
    f isa FloatFormat &&
        float_backend == :ac_std_float &&
        return "ac_float_from_bits<$(type(f))>($expression)"
    f isa FloatFormat && return "std::bit_cast<$(type(f))>($expression)"
    backend != :portable && return "hls_from_bits<$(type(f)),$(f.width)>($expression)"
    return "integer_cast<$(type(f))>(fixed_units_from_bits($expression,$(f.width),$(f.signed)))"
end
function _cpp_encode_bits(
    expression,
    f,
    backend,
    float_backend = :native;
    type = f ->
        float_backend == :ac_std_float ? _cpp_ac_type(f, backend) : _cpp_type(f, backend),
    storage = _cpp_storage,
)
    f isa FloatFormat &&
        float_backend == :ac_std_float &&
        return "FloatBits<$(type(f))>::bits($expression)"
    f isa FloatFormat && return "std::bit_cast<$(storage(f))>($expression)"
    units =
        backend == :portable ? "integer($expression)" :
        "hls_units<$(f.width),$(f.signed)>($expression)"
    return "fixed_bits_from_units<$(storage(f))>($units,$(f.width),$(f.signed))"
end
_cpp_hex(bits) = "0x" * string(UInt64(bits); base = 16) * "ULL"
function _cpp_fixed_bitcast(p, n, backend, word_type; call = j -> _cpp_value_name(p, j))
    source = IR.format(p, n.source)
    units =
        backend == :portable ? "integer($(call(n.source)))" :
        "hls_units<$(source.width),$(source.signed)>($(call(n.source)))"
    return "fixed_bits_from_units<$word_type>($units,$(source.width),$(source.signed))"
end
function _cpp_name(name::AbstractString)
    occursin(r"^[A-Za-z][A-Za-z_0-9]*$", name) ||
        throw(ArgumentError("name must be a simple identifier"))
    occursin("__", name) && throw(ArgumentError("reserved identifier"))
    return "presage_" * name
end
function _cpp_constant(bits, f, backend = :portable; type = f -> _cpp_type(f, backend))
    f isa FixedFormat && return backend == :portable ? _cpp_fixed_constant(bits, f) :
           _cpp_vendor_constant(bits, f, backend; type)
    f isa FloatFormat &&
        return "std::bit_cast<$(type(f))>(static_cast<$(_cpp_storage(f))>($(_cpp_hex(bits))))"
    f == Bool && return bits == 0 ? "false" : "true"
    return _cpp_hex(bits)
end

function _cpp_expr(
    p,
    i,
    backend = :portable;
    call = j -> _cpp_value_name(p, j),
    type = f -> _cpp_type(f, backend),
    vendor_type = _vendor_type,
)
    n, f = p.nodes[i], IR.format(p, i)
    f == IEEE16 &&
        n isa Union{IR.Mul, IR.Add, IR.FMA, IR.ScalePow2, IR.FloatReciprocal} &&
        throw(
            ArgumentError(
                "binary16 CPU support covers interfaces and conversions; use fixed, binary32 or binary64 arithmetic",
            ),
        )
    if n isa Union{IR.Mul, IR.Add, IR.FMA, IR.Convert, IR.Quantize, IR.ScalePow2} && (
        f isa FixedFormat ||
        n isa Union{IR.Convert, IR.Quantize} && IR.format(p, n.source) isa FixedFormat
    )
        return backend == :portable ? _cpp_fixed_expr(p, i; call, type) :
               _cpp_vendor_expr(p, i, backend; call, type = vendor_type, outtype = type)
    end
    if n isa IR.Input
        return _cpp_decode_bits("input", f, backend)
    elseif n isa IR.Const
        return _cpp_value_name(p, i)
    elseif n isa IR.TableLoad
        word = "load(table$(n.table),$(call(n.index)))"
        return f isa FloatFormat ?
               "std::bit_cast<$(type(f))>(static_cast<$(_cpp_storage(f))>($word))" : word
    elseif n isa Union{IR.Mul, IR.Add}
        op = n isa IR.Mul ? "*" : "+"
        return "canonical(static_cast<$(type(f))>($(call(n.a)) $op $(call(n.b))))"
    elseif n isa IR.FMA
        return "canonical(std::fma($(call(n.a)),$(call(n.b)),$(call(n.c))))"
    elseif n isa Union{IR.Convert, IR.Quantize}
        return "canonical(static_cast<$(type(f))>($(call(n.source))))"
    elseif n isa IR.ScalePow2
        return "canonical(std::ldexp($(call(n.source)),$(n.exponent)))"
    elseif n isa IR.FloatMantissa
        return "normalize_float($(call(n.source))).mantissa"
    elseif n isa IR.FloatReciprocal
        return "canonical($(type(f))(1) / $(call(n.source)))"
    elseif n isa IR.FloatExponent
        return "$(type(f))(input_exponent<1>($(call(n.source))))"
    elseif n isa IR.RootArgument
        return "root_argument<$(type(f)),$(n.divisor)>($(call(n.source)))"
    elseif n isa IR.ScaleByInputExponent
        exponent = "($(n.multiplier) * scale_$i)"
        source = IR.format(p, n.source)
        if source isa FixedFormat
            units =
                backend == :portable ? call(n.source) :
                "hls_units<$(source.width),$(source.signed)>($(call(n.source)))"
            return "float_from_fixed<$(type(f))>($units,std::int64_t($(_fraction(source)))-$exponent,0)"
        end
        return "canonical(static_cast<$(type(f))>(std::ldexp(static_cast<double>($(call(n.source))),static_cast<int>($exponent))))"
    elseif n isa IR.ScaleByExponent
        ef = IR.format(p, n.exponent)
        ef.width <= 32 ||
            throw(ArgumentError("native CPU dynamic exponents must fit C int"))
        units(j, format) =
            backend == :portable ? call(j) :
            "hls_units<$(format.width),$(format.signed)>($(call(j)))"
        exponent =
            backend == :portable ? "static_cast<std::int64_t>($(units(n.exponent, ef)))" :
            "integer_cast<std::int64_t>($(units(n.exponent, ef)))"
        source = IR.format(p, n.source)
        if source isa FixedFormat
            return "float_from_fixed<$(type(f))>($(units(n.source, source)),std::int64_t($(_fraction(source)))-$exponent,0)"
        end
        return "float_reconstruct<$(type(f))>($(call(n.source)),$exponent)"
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
        return "" # Structured flow preserves lazy branches.
    elseif n isa IR.Guard
        return ""
    elseif n isa IR.BitCast
        f isa FixedFormat && return _cpp_decode_bits(call(n.source), f, backend; type)
        IR.format(p, n.source) isa FixedFormat &&
            return _cpp_fixed_bitcast(p, n, backend, type(f); call)
        if f isa FloatFormat
            return "std::bit_cast<$(type(f))>(static_cast<$(_cpp_storage(f))>($(call(n.source))))"
        end
        return "static_cast<std::uint64_t>(std::bit_cast<$(_cpp_storage(IR.format(p,n.source)))>($(call(n.source))))"
    elseif n isa IR.ExtractBits
        return "(($(call(n.source)) >> $(n.offset)) & $(_cpp_hex(IR.mask(f))))"
    elseif n isa IR.UIntAdd
        return "(($(call(n.a)) + $(call(n.b))) & $(_cpp_hex(IR.mask(f))))"
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
            return replace(expression, "value" => source)
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

"""Little-endian CPU harness. Match `trace=true` with an instrumented evaluator."""
function emit_harness(
    io::IO,
    p::IR.Program;
    name::AbstractString = "evaluator",
    header::AbstractString = "evaluator.hpp",
    trace::Bool = false,
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
        p.types[index].width > 64 ? "observations.value<$index>().to_uint64()" :
        "observations.value<$index>()"
    observed =
        index === nothing ? "std::numeric_limits<std::uint64_t>::max()" :
        "(observations.visited[$(index - 1)] ? $indexword : std::numeric_limits<std::uint64_t>::max())"
    fixed_trace = IOBuffer()
    for (i, f) in enumerate(p.types)
        trace || break
        f isa FixedFormat || continue
        println(
            fixed_trace,
            """
{
    std::cout.put(observations.visited[$(i - 1)] ? 1 : 0);
    auto raw = observations.visited[$(i - 1)]
        ? $(ns)::trace_fixed_units<$(f.width),$(f.signed)>(observations.value<$i>())
        : $(ns)::Big(0);
    if (raw < 0) raw += $(ns)::Big(1) << $(f.width);
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
    trace_setup =
        trace ?
        """
    const bool trace = argc == 2 && std::string(argv[1]) == "--trace-index";
    const bool fixed_trace = argc == 2 && std::string(argv[1]) == "--trace-fixed";
    if (argc > 1 && !trace && !fixed_trace) { std::cerr << "expected --trace-index or --trace-fixed\\n"; return 1; }
""" :
        "if (argc != 1) { std::cerr << \"this harness takes no arguments\\n\"; return 1; }"
    evaluation =
        trace ?
        """
            $(ns)::Trace observations;
            auto result = $(ns)::evaluate_bits(word, (trace || fixed_trace) ? &observations : nullptr);
""" : "auto result = $(ns)::evaluate_bits(word);"
    observations =
        trace ?
        """
            if (trace || fixed_trace) {
                std::uint64_t index = $observed;
                for (int k=0;k<8;++k) std::cout.put(static_cast<char>((index >> (8*k)) & 0xff));
            }
            if (fixed_trace) {
                $(String(take!(fixed_trace)))
            }
""" : ""
    println(
        io,
        """
#include "$header"
#include <cfenv>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>
int main(int argc,[[maybe_unused]] char** argv) {
    $trace_setup
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
            $evaluation
            for (int k=0;k<$outbytes;++k) std::cout.put($outputbyte);
            $observations
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
