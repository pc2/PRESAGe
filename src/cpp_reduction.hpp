// Exact magnitude decomposition; no floating operations or host frexp behavior.
template<class T> struct FloatNormalization {
    T mantissa;
    std::int64_t exponent;
};
template<class T> FloatNormalization<T> normalize_float(const T& value) {
    using F = FloatBits<T>;
    using Word = typename F::Word;
    constexpr std::int64_t bias = (std::int64_t(1) << (F::exponent-1))-1;
    const Word mask = (Word(1) << F::fraction)-1;
    const Word raw = F::bits(value);
    const int field = float_exponent_field((raw >> F::fraction) & ((Word(1) << F::exponent)-1));
    Word fraction = raw & mask;
    if (field == (std::int64_t(1) << F::exponent)-1 || (field == 0 && fraction == 0))
        throw std::domain_error("normalization requires a finite nonzero input");
    std::int64_t exponent = field-bias;
    if (field == 0) {
        exponent = 1-bias;
        while ((fraction & (Word(1) << F::fraction)) == 0) {
            fraction = Word(fraction << 1);
            --exponent;
        }
        fraction &= mask;
    }
    Word word = Word((Word(bias) << F::fraction) | fraction);
    return {F::from_bits(word), exponent};
}
template<class T,class Sign> T copy_float_sign(const T& value,const Sign& sign) {
    using F = FloatBits<T>;
    using S = FloatBits<Sign>;
    using Word = typename F::Word;
    const Word mask = Word(1) << (F::width-1);
    const bool negative = ((S::bits(sign) >> (S::width-1)) & 1) != 0;
    return F::from_bits(Word((F::bits(value) & ~mask) | (negative ? mask : Word(0))));
}
template<int Divisor,class T> std::int64_t input_exponent(const T& input) {
    static_assert(Divisor>=1 && Divisor<=3);
    const auto exponent = normalize_float(input).exponent;
    return exponent/Divisor - (exponent%Divisor < 0);
}
template<class Out,int Divisor,class T> Out root_argument(const T& input) {
    static_assert(Divisor==2 || Divisor==3);
    using S = FloatBits<T>;
    using F = FloatBits<Out>;
    using Word = typename F::Word;
    static_assert(F::fraction==S::fraction);
    constexpr std::int64_t bias = (std::int64_t(1) << (F::exponent-1))-1;
    const auto normalized = normalize_float(input);
    const auto raw_remainder = normalized.exponent%Divisor;
    const auto remainder = raw_remainder < 0 ? raw_remainder+Divisor : raw_remainder;
    const Word mask = (Word(1) << F::fraction)-1;
    const Word fraction = Word(S::bits(normalized.mantissa)) & mask;
    return F::from_bits(Word((Word(bias+remainder) << F::fraction) | fraction));
}
