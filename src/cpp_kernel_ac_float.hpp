// presage:helper arithmetic_float
// Official AC arithmetic operates on the same IEEE payloads as EncodedFloat.
// Adapters retain PRESAGe's canonical NaNs and explicit special-value policy.
template <class T>
inline ac_std_float<T::width, T::exponent_bits> arithmetic_float(const T &value) {
    ac_std_float<T::width, T::exponent_bits> result;
    result.set_data(copy_bits<ac_int<T::width, true>, T::width>(value));
    return result;
}

// presage:helper arithmetic_result
template <class T, class In> inline T arithmetic_result(const In &value) {
    T result = copy_bits<T, T::width>(value.data());
    return result.is_nan() ? float_special<T>(false, true) : result;
}

// presage:helper float_add
template <class T> inline T float_add(const T &a, const T &b) {
    if (a.is_nan() || b.is_nan())
        return float_special<T>(false, true);
    if (a.is_infinite() || b.is_infinite()) {
        bool invalid = a.is_infinite() && b.is_infinite() && a.negative() != b.negative();
        return float_special<T>(a.is_infinite() ? a.negative() : b.negative(), invalid);
    }
    T result = arithmetic_result<T>(
        arithmetic_float(a).template add<AC_RND_CONV, false>(arithmetic_float(b)));
    // Same-format addition cannot round a nonzero exact sum to zero: all
    // operands are multiples of its minimum subnormal. Fix exact-zero signs.
    if (result.is_zero())
        result.bits[T::width - 1] =
            a.is_zero() && b.is_zero() && a.negative() && b.negative();
    return result;
}

// presage:helper float_mul
template <class T> inline T float_mul(const T &a, const T &b) {
    if (a.is_nan() || b.is_nan())
        return float_special<T>(false, true);
    bool negative = a.negative() != b.negative();
    if (a.is_infinite() || b.is_infinite())
        return float_special<T>(negative, a.is_zero() || b.is_zero());
    return arithmetic_result<T>(
        arithmetic_float(a).template mult<AC_RND_CONV, false>(arithmetic_float(b)));
}

// presage:helper float_fma
template <class T> inline T float_fma(const T &a, const T &b, const T &c) {
    if (a.is_nan() || b.is_nan() || c.is_nan())
        return float_special<T>(false, true);
    bool negative = a.negative() != b.negative();
    if (a.is_infinite() || b.is_infinite()) {
        bool invalid =
            a.is_zero() || b.is_zero() || (c.is_infinite() && negative != c.negative());
        return float_special<T>(negative, invalid);
    }
    if (c.is_infinite())
        return float_special<T>(c.negative(), false);
    return arithmetic_result<T>(arithmetic_float(a).template fma<AC_RND_CONV, false>(
        arithmetic_float(b), arithmetic_float(c)));
}

// presage:helper float_reciprocal
template <class T> inline T float_reciprocal(const T &value) {
    if (value.is_nan())
        return float_special<T>(false, true);
    if (value.is_zero())
        return float_special<T>(value.negative(), false);
    if (value.is_infinite()) {
        T result(0);
        result.bits[T::width - 1] = value.negative();
        return result;
    }
    // Construct 1 from its encoded exponent; no native floating conversions.
    T one(0);
    UInt<T::exponent_bits> field = T::bias;
#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)
#pragma unroll
#elif defined(__SYNTHESIS__)
#pragma HLS unroll
#endif
    for (int bit = 0; bit < T::exponent_bits; ++bit)
        one.bits[T::fraction_bits + bit] = bool(field[bit]);
    return arithmetic_result<T>(
        arithmetic_float(one).template div<AC_RND_CONV, false>(arithmetic_float(value)));
}
