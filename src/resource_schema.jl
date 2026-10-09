_resource_number_data(x::Integer) =
    typemin(Int64) <= x <= typemax(Int64) ? Int64(x) : string(x)
_resource_number_data(x::Rational) =
    denominator(x) == 1 ? _resource_number_data(numerator(x)) : _rational_text(x)

function _resource_formula_data(formula)
    return Dict(
        string(name) => _resource_number_data(getfield(formula, name)) for
        name in fieldnames(ResourceFormula) if getfield(formula, name) != 0
    )
end

function _resource_model_data(model)
    rules = map(collect(model.rules)) do rule
        data = Dict{String, Any}(
            "operation" => string(rule.operation),
            "format" => string(rule.format),
        )
        for name in (:exponent_bits, :fraction_bits, :max_width, :rounding)
            value = getfield(rule, name)
            value === nothing ||
                (data[string(name)] = value isa Symbol ? string(value) : value)
        end
        for name in _RESOURCE_NAMES
            formula = getfield(rule, name)
            formula === nothing ||
                (data[string(name)] = _resource_formula_data(formula))
        end
        data
    end
    return Dict{String, Any}(
        "schema" => "presage-resource-model",
        "schema_version" => 1,
        "name" => model.name,
        "toolchain" => string(model.toolchain),
        "priority" => string.(collect(model.priority)),
        "rules" => rules,
        "memory" => Dict(
            "depth" => model.memory.depth,
            "word_bits" => model.memory.word_bits,
            "policy" => string(model.memory_policy),
            "distributed_max_bits" => _resource_number_data(model.distributed_max_bits),
            "distributed_depth" => model.distributed_depth,
            "distributed_word_bits" => model.distributed_word_bits,
            "distributed_luts" => _resource_number_data(model.distributed_luts),
        ),
        "dsp" => Dict("operand_bits" => collect(model.dsp_operand_bits)),
    )
end

function _resource_keys(data, allowed, label)
    data isa AbstractDict || throw(ArgumentError("$label must be a table"))
    all(key -> key in allowed, keys(data)) || throw(ArgumentError("unknown $label field"))
end
function _resource_exact(x::String)
    occursin('/', x) && return _parse_rational(x)
    value = tryparse(BigInt, strip(x))
    value === nothing &&
        throw(ArgumentError("resource cost must be an integer or numerator/denominator"))
    value
end
_resource_exact(x::Union{Integer, Rational}) = x
_resource_exact(x) =
    throw(ArgumentError("resource costs must be integers or exact rational strings"))
function _resource_exact_integer(x)
    value = _resource_exact(x)
    denominator(value) == 1 || throw(ArgumentError("resource count must be an integer"))
    numerator(value)
end
function _read_resource_formula(value)
    value isa AbstractDict || return _resource_formula(_resource_exact(value))
    _resource_keys(value, string.(fieldnames(ResourceFormula)), "formula")
    ResourceFormula(; (Symbol(k) => _resource_exact(v) for (k, v) in value)...)
end

function _read_resource_model(data)
    _resource_keys(
        data,
        (
            "schema",
            "schema_version",
            "name",
            "toolchain",
            "priority",
            "memory",
            "dsp",
            "rules",
        ),
        "resource model",
    )
    get(data, "schema", nothing) == "presage-resource-model" &&
        get(data, "schema_version", nothing) isa Integer &&
        !(data["schema_version"] isa Bool) &&
        data["schema_version"] == 1 ||
        throw(ArgumentError("unsupported resource model schema"))
    memory, dsp = get(data, "memory", Dict()), get(data, "dsp", Dict())
    _resource_keys(
        memory,
        (
            "depth",
            "word_bits",
            "policy",
            "distributed_max_bits",
            "distributed_depth",
            "distributed_word_bits",
            "distributed_luts",
        ),
        "memory",
    )
    _resource_keys(dsp, ("operand_bits",), "DSP")
    rules = map(get(data, "rules", [])) do rule
        _resource_keys(
            rule,
            (
                "operation",
                "format",
                "exponent_bits",
                "fraction_bits",
                "max_width",
                "rounding",
                string.(_RESOURCE_NAMES)...,
            ),
            "rule",
        )
        haskey(rule, "operation") || throw(ArgumentError("rule needs an operation"))
        ResourceRule(
            Symbol(rule["operation"]);
            format = Symbol(get(rule, "format", "any")),
            exponent_bits = get(rule, "exponent_bits", nothing),
            fraction_bits = get(rule, "fraction_bits", nothing),
            max_width = get(rule, "max_width", nothing),
            rounding = haskey(rule, "rounding") ? Symbol(rule["rounding"]) : nothing,
            (
                name =>
                    haskey(rule, string(name)) ?
                    _read_resource_formula(rule[string(name)]) : nothing for
                name in _RESOURCE_NAMES
            )...,
        )
    end
    ResourceModel(;
        name = get(data, "name", "custom"),
        toolchain = Symbol(get(data, "toolchain", "generic")),
        memory = BlockMemoryModel(
            depth = get(memory, "depth", 512),
            word_bits = get(memory, "word_bits", 32),
        ),
        memory_policy = Symbol(get(memory, "policy", "block")),
        distributed_max_bits = _resource_exact_integer(
            get(memory, "distributed_max_bits", 4096),
        ),
        distributed_depth = get(memory, "distributed_depth", 64),
        distributed_word_bits = get(memory, "distributed_word_bits", 1),
        distributed_luts = _resource_exact_integer(get(memory, "distributed_luts", 1)),
        dsp_operand_bits = get(dsp, "operand_bits", [24, 17]),
        priority = Symbol.(get(data, "priority", ["luts", "rams", "dsps", "ffs"])),
        rules,
    )
end

"""Read editable resource assumptions from TOML. Unknown fields and inexact costs are rejected."""
read_resource_model(path::AbstractString) = _read_resource_model(TOML.parsefile(path))
read_resource_model(io::IO) = _read_resource_model(TOML.parse(read(io, String)))
"""Write a complete resource profile suitable for editing and exact replay."""
write_resource_model(io::IO, model::ResourceModel) =
    TOML.print(io, _resource_model_data(model); sorted = true)
write_resource_model(path::AbstractString, model::ResourceModel) =
    open(io -> write_resource_model(io, model), path, "w")

function _resource_counts_data(counts)
    Dict(
        string(name) => value === nothing ? "unknown" : _resource_number_data(value) for
        (name, value) in pairs(counts)
    )
end
function _resource_budget_data(budget)
    Dict(
        string(name) => _resource_number_data(getfield(budget, name)) for
        name in _RESOURCE_NAMES if getfield(budget, name) !== nothing
    )
end

function _resource_estimate_data(estimate)
    nodes = map(estimate.nodes) do node
        signature = node.signature
        data = Dict{String, Any}(
            "node" => node.node,
            "operation" => string(signature.operation),
            "format" => string(signature.format),
            "costs" => _resource_counts_data(node.costs),
            "missing" => string.(collect(node.missing)),
            "features" => Dict(
                string(name) => _resource_number_data(getfield(signature, name)) for
                name in fieldnames(ResourceFormula) if name != :constant
            ),
        )
        node.rule_index === nothing || (data["rule"] = node.rule_index)
        data
    end
    tables = map(estimate.tables) do table
        Dict(
            string(name) =>
                value isa Symbol ? string(value) : _resource_number_data(value) for
            (name, value) in pairs(table)
        )
    end
    Dict(
        "model" => estimate.model,
        "status" => string(estimate.status),
        "memory_model" => Dict(
            "depth" => estimate.memory_model.depth,
            "word_bits" => estimate.memory_model.word_bits,
        ),
        "totals" => _resource_counts_data(estimate.totals),
        "known" => _resource_counts_data(estimate.known),
        "nodes" => nodes,
        "tables" => tables,
    )
end

"""Write resource totals, known subtotals, matched rules and per-table allocations."""
write_resource_report(io::IO, estimate) = TOML.print(
    io,
    merge(
        Dict("schema" => "presage-resource-estimate", "schema_version" => 1),
        _resource_estimate_data(estimate),
    );
    sorted = true,
)
write_resource_report(path::AbstractString, estimate) =
    open(io -> write_resource_report(io, estimate), path, "w")
