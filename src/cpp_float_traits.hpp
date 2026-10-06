// Raw storage and format metadata, independent of the host floating ABI.
template<class T> int float_exponent_field(const T& word) {
    if constexpr (std::is_integral_v<T>) return static_cast<int>(word);
    else return word.to_int();
}
template<class T> struct FloatBits {
    using Word = std::conditional_t<sizeof(T)==2,std::uint16_t,
                 std::conditional_t<sizeof(T)==4,std::uint32_t,std::uint64_t>>;
    static constexpr int width = sizeof(T)*8;
    static constexpr int fraction = sizeof(T)==2 ? 10 : sizeof(T)==4 ? 23 : 52;
    static constexpr int exponent = sizeof(T)==2 ? 5 : sizeof(T)==4 ? 8 : 11;
    static Word bits(T value) { return std::bit_cast<Word>(value); }
    static T from_bits(Word word) { return std::bit_cast<T>(word); }
};
