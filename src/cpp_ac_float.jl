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
function _cpp_ac_constant(bits, f, backend; type = f -> _cpp_ac_type(f, backend))
    f isa FixedFormat && return _cpp_constant(bits, f, backend; type)
    f == Bool && return bits == 0 ? "false" : "true"
    raw = _cpp_ac_word(bits, f isa FloatFormat ? _cpp_storage(f) : type(f))
    return f isa FloatFormat ? "ac_float_from_bits<$(type(f))>($raw)" : raw
end
function _cpp_ac_expr(
    p,
    i,
    backend;
    call = j -> _cpp_value_name(p, j),
    type = f -> _cpp_ac_type(f, backend),
    vendor_type = _vendor_type,
)
    n, f = p.nodes[i], p.types[i]
    if n isa Union{IR.Convert, IR.Quantize, IR.ScalePow2}
        source = p.types[n.source]
        if f isa FloatFormat && source isa FloatFormat
            return n isa IR.ScalePow2 ?
                   "ac_float_scale<$(type(f)),$(n.exponent)>($(call(n.source)))" :
                   "ac_float_convert<$(type(f))>($(call(n.source)))"
        elseif source isa FixedFormat && f isa FloatFormat
            backend == :portable &&
                return "float_from_fixed<$(type(f))>($(call(n.source)),$(_fraction(source)),$(_cpp_mode(n.rounding)))"
            return "ac_float_from_fixed<$(type(f)),$(source.width),$(source.integer_bits),$(source.signed),$(_cpp_mode(n.rounding))>($(call(n.source)))"
        elseif source isa FloatFormat && f isa FixedFormat
            if backend == :portable
                scale = n isa IR.ScalePow2 ? n.exponent : 0
                return "fixed_from_float<$(type(f))>($(call(n.source)),$(f.width),$(_fraction(f)),$(f.signed),$(_cpp_mode(n.rounding)),$(_cpp_overflow(f.overflow)),$scale)"
            end
            integer =
                n isa IR.ScalePow2 ? BigInt(f.integer_bits) - n.exponent : f.integer_bits
            abs(integer) <= _VENDOR_WIDTH_LIMIT || throw(
                ArgumentError(
                    "AC float-to-fixed scale exceeds the 4096-bit CPU scale limit",
                ),
            )
            return "ac_float_to_fixed<$(type(f)),$(f.width),$integer,$(f.signed),$(_cpp_mode(n.rounding)),$(_cpp_overflow(f.overflow))>($(call(n.source)))"
        end
    end
    if f isa FixedFormat &&
       n isa Union{IR.Mul, IR.Add, IR.FMA, IR.Convert, IR.Quantize, IR.ScalePow2}
        return backend == :portable ? _cpp_fixed_expr(p, i; call, type) :
               _cpp_vendor_expr(p, i, backend; call, type = vendor_type, outtype = type)
    elseif n isa IR.Input
        return _cpp_decode_bits("input", f, backend, :ac_std_float)
    elseif n isa IR.Const
        return _cpp_value_name(p, i)
    elseif n isa IR.TableLoad
        word = "load(table$(n.table),$(call(n.index)))"
        return f isa FloatFormat ? "ac_float_from_bits<$(type(f))>($word)" : word
    elseif n isa Union{IR.Mul, IR.Add}
        op = n isa IR.Mul ? "mult" : "add"
        return "canonical($(call(n.a)).template $op<AC_RND_CONV,false>($(call(n.b))))"
    elseif n isa IR.FMA
        return "canonical($(call(n.a)).template fma<AC_RND_CONV,false>($(call(n.b)),$(call(n.c))))"
    elseif n isa IR.FloatMantissa
        return "normalize_float($(call(n.source))).mantissa"
    elseif n isa IR.FloatReciprocal
        one = _cpp_ac_constant(round_ieee(1, f), f, backend; type)
        return "canonical($one.template div<AC_RND_CONV,false>($(call(n.source))))"
    elseif n isa IR.FloatExponent
        return "$(type(f))(input_exponent<1>($(call(n.source))))"
    elseif n isa IR.RootArgument
        return "root_argument<$(type(f)),$(n.divisor)>($(call(n.source)))"
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
                exponent = "($(n.multiplier) * scale_$i)"
                return "float_from_fixed<$(type(f))>($(call(n.source)),std::int64_t($(_fraction(source)))-$exponent,0)"
            end
            return "ac_fixed_reconstruct<$(type(f)),$(source.width),$(source.integer_bits),$(source.signed),$(n.multiplier),$(n.divisor)>($(call(n.source)),$(call(n.input)))"
        end
        return "ac_float_reconstruct<$(type(f)),$(n.multiplier),$(n.divisor)>($(call(n.source)),$(call(n.input)))"
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
                return "float_from_fixed<$(type(f))>($(call(n.source)),std::int64_t($(_fraction(source)))-$exponent,0)"
            end
            return "ac_fixed_scale_by<$(type(f)),$(source.width),$(source.integer_bits),$(source.signed),$(ef.width)>($(call(n.source)),$exponent)"
        end
        return "ac_float_scale_by<$(type(f)),$(ef.width)>($(call(n.source)),$exponent)"
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
        return ""
    elseif n isa IR.Guard
        return ""
    elseif n isa IR.BitCast
        p.types[n.source] isa FixedFormat &&
            return _cpp_fixed_bitcast(p, n, backend, type(f); call)
        return f isa FloatFormat ? "ac_float_from_bits<$(type(f))>($(call(n.source)))" :
               "$(type(f))(FloatBits<$(type(p.types[n.source]))>::bits($(call(n.source))))"
    elseif n isa IR.ExtractBits
        return "ac_word_cast<$(type(f))>(($(call(n.source)) >> $(n.offset)) & $(_cpp_ac_constant(IR.mask(f),f,backend;type)))"
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
        expression = "$(type(f))(($(call(n.a)) $op $right) & $(_cpp_ac_constant(IR.mask(f),f,backend;type)))"
        return shift ? "($(call(n.b)) >= $(f.width) ? $(type(f))(0) : $expression)" :
               expression
    elseif n isa IR.Classify
        if p.types[n.source] isa FixedFormat
            return _cpp_expr(p, i, backend; call, type, vendor_type)
        end
        source = call(n.source)
        return n.kind == :nan ? "$source.isnan()" :
               n.kind == :infinity ? "$source.isinf()" :
               n.kind == :finite ? "$source.isfinite()" :
               n.kind == :negative ? "$source.signbit()" : "(!$source)"
    end
    throw(ArgumentError("unsupported AC floating emitter node"))
end
