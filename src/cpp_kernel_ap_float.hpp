// presage:helper float_fma
template <class T> inline T float_fma(const T &a, const T &b, const T &c) {
    return integer_float_fma(a, b, c);
}

// presage:helper float_add
template <class T> inline T float_add(const T &a, const T &b) {
    T one(typename T::Bits(T::bias) << T::fraction_bits);
    return integer_float_fma(a, one, b);
}

// presage:helper float_mul
template <class T> inline T float_mul(const T &a, const T &b) {
    T zero(0);
    zero.bits[T::width - 1] = a.negative() != b.negative();
    return integer_float_fma(a, b, zero);
}
