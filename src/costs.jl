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

"""Choose LUT or polynomial by availability and the configurable full-table storage threshold."""
function select_implementation(
    spec::FunctionSpec;
    implementation::Symbol = :auto,
    model::ImplementationModel = ImplementationModel(),
)
    implementation in (:auto, :lut, :polynomial) ||
        throw(ArgumentError("implementation must be auto, lut or polynomial"))
    lut_available =
        spec.input_format == spec.output_format == IEEE16 && spec.domain === nothing
    implementation == :lut &&
        !lut_available &&
        throw(
            ArgumentError(
                "LUT generation requires matching binary16 interfaces and an all-finite domain",
            ),
        )
    implementation != :auto && return implementation
    return lut_available && _lut_bits(spec) <= model.lut_max_bits ? :lut : :polynomial
end

"""Static IR costs, not estimates of FPGA latency, initiation interval or device resources."""
function implementation_cost(plan::PlanArtifact)
    p = plan.program
    p === nothing && throw(ArgumentError("plan has no evaluator"))
    return (;
        table_bits = sum(
            (BigInt(length(t.values)) * _cost_width(t.format) for t in p.tables);
            init = BigInt(0),
        ),
        table_reads = count(n -> n isa IR.TableLoad, p.nodes),
        multiplications = count(n -> n isa IR.Mul, p.nodes),
        additions = count(n -> n isa IR.Add, p.nodes),
        fmas = count(n -> n isa IR.FMA, p.nodes),
        conversions = count(n -> n isa Union{IR.Convert, IR.Quantize}, p.nodes),
        comparisons = count(n -> n isa IR.Compare, p.nodes),
    )
end
