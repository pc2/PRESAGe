function _cpp_validate_cpu(p, backend, floats)
    backend in _CPP_BACKENDS ||
        throw(ArgumentError("backend must be portable, ap_fixed or ac_fixed"))
    type =
        floats == :ac_std_float ? f -> _cpp_ac_type(f, backend) : f -> _cpp_type(f, backend)
    foreach(type, p.types)
    foreach(t -> type(t.format), p.tables)
    for n in p.nodes
        hasfield(typeof(n), :rounding) &&
            n.format isa FloatFormat &&
            n.rounding != :nearest_even &&
            !(
                n isa Union{IR.Convert, IR.Quantize} &&
                IR.format(p, n.source) isa FixedFormat
            ) &&
            throw(ArgumentError("CPU floating operations require nearest-even rounding"))
        floats == :ac_std_float &&
            n isa IR.ScalePow2 &&
            n.format isa FloatFormat &&
            n.format.exponent_bits == 30 &&
            throw(
                ArgumentError("AC floating scaling needs exponent headroom below 30 bits"),
            )
    end
    all(f -> !(f isa FixedFormat) || f.width <= typemax(Cint), p.types) ||
        throw(ArgumentError("fixed format exceeds CPU index range"))
end

function _cpp_cpu_support(io, body, p; name, backend, floats, trace, reachable)
    files = ["cpp_policies.hpp", "cpp_cpu_common.hpp"]
    if floats == :native
        push!(files, "cpp_native_float.hpp")
        any(i -> p.types[i] == IEEE16, trace ? eachindex(p.types) : reachable) &&
            push!(files, "cpp_half.hpp")
    end
    append!(files, ["cpp_float_traits.hpp", "cpp_reduction.hpp"])
    floats == :ac_std_float && push!(files, "cpp_ac_float.hpp")
    push!(files, "cpp_fixed.hpp")
    backend == :portable || push!(files, "cpp_vendor.hpp")
    roots = String[]
    extra = ""
    if floats == :native && any(i -> p.types[i] isa FloatFormat, reachable)
        push!(roots, "NativeFloatChecks")
    end
    if trace
        type =
            floats == :ac_std_float ? f -> _cpp_ac_type(f, backend) :
            f -> _cpp_type(f, backend)
        extra =
            "// presage:helper Trace\nusing Trace = EvaluationTrace<\n" *
            join(["    " * type(f) for f in p.types], ",\n") *
            ">;\n"
        if _has_fixed(p)
            units =
                backend == :portable ? "integer(value)" : "hls_units<Width, Signed>(value)"
            extra *=
                "// presage:helper trace_fixed_units\n" *
                "template <int Width, bool Signed, class T> inline Big trace_fixed_units(const T &value) {\n" *
                "    return $units;\n}\n"
            push!(roots, "trace_fixed_units")
        end
    end
    return _cpp_emit_header(io, body, files; name, target = :cpu, extra, roots)
end

function _cpp_cpu_padding(p, floats, word)
    f = IR.format(p, p.input)
    if f isa FixedFormat
        return "checked_fixed_bits($word, $(f.width));"
    elseif floats == :ac_std_float &&
           (_width(f) % 8 != 0 || _width(f) < 64 && _width(f) ∉ (16, 32))
        return "if (($word >> $(_width(f))) != 0) throw std::invalid_argument(\"bits exceed floating format width\");"
    end
    return ""
end

function _cpp_cpu_rounding_check(p, floats, reachable)
    floats == :ac_std_float && return ""
    any(i -> p.types[i] isa FloatFormat, reachable) && any(
        n ->
            n isa Union{
                IR.Mul,
                IR.Add,
                IR.FMA,
                IR.Convert,
                IR.Quantize,
                IR.ScalePow2,
                IR.ScaleByInputExponent,
                IR.ScaleByExponent,
                IR.FloatReciprocal,
            },
        (p.nodes[i] for i in reachable),
    ) || return ""
    return "if (std::fegetround() != FE_TONEAREST) throw std::runtime_error(\"PRESAGe requires FE_TONEAREST\");"
end

"""Emit a C++20 CPU evaluator and optional intermediate tracing.

Helpers are selected from the emitted operations and included directly in the
header. `trace=true` adds intermediate-value instrumentation for local tests;
ordinary output contains no tracing code.
"""
function emit_cpp(
    io::IO,
    p::IR.Program;
    name::AbstractString = "evaluator",
    backend::Symbol = :portable,
    float_backend::Symbol = :auto,
    trace::Bool = false,
)
    ns = _cpp_name(name)
    floats = _resolved_float_backend(p, float_backend)
    _cpp_validate_cpu(p, backend, floats)
    # Validate every operation before writing, including unreachable nodes.
    expression = floats == :ac_std_float ? _cpp_ac_expr : _cpp_expr
    foreach(i -> expression(p, i, backend), eachindex(p.nodes))
    flow, scopes = _cpp_flow(p)
    reachable = _cpp_reachable(flow)
    tables = _cpp_used_tables(p, reachable)
    types = _CppTypes(backend; target = :cpu, floats)
    type = f -> _cpp_alias!(types, f)
    vendor_type = (args...) -> _cpp_vendor_alias!(types, args...)
    foreach(i -> type(p.types[i]), sort!(collect(reachable)))
    foreach(i -> type(p.tables[i].format), sort!(collect(tables)))
    expressions = [
        i in reachable ? expression(p, i, backend; type, vendor_type) : "" for
        i in eachindex(p.nodes)
    ]
    infmt, outfmt = IR.format(p, p.input), IR.format(p)
    input, output = type(infmt), type(outfmt)
    body_io = IOBuffer()
    println(body_io, "\n// PRESAGe CPU evaluator; backend=$backend, floating=$floats.")
    println(body_io, "namespace $ns {\nusing namespace $(ns)_support;\n")
    for (alias, definition) in types.declarations
        println(body_io, "using $alias = $(replace(definition, r",\s*" => ", "));")
    end
    println(body_io, "\nusing Input = $input;\nusing Output = $output;")
    println(
        body_io,
        "using InputBits = $(_cpp_storage(infmt));\nusing OutputBits = $(_cpp_storage(outfmt));",
    )
    for (i, t) in enumerate(p.tables)
        i in tables || continue
        f = t.format
        tabletype = f isa FloatFormat ? _cpp_storage(f) : type(f)
        literal =
            f isa FloatFormat ? _width(f) <= 64 :
            f isa IR.UIntFormat ? f.width <= 64 : backend == :portable && f.width <= 126
        println(
            body_io,
            "\ninline $(literal ? "constexpr" : "const") $tabletype table$i[] = {",
        )
        for bits in t.values
            value = if floats == :ac_std_float
                f isa FloatFormat ? _cpp_ac_word(bits, tabletype) :
                _cpp_ac_constant(bits, f, backend; type)
            else
                f isa FloatFormat || f isa IR.UIntFormat ? _cpp_hex(bits) :
                _cpp_constant(bits, f, backend; type)
            end
            println(body_io, "    $value,")
        end
        println(body_io, "};")
    end
    for i in sort!(collect(flow.constants))
        n = p.nodes[i]
        value =
            floats == :ac_std_float ? _cpp_ac_constant(n.bits, n.format, backend; type) :
            _cpp_constant(n.bits, n.format, backend; type)
        println(
            body_io,
            "\ninline const $(type(n.format)) $(_cpp_value_name(p, i)) = $value;",
        )
    end
    println(
        body_io,
        "\ninline Output evaluate_core([[maybe_unused]] const Input& input$(trace ? ", Trace* trace = nullptr" : "")) {",
    )
    for i in sort!(collect(flow.cached))
        println(body_io, "    bool computed_$(_cpp_value_name(p, i)) = false;")
    end
    _cpp_render_block(body_io, flow, 1, scopes, expressions, types, "    ", trace)
    println(body_io, "    return $(_cpp_value_name(p, p.output));\n}")
    decode = _cpp_decode_bits("bits", infmt, backend, floats; type = _ -> "Input")
    encode = _cpp_encode_bits(
        "result",
        outfmt,
        backend,
        floats;
        type = _ -> "Output",
        storage = _ -> "OutputBits",
    )
    input_bits = _cpp_encode_bits(
        "x",
        infmt,
        backend,
        floats;
        type = _ -> "Input",
        storage = _ -> "InputBits",
    )
    println(
        body_io,
        """

inline OutputBits evaluate_bits(InputBits bits$(trace ? ", Trace* trace = nullptr" : "")) {
    $(_cpp_cpu_rounding_check(p, floats, reachable))
    $(_cpp_cpu_padding(p, floats, "bits"))
    const Input input = $decode;
    const Output result = evaluate_core(input$(trace ? ", trace" : ""));
    return $encode;
}
inline Output evaluate(const Input& x) {
    $(_cpp_cpu_rounding_check(p, floats, reachable))
    const InputBits bits = $input_bits;
    $(_cpp_cpu_padding(p, floats, "bits"))
    const Input input = $decode;
    return evaluate_core(input);
}
} // namespace $ns
""",
    )
    body = String(take!(body_io))
    _cpp_cpu_support(io, body, p; name, backend, floats, trace, reachable)
    return nothing
end

function emit_cpp(
    path::AbstractString,
    p::IR.Program;
    name = "evaluator",
    backend = :portable,
    float_backend = :auto,
    trace = false,
)
    text = sprint(io -> emit_cpp(io, p; name, backend, float_backend, trace))
    write(path, text)
    return nothing
end
