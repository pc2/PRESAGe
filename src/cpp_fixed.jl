_cpp_type(f::FixedFormat) = f.width <= 63 ? "std::int64_t" : f.width <= 126 ? "__int128_t" : "Big"
_cpp_mode(mode) = findfirst(==(mode),(:nearest_even,:toward_zero,:up,:down))-1
_cpp_overflow(mode) = findfirst(==(mode),(:reject,:saturate,:wrap))-1
function _cpp_fixed_constant(bits,f::FixedFormat)
    units = _fixed_units(bits,f)
    f.width > 126 && return "Big(\"$units\")"
    f.width <= 63 && return "static_cast<std::int64_t>($(units)LL)"
    mag = abs(units)
    hi,lo = mag>>64,mag & typemax(UInt64)
    text = "((__int128_t{$(hi)ULL} << 64) | __int128_t{$(lo)ULL})"
    return units < 0 ? "(-$text)" : text
end
function _cpp_fixed_round(expression,source_fraction,f,mode)
    return "fixed_round<$(_cpp_type(f))>($expression,$source_fraction,$(f.width),$(_fraction(f)),$(f.signed),$(_cpp_mode(mode)),$(_cpp_overflow(f.overflow)))"
end
function _cpp_fixed_expr(p,i)
    n,f = p.nodes[i],IR.format(p,i)
    call(j) = "n$j()"
    if n isa Union{IR.Convert,IR.Quantize}
        source = IR.format(p,n.source)
        if source isa FloatFormat
            return "fixed_from_float<$(_cpp_type(f))>($(call(n.source)),$(f.width),$(_fraction(f)),$(f.signed),$(_cpp_mode(n.rounding)),$(_cpp_overflow(f.overflow)))"
        elseif f isa FloatFormat
            return "float_from_fixed<$(_cpp_type(f))>($(call(n.source)),$(_fraction(source)),$(_cpp_mode(n.rounding)))"
        end
        return _cpp_fixed_round(call(n.source),_fraction(source),f,n.rounding)
    elseif n isa IR.ScalePow2
        source = IR.format(p,n.source)
        if source isa FloatFormat
            return "fixed_from_float<$(_cpp_type(f))>($(call(n.source)),$(f.width),$(_fraction(f)),$(f.signed),$(_cpp_mode(n.rounding)),$(_cpp_overflow(f.overflow)),$(n.exponent))"
        end
        return _cpp_fixed_round(call(n.source),BigInt(_fraction(source))-n.exponent,f,n.rounding)
    end
    a,b = IR.format(p,n.a),IR.format(p,n.b)
    fa,fb = _fraction(a),_fraction(b)
    source_fraction = n isa IR.Add ? max(fa,fb) : fa+fb
    widths = n isa IR.Add ? [a.width+source_fraction-fa,b.width+source_fraction-fb] : [a.width+b.width]
    if n isa IR.FMA
        c = IR.format(p,n.c)
        source_fraction = max(fa+fb,_fraction(c))
        widths = [a.width+b.width+source_fraction-fa-fb,c.width+source_fraction-_fraction(c)]
    end
    native = maximum(widths)+(n isa IR.Mul ? 0 : 1) <= 126
    promote(j) = native ? "static_cast<__int128_t>($(call(j)))" : "integer($(call(j)))"
    function align(expr,delta)
        delta == 0 && return expr
        return native ? "($expr * (__int128_t{1} << $delta))" : "($expr << $delta)"
    end
    expression = if n isa IR.Add
        "($(align(promote(n.a),source_fraction-fa)) + $(align(promote(n.b),source_fraction-fb)))"
    else
        product = "($(promote(n.a)) * $(promote(n.b)))"
        n isa IR.Mul ? product : "($(align(product,source_fraction-fa-fb)) + $(align(promote(n.c),source_fraction-_fraction(IR.format(p,n.c)))))"
    end
    return _cpp_fixed_round(expression,source_fraction,f,n.rounding)
end
