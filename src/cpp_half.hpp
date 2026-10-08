// presage:helper Half
// Portable binary16 storage and nearest-even IEEE conversions. No host half ABI.
struct Half {
    std::uint16_t bits = 0;
    Half() = default;
    explicit Half(float x);
    explicit Half(double x);
    operator float() const {
        std::uint32_t sign = std::uint32_t(bits & 0x8000) << 16;
        unsigned exponent = (bits >> 10) & 31, fraction = bits & 1023;
        if (exponent == 31)
            return std::bit_cast<float>(sign | 0x7f800000U | (fraction << 13));
        if (exponent == 0) {
            if (fraction == 0)
                return std::bit_cast<float>(sign);
            int power = -14;
            while (fraction < 1024) {
                fraction <<= 1;
                --power;
            }
            return std::bit_cast<float>(sign | (unsigned(power + 127) << 23) |
                                        ((fraction - 1024) << 13));
        }
        return std::bit_cast<float>(sign | ((exponent + 112) << 23) | (fraction << 13));
    }
};
static_assert(sizeof(Half) == 2);

template <class Word, int Mantissa, int ExponentBits> Half half_from_ieee(Word raw) {
    constexpr int bias = (1 << (ExponentBits - 1)) - 1;
    unsigned sign = unsigned(raw >> (Mantissa + ExponentBits)) << 15;
    unsigned exponent = unsigned((raw >> Mantissa) & ((Word(1) << ExponentBits) - 1));
    std::uint64_t significand = raw & ((Word(1) << Mantissa) - 1);
    auto result = [](unsigned bits) { return std::bit_cast<Half>(std::uint16_t(bits)); };
    if (exponent == (1U << ExponentBits) - 1)
        return result(significand ? 0x7e00 : sign | 0x7c00);
    if (exponent != 0)
        significand |= std::uint64_t(1) << Mantissa;
    if (significand == 0)
        return result(sign);
    int power = (exponent == 0 ? 1 - bias : int(exponent) - bias) - Mantissa;
    int binade = int(std::bit_width(significand)) - 1 + power;
    if (binade > 15)
        return result(sign | 0x7c00);
    int quantum = (binade < -14 ? -14 : binade) - 10;
    int shift = quantum - power;
    std::uint64_t units;
    if (shift <= 0)
        units = significand << -shift;
    else if (shift >= 64)
        units = 0; // Source significands have at most 53 bits.
    else {
        units = significand >> shift;
        std::uint64_t remainder = significand & ((std::uint64_t(1) << shift) - 1);
        std::uint64_t midpoint = std::uint64_t(1) << (shift - 1);
        if (remainder > midpoint || (remainder == midpoint && (units & 1)))
            ++units;
    }
    if (units >= 2048) {
        units >>= 1;
        ++quantum;
    }
    if (quantum + 10 > 15)
        return result(sign | 0x7c00);
    unsigned word = unsigned(units);
    if (units >= 1024)
        word = unsigned(quantum + 25) << 10 | (word - 1024);
    return result(sign | word);
}
inline Half::Half(float x)
    : bits(half_from_ieee<std::uint32_t, 23, 8>(std::bit_cast<std::uint32_t>(x)).bits) {}
inline Half::Half(double x)
    : bits(half_from_ieee<std::uint64_t, 52, 11>(std::bit_cast<std::uint64_t>(x)).bits) {}
// presage:helper canonical
inline Half canonical(Half x) {
    return (x.bits & 0x7fff) > 0x7c00 ? std::bit_cast<Half>(std::uint16_t(0x7e00)) : x;
}
