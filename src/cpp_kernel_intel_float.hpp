// presage:helper arithmetic_float
template <class T>
inline ihc::ap_float<T::exponent_bits, T::fraction_bits> arithmetic_float(const T &value) {
    ihc::ap_float<T::exponent_bits, T::fraction_bits> result;
    result.set_bits(value.bits);
    return result;
}

// presage:helper arithmetic_result
template <class T, class In> inline T arithmetic_result(const In &value) {
    T result(value.get_bits());
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
    using F = ihc::ap_float<T::exponent_bits, T::fraction_bits>;
    T result = arithmetic_result<T>(F::template add<
        ihc::fp_config::FP_Accuracy::HIGH, ihc::fp_config::FP_Subnormal::ON>(
        arithmetic_float(a), arithmetic_float(b)));
    if (result.is_zero())
        result.bits[T::width - 1] = a.is_zero() && b.is_zero() && a.negative() && b.negative();
    return result;
}

// presage:helper float_mul
template <class T> inline T float_mul(const T &a, const T &b) {
    if (a.is_nan() || b.is_nan())
        return float_special<T>(false, true);
    bool negative = a.negative() != b.negative();
    if (a.is_infinite() || b.is_infinite())
        return float_special<T>(negative, a.is_zero() || b.is_zero());
    using F = ihc::ap_float<T::exponent_bits, T::fraction_bits>;
    T result = arithmetic_result<T>(F::template mul<
        ihc::fp_config::FP_Accuracy::HIGH, ihc::fp_config::FP_Subnormal::ON>(
        arithmetic_float(a), arithmetic_float(b)));
    if (result.is_zero())
        result.bits[T::width - 1] = negative;
    return result;
}

// presage:helper float_fma
template <class T> inline T float_fma(const T &a, const T &b, const T &c) {
    static_assert((T::exponent_bits == 8 && T::fraction_bits == 23) ||
                  (T::exponent_bits == 11 && T::fraction_bits == 52));
    if (a.is_nan() || b.is_nan() || c.is_nan())
        return float_special<T>(false, true);
    using F = ihc::ap_float<T::exponent_bits, T::fraction_bits>;
    if constexpr (T::width == 32)
        return arithmetic_result<T>(F(sycl::fma(static_cast<float>(arithmetic_float(a)),
            static_cast<float>(arithmetic_float(b)), static_cast<float>(arithmetic_float(c)))));
    else
        return arithmetic_result<T>(F(sycl::fma(static_cast<double>(arithmetic_float(a)),
            static_cast<double>(arithmetic_float(b)), static_cast<double>(arithmetic_float(c)))));
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
    T one(0);
    UInt<T::exponent_bits> field = T::bias;
#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)
#pragma unroll
#elif defined(__SYNTHESIS__)
#pragma HLS unroll
#endif
    for (int bit = 0; bit < T::exponent_bits; ++bit)
        one.bits[T::fraction_bits + bit] = bool(field[bit]);
    using F = ihc::ap_float<T::exponent_bits, T::fraction_bits>;
    return arithmetic_result<T>(F::template div<
        ihc::fp_config::FP_Accuracy::HIGH, ihc::fp_config::FP_Subnormal::ON>(
        arithmetic_float(one), arithmetic_float(value)));
}
