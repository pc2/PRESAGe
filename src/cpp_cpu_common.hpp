// presage:helper load
template <class T, class Index, std::size_t N>
inline T load(const T (&table)[N], const Index &index) {
    if (index >= N)
        throw std::out_of_range("PRESAGe table index");
    if constexpr (std::is_integral_v<Index>)
        return table[index];
    else
        return table[index.to_uint64()];
}

// presage:helper EvaluationTrace
template <class... Values> struct EvaluationTrace {
    std::array<bool, sizeof...(Values)> visited{};
    std::tuple<Values...> values{};
    template <std::size_t Node> const auto &value() const {
        return std::get<Node - 1>(values);
    }
};

// presage:helper record
template <std::size_t Node, class Trace, class Value>
inline void record(Trace *trace, const Value &value) {
    if (trace) {
        trace->visited[Node - 1] = true;
        std::get<Node - 1>(trace->values) = value;
    }
}
