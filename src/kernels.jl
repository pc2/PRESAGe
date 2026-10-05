_push!(nodes, n) = (push!(nodes, n); length(nodes))
function _horner!(nodes, coordinate, coefficients, f, evaluation)
    evaluation in (:separate, :fma) ||
        throw(ArgumentError("evaluation must be :separate or :fma"))
    isempty(coefficients) && throw(ArgumentError("empty polynomial"))
    h = coefficients[end]
    for c in reverse(coefficients[1:(end - 1)])
        h =
            evaluation == :fma ? _push!(nodes, IR.FMA(h, coordinate, c, f)) :
            _push!(nodes, IR.Add(_push!(nodes, IR.Mul(h, coordinate, f)), c, f))
    end
    return h
end
function _nan_guard!(nodes, result, input, f)
    nan = _push!(nodes, IR.Const(f, _nan(f)))
    condition = _push!(nodes, IR.Classify(:nan, input))
    return _push!(nodes, IR.Select(condition, nan, result))
end

"""Uncertified Horner evaluator. Invalid domains return float NaN or reject fixed output."""
function polynomial_plan(
    spec::FunctionSpec,
    coefficients;
    internal_format::Union{FloatFormat, FixedFormat} = spec.output_format,
    evaluation::Symbol = :separate,
)
    f = internal_format
    nodes = IR.Node[IR.Input(spec.input_format)]
    coordinate = f == spec.input_format ? 1 : _push!(nodes, IR.Convert(1, f))
    cs = [_push!(nodes, IR.constant(_q(c), f)) for c in coefficients]
    output = _horner!(nodes, coordinate, cs, f, evaluation)
    f == spec.output_format ||
        (output = _push!(nodes, IR.Convert(output, spec.output_format)))
    if spec.domain !== nothing
        lo, hi = spec.domain
        input = spec.input_format
        if input isa FixedFormat
            a, b = _fixed_limits(input)
            lo, hi =
                max(lo, a * _pow2(-_fraction(input))), min(hi, b * _pow2(-_fraction(input)))
        end
        lo <= hi || throw(ArgumentError("domain has no supported representable interval"))
        lower =
            input isa FixedFormat ? round_fixed(lo, input; mode = :up) :
            round_ieee(lo, input; mode = :up)
        upper =
            input isa FixedFormat ? round_fixed(hi, input; mode = :down) :
            round_ieee(hi, input; mode = :down)
        dl, du = _decode_input(lower, input), _decode_input(upper, input)
        dl.kind in (:zero, :finite) &&
            du.kind in (:zero, :finite) &&
            dl.value <= du.value ||
            throw(ArgumentError("domain has no supported representable interval"))
        l = _push!(nodes, IR.Const(spec.input_format, lower))
        u = _push!(nodes, IR.Const(spec.input_format, upper))
        above = _push!(nodes, IR.Compare(:ge, 1, l))
        below = _push!(nodes, IR.Compare(:le, 1, u))
        falsevalue = _push!(nodes, IR.Const(Bool, 0))
        both = _push!(nodes, IR.Select(above, below, falsevalue))
        finite = _push!(nodes, IR.Classify(:finite, 1))
        valid = _push!(nodes, IR.Select(finite, both, falsevalue))
        if spec.output_format isa FixedFormat
            output = _push!(nodes, IR.Guard(valid, output))
        else
            nan = _push!(nodes, IR.Const(spec.output_format, _nan(spec.output_format)))
            output = _push!(nodes, IR.Select(valid, output, nan))
        end
    elseif spec.output_format isa FixedFormat
        finite = _push!(nodes, IR.Classify(:finite, 1))
        output = _push!(nodes, IR.Guard(finite, output))
    else
        output = _nan_guard!(nodes, output, 1, spec.output_format)
    end
    settings = Dict("evaluation" => string(evaluation))
    if f isa FixedFormat &&
       spec.input_format isa FixedFormat &&
       spec.output_format isa FixedFormat
        settings["kernel"] = "fixed_polynomial_horner"
    end
    return PlanArtifact(spec; program = IR.Program(nodes; output), settings)
end

function _erf_coefficients(center, width, degree, f, precision)
    Sollya.with_session(Sollya.Session(; precision)) do
        owned = Sollya.SollyaObject[]
        try
            functionexpr =
                Sollya.sollya("erf(x+($(numerator(center))/$(denominator(center))))")
            push!(owned, functionexpr)
            domain = Sollya.interval(-width / 2, width / 2)
            push!(owned, domain)
            polynomial = Sollya.fpminimax(
                functionexpr,
                degree,
                f.fraction_bits + 1,
                domain;
                error = :absolute,
                arithmetic = :floating,
            )
            push!(owned, polynomial)
            coefficients = Sollya.coefficients(polynomial)
            while length(coefficients) < degree + 1
                push!(coefficients, _q(0))
            end
            words = round_ieee.(coefficients, Ref(f))
            all(i -> decode_ieee(words[i], f).value == coefficients[i], eachindex(words)) ||
                throw(ArgumentError("coefficient exceeds its storage format"))
            return coefficients, words
        finally
            foreach(close, reverse(owned))
        end
    end
end

"""
Fresh IEEE32 erf candidate on [0,4], with odd symmetry, exact zeros and constant
tails. Uses explicit internal IEEE64 arithmetic by default; no complete-error
certificate is claimed. Segment coordinates and all coefficients are in the IR.
"""
function erf_candidate(;
    degree::Integer = 9,
    segments::Integer = 4,
    internal_format::FloatFormat = IEEE64,
    evaluation::Symbol = :separate,
    precision::Integer = 256,
)
    1 <= degree <= 32 || throw(ArgumentError("degree must be in 1:32"))
    1 <= segments <= 64 && ispow2(segments) ||
        throw(ArgumentError("segments must be a power of two up to 64"))
    evaluation in (:separate, :fma) || throw(ArgumentError("invalid evaluation mode"))
    f = internal_format
    f in (IEEE32, IEEE64) ||
        throw(ArgumentError("erf candidate supports binary32/binary64 internal arithmetic"))
    width = _q(4) // segments
    ss, rows = Segment[], Vector{UInt64}[]
    centers = [_q((2i - 1)) * width / 2 for i = 1:segments]
    for (i, center) in enumerate(centers)
        coefficients, words =
            _erf_coefficients(center, width, Int(degree), f, Int(precision))
        push!(ss, Segment((i - 1) * width, i * width, coefficients))
        push!(rows, words)
    end
    tables = IR.Table[IR.Table(f, round_ieee.(-centers, Ref(f)))]
    for k = 1:(degree + 1)
        push!(tables, IR.Table(f, [row[k] for row in rows]; unroll = true))
    end
    nodes = IR.Node[IR.Input(IEEE32)]
    u32, uindex = IR.UIntFormat(32), IR.UIntFormat(8)
    raw = _push!(nodes, IR.BitCast(1, u32))
    magnitude_mask = _push!(nodes, IR.Const(u32, 0x7fffffff))
    magnitude_bits = _push!(nodes, IR.BitOp(:bitand, raw, magnitude_mask))
    magnitude = _push!(nodes, IR.BitCast(magnitude_bits, IEEE32))
    coordinate_input = f == IEEE32 ? magnitude : _push!(nodes, IR.Convert(magnitude, f))
    index = _push!(nodes, IR.Const(uindex, 0))
    for i = 2:segments
        threshold = _push!(nodes, IR.constant((i - 1) * width, IEEE32))
        condition = _push!(nodes, IR.Compare(:ge, magnitude, threshold))
        row = _push!(nodes, IR.Const(uindex, i - 1))
        index = _push!(nodes, IR.Select(condition, row, index))
    end
    center = _push!(nodes, IR.TableLoad(1, index))
    coordinate = _push!(nodes, IR.Add(coordinate_input, center, f))
    coefficients = [_push!(nodes, IR.TableLoad(k + 1, index)) for k = 1:(degree + 1)]
    result = _horner!(nodes, coordinate, coefficients, f, evaluation)
    f == IEEE32 || (result = _push!(nodes, IR.Convert(result, IEEE32)))
    limit = _push!(nodes, IR.constant(4, IEEE32))
    tail = _push!(nodes, IR.Compare(:gt, magnitude, limit))
    one = _push!(nodes, IR.constant(1, IEEE32))
    positive = _push!(nodes, IR.Select(tail, one, result))
    positivebits = _push!(nodes, IR.BitCast(positive, u32))
    signmask = _push!(nodes, IR.Const(u32, 0x80000000))
    signbits = _push!(nodes, IR.BitOp(:bitand, raw, signmask))
    signedbits = _push!(nodes, IR.BitOp(:bitxor, positivebits, signbits))
    signed = _push!(nodes, IR.BitCast(signedbits, IEEE32))
    zero = _push!(nodes, IR.Classify(:zero, 1))
    result = _push!(nodes, IR.Select(zero, 1, signed))
    result = _nan_guard!(nodes, result, 1, IEEE32)
    return PlanArtifact(
        erf_spec();
        program = IR.Program(nodes; tables, output = result),
        segments = ss,
        dispatch = Dispatch(round_ieee(4, IEEE32)),
        settings = Dict("degree" => string(degree), "evaluation" => string(evaluation)),
    )
end
evaluate_bits(plan::PlanArtifact, bits::Integer) =
    plan.program === nothing ? throw(ArgumentError("plan has no evaluator")) :
    evaluate_bits(plan.program, bits)
interpret_trace(plan::PlanArtifact, bits::Integer) =
    plan.program === nothing ? throw(ArgumentError("plan has no evaluator")) :
    interpret_trace(plan.program, bits)
emit_cpp(io::IO, plan::PlanArtifact; kwargs...) =
    plan.program === nothing ? throw(ArgumentError("plan has no evaluator")) :
    emit_cpp(io, plan.program; kwargs...)
emit_cpp(path::AbstractString, plan::PlanArtifact; kwargs...) =
    open(io -> emit_cpp(io, plan; kwargs...), path, "w")
