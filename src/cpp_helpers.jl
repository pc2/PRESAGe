# Helpers are explicit source fragments, delimited by `// presage:helper`.
# The marker lists the names a fragment defines. References in the emitted
# evaluator seed a transitive closure over those names; overloads and template
# specializations stay together. This is not a parser for arbitrary C++.
_cpp_code(text) =
    replace(text, r"(?s)//[^\n]*|/\*.*?\*/|\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'" => " ")
_cpp_identifiers(text) =
    Set(m.match for m in eachmatch(r"\b[A-Za-z_][A-Za-z_0-9]*\b", _cpp_code(text)))

function _cpp_helper_fragments(text)
    markers = collect(eachmatch(r"(?m)^// presage:helper ([A-Za-z_0-9 ]+)\n", text))
    isempty(markers) && error("C++ helper source has no fragment markers")
    first(markers).offset == 1 || error("C++ helper source has unmarked content")
    return [
        (;
            names = Set(split(marker.captures[1])),
            text = String(
                SubString(
                    text,
                    marker.offset + sizeof(marker.match),
                    i < length(markers) ? prevind(text, markers[i + 1].offset) :
                    lastindex(text),
                ),
            ),
        ) for (i, marker) in enumerate(markers)
    ]
end

function _cpp_select_helpers(body, files; prelude = "", extra = "", roots = String[])
    fragments = isempty(prelude) ? NamedTuple[] : _cpp_helper_fragments(prelude)
    append!(
        fragments,
        reduce(
            vcat,
            [
                _cpp_helper_fragments(read(joinpath(@__DIR__, file), String)) for
                file in files
            ],
        ),
    )
    isempty(extra) || append!(fragments, _cpp_helper_fragments(extra))
    needed = union(_cpp_identifiers(body), roots)
    selected = falses(length(fragments))
    changed = true
    while changed
        changed = false
        for (i, fragment) in enumerate(fragments)
            selected[i] && continue
            isdisjoint(needed, fragment.names) && continue
            selected[i] = true
            union!(needed, _cpp_identifiers(fragment.text))
            changed = true
        end
    end
    code = join(
        (strip(fragment.text) for (i, fragment) in enumerate(fragments) if selected[i]),
        "\n\n",
    )
    return isempty(code) ? "" : code * "\n"
end

const _CPP_STANDARD_HEADERS = (
    "algorithm" => ("max", "min"),
    "array" => ("array",),
    "bit" => ("bit_cast", "bit_width"),
    "cfenv" => ("fegetround", "fesetround"),
    "cmath" => ("fma", "ldexp", "isnan", "isinf", "isfinite", "signbit"),
    "cstddef" => ("size_t",),
    "cstdint" => ("int64_t", "uint16_t", "uint32_t", "uint64_t"),
    "limits" => ("numeric_limits",),
    "stdexcept" => (
        "invalid_argument",
        "out_of_range",
        "runtime_error",
        "domain_error",
        "overflow_error",
    ),
    "tuple" => ("tuple", "get"),
    "type_traits" => ("conditional_t", "is_integral_v", "is_same_v"),
)

function _cpp_emit_header(
    io,
    body,
    files;
    name,
    target,
    toolchain = :generic,
    prelude = "",
    extra = "",
    roots = String[],
)
    helpers = _cpp_select_helpers(body, files; prelude, extra, roots)
    code = _cpp_code(body * helpers)
    identifiers = _cpp_identifiers(code)
    standard = Set(m.captures[1] for m in eachmatch(r"\bstd::([A-Za-z_0-9]+)", code))
    ap = !isdisjoint(identifiers, ("ap_int", "ap_uint", "ap_fixed", "ap_ufixed"))
    # Initialize libc++ configuration before the AP public-header guard.
    ap && push!(standard, "size_t")
    println(io, "#pragma once")
    for (header, names) in _CPP_STANDARD_HEADERS
        isdisjoint(standard, names) || println(io, "#include <$header>")
    end
    "mpz_class" in identifiers && println(io, "#include <gmpxx.h>")
    ac_fixed = "ac_fixed" in identifiers
    ac_float = "ac_std_float" in identifiers
    ac_int = "ac_int" in identifiers
    ap && println(io, _cpp_vendor_include(:ap_fixed; context = string(target)))
    if ac_fixed || ac_float || ac_int
        if target == :kernel && toolchain == :oneapi
            println(io, "#if defined(__INTEL_LLVM_COMPILER)")
            ac_fixed && println(io, "#include <sycl/ext/intel/ac_types/ac_fixed.hpp>")
            ac_int && println(io, "#include <sycl/ext/intel/ac_types/ac_int.hpp>")
            ac_float && println(io, "#include <sycl/ext/intel/ac_types/ac_std_float.hpp>")
            println(io, "#else")
        end
        ac_fixed && println(io, "#include <ac_fixed.h>")
        ac_int && !ac_fixed && !ac_float && println(io, "#include <ac_int.h>")
        ac_float && println(io, "#include <ac_std_float.h>")
        target == :kernel && toolchain == :oneapi && println(io, "#endif")
    end
    if target == :cpu
        println(
            io,
            "#if defined(__FAST_MATH__)\n#error \"PRESAGe requires strict floating semantics\"\n#endif",
        )
    end
    ns = _cpp_name(name) * "_support"
    println(io, "\nnamespace $ns {\n", helpers, "} // namespace $ns")
    body = replace(body, r"(?m)^[ \t]+$" => "", r"\n{3,}" => "\n\n")
    print(io, body)
    return nothing
end

function _cpp_reachable(flow)
    p = flow.program
    return union(keys(flow.uses), keys(flow.writes), flow.constants, (p.input, p.output))
end

function _cpp_used_tables(p, reachable)
    return Set(p.nodes[i].table for i in reachable if p.nodes[i] isa IR.TableLoad)
end
