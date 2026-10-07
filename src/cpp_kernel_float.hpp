// IEEE encodings use vendor integers. This type performs no floating arithmetic.
template <class Word, int E, int M> struct EncodedFloat {
    using Bits = Word;
    static constexpr int width = 1 + E + M, exponent_bits = E, fraction_bits = M;
    static constexpr long long bias = (1LL << (E - 1)) - 1;
    Word bits;
    explicit EncodedFloat(const Word &raw = Word(0)) : bits(raw) {}
    auto operator[](int bit) -> decltype(bits[bit]) { return bits[bit]; }
    bool operator[](int bit) const { return bool(bits[bit]); }
    bool negative() const { return bool(bits[width - 1]); }
    unsigned long long field() const { return UInt<E>(bits >> M).to_uint64(); }
    UInt<M> fraction() const { return UInt<M>(bits); }
    bool is_nan() const { return field() == (1ULL << E) - 1 && fraction() != 0; }
    bool is_infinite() const { return field() == (1ULL << E) - 1 && fraction() == 0; }
    bool is_finite() const { return field() != (1ULL << E) - 1; }
    bool is_zero() const { return field() == 0 && fraction() == 0; }
    UInt<M + 1> significand() const {
        UInt<M + 1> result = fraction();
        result[M] = field() != 0;
        return result;
    }
    long long power() const {
        return (field() ? static_cast<long long>(field()) - bias : 1 - bias) - M;
    }
};

template <int Width> inline int highest_bit(const UInt<Width> &value) {
    int highest = -1;
    for (int bit = 0; bit < Width; ++bit)
        if (value[bit])
            highest = bit;
    return highest;
}

template <class Word> struct ShiftResult {
    Word value;
    bool overflow;
};

// Round unsigned magnitude with its original sign. Large shifts are tested
// before conversion to int; discarded bits are read only at bounded indices.
template <int Work, int SourceWidth, int Mode>
inline ShiftResult<UInt<Work>> rounded_shift(const UInt<SourceWidth> &source,
                                             long long shift, bool negative) {
    static_assert(Work >= SourceWidth, "source magnitude must fit the work word");
    UInt<Work> result = source;
    if (shift >= 0) {
        int top = highest_bit<SourceWidth>(source);
        bool overflow = top >= 0 && shift > Work - 1 - top;
        result = shift >= Work ? UInt<Work>(0) : UInt<Work>(result << int(shift));
        return {result, overflow};
    }
    long long distance = -shift;
    result = distance >= SourceWidth ? UInt<Work>(0) : UInt<Work>(result >> int(distance));
    bool guard = false, sticky = false;
    for (int bit = 0; bit < SourceWidth; ++bit) {
        if (bit == distance - 1)
            guard = bool(source[bit]);
        if (bit < distance - 1 && source[bit])
            sticky = true;
    }
    bool increment = Mode == 0 ? guard && (sticky || bool(result[0]))
                               : (guard || sticky) &&
                                     ((Mode == 2 && !negative) || (Mode == 3 && negative));
    if (increment)
        ++result;
    return {result, false};
}

template <class Out> inline Out float_special(bool negative, bool nan) {
    Out result(0);
    for (int bit = 0; bit < Out::exponent_bits; ++bit)
        result.bits[Out::fraction_bits + bit] = true;
    result.bits[Out::width - 1] = negative && !nan;
    if (nan)
        result.bits[Out::fraction_bits - 1] = true;
    return result;
}

template <class Out, int Mode> inline Out float_overflow(bool negative) {
    Out result = float_special<Out>(negative, false);
    bool infinity = Mode == 0 || (Mode == 2 && !negative) || (Mode == 3 && negative);
    if (!infinity)
        --result.bits;
    return result;
}

template <class Out, int SourceWidth, int Mode>
inline Out dyadic_to_float(const UInt<SourceWidth> &magnitude, long long power,
                           bool negative) {
    constexpr int M = Out::fraction_bits;
    constexpr int Work = SourceWidth > M + 2 ? SourceWidth : M + 2;
    Out result(0);
    result.bits[Out::width - 1] = negative;
    int top = highest_bit<SourceWidth>(magnitude);
    if (top < 0)
        return result;
    long long binade = power + top;
    if (binade > Out::bias)
        return float_overflow<Out, Mode>(negative);
    long long minimum = 1 - Out::bias - M;
    long long quantum = binade - M > minimum ? binade - M : minimum;
    auto rounded =
        rounded_shift<Work, SourceWidth, Mode>(magnitude, power - quantum, negative);
    // With this quantum the result has at most M+2 bits, including one carry.
    if (rounded.value[M + 1]) {
        rounded.value >>= 1;
        ++quantum;
    }
    long long exponent = quantum + M;
    if (exponent > Out::bias)
        return float_overflow<Out, Mode>(negative);
    for (int bit = 0; bit < M; ++bit)
        result.bits[bit] = bool(rounded.value[bit]);
    if (rounded.value[M]) {
        UInt<Out::exponent_bits> field = exponent + Out::bias;
        for (int bit = 0; bit < Out::exponent_bits; ++bit)
            result.bits[M + bit] = bool(field[bit]);
    }
    return result;
}

template <class Out, int Width, int IntegerBits, bool Signed, int Mode, int Overflow,
          int Scale, class In>
inline Out float_to_fixed(const In &value, Status &status) {
    if (!value.is_finite()) {
        status = Status::domain_rejected;
        return Out(0);
    }
    constexpr int SourceWidth = In::fraction_bits + 1;
    constexpr int Work = SourceWidth > Width + 1 ? SourceWidth : Width + 1;
    bool negative = value.negative();
    auto rounded = rounded_shift<Work, SourceWidth, Mode>(
        value.significand(), value.power() + Scale + Width - IntegerBits, negative);
    UInt<Work> bound = 0;
    for (int bit = 0; bit < Width; ++bit) {
        if (negative)
            bound[bit] = Signed && bit == Width - 1;
        else
            bound[bit] = !Signed || bit < Width - 1;
    }
    if (rounded.overflow || rounded.value > bound) {
        if constexpr (Overflow == 0) {
            status = Status::overflow_rejected;
            return Out(0);
        } else if constexpr (Overflow == 1) {
            return limit<Out, Width, Signed>(!negative);
        }
    }
    UInt<Width> raw = rounded.value;
    if (negative)
        raw = -raw;
    return copy_bits<Out, Width>(raw);
}

template <class Out, int Width, int IntegerBits, bool Signed, int Mode, class In>
inline Out fixed_scale(const In &value, long long scale) {
    UInt<Width> magnitude = copy_bits<UInt<Width>, Width>(value);
    bool negative = Signed && bool(value[Width - 1]);
    if (negative) {
        magnitude = ~magnitude;
        ++magnitude;
    }
    return dyadic_to_float<Out, Width, Mode>(magnitude, scale - Width + IntegerBits,
                                             negative);
}

template <class Out, int Width, int IntegerBits, bool Signed, int Mode, int Scale, class In>
inline Out fixed_to_float(const In &value) {
    return fixed_scale<Out, Width, IntegerBits, Signed, Mode>(value, Scale);
}

template <class Out, int Mode, class In>
inline Out float_scale(const In &value, long long scale) {
    if (value.is_nan())
        return float_special<Out>(false, true);
    if (value.is_infinite())
        return float_special<Out>(value.negative(), false);
    return dyadic_to_float<Out, In::fraction_bits + 1, Mode>(
        value.significand(), value.power() + scale, value.negative());
}

template <class Out, int Mode, int Scale, class In>
inline Out float_convert(const In &value) {
    return float_scale<Out, Mode>(value, Scale);
}

template <class In> inline int normalization_top(const In &value, Status &status) {
    if (!value.is_finite() || value.is_zero()) {
        status = Status::domain_rejected;
        return -1;
    }
    return highest_bit<In::fraction_bits + 1>(value.significand());
}

template <int Divisor, class In>
inline long long input_exponent(const In &value, Status &status) {
    static_assert(Divisor >= 1 && Divisor <= 3, "unsupported exponent divisor");
    int top = normalization_top(value, status);
    if (status != Status::ok)
        return 0;
    long long exponent = value.power() + top;
    return exponent / Divisor - (exponent % Divisor < 0);
}

template <class Out, int Divisor, class In>
inline Out normalized_argument(const In &value, Status &status) {
    static_assert(Out::fraction_bits == In::fraction_bits, "normalization must be exact");
    static_assert(Divisor >= 1 && Divisor <= 3, "unsupported exponent divisor");
    int top = normalization_top(value, status);
    if (status != Status::ok)
        return Out(0);
    long long remainder = (value.power() + top) % Divisor;
    if (remainder < 0)
        remainder += Divisor;
    return dyadic_to_float<Out, In::fraction_bits + 1, 0>(value.significand(),
                                                          remainder - top, false);
}

template <class Out, class In> inline Out float_exponent(const In &value, Status &status) {
    return Out(input_exponent<1>(value, status));
}

// A scale beyond Limit gives the same overflow/underflow result as Limit.
// Compare the full signed integer magnitude before narrowing to a scalar.
template <int Width, long long Limit, class In>
inline long long bounded_exponent(const In &value) {
    static_assert(Limit > 0, "positive scale bound required");
    UInt<Width> raw = copy_bits<UInt<Width>, Width>(value);
    bool negative = bool(raw[Width - 1]);
    if (negative) {
        raw = ~raw;
        ++raw;
    }
    constexpr int Work = Width > 63 ? Width : 63;
    UInt<Work> magnitude = raw;
    if (magnitude > UInt<Work>(Limit))
        return negative ? -Limit : Limit;
    long long scale = static_cast<long long>(magnitude.to_uint64());
    return negative ? -scale : scale;
}

template <int Predicate, class T> inline bool float_compare(const T &a, const T &b) {
    if (a.is_nan() || b.is_nan())
        return Predicate == 1;
    bool equal = a.bits == b.bits || (a.is_zero() && b.is_zero());
    bool less = !equal && (a.negative() != b.negative() ? a.negative()
                           : a.negative()               ? a.bits > b.bits
                                                        : a.bits < b.bits);
    if constexpr (Predicate == 0)
        return equal;
    if constexpr (Predicate == 1)
        return !equal;
    if constexpr (Predicate == 2)
        return less;
    if constexpr (Predicate == 3)
        return less || equal;
    if constexpr (Predicate == 4)
        return !less && !equal;
    return !less;
}

template <class T, class Sign> inline T float_copy_sign(T value, const Sign &sign) {
    value.bits[T::width - 1] = sign.negative();
    return value;
}
