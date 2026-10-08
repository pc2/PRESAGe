// presage:helper NativeFloatChecks
static_assert(std::numeric_limits<float>::is_iec559 &&
              std::numeric_limits<float>::digits == 24);
static_assert(std::numeric_limits<double>::is_iec559 &&
              std::numeric_limits<double>::digits == 53);

// presage:helper canonical
inline float canonical(float x) {
    return std::isnan(x) ? std::bit_cast<float>(std::uint32_t{0x7fc00000}) : x;
}
inline double canonical(double x) {
    return std::isnan(x) ? std::bit_cast<double>(std::uint64_t{0x7ff8000000000000ULL}) : x;
}
