// Exact integer helpers for CPU verification of fixed arithmetic.
#if !defined(__SIZEOF_INT128__)
#error "PRESAGe fixed CPU evaluation requires native 128-bit integers"
#endif
using Big = mpz_class;
inline Big integer(const Big& x) { return x; }
template<class T,class U> Big integer(const __gmp_expr<T,U>& x) { return Big(x); }
template<class T> Big integer(T x) {
    bool negative = x < 0;
    __uint128_t magnitude = negative ? -static_cast<__uint128_t>(x) : static_cast<__uint128_t>(x);
    std::uint64_t words[2] = {static_cast<std::uint64_t>(magnitude),static_cast<std::uint64_t>(magnitude >> 64)};
    Big result;
    mpz_import(result.get_mpz_t(),2,-1,sizeof(words[0]),0,0,words);
    return negative ? -result : result;
}
template<class T> T integer_cast(const Big& x) {
    if constexpr (std::is_same_v<T,Big>) return x;
    else {
        Big magnitude = x < 0 ? -x : x;
        std::uint64_t words[2] = {0,0};
        std::size_t count = 0;
        if (mpz_sizeinbase(magnitude.get_mpz_t(),2) > 126) throw std::overflow_error("native integer range");
        mpz_export(words,&count,-1,sizeof(words[0]),0,0,magnitude.get_mpz_t());
        __int128_t value = static_cast<__int128_t>((__uint128_t{words[1]} << 64) | words[0]);
        return static_cast<T>(x < 0 ? -value : value);
    }
}
template<class T> Big checked_fixed_bits(const T& bits,int width) {
    Big raw = integer(bits);
    if (raw < 0 || raw >= (Big(1) << width))
        throw std::invalid_argument("bits exceed fixed format width");
    return raw;
}
template<class T> Big fixed_units_from_bits(const T& bits,int width,bool is_signed) {
    Big raw = checked_fixed_bits(bits,width);
    if (is_signed && mpz_tstbit(raw.get_mpz_t(),width-1)) raw -= Big(1) << width;
    return raw;
}
template<class Word,class T> Word fixed_bits_from_units(const T& value,int width,bool is_signed) {
    Big units = integer(value);
    Big modulus = Big(1) << width;
    Big lower = is_signed ? -(modulus >> 1) : Big(0);
    Big upper = is_signed ? Big((modulus >> 1)-1) : Big(modulus-1);
    if (units < lower || units > upper)
        throw std::invalid_argument("fixed input value exceeds declared format");
    if (units < 0) units += modulus;
    return integer_cast<Word>(units);
}
inline Big rounded_shift(Big x,std::int64_t shift,int mode) {
    if (x == 0) return x;
    if (shift >= 0) return x << static_cast<mp_bitcnt_t>(shift);
    bool negative = x < 0;
    Big magnitude = negative ? -x : x;
    if (magnitude == 0) return magnitude;
    auto bits = mpz_sizeinbase(magnitude.get_mpz_t(),2);
    auto distance = static_cast<std::uint64_t>(-shift);
    Big q = 0;
    bool increment = false;
    if (distance > bits) increment = (mode == 2 && !negative) || (mode == 3 && negative);
    else {
        Big divisor = Big(1) << static_cast<mp_bitcnt_t>(distance);
        q = magnitude / divisor;
        Big remainder = magnitude % divisor;
        if (remainder != 0) {
            increment = mode == 0 ? (2*remainder > divisor || (2*remainder == divisor && mpz_odd_p(q.get_mpz_t()))) :
                (mode == 2 && !negative) || (mode == 3 && negative);
        }
    }
    if (increment) ++q;
    return negative ? -q : q;
}
template<class T,class U> T fixed_round(U value,std::int64_t source_fraction,int width,int fraction,
                                       bool is_signed,int mode,int overflow) {
    Big x = integer(value);
    Big modulus = Big(1) << width;
    Big lower = is_signed ? -(modulus >> 1) : Big(0);
    Big upper = is_signed ? Big((modulus >> 1)-1) : Big(modulus-1);
    std::int64_t shift = std::int64_t(fraction)-source_fraction;
    if (x != 0 && shift >= 0 && std::uint64_t(shift)+mpz_sizeinbase(x.get_mpz_t(),2) > std::uint64_t(width)) {
        if (overflow == 0) throw std::overflow_error("fixed result exceeds declared format");
        if (overflow == 1) return integer_cast<T>(x < 0 ? lower : upper);
        if (shift >= width) return integer_cast<T>(Big(0));
        x %= modulus;
    }
    x = rounded_shift(x,shift,mode);
    if (x < lower || x > upper) {
        if (overflow == 0) throw std::overflow_error("fixed result exceeds declared format");
        if (overflow == 1) x = x < lower ? lower : upper;
        else {
            mpz_mod(x.get_mpz_t(),x.get_mpz_t(),modulus.get_mpz_t());
            if (is_signed && x > upper) x -= modulus;
        }
    }
    return integer_cast<T>(x);
}
template<class T,class Float> T fixed_from_float(Float x,int width,int fraction,bool is_signed,int mode,int overflow,int scale=0) {
    using Word = std::conditional_t<sizeof(Float)==2,std::uint16_t,std::conditional_t<sizeof(Float)==4,std::uint32_t,std::uint64_t>>;
    constexpr int mantissa = sizeof(Float)==2 ? 10 : sizeof(Float)==4 ? 23 : 52;
    constexpr int exponent_bits = sizeof(Float)==2 ? 5 : sizeof(Float)==4 ? 8 : 11;
    constexpr int bias = (1 << (exponent_bits-1))-1;
    Word raw = std::bit_cast<Word>(x);
    Word exponent = (raw >> mantissa) & ((Word(1) << exponent_bits)-1);
    if (exponent == (Word(1) << exponent_bits)-1) throw std::domain_error("fixed conversion requires a finite value");
    Word significand = raw & ((Word(1) << mantissa)-1);
    if (exponent != 0) significand |= Word(1) << mantissa;
    Big value = integer(significand);
    if (raw >> (mantissa+exponent_bits)) value = -value;
    int power = (exponent == 0 ? 1-bias : int(exponent)-bias)-mantissa;
    return fixed_round<T>(value,-std::int64_t(power)-scale,width,fraction,is_signed,mode,overflow);
}
template<class Float,class T> Float float_from_fixed(T value,int fraction,int mode) {
    using Word = std::conditional_t<sizeof(Float)==2,std::uint16_t,std::conditional_t<sizeof(Float)==4,std::uint32_t,std::uint64_t>>;
    constexpr int mantissa = sizeof(Float)==2 ? 10 : sizeof(Float)==4 ? 23 : 52;
    constexpr int exponent_bits = sizeof(Float)==2 ? 5 : sizeof(Float)==4 ? 8 : 11;
    constexpr int bias = (1 << (exponent_bits-1))-1;
    constexpr int emin = 1-bias;
    constexpr Word inf = ((Word(1) << exponent_bits)-1) << mantissa;
    Big signed_value = integer(value);
    bool negative = signed_value < 0;
    Word sign = negative ? Word(1) << (mantissa+exponent_bits) : Word(0);
    Big n = negative ? -signed_value : signed_value;
    if (n == 0) return std::bit_cast<Float>(sign);
    std::int64_t binade = std::int64_t(mpz_sizeinbase(n.get_mpz_t(),2))-1-fraction;
    auto overflow_result = [&]() {
        bool infinity = mode == 0 || (mode == 2 && !negative) || (mode == 3 && negative);
        return std::bit_cast<Float>(Word(sign | (infinity ? inf : inf-1)));
    };
    if (binade > bias) return overflow_result();
    std::int64_t quantum = std::max<std::int64_t>(emin-mantissa,binade-mantissa);
    // Round with the original sign so directed modes choose the right magnitude.
    Big q = rounded_shift(signed_value,-std::int64_t(fraction)-quantum,mode);
    if (q < 0) q = -q;
    if (q >= (Big(1) << (mantissa+1))) { q >>= 1; ++quantum; }
    if (quantum+mantissa > bias) return overflow_result();
    Word word = static_cast<Word>(integer_cast<std::uint64_t>(q));
    if (q >= (Big(1) << mantissa)) word = Word((Word(quantum+mantissa+bias) << mantissa) | (word-(Word(1)<<mantissa)));
    return std::bit_cast<Float>(Word(sign | word));
}
