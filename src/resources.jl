const _RESOURCE_NAMES = (:luts, :ffs, :dsps, :rams, :mlabs)
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

"""Optional limits on logic, registers, exact DSP equivalents, block RAM and MLAB estimates."""
struct ResourceBudget
    luts::Union{Nothing, BigInt}
    ffs::Union{Nothing, BigInt}
    dsps::Union{Nothing, Rational{BigInt}}
    rams::Union{Nothing, BigInt}
    mlabs::Union{Nothing, BigInt}
    function ResourceBudget(;
        luts = nothing,
        ffs = nothing,
        dsps = nothing,
        rams = nothing,
        mlabs = nothing,
    )
        values = map(zip(_RESOURCE_NAMES, (luts, ffs, dsps, rams, mlabs))) do (name, value)
            value === nothing ? nothing : _resource_count(value, name)
        end
        new(values...)
    end
end

function _resource_count(value, name)
    if name == :dsps
        value isa Union{Integer, Rational} && !(value isa Bool) && value >= 0 ||
            throw(ArgumentError("DSP equivalents must be nonnegative exact numbers"))
        return _q(value)
    end
    return _resource_integer(value, string(name))
end

"""A nonnegative linear cost in exact node width features.

Coefficients are integers or exact rationals.
DSP equivalents retain fractional costs, other resources round upward.
Intermediate, rounding and overflow widths describe the fixed arithmetic helpers.
"""
struct ResourceFormula
    constant::Rational{BigInt}
    result_bits::Rational{BigInt}
    output_bits::Rational{BigInt}
    operand_bits::Rational{BigInt}
    max_operand_bits::Rational{BigInt}
    operand_product::Rational{BigInt}
    dsp_tiles::Rational{BigInt}
    intermediate_bits::Rational{BigInt}
    rounding_bits::Rational{BigInt}
    overflow_bits::Rational{BigInt}
    function ResourceFormula(;
        constant = 0,
        result_bits = 0,
        output_bits = 0,
        operand_bits = 0,
        max_operand_bits = 0,
        operand_product = 0,
        dsp_tiles = 0,
        intermediate_bits = 0,
        rounding_bits = 0,
        overflow_bits = 0,
    )
        coefficients = map((
            constant,
            result_bits,
            output_bits,
            operand_bits,
            max_operand_bits,
            operand_product,
            dsp_tiles,
            intermediate_bits,
            rounding_bits,
            overflow_bits,
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
    result_width::Union{Nothing, Int}
    operand_widths::Tuple{Vararg{Int}}
    operand_constants::Tuple{Vararg{String}}
    formats::Tuple{Vararg{IR.ArithmeticFormat}}
    integer_bits::Union{Nothing, Int}
    overflow::Union{Nothing, Symbol}
    luts::Union{Nothing, ResourceFormula}
    ffs::Union{Nothing, ResourceFormula}
    dsps::Union{Nothing, ResourceFormula}
    rams::Union{Nothing, ResourceFormula}
    mlabs::Union{Nothing, ResourceFormula}
    function ResourceRule(
        operation::Symbol;
        format::Symbol = :any,
        exponent_bits = nothing,
        fraction_bits = nothing,
        max_width = nothing,
        rounding = nothing,
        result_width = nothing,
        operand_widths = (),
        operand_constants = (),
        formats = (),
        integer_bits = nothing,
        overflow = nothing,
        luts = nothing,
        ffs = nothing,
        dsps = nothing,
        rams = nothing,
        mlabs = 0,
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
            (result_width, "result_width", 1),
        )
            value === nothing && continue
            _resource_integer(value, name; positive = minimum == 1) <= typemax(Int) ||
                throw(ArgumentError("$name exceeds Int"))
        end
        rounding === nothing ||
            rounding in (:nearest_even, :toward_zero, :up, :down) ||
            throw(ArgumentError("unknown resource rounding mode"))
        all(width -> width isa Integer && !(width isa Bool) && width > 0, operand_widths) ||
            throw(ArgumentError("operand widths must be positive integers"))
        all(
            value ->
                value isa AbstractString &&
                    (value == "variable" || occursin(r"^0x[0-9a-f]+$", value)),
            operand_constants,
        ) || throw(ArgumentError("operand constants must be hexadecimal words or variable"))
        all(value -> value isa IR.ArithmeticFormat, formats) ||
            throw(ArgumentError("calibration formats must be arithmetic formats"))
        integer_bits === nothing ||
            integer_bits isa Integer && !(integer_bits isa Bool) ||
            throw(ArgumentError("integer_bits must be an integer"))
        overflow === nothing ||
            overflow in (:wrap, :saturate, :reject) ||
            throw(ArgumentError("unknown overflow policy"))
        new(
            operation,
            format,
            exponent_bits,
            fraction_bits,
            max_width,
            rounding,
            result_width,
            Tuple(operand_widths),
            Tuple(operand_constants),
            Tuple(formats),
            integer_bits,
            overflow,
            map(_resource_formula, (luts, ffs, dsps, rams, mlabs))...,
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
    device::Union{Nothing, String}
    compiler::Union{Nothing, String}
    pipeline::ResourceBudget
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
        device::Union{Nothing, AbstractString} = nothing,
        compiler::Union{Nothing, AbstractString} = nothing,
        pipeline::ResourceBudget = ResourceBudget(
            luts = 0,
            ffs = 0,
            dsps = 0,
            rams = 0,
            mlabs = 0,
        ),
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
            device === nothing ? nothing : String(device),
            compiler === nothing ? nothing : String(compiler),
            pipeline,
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

function _resource_constant_bits(p, i)
    node = p.nodes[i]
    node isa IR.Const && return node.bits
    node isa Union{IR.Convert, IR.Quantize, IR.ScalePow2} || return nothing
    source, output = IR.format(p, node.source), IR.format(p, i)
    source isa FixedFormat && output isa FixedFormat || return nothing
    bits = _resource_constant_bits(p, node.source)
    bits === nothing && return nothing
    exponent = -BigInt(_fraction(source))
    node isa IR.ScalePow2 && (exponent += node.exponent)
    try
        return _round_fixed_dyadic(
            _fixed_units(bits, source),
            exponent,
            output,
            node.rounding,
        )
    catch error
        error isa OverflowError || rethrow()
        return nothing
    end
end

function _resource_fixed_extent(p, i, model)
    node, format = p.nodes[i], IR.format(p, i)
    width = _resource_width(format)
    model.toolchain == :vitis && format isa FixedFormat || return (width, 0)
    node isa IR.TableLoad &&
        return (_resource_storage_width(p.tables[node.table], model), 0)
    node isa Union{IR.Convert, IR.Quantize} || return (width, 0)
    _resource_constant_bits(p, i) === nothing || return (width, 0)
    source = IR.format(p, node.source)
    source isa FixedFormat && source.signed == format.signed || return (width, 0)
    # Vitis retains the declared ROM output width across fixed conversions.
    source_width, zeros =
        p.nodes[node.source] isa IR.TableLoad ? (source.width, 0) :
        _resource_fixed_extent(p, node.source, model)
    shift = _fraction(format) - _fraction(source)
    # Exact extensions preserve the input range and known low zero bits.
    shift + zeros >= 0 && source_width + shift <= width || return (width, 0)
    return (max(1, source_width + shift), shift + zeros)
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
    widths = BigInt[first(_resource_fixed_extent(p, j, model)) for j in IR.refs(n)]
    tile_a, tile_b = model.dsp_operand_bits
    tiles = if n isa Union{IR.Mul, IR.FMA}
        a, b = widths[1:2]
        min(cld(a, tile_a) * cld(b, tile_b), cld(a, tile_b) * cld(b, tile_a))
    else
        BigInt(0)
    end
    intermediate, discarded, overflow = BigInt(0), BigInt(0), BigInt(0)
    if output isa FixedFormat && all(f -> f isa FixedFormat, operands) && !isempty(operands)
        a = first(operands)
        fraction, integer = _fraction(a), a.integer_bits + !a.signed
        if n isa IR.Add
            fraction = maximum(_fraction, operands)
            integer = maximum(f -> f.integer_bits + !f.signed, operands) + 1
        elseif n isa Union{IR.Mul, IR.FMA}
            b = operands[2]
            fraction = _fraction(a) + _fraction(b)
            integer = a.integer_bits + b.integer_bits
            if n isa IR.FMA
                c = operands[3]
                fraction = max(fraction, _fraction(c))
                integer = max(integer, c.integer_bits + !c.signed) + 1
            end
        elseif n isa IR.ScalePow2
            fraction -= n.exponent
            integer += n.exponent
        end
        if n isa Union{IR.Add, IR.Mul, IR.FMA, IR.Convert, IR.Quantize, IR.ScalePow2}
            intermediate = integer + fraction
            discarded = max(0, fraction - _fraction(output))
            overflow =
                output.overflow == :reject ? max(0, integer - output.integer_bits) : 0
        end
    end
    return (;
        operation = _resource_operation(n),
        format = family,
        formats = Tuple(data),
        operand_widths = Tuple(Int.(widths)),
        operand_constants = Tuple(map(IR.refs(n)) do j
            bits = _resource_constant_bits(p, j)
            bits === nothing ? "variable" : _ir_hex(bits)
        end),
        integer_bits = output isa FixedFormat ? output.integer_bits : nothing,
        overflow = output isa FixedFormat ? output.overflow : nothing,
        rounding = hasproperty(n, :rounding) ? n.rounding : nothing,
        result_bits = BigInt(_resource_width(output)),
        output_bits = i == p.output ? BigInt(_resource_width(output)) : BigInt(0),
        operand_bits = sum(widths; init = BigInt(0)),
        max_operand_bits = isempty(widths) ? BigInt(0) : maximum(widths),
        operand_product = n isa Union{IR.Mul, IR.FMA} ? widths[1] * widths[2] : BigInt(0),
        dsp_tiles = tiles,
        intermediate_bits = intermediate,
        rounding_bits = discarded,
        overflow_bits = overflow,
    )
end

function _resource_matches(rule, signature)
    rule.operation == signature.operation || return false
    rule.format in (:any, signature.format) || return false
    rule.max_width === nothing ||
        max(signature.result_bits, signature.max_operand_bits) <= rule.max_width ||
        return false
    rule.rounding === nothing || rule.rounding == signature.rounding || return false
    rule.result_width === nothing ||
        rule.result_width == signature.result_bits ||
        return false
    isempty(rule.operand_widths) ||
        rule.operand_widths == signature.operand_widths ||
        return false
    isempty(rule.operand_constants) ||
        rule.operand_constants == signature.operand_constants ||
        return false
    isempty(rule.formats) || rule.formats == signature.formats || return false
    rule.integer_bits === nothing ||
        all(
            f -> f isa FixedFormat && f.integer_bits == rule.integer_bits,
            signature.formats,
        ) ||
        return false
    rule.overflow === nothing || rule.overflow == signature.overflow || return false
    return rule.exponent_bits === nothing || all(signature.formats) do f
        f isa FloatFormat &&
            f.exponent_bits == rule.exponent_bits &&
            f.fraction_bits == rule.fraction_bits
    end
end

function _resource_value(formula, signature; fractional = false)
    formula === nothing && return nothing
    value =
        formula.constant + sum(
            getfield(formula, name) * getfield(signature, name) for
            name in filter(!=(:constant), fieldnames(ResourceFormula))
        )
    return fractional ? value : cld(numerator(value), denominator(value))
end

function _resource_table_storage(table, model)
    model.memory_policy != :auto && return model.memory_policy
    padded_bits =
        BigInt(table.banks) *
        cld(length(table.values), table.banks) *
        _cost_width(table.format)
    return padded_bits <= model.distributed_max_bits ? :distributed : :block
end

function _resource_storage_width(table, model)
    width = _cost_width(table.format)
    model.toolchain == :oneapi &&
        return width > 64 ? 64cld(width, 64) : nextpow(2, max(8, width))
    model.toolchain != :vitis && return width
    table.format isa FixedFormat || return width
    values = table.values
    isempty(values) && return width
    # Constant sign extension is reconstructed outside the ROM.
    if table.format.signed
        signed =
            map(value -> value >= big(2)^(width - 1) ? value - big(2)^width : value, values)
        return min(
            width,
            maximum(
                value ->
                    value < 0 ? ndigits(-value - 1; base = 2) + 1 :
                    ndigits(value; base = 2) + 1,
                signed,
            ),
        )
    end
    return max(1, ndigits(maximum(values); base = 2))
end

function _resource_table_cost(p, model, memory_model)
    layout = table_memory_cost(p; model = memory_model)
    tables = map(layout.tables) do t
        table = p.tables[t.table]
        storage = _resource_table_storage(table, model)
        word_bits = _resource_storage_width(table, model)
        allocated_word_bits =
            model.toolchain == :vitis ? nextpow(2, word_bits) : word_bits
        blocks =
            BigInt(t.banks) *
            cld(t.rows, memory_model.depth) *
            cld(allocated_word_bits, memory_model.word_bits)
        distributed = storage == :distributed
        # Distributed depth tiles use power of two padding for each bank and column.
        depth = nextpow(big(2), cld(BigInt(t.rows), model.distributed_depth))
        luts =
            distributed ?
            BigInt(t.banks) *
            depth *
            cld(allocated_word_bits, model.distributed_word_bits) *
            model.distributed_luts : BigInt(0)
        mlabs =
            distributed && model.toolchain == :oneapi ?
            BigInt(t.banks) * depth * cld(word_bits, model.distributed_word_bits) :
            BigInt(0)
        model.toolchain == :oneapi && (luts = BigInt(0))
        ffs =
            distributed && model.toolchain == :vitis ?
            BigInt(t.banks) * allocated_word_bits : BigInt(0)
        merge(
            t,
            (;
                storage,
                storage_bits = word_bits,
                allocated_word_bits,
                width_blocks = cld(allocated_word_bits, memory_model.word_bits),
                blocks,
                allocated_bits = blocks * memory_model.depth * memory_model.word_bits,
                luts,
                ffs,
                mlabs,
                rams = distributed ? BigInt(0) : blocks,
            ),
        )
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
    target::Union{Nothing, TargetProfile} = model.toolchain == :generic ? nothing :
                                            TargetProfile(model.toolchain),
)
    support =
        target === nothing ? (supported = true, reasons = ()) : target_support(p, target)
    flow, _ = _cpp_flow(p)
    reachable = sort!(collect(_cpp_reachable(flow)))
    tables = _resource_table_cost(p, model, memory_model)
    if target !== nothing &&
       target.toolchain == :oneapi &&
       any(t -> t.storage == :distributed, tables)
        support = (
            supported = false,
            reasons = (
                support.reasons...,
                "Intel constant ROM emission requires block storage",
            ),
        )
    end
    known = Dict{Symbol, Union{BigInt, Rational{BigInt}}}(
        name => BigInt(0) for name in _RESOURCE_NAMES
    )
    known[:luts] = sum((t.luts for t in tables); init = BigInt(0))
    known[:rams] = sum((t.rams for t in tables); init = BigInt(0))
    known[:mlabs] = sum((t.mlabs for t in tables); init = BigInt(0))
    known[:ffs] = sum((t.ffs for t in tables); init = BigInt(0))
    unknown = Set{Symbol}()
    nodes = map(reachable) do i
        signature = _resource_signature(p, i, model)
        rule_index = findfirst(rule -> _resource_matches(rule, signature), model.rules)
        rule = rule_index === nothing ? nothing : model.rules[rule_index]
        costs = NamedTuple{_RESOURCE_NAMES}(
            Tuple(
                rule === nothing ? nothing :
                _resource_value(
                    getfield(rule, name),
                    signature;
                    fractional = name == :dsps,
                ) for name in _RESOURCE_NAMES
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
    datapath = NamedTuple{_RESOURCE_NAMES}(
        Tuple(
            name in unknown ? nothing :
            sum((getfield(node.costs, name) for node in nodes); init = BigInt(0)) for
            name in _RESOURCE_NAMES
        ),
    )
    pipeline = NamedTuple{_RESOURCE_NAMES}(
        Tuple(getfield(model.pipeline, name) for name in _RESOURCE_NAMES),
    )
    for name in _RESOURCE_NAMES
        value = getfield(pipeline, name)
        value === nothing ? push!(unknown, name) : (known[name] += value)
    end
    totals = NamedTuple{_RESOURCE_NAMES}(
        Tuple(
            !support.supported || name in unknown ? nothing : known[name] for
            name in _RESOURCE_NAMES
        ),
    )
    subtotal = NamedTuple{_RESOURCE_NAMES}(Tuple(known[name] for name in _RESOURCE_NAMES))
    return (;
        model = model.name,
        memory_model,
        status = !support.supported ? :unsupported :
                 isempty(unknown) ? :complete : :partial,
        support,
        totals,
        known = subtotal,
        datapath,
        pipeline,
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
    absolute::ResourceBudget = ResourceBudget(
        luts = 5,
        ffs = 5,
        dsps = 0,
        rams = 0,
        mlabs = 0,
    ),
    relative = (luts = 1 // 2, ffs = 1 // 2, dsps = 0, rams = 0, mlabs = 0),
)
    Set(keys(relative)) == Set(_RESOURCE_NAMES) ||
        throw(ArgumentError("relative tolerances need all resources"))
    coefficients = Dict(
        name => ResourceFormula(constant = relative[name]).constant for
        name in _RESOURCE_NAMES
    )
    all(name -> getfield(absolute, name) !== nothing, _RESOURCE_NAMES) ||
        throw(ArgumentError("absolute tolerances need all resources"))
    totals = predicted isa AbstractDict ? predicted["totals"] : predicted.totals
    checks = Dict{String, Any}()
    statuses = Symbol[]
    for name in _RESOURCE_NAMES
        value =
            totals isa AbstractDict ? get(totals, string(name), "unknown") :
            get(totals, name, nothing)
        value == "unknown" && (value = nothing)
        value isa String && (value = _resource_exact(value))
        value === nothing || _resource_count(value, name)
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
