_search_schema_version(config) =
    any(!isnothing, config.precisions) ? 3 : config.segments == (1,) ? 1 : 2

function _search_config_fields(config::PolynomialSearchConfig)
    fields = Dict{String, Any}(
        "order" =>
            config.segments == (1,) ? "degree_then_format" :
            "segment_then_degree_then_format",
        "degrees" => collect(config.degrees),
        "internal_formats" => [
            precision === nothing ? Dict("format" => _format_data(f)) :
            Dict("format" => _format_data(f), "precision" => _precision_data(precision)) for (f, precision) in zip(config.internal_formats, config.precisions)
        ],
        "settings" => Dict(
            "evaluation" => string(config.evaluation),
            "generation_precision" => config.generation_precision,
            "proof_precision" => config.proof_precision,
            "norm_accuracy" => _rational_text(config.accuracy),
            "max_refinements" => config.max_refinements,
        ),
        "limits" => Dict(
            "max_attempts" => config.max_attempts,
            "job_timeout_seconds" => config.job_timeout,
            "total_timeout_seconds" => config.total_timeout,
        ),
    )
    _search_schema_version(config) == 1 || (fields["segments"] = collect(config.segments))
    return fields
end

function _search_config_data(config::PolynomialSearchConfig)
    return merge(
        Dict(
            "schema" => "presage-search-config",
            "schema_version" => _search_schema_version(config),
        ),
        _search_config_fields(config),
    )
end

function _search_keys(data, allowed, name)
    data isa AbstractDict || throw(ArgumentError("$name must be a table"))
    all(key -> key in allowed, keys(data)) || throw(ArgumentError("unknown field in $name"))
    return nothing
end

function _read_search_config(data)
    _search_keys(
        data,
        (
            "schema",
            "schema_version",
            "order",
            "degrees",
            "internal_formats",
            "segments",
            "settings",
            "limits",
        ),
        "search configuration",
    )
    get(data, "schema", nothing) == "presage-search-config" ||
        throw(ArgumentError("unknown search configuration schema"))
    version = get(data, "schema_version", nothing)
    version isa Integer && !(version isa Bool) && version in (1, 2, 3) ||
        throw(ArgumentError("unsupported search configuration version"))
    (version == 1 ? !haskey(data, "segments") : haskey(data, "segments")) ||
        throw(ArgumentError("segment choices require search configuration v2"))
    order =
        version == 1 || (version == 3 && data["segments"] == [1]) ? "degree_then_format" :
        "segment_then_degree_then_format"
    get(data, "order", order) == order || throw(ArgumentError("unsupported search order"))
    haskey(data, "degrees") && haskey(data, "internal_formats") ||
        throw(ArgumentError("search configuration requires degrees and internal_formats"))
    choices = data["internal_formats"]
    choices isa AbstractVector || throw(ArgumentError("internal_formats must be an array"))
    formats = map(choices) do choice
        _search_keys(
            choice,
            version < 3 ? ("format",) : ("format", "precision"),
            "internal format choice",
        )
        haskey(choice, "format") ||
            throw(ArgumentError("internal choice requires a format"))
        value = choice["format"]
        if value isa AbstractDict
            fields = ("kind", "width", "integer_bits", "signed", "rounding", "overflow")
            _search_keys(value, fields, "fixed format")
            all(key -> haskey(value, key), fields) ||
                throw(ArgumentError("incomplete fixed format"))
        end
        try
            _read_format(value)
        catch err
            err isa Union{MethodError, TypeError} || rethrow()
            throw(
                ArgumentError(
                    "invalid internal format field type: " * sprint(showerror, err),
                ),
            )
        end
    end
    precisions = [
        haskey(choice, "precision") ? _read_precision(choice["precision"]) : nothing for
        choice in choices
    ]
    version == 3 &&
        !any(!isnothing, precisions) &&
        throw(ArgumentError("search configuration v3 requires precision layouts"))
    settings = get(data, "settings", Dict{String, Any}())
    limits = get(data, "limits", Dict{String, Any}())
    _search_keys(
        settings,
        (
            "evaluation",
            "generation_precision",
            "proof_precision",
            "norm_accuracy",
            "max_refinements",
        ),
        "search settings",
    )
    _search_keys(
        limits,
        ("max_attempts", "job_timeout_seconds", "total_timeout_seconds"),
        "search limits",
    )
    try
        return PolynomialSearchConfig(
            degrees = data["degrees"],
            internal_formats = formats,
            precisions = precisions,
            segments = get(data, "segments", (1,)),
            evaluation = Symbol(get(settings, "evaluation", "separate")),
            generation_precision = get(settings, "generation_precision", 256),
            proof_precision = get(settings, "proof_precision", 256),
            accuracy = _parse_rational(get(settings, "norm_accuracy", "1/1024")),
            max_refinements = get(settings, "max_refinements", 2),
            max_attempts = get(limits, "max_attempts", 64),
            job_timeout = get(limits, "job_timeout_seconds", 60),
            total_timeout = get(limits, "total_timeout_seconds", 300),
        )
    catch err
        err isa Union{MethodError, TypeError} || rethrow()
        throw(
            ArgumentError(
                "invalid search configuration field type: " * sprint(showerror, err),
            ),
        )
    end
end

"""Write a versioned search configuration with explicit ordered choices and limits."""
write_search_config(io::IO, config::PolynomialSearchConfig) =
    TOML.print(io, _search_config_data(config); sorted = true)
write_search_config(path::AbstractString, config::PolynomialSearchConfig) =
    open(io -> write_search_config(io, config), path, "w")

"""Read and validate a search configuration, applying defaults for omitted settings/limits."""
read_search_config(io::IO) = _read_search_config(TOML.parse(read(io, String)))
read_search_config(path::AbstractString) = _read_search_config(TOML.parsefile(path))
