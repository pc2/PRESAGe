"""
Function, formats, finite-input domain and exact absolute error target.
The output format defaults to the input format; `domain=nothing` means all
finite inputs. Standard special-value behavior is shared by all specifications.
"""
struct FunctionSpec
    expression::String
    input_format::FloatFormat
    output_format::FloatFormat
    absolute_error::Rational{BigInt}
    domain::Union{Nothing,Tuple{Rational{BigInt},Rational{BigInt}}}
    function FunctionSpec(expression::AbstractString; input_format::FloatFormat=IEEE32,
                          output_format::FloatFormat=input_format,
                          absolute_error::Union{Integer,Rational}=1//(1 << 23),
                          domain=nothing)
        isempty(strip(expression)) && throw(ArgumentError("empty function expression"))
        absolute_error > 0 || throw(ArgumentError("absolute error must be positive"))
        d = domain === nothing ? nothing : (_q(domain[1]), _q(domain[2]))
        d === nothing || d[1] <= d[2] || throw(ArgumentError("reversed domain"))
        new(String(expression), input_format, output_format, _q(absolute_error), d)
    end
end

"""IEEE32 erf specification with absolute error target 2^-23."""
erf_spec() = FunctionSpec("erf(x)")

"""Exact central/tail dispatch contract; the threshold is an input bit pattern."""
struct Dispatch
    magnitude_threshold::UInt64
    comparison::Symbol
    positive_tail::Rational{BigInt}
    negative_tail::Rational{BigInt}
    function Dispatch(threshold::Integer; comparison::Symbol=:greater,
                      positive_tail::Union{Integer,Rational}=1,
                      negative_tail::Union{Integer,Rational}=-1)
        comparison in (:greater, :greater_equal) || throw(ArgumentError("invalid dispatch comparison"))
        new(UInt64(threshold), comparison, _q(positive_tail), _q(negative_tail))
    end
end

"""Candidate segment with exact endpoints and ascending polynomial coefficients."""
struct Segment
    lower::Rational{BigInt}
    upper::Rational{BigInt}
    coefficients::Vector{Rational{BigInt}}
    function Segment(lower::Union{Integer,Rational}, upper::Union{Integer,Rational}, coefficients)
        lower < upper || throw(ArgumentError("segment must have positive width"))
        c = _q.(collect(coefficients))
        isempty(c) && throw(ArgumentError("segment needs coefficients"))
        new(_q(lower), _q(upper), c)
    end
end

"""
Version 1 contract/candidate artifact. No evaluator semantics or certificate is
implied; certified plans need the arithmetic IR and a later schema revision.
"""
struct PlanArtifact
    spec::FunctionSpec
    status::Symbol
    dispatch::Union{Nothing,Dispatch}
    segments::Vector{Segment}
    settings::Dict{String,String}
    function PlanArtifact(spec::FunctionSpec; status::Symbol=:contract,
                          dispatch::Union{Nothing,Dispatch}=nothing, segments=Segment[],
                          settings=Dict{String,String}())
        status in (:contract, :candidate) || throw(ArgumentError("schema v1 cannot claim certification"))
        if dispatch !== nothing
            t = decode_ieee(dispatch.magnitude_threshold, spec.input_format)
            t.kind == :finite && !t.negative && t.value > 0 ||
                throw(ArgumentError("dispatch needs a positive finite threshold"))
        end
        ss = collect(Segment, segments)
        all(i -> ss[i-1].upper <= ss[i].lower, 2:length(ss)) ||
            throw(ArgumentError("segments must be ordered and nonoverlapping"))
        new(spec, status, dispatch, ss, Dict{String,String}(settings))
    end
end
