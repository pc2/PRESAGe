const PolynomialFormat = Union{FloatFormat, FixedFormat}

"""
    PolynomialPrecision(coordinate_format; coefficient_formats, stage_formats)

Explicit polynomial formats, indexed in ascending power order. For degree `d`,
both lists contain `d+1` formats: coefficient storage `a₀,…,a_d` and accumulator
results `h₀,…,h_d`, including the initial load of `a_d`. All formats use the same
fixed/floating family; fixed formats require nearest-even rounding and rejected
overflow. The coordinate format is independent. Lists are copied into tuples.
"""
struct PolynomialPrecision
    coordinate_format::PolynomialFormat
    coefficient_formats::Tuple{Vararg{PolynomialFormat}}
    stage_formats::Tuple{Vararg{PolynomialFormat}}
    function PolynomialPrecision(
        coordinate_format::PolynomialFormat;
        coefficient_formats,
        stage_formats,
    )
        for formats in (coefficient_formats, stage_formats)
            formats isa Union{Tuple, AbstractVector} && 1 <= length(formats) <= 33 ||
                throw(ArgumentError("precision lists must contain 1:33 formats"))
            all(f -> f isa typeof(coordinate_format), formats) ||
                throw(ArgumentError("polynomial formats must use one arithmetic family"))
        end
        length(coefficient_formats) == length(stage_formats) || throw(
            ArgumentError("coefficient and stage format lists must have equal lengths"),
        )
        all((coordinate_format, coefficient_formats..., stage_formats...)) do f
            !(f isa FixedFormat) ||
                (f.rounding == :nearest_even && f.overflow == :reject)
        end || throw(
            ArgumentError(
                "fixed precision layouts require nearest-even rounding and rejected overflow",
            ),
        )
        new(coordinate_format, Tuple(coefficient_formats), Tuple(stage_formats))
    end
end

Base.:(==)(a::PolynomialPrecision, b::PolynomialPrecision) =
    a.coordinate_format == b.coordinate_format &&
    a.coefficient_formats == b.coefficient_formats &&
    a.stage_formats == b.stage_formats
Base.hash(p::PolynomialPrecision, h::UInt) =
    hash((p.coordinate_format, p.coefficient_formats, p.stage_formats), h)

function _precision_prefix(precision, count)
    count <= length(precision.coefficient_formats) ||
        throw(ArgumentError("precision layout is shorter than the polynomial"))
    return PolynomialPrecision(
        precision.coordinate_format;
        coefficient_formats = precision.coefficient_formats[1:count],
        stage_formats = precision.stage_formats[1:count],
    )
end
