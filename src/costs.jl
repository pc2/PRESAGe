"""Local selection policy. The LUT bit threshold is arbitrary until synthesis calibration."""
struct ImplementationModel
    lut_max_bits::BigInt
    function ImplementationModel(; lut_max_bits::Integer = 1 << 20)
        lut_max_bits >= 0 ||
            throw(ArgumentError("LUT storage threshold must be nonnegative"))
        new(BigInt(lut_max_bits))
    end
end
_lut_bits(spec) = (BigInt(1) << _width(spec.input_format)) * _width(spec.output_format)
_cost_width(f::IR.UIntFormat) = f.width
_cost_width(f) = _width(f)

"""
    BlockMemoryModel(; depth=512, word_bits=32)

Assumed rectangular memory block for local layout comparisons. The default
matches a 512-row, 32-bit coefficient bank; synthesis must establish actual
device usage. Depth and width tiling are independent, with no cross-table packing.
"""
struct BlockMemoryModel
    depth::Int
    word_bits::Int
    function BlockMemoryModel(; depth::Integer = 512, word_bits::Integer = 32)
        for value in (depth, word_bits)
            !(value isa Bool) && 1 <= value <= typemax(Int) || throw(
                ArgumentError("memory depth and word width must be positive integers"),
            )
        end
        new(Int(depth), Int(word_bits))
    end
end

"""
    table_memory_cost(plan_or_program; model=BlockMemoryModel())

Report each reachable table's entries, declared word width, cyclic row banks
and independent depth/width tiling. Includes center tables and bank padding;
unreachable tables are omitted, as in kernel emission. `blocks` is a layout
estimate under the supplied model, not a measured FPGA resource count.
"""
function table_memory_cost(p::IR.Program; model::BlockMemoryModel = BlockMemoryModel())
    flow, _ = _cpp_flow(p)
    used = _cpp_used_tables(p, _cpp_reachable(flow))
    tables = map(sort!(collect(used))) do number
        t = p.tables[number]
        entries, word_bits = length(t.values), _cost_width(t.format)
        rows = cld(entries, t.banks)
        depth_blocks = cld(rows, model.depth)
        width_blocks = cld(word_bits, model.word_bits)
        blocks = BigInt(t.banks) * depth_blocks * width_blocks
        return (;
            table = number,
            entries,
            word_bits,
            banks = t.banks,
            rows,
            depth_blocks,
            width_blocks,
            blocks,
            logical_bits = BigInt(entries) * word_bits,
            allocated_bits = blocks * model.depth * model.word_bits,
        )
    end
    return (;
        model,
        tables,
        blocks = sum((t.blocks for t in tables); init = BigInt(0)),
        logical_bits = sum((t.logical_bits for t in tables); init = BigInt(0)),
        allocated_bits = sum((t.allocated_bits for t in tables); init = BigInt(0)),
    )
end
function table_memory_cost(plan::PlanArtifact; kwargs...)
    plan.program === nothing && throw(ArgumentError("plan has no evaluator"))
    return table_memory_cost(plan.program; kwargs...)
end

"""Choose LUT or polynomial by availability and the configurable full-table storage threshold."""
function select_implementation(
    spec::FunctionSpec;
    implementation::Symbol = :auto,
    model::ImplementationModel = ImplementationModel(),
    lut_max_entries::Integer = 65536,
)
    implementation in (:auto, :lut, :polynomial) ||
        throw(ArgumentError("implementation must be auto, lut or polynomial"))
    lut_available = _lut_availability(spec, lut_max_entries).available
    implementation == :lut &&
        !lut_available &&
        throw(ArgumentError(_lut_availability(spec, lut_max_entries).reason))
    implementation != :auto && return implementation
    return lut_available && _lut_bits(spec) <= model.lut_max_bits ? :lut : :polynomial
end

"""Static IR counts and assumed table layout costs; no latency or synthesis estimates."""
function implementation_cost(
    plan::PlanArtifact;
    memory_model::BlockMemoryModel = BlockMemoryModel(),
)
    p = plan.program
    p === nothing && throw(ArgumentError("plan has no evaluator"))
    memory = table_memory_cost(p; model = memory_model)
    return (;
        table_bits = sum(
            (BigInt(length(t.values)) * _cost_width(t.format) for t in p.tables);
            init = BigInt(0),
        ),
        table_blocks = memory.blocks,
        table_allocated_bits = memory.allocated_bits,
        table_block_depth = memory_model.depth,
        table_block_word_bits = memory_model.word_bits,
        table_reads = count(n -> n isa IR.TableLoad, p.nodes),
        multiplications = count(n -> n isa IR.Mul, p.nodes),
        additions = count(n -> n isa Union{IR.Add, IR.UIntAdd}, p.nodes),
        fmas = count(n -> n isa IR.FMA, p.nodes),
        divisions = count(n -> n isa IR.FloatReciprocal, p.nodes),
        conversions = count(n -> n isa Union{IR.Convert, IR.Quantize}, p.nodes),
        comparisons = count(n -> n isa IR.Compare, p.nodes),
        normalizations = count(
            n -> n isa Union{IR.FloatMantissa, IR.RootArgument},
            p.nodes,
        ),
        exponent_scalings = count(
            n -> n isa Union{IR.ScaleByInputExponent, IR.ScaleByExponent},
            p.nodes,
        ),
        exponent_extractions = count(n -> n isa IR.FloatExponent, p.nodes),
        sign_copies = count(n -> n isa IR.CopySign, p.nodes),
    )
end
