const _CPP_BACKENDS = (:portable, :ap_fixed, :ac_fixed)
const _VENDOR_WIDTH_LIMIT = 4096

function _vendor_type(w, i, s, mode, overflow, backend)
    1 <= w <= _VENDOR_WIDTH_LIMIT && abs(BigInt(i)) <= _VENDOR_WIDTH_LIMIT ||
        throw(ArgumentError("vendor intermediate exceeds the 4096-bit CPU limit"))
    prefix = backend == :ap_fixed ? "AP" : "AC"
    # RND_INF means nearest with a particular tie rule, not directed upward.
    quantizer =
        mode == :nearest_even ? "RND_CONV" : mode == :toward_zero ? "TRN_ZERO" : "TRN"
    policy = overflow == :saturate ? "SAT" : "WRAP"
    backend == :ap_fixed &&
        return "ap_$(s ? "" : "u")fixed<$w,$i,$(prefix)_$quantizer,$(prefix)_$policy>"
    return "ac_fixed<$w,$i,$s,$(prefix)_$quantizer,$(prefix)_$policy>"
end
_cpp_type(f, backend) = _cpp_type(f)
_cpp_type(f::FixedFormat, backend) =
    backend == :portable ? _cpp_type(f) :
    _vendor_type(f.width, f.integer_bits, f.signed, f.rounding, f.overflow, backend)

function _cpp_vendor_constant(bits, f, backend)
    return "hls_bits<$(_cpp_type(f,backend)),$(f.width)>(\"$(string(bits;base=16))\")"
end

function _vendor_round(expression, source, f, backend)
    w, i, s = source
    integer = max(i + !s, f.integer_bits + !f.signed) + 1
    wide = _vendor_type(integer + _fraction(f), integer, true, f.rounding, :wrap, backend)
    return "hls_quantize<$(_cpp_type(f,backend)),$wide,$(f.width),$(f.signed),$(_cpp_mode(f.rounding)),$(_cpp_overflow(f.overflow))>($expression)"
end
_vendor_shape(f::FixedFormat) = (f.width, f.integer_bits, f.signed)

function _vendor_float_shape(f::FloatFormat)
    bias = (1 << (f.exponent_bits - 1)) - 1
    fraction = bias - 1 + f.fraction_bits
    integer = bias + 2 # Complete finite range plus a sign bit.
    return (integer + fraction, integer, true)
end

function _cpp_vendor_expr(p, i, backend)
    n, f = p.nodes[i], IR.format(p, i)
    call(j) = "n$j()"
    if n isa Union{IR.Convert, IR.Quantize, IR.ScalePow2}
        source = IR.format(p, n.source)
        if f isa FloatFormat
            units = "hls_units<$(source.width),$(source.signed)>($(call(n.source)))"
            return "float_from_fixed<$(_cpp_type(f))>($units,$(_fraction(source)),$(_cpp_mode(n.rounding)))"
        end
        shape = source isa FloatFormat ? _vendor_float_shape(source) : _vendor_shape(source)
        exponent = n isa IR.ScalePow2 ? n.exponent : 0
        w, integer, signed = shape
        scaled_integer = BigInt(integer) + exponent
        # Scaling reinterprets the exact payload at a new binary point.
        scaled = _vendor_type(w, scaled_integer, signed, :down, :wrap, backend)
        expression = if source isa FloatFormat
            "hls_from_float<$scaled,$(w-integer)>($(call(n.source)))"
        elseif exponent != 0
            "hls_reinterpret<$scaled,$w>($(call(n.source)))"
        else
            call(n.source)
        end
        return _vendor_round(expression, (w, scaled_integer, signed), f, backend)
    end
    a, b = IR.format(p, n.a), IR.format(p, n.b)
    fa, fb = _fraction(a), _fraction(b)
    if n isa IR.Add
        fraction = max(fa, fb)
        integer = max(a.integer_bits + !a.signed, b.integer_bits + !b.signed) + 1
        shape = (integer + fraction, integer, true)
        expression = "($(call(n.a)) + $(call(n.b)))"
    else
        shape = (a.width + b.width, a.integer_bits + b.integer_bits, a.signed || b.signed)
        expression = "($(call(n.a)) * $(call(n.b)))"
        if n isa IR.FMA
            c = IR.format(p, n.c)
            fraction = max(fa + fb, _fraction(c))
            integer = max(shape[2] + !shape[3], c.integer_bits + !c.signed) + 1
            shape = (integer + fraction, integer, true)
            expression = "($expression + $(call(n.c)))"
        end
    end
    # Store the native expression in a full-width, exact temporary before narrowing.
    exact = _vendor_type(shape..., :down, :wrap, backend)
    return _vendor_round("$exact($expression)", shape, f, backend)
end

function _cpp_vendor_include(backend)
    backend == :ac_fixed && return "#include <ac_fixed.h>"
    return """
    #ifndef AP_INT_MAX_W
    #define AP_INT_MAX_W 4096
    #endif
    #if AP_INT_MAX_W < 4096
    #error "PRESAGe ap_fixed CPU evaluation requires AP_INT_MAX_W >= 4096"
    #endif
    // The public simulation repo declares std::complex outside libc++'s inline
    // namespace. PRESAGe uses scalar arithmetic, so skip those specializations.
    #if defined(_LIBCPP_VERSION)
    #define __AP_INT_SPECIAL_H__
    #define __AP_FIXED_SPECIAL_H__
    #endif
    #include <ap_fixed.h>
    """
end
