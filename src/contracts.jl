"""
Function, formats, finite-input domain and exact absolute error target.
The output format defaults to the input format; `domain=nothing` means all
finite inputs, including every fixed encoding. Fixed outputs have no nonfinite
encoding; their format declares rounding and overflow behavior.
"""
struct FunctionSpec
    expression::String
    input_format::Union{FloatFormat, FixedFormat}
    output_format::Union{FloatFormat, FixedFormat}
    absolute_error::Rational{BigInt}
    domain::Union{Nothing, Tuple{Rational{BigInt}, Rational{BigInt}}}
    function FunctionSpec(
        expression::AbstractString;
        input_format::Union{FloatFormat, FixedFormat} = IEEE32,
        output_format::Union{FloatFormat, FixedFormat} = input_format,
        absolute_error::Union{Integer, Rational} = 1 // (1 << 23),
        domain = nothing,
    )
        isempty(strip(expression)) && throw(ArgumentError("empty function expression"))
        absolute_error > 0 || throw(ArgumentError("absolute error must be positive"))
        d = domain === nothing ? nothing : (_q(domain[1]), _q(domain[2]))
        d === nothing || d[1] <= d[2] || throw(ArgumentError("reversed domain"))
        new(String(expression), input_format, output_format, _q(absolute_error), d)
    end
end

"""erf specification with matching IEEE interfaces and default absolute target 2^-fraction_bits."""
erf_spec(; format::FloatFormat = IEEE32, absolute_error = _pow2(-format.fraction_bits)) =
    FunctionSpec("erf(x)"; input_format = format, absolute_error)

"""Exact central/tail dispatch contract; the threshold is an input bit pattern."""
struct Dispatch
    magnitude_threshold::Union{UInt64, BigInt}
    comparison::Symbol
    positive_tail::Rational{BigInt}
    negative_tail::Rational{BigInt}
    function Dispatch(
        threshold::Integer;
        comparison::Symbol = :greater,
        positive_tail::Union{Integer, Rational} = 1,
        negative_tail::Union{Integer, Rational} = -1,
    )
        comparison in (:greater, :greater_equal) ||
            throw(ArgumentError("invalid dispatch comparison"))
        threshold >= 0 || throw(ArgumentError("threshold must be nonnegative"))
        word = threshold <= typemax(UInt64) ? UInt64(threshold) : BigInt(threshold)
        new(word, comparison, _q(positive_tail), _q(negative_tail))
    end
end

"""Candidate segment with exact endpoints and ascending polynomial coefficients."""
struct Segment
    lower::Rational{BigInt}
    upper::Rational{BigInt}
    coefficients::Vector{Rational{BigInt}}
    function Segment(
        lower::Union{Integer, Rational},
        upper::Union{Integer, Rational},
        coefficients,
    )
        lower < upper || throw(ArgumentError("segment must have positive width"))
        c = _q.(collect(coefficients))
        isempty(c) && throw(ArgumentError("segment needs coefficients"))
        new(_q(lower), _q(upper), c)
    end
end

"""
Exact contract/candidate artifact. An optional arithmetic program defines an
evaluator, while certification remains separate.
"""
struct PlanArtifact
    spec::FunctionSpec
    status::Symbol
    dispatch::Union{Nothing, Dispatch}
    segments::Vector{Segment}
    settings::Dict{String, String}
    program::Union{Nothing, IR.Program}
    precision::Union{Nothing, PolynomialPrecision}
    function PlanArtifact(
        spec::FunctionSpec;
        program::Union{Nothing, IR.Program} = nothing,
        status::Symbol = program === nothing ? :contract : :candidate,
        dispatch::Union{Nothing, Dispatch} = nothing,
        segments = Segment[],
        settings = Dict{String, String}(),
        precision::Union{Nothing, PolynomialPrecision} = nothing,
    )
        status in (:contract, :candidate) ||
            throw(ArgumentError("artifact cannot claim certification"))
        precision === nothing ||
            program !== nothing ||
            throw(ArgumentError("precision metadata requires an evaluator program"))
        if program !== nothing
            status == :candidate ||
                throw(ArgumentError("an evaluator program is a candidate"))
            IR.format(program, program.input) == spec.input_format &&
                IR.format(program) == spec.output_format || throw(
                ArgumentError("program formats differ from the function specification"),
            )
        end
        if dispatch !== nothing
            spec.input_format isa FloatFormat ||
                throw(ArgumentError("magnitude-tail metadata requires a floating input"))
            t = decode_ieee(dispatch.magnitude_threshold, spec.input_format)
            t.kind == :finite && !t.negative && t.value > 0 ||
                throw(ArgumentError("dispatch needs a positive finite threshold"))
        end
        ss = collect(Segment, segments)
        all(i -> ss[i - 1].upper <= ss[i].lower, 2:length(ss)) ||
            throw(ArgumentError("segments must be ordered and nonoverlapping"))
        new(spec, status, dispatch, ss, Dict{String, String}(settings), program, precision)
    end
end
