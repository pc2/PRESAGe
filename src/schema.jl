const _SCHEMA_VERSION = 10
_has_cube_reduction(p::IR.Program) = any(
    n -> n isa Union{IR.RootArgument, IR.ScaleByInputExponent} && n.divisor == 3,
    p.nodes,
)
_has_root_reduction(p::IR.Program) = any(
    n -> n isa IR.RootArgument || n isa IR.ScaleByInputExponent && n.divisor != 1,
    p.nodes,
)
_has_exponent_reduction(p::IR.Program) = any(
    n ->
        n isa
        Union{IR.FloatMantissa, IR.RootArgument, IR.ScaleByInputExponent, IR.CopySign},
    p.nodes,
)
_has_fixed(p::IR.Program) =
    any(f -> f isa FixedFormat, p.types) || any(t -> t.format isa FixedFormat, p.tables)
_rational_text(q::Rational) = "$(numerator(q))/$(denominator(q))"
function _parse_rational(text::AbstractString)
    occursin(r"^-?\d+/[1-9]\d*$", text) ||
        throw(ArgumentError("expected numerator/positive-denominator string"))
    n, d = split(text, '/')
    return parse(BigInt, n) // parse(BigInt, d)
end
function _format_data(f::FloatFormat)
    f == IEEE16 && return "binary16"
    f == IEEE32 && return "binary32"
    f == IEEE64 && return "binary64"
    f == IEEE128 && return "binary128"
    f == IEEE256 && return "binary256"
    return "float($(f.exponent_bits),$(f.fraction_bits))"
end
function _read_format(text::AbstractString)
    text == "binary16" && return IEEE16
    text == "binary32" && return IEEE32
    text == "binary64" && return IEEE64
    text == "binary128" && return IEEE128
    text == "binary256" && return IEEE256
    parts = match(r"^float\((\d+),(\d+)\)$", text)
    parts === nothing && throw(ArgumentError("unsupported floating format: $text"))
    return FloatFormat(parse(Int, parts[1]), parse(Int, parts[2]))
end
_read_format(value) = throw(ArgumentError("expected a floating format name"))
_format_data(f::FixedFormat) = Dict(
    "kind" => "fixed",
    "width" => f.width,
    "integer_bits" => f.integer_bits,
    "signed" => f.signed,
    "rounding" => string(f.rounding),
    "overflow" => string(f.overflow),
)
function _read_format(d::AbstractDict)
    d["kind"] == "fixed" || throw(ArgumentError("unsupported arithmetic format"))
    return FixedFormat(
        d["width"],
        d["integer_bits"];
        signed = d["signed"],
        rounding = Symbol(d["rounding"]),
        overflow = Symbol(d["overflow"]),
    )
end

function _spec_data(s::FunctionSpec)
    spec = Dict{String, Any}(
        "expression" => s.expression,
        "input_format" => _format_data(s.input_format),
        "absolute_error" => _rational_text(s.absolute_error),
    )
    s.output_format == s.input_format ||
        (spec["output_format"] = _format_data(s.output_format))
    s.domain === nothing || (spec["domain"] = _rational_text.(collect(s.domain)))
    return spec
end

_precision_data(p::PolynomialPrecision) = Dict(
    "coordinate_format" => _format_data(p.coordinate_format),
    "coefficient_formats" =>
        [Dict("format" => _format_data(f)) for f in p.coefficient_formats],
    "stage_formats" => [Dict("format" => _format_data(f)) for f in p.stage_formats],
)

function _read_precision(data)
    data isa AbstractDict &&
        Set(keys(data)) ==
        Set(("coordinate_format", "coefficient_formats", "stage_formats")) ||
        throw(ArgumentError("invalid polynomial precision fields"))
    function format(value)
        if value isa AbstractDict
            fields = ("kind", "width", "integer_bits", "signed", "rounding", "overflow")
            Set(keys(value)) == Set(fields) ||
                throw(ArgumentError("invalid fixed precision fields"))
        end
        return _read_format(value)
    end
    function formats(name)
        items = data[name]
        items isa AbstractVector || throw(ArgumentError("$name must be an array"))
        return map(items) do item
            item isa AbstractDict && Set(keys(item)) == Set(("format",)) ||
                throw(ArgumentError("invalid precision format entry"))
            format(item["format"])
        end
    end
    try
        return PolynomialPrecision(
            format(data["coordinate_format"]);
            coefficient_formats = formats("coefficient_formats"),
            stage_formats = formats("stage_formats"),
        )
    catch err
        err isa Union{MethodError, TypeError, KeyError} || rethrow()
        throw(ArgumentError("invalid precision format: " * sprint(showerror, err)))
    end
end

function _plan_data(p::PlanArtifact)
    fixedio = p.spec.input_format isa FixedFormat || p.spec.output_format isa FixedFormat
    guarded = p.program !== nothing && any(n -> n isa IR.Guard, p.program.nodes)
    version =
        p.program !== nothing && any(n -> n isa IR.FloatReciprocal, p.program.nodes) ? 10 :
        p.program !== nothing && any(n -> n isa IR.FloatExponent, p.program.nodes) ? 9 :
        p.program !== nothing && _has_cube_reduction(p.program) ? 8 :
        p.program !== nothing && _has_root_reduction(p.program) ? 7 :
        p.program !== nothing && _has_exponent_reduction(p.program) ? 6 :
        p.precision !== nothing ? 5 :
        fixedio || guarded ? 4 : p.program === nothing ? 1 : _has_fixed(p.program) ? 3 : 2
    d = Dict{String, Any}(
        "schema" => "presage-plan",
        "schema_version" => version,
        "status" => string(p.status),
        "spec" => _spec_data(p.spec),
    )
    isempty(p.settings) || (d["settings"] = p.settings)
    p.program === nothing || (d["program"] = _program_data(p.program))
    p.precision === nothing || (d["precision"] = _precision_data(p.precision))
    if !isempty(p.segments)
        d["segments"] = [
            Dict(
                "lower" => _rational_text(t.lower),
                "upper" => _rational_text(t.upper),
                "coefficients" => _rational_text.(t.coefficients),
            ) for t in p.segments
        ]
    end
    if p.dispatch !== nothing
        b = p.dispatch
        d["dispatch"] = Dict(
            "kind" => "magnitude_tail",
            "comparison" => string(b.comparison),
            "threshold_bits" => hex_bits(b.magnitude_threshold, p.spec.input_format),
            "positive_tail" => _rational_text(b.positive_tail),
            "negative_tail" => _rational_text(b.negative_tail),
        )
    end
    return d
end

"""Write versioned TOML; numerical payloads are exact rational strings or IEEE bits."""
write_plan(io::IO, p::PlanArtifact) = TOML.print(io, _plan_data(p); sorted = true)
write_plan(path::AbstractString, p::PlanArtifact) = open(io -> write_plan(io, p), path, "w")

function _read_plan(d)
    d["schema"] == "presage-plan" || throw(ArgumentError("unknown plan schema"))
    d["schema_version"] isa Integer &&
        !(d["schema_version"] isa Bool) &&
        1 <= d["schema_version"] <= _SCHEMA_VERSION ||
        throw(ArgumentError("unsupported plan schema version"))
    haskey(d, "program") &&
        d["schema_version"] < 2 &&
        throw(ArgumentError("arithmetic programs require schema v2"))
    haskey(d, "precision") &&
        d["schema_version"] < 5 &&
        throw(ArgumentError("individual precision requires plan schema v5"))
    s = d["spec"]
    domain = if haskey(s, "domain")
        length(s["domain"]) == 2 || throw(ArgumentError("need two domain bounds"))
        Tuple(_parse_rational.(s["domain"]))
    else
        nothing
    end
    spec = FunctionSpec(
        s["expression"];
        input_format = _read_format(s["input_format"]),
        output_format = _read_format(get(s, "output_format", s["input_format"])),
        absolute_error = _parse_rational(s["absolute_error"]),
        domain,
    )
    d["schema_version"] < 4 &&
        (spec.input_format isa FixedFormat || spec.output_format isa FixedFormat) &&
        throw(ArgumentError("fixed input/output requires schema v4"))
    dispatch = if haskey(d, "dispatch")
        b = d["dispatch"]
        b["kind"] == "magnitude_tail" || throw(ArgumentError("unsupported dispatch"))
        occursin(r"^0x[0-9a-fA-F]+$", b["threshold_bits"]) ||
            throw(ArgumentError("invalid threshold bits"))
        Dispatch(
            parse(BigInt, b["threshold_bits"][3:end]; base = 16);
            comparison = Symbol(b["comparison"]),
            positive_tail = _parse_rational(b["positive_tail"]),
            negative_tail = _parse_rational(b["negative_tail"]),
        )
    else
        nothing
    end
    segments = Segment[]
    for t in get(d, "segments", [])
        push!(
            segments,
            Segment(
                _parse_rational(t["lower"]),
                _parse_rational(t["upper"]),
                _parse_rational.(t["coefficients"]),
            ),
        )
    end
    program = haskey(d, "program") ? _read_program(d["program"]) : nothing
    program !== nothing &&
        any(n -> n isa IR.FloatReciprocal, program.nodes) &&
        d["schema_version"] < 10 &&
        throw(ArgumentError("rounded floating reciprocal requires schema v10"))
    program !== nothing &&
        any(n -> n isa IR.FloatExponent, program.nodes) &&
        d["schema_version"] < 9 &&
        throw(ArgumentError("exact exponent extraction requires schema v9"))
    program !== nothing &&
        _has_cube_reduction(program) &&
        d["schema_version"] < 8 &&
        throw(ArgumentError("cube root exponent splitting requires schema v8"))
    program !== nothing &&
        _has_root_reduction(program) &&
        d["schema_version"] < 7 &&
        throw(ArgumentError("root exponent splitting requires schema v7"))
    program !== nothing &&
        _has_exponent_reduction(program) &&
        d["schema_version"] < 6 &&
        throw(ArgumentError("exponent reduction requires schema v6"))
    program !== nothing &&
        _has_fixed(program) &&
        d["schema_version"] < 3 &&
        throw(ArgumentError("fixed arithmetic requires schema v3"))
    program !== nothing &&
        any(n -> n isa IR.Guard, program.nodes) &&
        d["schema_version"] < 4 &&
        throw(ArgumentError("domain guards require schema v4"))
    return PlanArtifact(
        spec;
        status = Symbol(d["status"]),
        dispatch,
        segments,
        settings = get(d, "settings", Dict{String, String}()),
        program,
        precision = haskey(d, "precision") ? _read_precision(d["precision"]) : nothing,
    )
end
read_plan(io::IO) = _read_plan(TOML.parse(read(io, String)))
read_plan(path::AbstractString) = _read_plan(TOML.parsefile(path))
