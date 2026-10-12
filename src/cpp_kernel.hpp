// presage:helper Status
// Fixed kernel support. All loops have bounds fixed by the generated formats.
enum class Status : unsigned char {
    ok = 0,
    domain_rejected = 1,
    overflow_rejected = 2,
    table_index_rejected = 3
};

// presage:helper copy_bits
template <class T, int Width, class U> inline T copy_bits(const U &source) {
    T result = T(0);
#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)
#pragma unroll
#elif defined(__SYNTHESIS__)
#pragma HLS unroll
#endif
    for (int bit = 0; bit < Width; ++bit)
        result[bit] = bool(source[bit]);
    return result;
}

// presage:helper from_chunks
template <class T, int Width, std::size_t N>
inline T from_chunks(const unsigned long long (&words)[N]) {
    static_assert(N == (Width + 63) / 64, "incorrect constant word count");
    T result = T(0);
#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)
#pragma unroll
#elif defined(__SYNTHESIS__)
#pragma HLS unroll
#endif
    for (int bit = 0; bit < Width; ++bit)
        result[bit] = (words[bit / 64] >> (bit % 64)) & 1ULL;
    return result;
}

// presage:helper limit
template <class T, int Width, bool Signed> inline T limit(bool upper) {
    T result = 0;
#if defined(__INTEL_LLVM_COMPILER) && defined(__SYCL_DEVICE_ONLY__)
#pragma unroll
#elif defined(__SYNTHESIS__)
#pragma HLS unroll
#endif
    for (int bit = 0; bit < Width; ++bit)
        result[bit] = upper ? !(Signed && bit == Width - 1) : (Signed && bit == Width - 1);
    return result;
}

// presage:helper kernel_quantize
template <class Out, class Wide, int Width, bool Signed, int Mode, int Overflow,
          class Source>
inline Out kernel_quantize(const Source &source, Status &status) {
    Wide rounded = source; // Native RND_CONV, TRN_ZERO or TRN, before overflow.
    if constexpr (Mode == 2) {
        if (rounded < source) {
            Wide quantum = 0;
            quantum[0] = 1;
            rounded += quantum;
        }
    }
    if constexpr (Overflow == 0) {
        Wide lower = limit<Out, Width, Signed>(false);
        Wide upper = limit<Out, Width, Signed>(true);
        if (rounded < lower || rounded > upper) {
            status = Status::overflow_rejected;
            return Out(0);
        }
    }
    return Out(rounded); // Native wrap/saturation; rounding is already complete.
}
