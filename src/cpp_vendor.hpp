// Native ap_fixed/ac_fixed arithmetic and quantization. GMP handles host raw
// word transport, tracing and exact IEEE conversion; it does not evaluate the
// native fixed operations.
template<class T,int Width,class Word> T hls_from_bits(const Word& bits) {
    Big raw = checked_fixed_bits(bits,Width);
    T result = 0;
    for (int bit=0;bit<Width;++bit) result[bit] = mpz_tstbit(raw.get_mpz_t(),bit);
    return result;
}
template<class T,int Width> T hls_bits(const char* hex) {
    T result = 0;
    std::size_t length = 0;
    while (hex[length]) ++length;
    int bit = 0;
    while (length && bit < Width) {
        char c = hex[--length];
        unsigned digit = c <= '9' ? unsigned(c-'0') : unsigned(c-'a'+10);
        for (int k=0;k<4 && bit<Width;++k,++bit) result[bit] = (digit >> k) & 1;
    }
    return result;
}
template<class T,int Width,class U> T hls_reinterpret(const U& source) {
    T result = 0;
    for (int bit=0;bit<Width;++bit) result[bit] = bool(source[bit]);
    return result;
}
template<class T,int Width,bool Signed> T hls_limit(bool upper) {
    T result = 0;
    for (int bit=0;bit<Width;++bit)
        result[bit] = upper ? !(Signed && bit==Width-1) : (Signed && bit==Width-1);
    return result;
}
template<class Out,class Wide,int Width,bool Signed,int Mode,int Overflow,class Source>
Out hls_quantize(const Source& source) {
    Wide rounded = source; // The library applies RND_CONV, TRN_ZERO or TRN.
    if constexpr (Mode == 2) {
        if (rounded < source) {
            Wide quantum = 0;
            quantum[0] = 1;
            rounded += quantum;
        }
    }
    if constexpr (Overflow == 0) {
        Wide lower = hls_limit<Out,Width,Signed>(false);
        Wide upper = hls_limit<Out,Width,Signed>(true);
        if (rounded < lower || rounded > upper)
            throw std::overflow_error("fixed result exceeds declared format");
    }
    return Out(rounded); // Native wrap or saturation; rounding is already exact.
}
template<class T,int Fraction,class Float> T hls_from_float(Float x) {
    using Word = std::conditional_t<sizeof(Float)==2,std::uint16_t,std::conditional_t<sizeof(Float)==4,std::uint32_t,std::uint64_t>>;
    constexpr int mantissa = sizeof(Float)==2 ? 10 : sizeof(Float)==4 ? 23 : 52;
    constexpr int exponent_bits = sizeof(Float)==2 ? 5 : sizeof(Float)==4 ? 8 : 11;
    constexpr int bias = (1 << (exponent_bits-1))-1;
    Word raw = std::bit_cast<Word>(x);
    Word exponent = (raw >> mantissa) & ((Word(1) << exponent_bits)-1);
    if (exponent == (Word(1) << exponent_bits)-1)
        throw std::domain_error("fixed conversion requires a finite value");
    Word significand = raw & ((Word(1) << mantissa)-1);
    if (exponent != 0) significand |= Word(1) << mantissa;
    int power = (exponent == 0 ? 1-bias : int(exponent)-bias)-mantissa;
    T result = 0;
    for (int bit=0;bit<=mantissa;++bit)
        if ((significand >> bit) & 1) result[bit+power+Fraction] = 1;
    if (raw >> (mantissa+exponent_bits)) result = -result;
    return result;
}
template<int Width,bool Signed,class T> Big hls_units(const T& value) {
    Big result = 0;
    for (int bit=0;bit<Width;++bit)
        if (value[bit]) mpz_setbit(result.get_mpz_t(),bit);
    if constexpr (Signed) {
        if (value[Width-1]) result -= Big(1) << Width;
    }
    return result;
}
