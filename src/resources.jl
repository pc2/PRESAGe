const _RESOURCE_NAMES = (:luts, :ffs, :dsps, :rams)
const _RESOURCE_OPERATIONS = (
    :input,
    :constant,
    :table_load,
    :mul,
    :add,
    :fma,
    :convert,
    :compare,
    :select,
    :guard,
    :bitcast,
    :extract_bits,
    :bitop,
    :scale_pow2,
    :classify,
    :normalize,
    :exponent,
    :reciprocal,
    :root_argument,
    :scale_exponent,
    :copy_sign,
)

_resource_integer(value, name; positive = false) = begin
    value isa Integer && !(value isa Bool) && value >= (positive ? 1 : 0) || throw(
        ArgumentError("$name must be a $(positive ? "positive" : "nonnegative") integer"),
    )
    BigInt(value)
end

"""Optional limits on LUT/ALUT, flip-flop, DSP and block-memory estimates."""
struct ResourceBudget
    luts::Union{Nothing, BigInt}
    ffs::Union{Nothing, BigInt}
    dsps::Union{Nothing, BigInt}
    rams::Union{Nothing, BigInt}
    function ResourceBudget(; luts = nothing, ffs = nothing, dsps = nothing, rams = nothing)
        values = map(zip(_RESOURCE_NAMES, (luts, ffs, dsps, rams))) do (name, value)
            value === nothing ? nothing : _resource_integer(value, string(name))
        end
        new(values...)
    end
end

"""Ceiling of a nonnegative linear cost in exact node-width features.

Features are `result_bits`, `operand_bits`, `max_operand_bits`, the product of
the first two operand widths, and rectangular `dsp_tiles`. Coefficients may be
integers or exact rationals. These are configurable assumptions, not proofs.
"""
struct ResourceFormula
    constant::Rational{BigInt}
    result_bits::Rational{BigInt}
    operand_bits::Rational{BigInt}
    max_operand_bits::Rational{BigInt}
    operand_product::Rational{BigInt}
    dsp_tiles::Rational{BigInt}
    function ResourceFormula(;
        constant = 0,
        result_bits = 0,
        operand_bits = 0,
        max_operand_bits = 0,
        operand_product = 0,
        dsp_tiles = 0,
    )
        coefficients = map((
            constant,
            result_bits,
            operand_bits,
            max_operand_bits,
            operand_product,
            dsp_tiles,
        )) do value
            value isa Union{Integer, Rational} && !(value isa Bool) && value >= 0 ||
                throw(
                    ArgumentError(
                        "resource coefficients must be nonnegative exact numbers",
                    ),
                )
            _q(value)
        end
        new(coefficients...)
    end
end
_resource_formula(value::ResourceFormula) = value
_resource_formula(value::Union{Integer, Rational}) = ResourceFormula(constant = value)
_resource_formula(::Nothing) = nothing

"""One operation cost rule. First matching rule wins; omitted resources are unknown.

`format` is fixed, uint, bool, float, mixed or any. Exact floating rules require
both exponent/fraction widths. Optional rounding and maximum width restrictions
prevent a calibrated rule being applied outside its declared scope.
"""
struct ResourceRule
    operation::Symbol
    format::Symbol
    exponent_bits::Union{Nothing, Int}
    fraction_bits::Union{Nothing, Int}
    max_width::Union{Nothing, Int}
    rounding::Union{Nothing, Symbol}
    luts::Union{Nothing, ResourceFormula}
    ffs::Union{Nothing, ResourceFormula}
    dsps::Union{Nothing, ResourceFormula}
    rams::Union{Nothing, ResourceFormula}
    function ResourceRule(
        operation::Symbol;
        format::Symbol = :any,
        exponent_bits = nothing,
        fraction_bits = nothing,
        max_width = nothing,
        rounding = nothing,
        luts = nothing,
        ffs = nothing,
        dsps = nothing,
        rams = nothing,
    )
        operation in _RESOURCE_OPERATIONS ||
            throw(ArgumentError("unknown resource operation $operation"))
        format in (:fixed, :uint, :bool, :float, :mixed, :any) ||
            throw(ArgumentError("unknown resource format $format"))
        (exponent_bits === nothing) == (fraction_bits === nothing) || throw(
            ArgumentError("floating rules require both exponent_bits and fraction_bits"),
        )
        exponent_bits === nothing ||
            format == :float ||
            throw(ArgumentError("floating precision requires format=float"))
        for (value, name, minimum) in (
            (exponent_bits, "exponent_bits", 1),
            (fraction_bits, "fraction_bits", 0),
            (max_width, "max_width", 1),
        )
            value === nothing && continue
            _resource_integer(value, name; positive = minimum == 1) <= typemax(Int) ||
                throw(ArgumentError("$name exceeds Int"))
        end
        rounding === nothing ||
            rounding in (:nearest_even, :toward_zero, :up, :down) ||
            throw(ArgumentError("unknown resource rounding mode"))
        new(
            operation,
            format,
            exponent_bits,
            fraction_bits,
            max_width,
            rounding,
            map(_resource_formula, (luts, ffs, dsps, rams))...,
        )
    end
end

"""Editable target cost assumptions, including RAM/distributed-ROM policy.

Rules describe one spatial instance per reachable IR node. No automatic sharing,
pipeline scheduling or compiler optimization is assumed. `priority` controls
lexicographic selection with `objective=:resources`.
"""
struct ResourceModel
    name::String
    toolchain::Symbol
    memory::BlockMemoryModel
    memory_policy::Symbol
    distributed_max_bits::BigInt
    distributed_depth::Int
    distributed_word_bits::Int
    distributed_luts::BigInt
    dsp_operand_bits::Tuple{Int, Int}
    priority::Tuple{Vararg{Symbol}}
    rules::Tuple{Vararg{ResourceRule}}
    function ResourceModel(;
        name::AbstractString = "custom",
        toolchain::Symbol = :generic,
        memory = BlockMemoryModel(),
        memory_policy::Symbol = :block,
        distributed_max_bits = 4096,
        distributed_depth::Integer = 64,
        distributed_word_bits::Integer = 1,
        distributed_luts = 1,
        dsp_operand_bits = (24, 17),
        priority = (:luts, :rams, :dsps, :ffs),
        rules = (),
    )
        isempty(name) && throw(ArgumentError("resource model name must not be empty"))
        toolchain in (:generic, :vitis, :oneapi) ||
            throw(ArgumentError("unknown model toolchain"))
        memory isa BlockMemoryModel ||
            throw(ArgumentError("memory must be a BlockMemoryModel"))
        memory_policy in (:block, :distributed, :auto) ||
            throw(ArgumentError("memory_policy must be block, distributed or auto"))
        threshold = _resource_integer(distributed_max_bits, "distributed_max_bits")
        luts = _resource_integer(distributed_luts, "distributed_luts")
        for (value, label) in (
            (distributed_depth, "distributed_depth"),
            (distributed_word_bits, "distributed_word_bits"),
        )
            _resource_integer(value, label; positive = true) <= typemax(Int) ||
                throw(ArgumentError("$label exceeds Int"))
        end
        length(dsp_operand_bits) == 2 ||
            throw(ArgumentError("DSP tile needs two operand widths"))
        all(
            x -> _resource_integer(x, "DSP operand width"; positive = true) <= typemax(Int),
            dsp_operand_bits,
        ) || throw(ArgumentError("DSP operand width exceeds Int"))
        order = Tuple(priority)
        !isempty(order) &&
            length(unique(order)) == length(order) &&
            all(x -> x in _RESOURCE_NAMES, order) ||
            throw(ArgumentError("priority must contain distinct resource names"))
        all(x -> x isa ResourceRule, rules) ||
            throw(ArgumentError("rules must be ResourceRule values"))
        new(
            String(name),
            toolchain,
            memory,
            memory_policy,
            threshold,
            Int(distributed_depth),
            Int(distributed_word_bits),
            luts,
            Tuple(Int.(dsp_operand_bits)),
            order,
            Tuple(rules),
        )
    end
end

_resource_width(::Type{Bool}) = 1
_resource_width(f) = _cost_width(f)
_resource_family(::Type{Bool}) = :bool
_resource_family(::FloatFormat) = :float
_resource_family(::FixedFormat) = :fixed
_resource_family(::IR.UIntFormat) = :uint

function _resource_operation(n)
    n isa IR.Input && return :input
    n isa IR.Const && return :constant
    n isa IR.TableLoad && return :table_load
    n isa IR.Mul && return :mul
    n isa Union{IR.Add, IR.UIntAdd} && return :add
    n isa IR.FMA && return :fma
    n isa Union{IR.Convert, IR.Quantize} && return :convert
    n isa IR.Compare && return :compare
    n isa IR.Select && return :select
    n isa IR.Guard && return :guard
    n isa IR.BitCast && return :bitcast
    n isa IR.ExtractBits && return :extract_bits
    n isa IR.BitOp && return :bitop
    n isa IR.ScalePow2 && return :scale_pow2
    n isa IR.Classify && return :classify
    n isa IR.FloatMantissa && return :normalize
    n isa IR.FloatExponent && return :exponent
    n isa IR.FloatReciprocal && return :reciprocal
    n isa IR.RootArgument && return :root_argument
    n isa Union{IR.ScaleByInputExponent, IR.ScaleByExponent} && return :scale_exponent
    n isa IR.CopySign && return :copy_sign
    throw(ArgumentError("unmodeled IR operation $(typeof(n))"))
end

function _resource_signature(p, i, model)
    n, output = p.nodes[i], IR.format(p, i)
    operands = [IR.format(p, j) for j in IR.refs(n)]
    # Control bits and table indices do not change the data format family.
    data =
        n isa IR.TableLoad ? [output] :
        n isa IR.Select ? [output, operands[2], operands[3]] :
        n isa IR.Guard ? [output, operands[2]] :
        n isa Union{IR.Compare, IR.Classify, IR.FloatExponent} ? operands :
        [output, operands...]
    families = unique(_resource_family.(data))
    family = length(families) == 1 ? only(families) : :mixed
    widths = BigInt.(_resource_width.(operands))
    tile_a, tile_b = model.dsp_operand_bits
    tiles = if n isa Union{IR.Mul, IR.FMA}
        a, b = widths[1:2]
        min(cld(a, tile_a) * cld(b, tile_b), cld(a, tile_b) * cld(b, tile_a))
    else
        BigInt(0)
    end
    return (;
        operation = _resource_operation(n),
        format = family,
        formats = Tuple(data),
        rounding = hasproperty(n, :rounding) ? n.rounding : nothing,
        result_bits = BigInt(_resource_width(output)),
        operand_bits = sum(widths; init = BigInt(0)),
        max_operand_bits = isempty(widths) ? BigInt(0) : maximum(widths),
        operand_product = n isa Union{IR.Mul, IR.FMA} ? widths[1] * widths[2] : BigInt(0),
        dsp_tiles = tiles,
    )
end

function _resource_matches(rule, signature)
    rule.operation == signature.operation || return false
    rule.format in (:any, signature.format) || return false
    rule.max_width === nothing ||
        max(signature.result_bits, signature.max_operand_bits) <= rule.max_width ||
        return false
    rule.rounding === nothing || rule.rounding == signature.rounding || return false
    return rule.exponent_bits === nothing || all(signature.formats) do f
        f isa FloatFormat &&
            f.exponent_bits == rule.exponent_bits &&
            f.fraction_bits == rule.fraction_bits
    end
end

function _resource_value(formula, signature)
    formula === nothing && return nothing
    value =
        formula.constant + sum(
            getfield(formula, name) * getfield(signature, name) for name in
            (:result_bits, :operand_bits, :max_operand_bits, :operand_product, :dsp_tiles)
        )
    return cld(numerator(value), denominator(value))
end

function _resource_table_storage(table, model)
    model.memory_policy != :auto && return model.memory_policy
    padded_bits =
        BigInt(table.banks) *
        cld(length(table.values), table.banks) *
        _cost_width(table.format)
    return padded_bits <= model.distributed_max_bits ? :distributed : :block
end

function _resource_table_cost(p, model, memory_model)
    layout = table_memory_cost(p; model = memory_model)
    tables = map(layout.tables) do t
        storage = _resource_table_storage(p.tables[t.table], model)
        distributed = storage == :distributed
        # Independent banks and columns; distributed depth tiles use power-of-two padding.
        depth = nextpow(big(2), cld(BigInt(t.rows), model.distributed_depth))
        luts =
            distributed ?
            BigInt(t.banks) *
            depth *
            cld(t.word_bits, model.distributed_word_bits) *
            model.distributed_luts : BigInt(0)
        merge(t, (; storage, luts, rams = distributed ? BigInt(0) : t.blocks))
    end
    return tables
end

"""
    estimate_resources(plan_or_program; model, memory_model=model.memory)

Estimate all reachable IR nodes and ROMs. A missing rule/resource gives an
unknown total (`nothing`) and an explicit coverage record; `known` retains the
subtotal. Tables are counted once, including centers and cyclic padding.
"""
function estimate_resources(
    p::IR.Program;
    model::ResourceModel,
    memory_model::BlockMemoryModel = model.memory,
)
    flow, _ = _cpp_flow(p)
    reachable = sort!(collect(_cpp_reachable(flow)))
    tables = _resource_table_cost(p, model, memory_model)
    known = Dict(name => BigInt(0) for name in _RESOURCE_NAMES)
    known[:luts] = sum((t.luts for t in tables); init = BigInt(0))
    known[:rams] = sum((t.rams for t in tables); init = BigInt(0))
    unknown = Set{Symbol}()
    nodes = map(reachable) do i
        signature = _resource_signature(p, i, model)
        rule_index = findfirst(rule -> _resource_matches(rule, signature), model.rules)
        rule = rule_index === nothing ? nothing : model.rules[rule_index]
        costs = NamedTuple{_RESOURCE_NAMES}(
            Tuple(
                rule === nothing ? nothing :
                _resource_value(getfield(rule, name), signature) for
                name in _RESOURCE_NAMES
            ),
        )
        missing = Symbol[]
        for name in _RESOURCE_NAMES
            value = getfield(costs, name)
            if value === nothing
                push!(unknown, name)
                push!(missing, name)
            else
                known[name] += value
            end
        end
        (; node = i, signature, rule_index, costs, missing = Tuple(missing))
    end
    totals = NamedTuple{_RESOURCE_NAMES}(
        Tuple(name in unknown ? nothing : known[name] for name in _RESOURCE_NAMES),
    )
    subtotal = NamedTuple{_RESOURCE_NAMES}(Tuple(known[name] for name in _RESOURCE_NAMES))
    return (;
        model = model.name,
        memory_model,
        status = isempty(unknown) ? :complete : :partial,
        totals,
        known = subtotal,
        nodes,
        tables,
    )
end

function estimate_resources(plan::PlanArtifact; kwargs...)
    plan.program === nothing && throw(ArgumentError("plan has no evaluator"))
    estimate_resources(plan.program; kwargs...)
end

"""
    compare_resources(estimate_or_report, measured::ResourceBudget; absolute, relative)

Compare predictions with normalized synthesis counts. Each allowed difference is
`absolute + relative * measured`. Unknown predictions or missing measurements
remain unresolved. Defaults allow 50% plus five LUTs/FFs and exact DSP/RAM counts;
callers should configure tolerances for their calibrated target.
"""
function compare_resources(
    predicted,
    measured::ResourceBudget;
    absolute::ResourceBudget = ResourceBudget(luts = 5, ffs = 5, dsps = 0, rams = 0),
    relative = (luts = 1 // 2, ffs = 1 // 2, dsps = 0, rams = 0),
)
    Set(keys(relative)) == Set(_RESOURCE_NAMES) ||
        throw(ArgumentError("relative tolerances need all four resources"))
    coefficients = Dict(
        name => ResourceFormula(constant = relative[name]).constant for
        name in _RESOURCE_NAMES
    )
    all(name -> getfield(absolute, name) !== nothing, _RESOURCE_NAMES) ||
        throw(ArgumentError("absolute tolerances need all four resources"))
    totals = predicted isa AbstractDict ? predicted["totals"] : predicted.totals
    checks = Dict{String, Any}()
    statuses = Symbol[]
    for name in _RESOURCE_NAMES
        value = totals isa AbstractDict ? totals[string(name)] : getfield(totals, name)
        value == "unknown" && (value = nothing)
        value isa String && (value = parse(BigInt, value))
        value === nothing || _resource_integer(value, "prediction")
        actual = getfield(measured, name)
        data = Dict{String, Any}(
            "predicted" => value === nothing ? "unknown" : _resource_number_data(value),
            "measured" =>
                actual === nothing ? "unknown" : _resource_number_data(actual),
        )
        status = if value === nothing || actual === nothing
            :unresolved
        else
            difference = abs(actual - value)
            allowance = getfield(absolute, name) + coefficients[name] * actual
            data["difference"] = _resource_number_data(difference)
            data["allowance"] = _resource_number_data(allowance)
            difference <= allowance ? :passed : :failed
        end
        data["status"] = string(status)
        checks[string(name)] = data
        push!(statuses, status)
    end
    status = :failed in statuses ? :failed : :unresolved in statuses ? :unresolved : :passed
    return Dict(
        "schema" => "presage-resource-comparison",
        "schema_version" => 1,
        "status" => string(status),
        "resources" => checks,
    )
end
