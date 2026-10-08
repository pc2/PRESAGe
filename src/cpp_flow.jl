mutable struct _CppTypes
    backend::Symbol
    target::Symbol
    floats::Symbol
    aliases::Dict{String, String}
    declarations::Vector{Pair{String, String}}
end
_CppTypes(backend; target = :kernel, floats = :native) =
    _CppTypes(backend, target, floats, Dict(), Pair{String, String}[])

function _cpp_alias!(types, name, definition)
    return get!(types.aliases, definition) do
        push!(types.declarations, name => definition)
        name
    end
end

function _cpp_vendor_alias!(types, w, i, signed, mode, overflow, backend)
    integer = i < 0 ? "m$(abs(i))" : string(i)
    rounding = mode == :nearest_even ? "" : mode == :toward_zero ? "Trunc" : "Floor"
    policy = overflow == :saturate ? "Sat" : ""
    name = "Fixed$(w)_$integer$(signed ? "" : "u")$rounding$policy"
    return _cpp_alias!(types, name, _vendor_type(w, i, signed, mode, overflow, backend))
end

function _cpp_alias!(types, f)
    f == Bool && return "bool"
    if f isa FixedFormat
        if types.backend == :portable
            return _cpp_type(f)
        end
        return _cpp_vendor_alias!(
            types,
            f.width,
            f.integer_bits,
            f.signed,
            f.rounding,
            f.overflow,
            types.backend,
        )
    elseif f isa IR.UIntFormat
        if types.target == :cpu
            definition = _cpp_ac_type(f, types.backend)
            width = f.width <= 64 ? 64 : f.width
        else
            definition, width = _kernel_type(f, types.backend), f.width
        end
        return _cpp_alias!(types, "UInt$width", definition)
    end
    if types.target == :cpu && types.floats == :native
        return _cpp_type(f)
    end
    name =
        f in (IEEE16, IEEE32, IEEE64, IEEE128, IEEE256) ? "Binary$(_width(f))" :
        "Float$(f.exponent_bits)_$(f.fraction_bits)"
    definition = if types.target == :kernel
        word = _cpp_alias!(types, IR.UIntFormat(_width(f)))
        "EncodedFloat<$word,$(f.exponent_bits),$(f.fraction_bits)>"
    else
        _cpp_ac_type(f, types.backend)
    end
    return _cpp_alias!(types, name, definition)
end

function _cpp_value_name(p, i)
    n = p.nodes[i]
    n isa IR.Input && return "input"
    i == p.output && !(n isa IR.Const) && return "result"
    prefix =
        n isa IR.Const ? "constant" :
        n isa IR.Mul ? "product" :
        n isa IR.Add ? "sum" :
        n isa IR.FMA ? "fma" :
        n isa Union{IR.Convert, IR.Quantize} ? "converted" :
        n isa IR.FloatMantissa ? "mantissa" :
        n isa IR.FloatExponent ? "exponent" :
        n isa IR.RootArgument ? "root_argument" :
        n isa Union{IR.ScaleByExponent, IR.ScaleByInputExponent, IR.ScalePow2} ? "scaled" :
        n isa IR.Select ? "selected" :
        n isa IR.Guard ? "guarded" :
        n isa Union{IR.Compare, IR.Classify} ? "condition" :
        n isa IR.TableLoad ? "table_value" :
        n isa IR.FloatReciprocal ? "reciprocal" :
        n isa IR.CopySign ? "signed_value" : "bits"
    return "$(prefix)_$i"
end

mutable struct _CppBlock
    parent::Int
    statements::Vector{Any}
end
mutable struct _CppFlow
    program::IR.Program
    blocks::Vector{_CppBlock}
    uses::Dict{Int, Set{Int}}
    writes::Dict{Int, Set{Int}}
    constants::Set{Int}
    cached::Set{Int}
end
_CppFlow(p) = _CppFlow(p, [_CppBlock(0, [])], Dict(), Dict(), Set(), Set())

mutable struct _CppState
    done::Set{Int}
    maybe::Set{Int}
end
_CppState() = _CppState(Set(), Set())
Base.copy(s::_CppState) = _CppState(copy(s.done), copy(s.maybe))

function _cpp_merge(a, b)
    done = intersect(a.done, b.done)
    return _CppState(done, setdiff(union(a.done, a.maybe, b.done, b.maybe), done))
end
_cpp_statement!(flow, block, statement) = push!(flow.blocks[block].statements, statement)
function _cpp_child!(flow, parent)
    push!(flow.blocks, _CppBlock(parent, []))
    return length(flow.blocks)
end
function _cpp_use!(flow, block, i)
    push!(get!(Set{Int}, flow.uses, i), block)
    return _cpp_value_name(flow.program, i)
end
function _cpp_assign!(flow, block, i; source = nothing)
    source === nothing || _cpp_use!(flow, block, source)
    push!(get!(Set{Int}, flow.writes, i), block)
    _cpp_statement!(flow, block, (; kind = :assign, node = i, source))
end

function _kernel_can_reject(p, i)
    n, f = p.nodes[i], IR.format(p, i)
    n isa Union{IR.FloatMantissa, IR.FloatExponent, IR.RootArgument, IR.TableLoad} &&
        return true
    if n isa Union{IR.Mul, IR.Add, IR.FMA, IR.Convert, IR.Quantize, IR.ScalePow2}
        return f isa FixedFormat && (
            f.overflow == :reject ||
            n isa Union{IR.Convert, IR.Quantize, IR.ScalePow2} &&
            IR.format(p, n.source) isa FloatFormat
        )
    end
    return false
end

function _cpp_visit!(flow, block, i, state)
    i in state.done && return state
    n = flow.program.nodes[i]
    if i in state.maybe && !(n isa Union{IR.Input, IR.Const})
        push!(flow.cached, i)
        body = _cpp_child!(flow, block)
        inside = copy(state)
        delete!(inside.maybe, i)
        inside = _cpp_visit_uncached!(flow, body, i, inside)
        _cpp_statement!(flow, block, (; kind = :cached, node = i, body))
        skipped = copy(state)
        push!(skipped.done, i)
        delete!(skipped.maybe, i)
        return _cpp_merge(inside, skipped)
    end
    return _cpp_visit_uncached!(flow, block, i, state)
end

# A branch must visit this dependency chain before doing any other work. A
# shared member can therefore be evaluated before the branch without changing
# operand order, rejection order or laziness. Stop at conditional cache hits and
# at input-exponent normalization, which can reject before its source is visited.
function _cpp_leading(p, i, state)
    chain = Int[]
    while i ∉ state.done
        push!(chain, i)
        i in state.maybe && break
        n = p.nodes[i]
        refs =
            n isa Union{IR.Select, IR.Guard} ? (n.condition,) :
            n isa IR.ScaleByInputExponent ? (n.input,) : IR.refs(n)
        next = findfirst(ref -> ref ∉ state.done, refs)
        next === nothing && break
        i = refs[next]
    end
    return chain
end

function _cpp_visit_uncached!(flow, block, i, state)
    p, n = flow.program, flow.program.nodes[i]
    if n isa Union{IR.Input, IR.Const}
        n isa IR.Const && push!(flow.constants, i)
        _cpp_statement!(flow, block, (; kind = :observe, node = i))
    elseif n isa IR.Select
        state = _cpp_visit!(flow, block, n.condition, state)
        _cpp_use!(flow, block, n.condition)
        while true
            left = _cpp_leading(p, n.yes, state)
            right = _cpp_leading(p, n.no, state)
            shared = findfirst(ref -> ref in right, left)
            shared === nothing && break
            state = _cpp_visit!(flow, block, left[shared], state)
        end
        yes, no = _cpp_child!(flow, block), _cpp_child!(flow, block)
        left = _cpp_visit!(flow, yes, n.yes, copy(state))
        right = _cpp_visit!(flow, no, n.no, copy(state))
        _cpp_assign!(flow, yes, i; source = n.yes)
        _cpp_assign!(flow, no, i; source = n.no)
        _cpp_statement!(flow, block, (; kind = :select, condition = n.condition, yes, no))
        state = _cpp_merge(left, right)
    elseif n isa IR.Guard
        state = _cpp_visit!(flow, block, n.condition, state)
        _cpp_use!(flow, block, n.condition)
        _cpp_statement!(flow, block, (; kind = :guard, condition = n.condition))
        state = _cpp_visit!(flow, block, n.source, state)
        _cpp_assign!(flow, block, i; source = n.source)
    else
        if n isa IR.ScaleByInputExponent
            state = _cpp_visit!(flow, block, n.input, state)
            _cpp_use!(flow, block, n.input)
            _cpp_statement!(flow, block, (; kind = :input_scale, node = i))
            state = _cpp_visit!(flow, block, n.source, state)
        else
            for ref in unique(IR.refs(n))
                state = _cpp_visit!(flow, block, ref, state)
            end
        end
        foreach(ref -> _cpp_use!(flow, block, ref), IR.refs(n))
        _cpp_assign!(flow, block, i)
    end
    push!(state.done, i)
    delete!(state.maybe, i)
    return state
end

function _cpp_common_scope(flow, scopes)
    current = first(scopes)
    for scope in scopes
        ancestors = Set{Int}()
        while scope != 0
            push!(ancestors, scope)
            scope = flow.blocks[scope].parent
        end
        while current ∉ ancestors
            current = flow.blocks[current].parent
        end
    end
    return current
end

function _cpp_flow(p)
    flow = _CppFlow(p)
    _cpp_visit!(flow, 1, p.output, _CppState())
    _cpp_use!(flow, 1, p.output)
    scopes = Dict(
        i => _cpp_common_scope(flow, union(blocks, get(flow.uses, i, Set{Int}()))) for
        (i, blocks) in flow.writes
    )
    return flow, scopes
end

function _cpp_observe(io, flow, i, indent, trace, target)
    trace || return
    value = _cpp_value_name(flow.program, i)
    if target == :cpu
        println(io, indent, "record<$i>(trace, $value);")
    else
        println(
            io,
            indent,
            "if (trace) { trace->visited$i = true; trace->value$i = $value; }",
        )
    end
end

function _cpp_assignment(io, indent, destination, expression)
    expression = replace(expression, r",\s*" => ", ")
    if length(indent) + length(destination) + length(expression) + 4 <= 92
        println(io, indent, "$destination = $expression;")
    else
        # The emitter owns these expressions: split the outer function call,
        # leaving the exact vendor expression and its evaluation order intact.
        opening = findfirst('(', expression)
        println(io, indent, "$destination =")
        if opening !== nothing &&
           opening != firstindex(expression) &&
           endswith(expression, ')')
            println(io, indent, "    ", expression[1:opening])
            println(
                io,
                indent,
                "        ",
                expression[nextind(expression, opening):(end - 1)],
                ");",
            )
        else
            println(io, indent, "    $expression;")
        end
    end
end

function _cpp_render_block(io, flow, block, scopes, expressions, types, indent, trace)
    p = flow.program
    for i in sort!(collect(keys(scopes)))
        if scopes[i] == block &&
           (length(flow.writes[i]) > 1 || first(flow.writes[i]) != block)
            type, value = _cpp_alias!(types, IR.format(p, i)), _cpp_value_name(p, i)
            println(io, indent, "$type $value{};")
        end
    end
    for statement in flow.blocks[block].statements
        kind = statement.kind
        if kind == :assign
            i = statement.node
            value, type = _cpp_value_name(p, i), _cpp_alias!(types, IR.format(p, i))
            expression =
                statement.source === nothing ? expressions[i] :
                _cpp_value_name(p, statement.source)
            local_declaration = scopes[i] == block && length(flow.writes[i]) == 1
            prefix = local_declaration ? "const $type " : ""
            _cpp_assignment(io, indent, "$prefix$value", expression)
            if types.target == :kernel &&
               statement.source === nothing &&
               _kernel_can_reject(p, i)
                println(io, indent, "if (status != Status::ok) return {Output(0), status};")
            end
            i in flow.cached && println(io, indent, "computed_$value = true;")
            _cpp_observe(io, flow, i, indent, trace, types.target)
        elseif kind == :observe
            _cpp_observe(io, flow, statement.node, indent, trace, types.target)
        elseif kind == :guard
            condition = _cpp_value_name(p, statement.condition)
            rejection =
                types.target == :kernel ? "return {Output(0), Status::domain_rejected}" :
                "throw std::domain_error(\"input outside declared domain\")"
            println(io, indent, "if (!$condition) $rejection;")
        elseif kind == :input_scale
            i = statement.node
            n = p.nodes[i]
            value = _cpp_value_name(p, n.input)
            arguments = types.target == :kernel ? "$value, status" : value
            println(
                io,
                indent,
                "[[maybe_unused]] const long long scale_$i = input_exponent<$(n.divisor)>($arguments);",
            )
            if types.target == :kernel
                println(io, indent, "if (status != Status::ok) return {Output(0), status};")
            end
        elseif kind == :cached
            value = _cpp_value_name(p, statement.node)
            println(io, indent, "if (!computed_$value) {")
            _cpp_render_block(
                io,
                flow,
                statement.body,
                scopes,
                expressions,
                types,
                indent * "    ",
                trace,
            )
            println(io, indent, "}")
        elseif kind == :select
            condition = _cpp_value_name(p, statement.condition)
            println(io, indent, "if ($condition) {")
            _cpp_render_block(
                io,
                flow,
                statement.yes,
                scopes,
                expressions,
                types,
                indent * "    ",
                trace,
            )
            println(io, indent, "} else {")
            _cpp_render_block(
                io,
                flow,
                statement.no,
                scopes,
                expressions,
                types,
                indent * "    ",
                trace,
            )
            println(io, indent, "}")
        end
    end
end
