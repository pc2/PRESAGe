const _Interval = Tuple{Rational{BigInt}, Rational{BigInt}}
_singleton(q) = (_q(q), _q(q))
_interval_add(a, b) = (a[1] + b[1], a[2] + b[2])
function _interval_mul(a, b)
    values = (a[1] * b[1], a[1] * b[2], a[2] * b[1], a[2] * b[2])
    return (minimum(values), maximum(values))
end
_interval_magnitude(a) = max(abs(a[1]), abs(a[2]))
_interval_round(a, f) =
    (decode_fixed(round_fixed(a[1], f), f), decode_fixed(round_fixed(a[2], f), f))
function _shared_fixed_format(ranges, fraction_bits)
    lo = minimum(
        _rounded_integer(r[1] * _pow2(fraction_bits), :nearest_even) for r in ranges
    )
    hi = maximum(
        _rounded_integer(r[2] * _pow2(fraction_bits), :nearest_even) for r in ranges
    )
    integer_bits = 1
    while lo < -(BigInt(1) << (fraction_bits + integer_bits - 1)) ||
        hi >= BigInt(1) << (fraction_bits + integer_bits - 1)
        integer_bits += 1
    end
    return FixedFormat(integer_bits + fraction_bits, integer_bits)
end
function _sum_format(a::FixedFormat, b::FixedFormat)
    fraction = max(_fraction(a), _fraction(b))
    width = max(a.width + fraction - _fraction(a), b.width + fraction - _fraction(b)) + 1
    return FixedFormat(width, width - fraction)
end
_product_format(a::FixedFormat, b::FixedFormat) =
    FixedFormat(a.width + b.width, a.integer_bits + b.integer_bits)

function _check_fixed_erf_spec(spec)
    spec.expression == "erf(x)" &&
        spec.domain === nothing &&
        spec.input_format == spec.output_format &&
        spec.input_format in (IEEE16, IEEE32) || throw(
        ArgumentError(
            "fixed erf supports all-finite matching binary16 or binary32 interfaces",
        ),
    )
    return spec.input_format
end

# This layout is also reconstructed by the certifier and compared to the entire
# executed graph. Metadata alone cannot authorise a numerical certificate.
function _fixed_erf_layout(
    ss,
    fraction_bits,
    coefficient_fraction_bits,
    evaluation;
    spec = erf_spec(),
)
    interface = _check_fixed_erf_spec(spec)
    nsegments, degree = length(ss), length(first(ss).coefficients) - 1
    width = _q(4) / nsegments
    centers = [_q(2i - 1) * width / 2 for i = 1:nsegments]
    domain = (-width / 2, width / 2)
    inputformat = _shared_fixed_format([(_q(0), _q(4))], fraction_bits)
    coordinateformat = _shared_fixed_format([domain], fraction_bits)
    tables = IR.Table[IR.Table(inputformat, round_fixed.(-centers, Ref(inputformat)))]
    coefficients = [s.coefficients for s in ss]
    for k = 1:(degree + 1)
        ranges = [_singleton(c[k]) for c in coefficients]
        f = _shared_fixed_format(ranges, coefficient_fraction_bits)
        words = [round_fixed(c[k], f) for c in coefficients]
        all(i -> decode_fixed(words[i], f) == coefficients[i][k], 1:nsegments) ||
            throw(ArgumentError("coefficients are not representable at the declared scale"))
        push!(tables, IR.Table(f, words; unroll = true))
    end
    all(i -> decode_fixed(tables[1].values[i], inputformat) == -centers[i], 1:nsegments) ||
        throw(ArgumentError("coordinate precision cannot represent the segment centres"))
    nodes = IR.Node[IR.Input(interface)]
    u32 = IR.UIntFormat(_width(interface))
    raw = _push!(nodes, IR.BitCast(1, u32))
    mask = _push!(nodes, IR.Const(u32, _wordmask(interface) ⊻ _sign(interface)))
    magnitude_bits = _push!(nodes, IR.BitOp(:bitand, raw, mask))
    magnitude = _push!(nodes, IR.BitCast(magnitude_bits, interface))
    thresholds = [round_ieee(i * width, interface) for i = 1:(nsegments - 1)]
    index = _segment_index!(nodes, magnitude, interface, thresholds)
    ranges = [Dict{Int, _Interval}() for _ in ss]
    function record(node, values)
        for i in eachindex(ranges)
            ranges[i][node] = values[i]
        end
        return node
    end
    converted = record(
        _push!(nodes, IR.Convert(magnitude, inputformat)),
        [_interval_round((s.lower, s.upper), inputformat) for s in ss],
    )
    center =
        record(_push!(nodes, IR.TableLoad(1, index)), [_singleton(-c) for c in centers])
    widecoordinate = record(
        _push!(nodes, IR.Add(converted, center, _sum_format(inputformat, inputformat))),
        [_interval_add(r[converted], r[center]) for r in ranges],
    )
    coordinate = record(
        _push!(nodes, IR.Quantize(widecoordinate, coordinateformat)),
        [_interval_round(r[widecoordinate], coordinateformat) for r in ranges],
    )
    loads = [
        record(
            _push!(nodes, IR.TableLoad(k + 1, index)),
            [_singleton(c[k]) for c in coefficients],
        ) for k = 1:(degree + 1)
    ]
    firstformat = _shared_fixed_format([r[loads[end]] for r in ranges], fraction_bits)
    h = record(
        _push!(nodes, IR.Quantize(loads[end], firstformat)),
        [_interval_round(r[loads[end]], firstformat) for r in ranges],
    )
    initial, stages = h, NamedTuple[]
    hformat = firstformat
    for k = degree:-1:1
        productformat = _product_format(hformat, coordinateformat)
        products = [_interval_mul(r[h], r[coordinate]) for r in ranges]
        product, productquantizer = nothing, nothing
        if evaluation == :separate
            product = record(_push!(nodes, IR.Mul(h, coordinate, productformat)), products)
            storedproduct = _shared_fixed_format(products, fraction_bits)
            productquantizer = record(
                _push!(nodes, IR.Quantize(product, storedproduct)),
                [_interval_round(r[product], storedproduct) for r in ranges],
            )
            sumformat = _sum_format(storedproduct, tables[k + 1].format)
            wide = record(
                _push!(nodes, IR.Add(productquantizer, loads[k], sumformat)),
                [_interval_add(r[productquantizer], r[loads[k]]) for r in ranges],
            )
        else
            sumformat = _sum_format(productformat, tables[k + 1].format)
            wide = record(
                _push!(nodes, IR.FMA(h, coordinate, loads[k], sumformat)),
                [
                    _interval_add(products[i], ranges[i][loads[k]]) for
                    i in eachindex(ranges)
                ],
            )
        end
        nextformat = _shared_fixed_format([r[wide] for r in ranges], fraction_bits)
        next = record(
            _push!(nodes, IR.Quantize(wide, nextformat)),
            [_interval_round(r[wide], nextformat) for r in ranges],
        )
        push!(
            stages,
            (
                coefficient = k,
                previous = h,
                product = product,
                productquantizer = productquantizer,
                wide = wide,
                result = next,
            ),
        )
        h, hformat = next, nextformat
    end
    result = _push!(nodes, IR.Convert(h, interface))
    limit = _push!(nodes, IR.constant(4, interface))
    tail = _push!(nodes, IR.Compare(:gt, magnitude, limit))
    one = _push!(nodes, IR.constant(1, interface))
    positive = _push!(nodes, IR.Select(tail, one, result))
    positivebits = _push!(nodes, IR.BitCast(positive, u32))
    signmask = _push!(nodes, IR.Const(u32, _sign(interface)))
    signbits = _push!(nodes, IR.BitOp(:bitand, raw, signmask))
    signedbits = _push!(nodes, IR.BitOp(:bitxor, positivebits, signbits))
    signed = _push!(nodes, IR.BitCast(signedbits, interface))
    zero = _push!(nodes, IR.Classify(:zero, 1))
    output = _push!(nodes, IR.Select(zero, 1, signed))
    output = _nan_guard!(nodes, output, 1, interface)
    program = IR.Program(nodes; tables, output)
    plan = PlanArtifact(
        spec;
        program,
        segments = ss,
        dispatch = Dispatch(round_ieee(4, interface)),
        settings = Dict(
            "kernel" => "erf_fixed_horner",
            "fraction_bits" => string(fraction_bits),
            "coefficient_fraction_bits" => string(coefficient_fraction_bits),
            "evaluation" => string(evaluation),
        ),
    )
    return (; plan, ranges, coordinate, initial, stages, final = h, domain, centers, index)
end

"""Fresh fixed Horner erf candidate with common per-stage widths derived from exact range bounds."""
function erf_fixed_candidate(;
    spec::FunctionSpec = erf_spec(),
    degree::Integer = 9,
    segments::Integer = 4,
    fraction_bits::Integer = 31,
    coefficient_fraction_bits::Integer = fraction_bits,
    evaluation::Symbol = :separate,
    precision::Integer = 256,
)
    _check_fixed_erf_spec(spec)
    1 <= degree <= 32 || throw(ArgumentError("degree must be in 1:32"))
    _validate_segment_count(segments)
    0 <= fraction_bits <= 256 && 0 <= coefficient_fraction_bits <= 256 ||
        throw(ArgumentError("fractional widths must be in 0:256"))
    evaluation in (:separate, :fma) || throw(ArgumentError("invalid evaluation mode"))
    fraction_bits >= max(0, trailing_zeros(Int(segments)) - 1) ||
        throw(ArgumentError("insufficient coordinate precision"))
    width = _q(4) / segments
    ss = Segment[]
    Sollya.with_session(Sollya.Session(; precision)) do
        for i = 1:segments
            center = (2i - 1) * width / 2
            owned = Sollya.SollyaObject[]
            try
                f = Sollya.sollya("erf(x+($(_rational_text(center))))")
                push!(owned, f)
                domain = Sollya.interval(-width / 2, width / 2)
                push!(owned, domain)
                p = Sollya.fpminimax(
                    f,
                    degree,
                    coefficient_fraction_bits,
                    domain;
                    error = :absolute,
                    arithmetic = :fixed,
                )
                push!(owned, p)
                coefficients = Sollya.coefficients(p)
                append!(coefficients, fill(_q(0), degree + 1 - length(coefficients)))
                push!(ss, Segment((i - 1) * width, i * width, coefficients))
            finally
                foreach(close, reverse(owned))
            end
        end
    end
    return _fixed_erf_layout(
        ss,
        Int(fraction_bits),
        Int(coefficient_fraction_bits),
        evaluation,
        spec = spec,
    ).plan
end
