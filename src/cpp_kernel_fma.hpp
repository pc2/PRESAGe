// presage:helper shift_right_jam
template <int Width>
inline UInt<Width> shift_right_jam(const UInt<Width> &value, long long distance) {
    UInt<Width> result = distance >= Width ? UInt<Width>(0) : UInt<Width>(value >> int(distance));
    bool sticky = false;
#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)
#pragma unroll
#elif defined(__SYNTHESIS__)
#pragma HLS unroll
#endif
    for (int bit = 0; bit < Width; ++bit)
        if (bit < distance && value[bit])
            sticky = true;
    result[0] = bool(result[0]) || sticky;
    return result;
}

// presage:helper integer_float_fma
template <class T> inline T integer_float_fma(const T &a, const T &b, const T &c) {
    constexpr int P = T::fraction_bits + 1;
    constexpr int Work = 2 * P + 4;
    bool product_negative = a.negative() != b.negative();
    if (a.is_nan() || b.is_nan() || c.is_nan())
        return float_special<T>(false, true);
    if (a.is_infinite() || b.is_infinite()) {
        bool invalid = a.is_zero() || b.is_zero() ||
                       (c.is_infinite() && c.negative() != product_negative);
        return float_special<T>(product_negative, invalid);
    }
    if (c.is_infinite())
        return c;
    if (a.is_zero() || b.is_zero()) {
        T result = c;
        if (c.is_zero())
            result.bits[T::width - 1] = product_negative && c.negative();
        return result;
    }
    UInt<2 * P> product = a.significand() * b.significand();
    long long product_power = a.power() + b.power();
    if (c.is_zero())
        return dyadic_to_float<T, 2 * P, 0>(product, product_power, product_negative);

    int product_top = highest_bit<2 * P>(product);
    int addend_top = highest_bit<P>(c.significand());
    long long product_binade = product_power + product_top;
    long long addend_binade = c.power() + addend_top;
    long long binade = product_binade > addend_binade ? product_binade : addend_binade;
    // Three low bits preserve exact cancellation when the binades differ by at most one.
    // For larger gaps, a sticky bit lies below every possible rounding position.
    UInt<Work> left = UInt<Work>(product) << (Work - 2 - product_top);
    UInt<Work> right = UInt<Work>(c.significand()) << (Work - 2 - addend_top);
    left = shift_right_jam<Work>(left, binade - product_binade);
    right = shift_right_jam<Work>(right, binade - addend_binade);
    UInt<Work> magnitude;
    bool negative;
    if (product_negative == c.negative()) {
        magnitude = left + right;
        negative = product_negative;
    } else if (left >= right) {
        magnitude = left - right;
        negative = product_negative && left != right;
    } else {
        magnitude = right - left;
        negative = c.negative();
    }
    return dyadic_to_float<T, Work, 0>(magnitude, binade - (Work - 2), negative);
}
