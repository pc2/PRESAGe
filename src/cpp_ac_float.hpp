// Official AC types perform floating arithmetic and rounding. Helpers only
// adapt raw words, canonical NaNs and explicit format conversions.
template<class T> T ac_word(const char* hex) {
    T word = 0;
    for (;*hex;++hex) word = (word << 4) | unsigned(*hex <= '9' ? *hex-'0' : *hex-'a'+10);
    return word;
}
template<class Out,class In> Out ac_word_cast(const In& value) {
    if constexpr (std::is_integral_v<Out> && !std::is_integral_v<In>) return value.to_uint64();
    else return Out(value);
}
template<int W,int E> struct FloatBits<ac_std_float<W,E>> {
    using Word = std::conditional_t<(W<=16),std::uint16_t,
                 std::conditional_t<(W<=32),std::uint32_t,
                 std::conditional_t<(W<=64),std::uint64_t,ac_int<8*((W+7)/8),false>>>>;
    static constexpr int width = W, fraction = W-E-1, exponent = E;
    static Word bits(const ac_std_float<W,E>& value) {
        if constexpr (W<=64) return ac_int<W,false>(value.data()).to_uint64();
        else return ac_int<W,false>(value.data());
    }
    static ac_std_float<W,E> from_bits(const Word& word) {
        ac_int<W,true> raw = 0;
        for (int bit=0;bit<W;++bit) raw[bit] = ((word >> bit) & 1) != 0;
        ac_std_float<W,E> value;
        value.set_data(raw);
        return value;
    }
};
template<class T,class Word> T ac_float_from_bits(const Word& word) {
    return FloatBits<T>::from_bits(typename FloatBits<T>::Word(word));
}
template<int W,int E> ac_std_float<W,E> canonical(ac_std_float<W,E> value) {
    return value.isnan() ? ac_std_float<W,E>::nan() : value;
}
template<class T> auto as_ac_float(const T& value) {
    using F = FloatBits<T>;
    return ac_float_from_bits<ac_std_float<F::width,F::exponent>>(F::bits(value));
}
template<class Out,class In> Out ac_float_convert(const In& value) {
    using F = FloatBits<Out>;
    auto converted = as_ac_float(value).template convert<F::width,F::exponent,AC_RND_CONV>();
    return FloatBits<Out>::from_bits(FloatBits<decltype(converted)>::bits(canonical(converted)));
}
template<class T,int Scale> T ac_float_scale(const T& value) {
    using F = FloatBits<T>;
    constexpr std::int64_t bias = (std::int64_t(1) << (F::exponent-1))-1;
    auto x = as_ac_float(value);
    if (x.isnan() || x.isinf() || !x) return canonical(value);
    if constexpr (std::int64_t(Scale) > 2*bias+F::fraction+2 ||
                  std::int64_t(Scale) < -2*bias-F::fraction-2) {
        auto result = Scale > 0 ? decltype(x)::inf() : decltype(x)::zero();
        result.set_signbit(x.signbit());
        return FloatBits<T>::from_bits(FloatBits<decltype(result)>::bits(result));
    } else {
        constexpr std::uint64_t distance = Scale < 0 ? -std::int64_t(Scale) : Scale;
        constexpr int E = std::bit_width(std::uint64_t(bias)+distance+F::fraction+2)+1;
        static_assert(E<=30,"AC scaling requires a signed int exponent range");
        constexpr int W = 1+E+F::fraction;
        using Wide = ac_std_float<W,E>;
        auto wide = x.template convert<W,E,AC_RND_CONV>();
        ac_int<W,true> raw = ac_int<E,false>((std::int64_t(1) << (E-1))-1+Scale);
        raw <<= F::fraction;
        Wide factor;
        factor.set_data(raw);
        auto product = wide.template mult<AC_RND_CONV,false>(factor);
        return ac_float_convert<T>(product);
    }
}

// Scale an exactly widened value using official AC multiplication and final
// conversion. The caller supplies enough exponent range to keep both factors
// and their product finite and normal; only the final conversion can round.
template<class Out,class Wide> Out ac_scale_exact(const Wide& value,std::int64_t scale) {
    constexpr int M = Wide::mant_bits, E = Wide::e_width;
    constexpr std::int64_t bias = (std::int64_t(1) << (E-1))-1;
    ac_int<Wide::width,true> raw = ac_int<E,false>(bias+scale);
    raw <<= M;
    Wide factor;
    factor.set_data(raw);
    return ac_float_convert<Out>(value.template mult<AC_RND_CONV,false>(factor));
}
template<class Out,int Multiplier,int Divisor,class In,class Input>
Out ac_float_reconstruct(const In& value,const Input& input) {
    using S = FloatBits<In>;
    using I = FloatBits<Input>;
    constexpr std::uint64_t bound = (std::uint64_t(1) << (S::exponent-1)) + S::fraction
                                 + (std::uint64_t(1) << (I::exponent-1)) + I::fraction + 2;
    constexpr int E = std::bit_width(bound)+1;
    static_assert(E<=30,"AC reconstruction needs exponent headroom within 30 bits");
    using Wide = ac_std_float<1+E+S::fraction,E>;
    auto x = as_ac_float(value);
    auto wide = x.template convert<Wide::width,E,AC_RND_CONV>();
    return ac_scale_exact<Out>(wide,Multiplier*input_exponent<Divisor>(input));
}
template<class Out,int Width,int IntegerBits,bool Signed,int Multiplier,int Divisor,class Source,class Input>
Out ac_fixed_reconstruct(const Source& source,const Input& input) {
    using I = FloatBits<Input>;
    constexpr std::uint64_t bound = Width + (std::uint64_t(1) << (I::exponent-1)) + I::fraction + 2;
    constexpr int E = std::bit_width(bound)+1;
    constexpr int M = Width>1 ? Width-1 : 1;
    static_assert(E<=30,"AC reconstruction needs exponent headroom within 30 bits");
    using Wide = ac_std_float<1+E+M,E>;
    ac_fixed<Width,IntegerBits,Signed> exact = 0;
    for (int bit=0;bit<Width;++bit) exact[bit] = bool(source[bit]);
    Wide wide;
    wide.template assign_from<AC_RND_CONV>(exact);
    return ac_scale_exact<Out>(wide,Multiplier*input_exponent<Divisor>(input));
}
template<class Out,int Width,int IntegerBits,bool Signed,int Mode,class Source>
Out ac_float_from_fixed(const Source& source) {
    ac_fixed<Width,IntegerBits,Signed> exact = 0;
    for (int bit=0;bit<Width;++bit) exact[bit] = bool(source[bit]);
    Out result;
    result.template assign_from<Mode==0 ? AC_RND_CONV : AC_TRN_ZERO>(exact);
    if constexpr (Mode==2 || Mode==3) {
        bool away = (Mode==2 && exact>0) || (Mode==3 && exact<0);
        auto recovered = result.template convert_to_ac_fixed<Width,IntegerBits,Signed,AC_TRN_ZERO,AC_WRAP>();
        if (away && recovered != exact) {
            ac_int<Out::width,false> raw = result.data();
            ++raw; // Increasing the sign-magnitude payload moves away from zero.
            result.set_data(ac_int<Out::width,true>(raw));
        }
    }
    return result;
}
template<int Fraction,class T> bool ac_float_fractional(const T& value) {
    constexpr int M = T::mant_bits, E = T::e_width;
    ac_int<M+1,false> significand = value.data();
    significand[M] = false;
    int exponent = ac_int<E,false>(value.data() >> M).to_int();
    if (exponent) significand[M] = true;
    std::int64_t shift = std::int64_t(exponent ? exponent-T::exp_bias : T::min_exp)-M+Fraction;
    if (shift>=0 || !significand) return false;
    if (-shift>M) return true;
    ac_int<M+1,false> mask = -1;
    mask >>= M+1+shift;
    return (significand & mask) != 0;
}
template<class Out,int Width,int IntegerBits,bool Signed,int Mode,int Overflow,class T>
Out ac_float_to_fixed(const T& value) {
    if (!value.isfinite()) throw std::domain_error("fixed conversion requires a finite value");
    constexpr ac_q_mode Q = Mode==0 ? AC_RND_CONV : Mode==1 ? AC_TRN_ZERO : AC_TRN;
    constexpr ac_o_mode O = Overflow==2 ? AC_WRAP : AC_SAT;
    auto rounded = value.template convert_to_ac_fixed<Width+2,IntegerBits+2,true,Q,O>();
    if constexpr (Mode==2) {
        if (ac_float_fractional<Width-IntegerBits>(value)) {
            decltype(rounded) quantum = 0;
            quantum[0] = true;
            rounded += quantum;
        }
    }
    ac_fixed<Width,IntegerBits,Signed> lower = 0, upper = 0;
    for (int bit=0;bit<Width;++bit) {
        lower[bit] = Signed && bit==Width-1;
        upper[bit] = !(Signed && bit==Width-1);
    }
    if constexpr (Overflow==0) {
        if (rounded<lower || rounded>upper)
            throw std::overflow_error("fixed result exceeds declared format");
    }
    if constexpr (Overflow==1) {
        if (rounded<lower) rounded = lower;
        if (rounded>upper) rounded = upper;
    }
    Out result = 0;
    for (int bit=0;bit<Width;++bit) result[bit] = bool(rounded[bit]);
    return result;
}
