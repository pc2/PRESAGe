"""Directory for exact, locally trusted passing plans and certificates."""
struct NumericalCache
    directory::String
    NumericalCache(directory::AbstractString) = new(abspath(directory))
end

function _numerical_text(data)
    io = IOBuffer()
    TOML.print(io, data; sorted = true)
    String(take!(io))
end
_numerical_digest(data) = bytes2hex(sha256(_numerical_text(data)))
_file_digest(path) = bytes2hex(open(sha256, path))

function _numerical_sources(; track = false)
    files = Dict{String, String}()
    for (label, root) in
        (("presage", dirname(@__DIR__)), ("sollya", dirname(dirname(pathof(Sollya)))))
        project = joinpath(root, "Project.toml")
        track && Base.include_dependency(project)
        track && Base.include_dependency(joinpath(root, "src"))
        files["$label/Project.toml"] = _file_digest(project)
        for (directory, _, names) in walkdir(joinpath(root, "src")), name in sort(names)
            endswith(name, ".jl") || continue
            path = joinpath(directory, name)
            track && Base.include_dependency(path)
            files["$label/$(relpath(path, root))"] = _file_digest(path)
        end
    end
    worker = joinpath(@__DIR__, "..", "scripts", "polynomial_worker.jl")
    track && Base.include_dependency(worker)
    files["presage/scripts/polynomial_worker.jl"] = _file_digest(worker)
    _numerical_digest(files)
end

# Captured with the loaded code, including in a precompile image. A process that
# has older code loaded must not label its results with newer on-disk sources.
const _NUMERICAL_SOURCE_ID = _numerical_sources(; track = true)

function _numerical_identity()
    _numerical_sources() == _NUMERICAL_SOURCE_ID || throw(
        ArgumentError(
            "numerical sources changed after loading PRESAGe; restart Julia before using the cache",
        ),
    )
    native = Sollya.library_path()
    libraries = Dict{String, String}()
    for path in unique([native; Libdl.dllist()])
        occursin(r"(sollya|mpfr|gmp)"i, basename(path)) && isfile(path) || continue
        libraries[realpath(path)] = _file_digest(path)
    end
    project = Base.active_project()
    environment = Dict{String, String}()
    if project !== nothing
        environment["project"] = _file_digest(project)
        manifest = joinpath(dirname(project), "Manifest.toml")
        isfile(manifest) && (environment["manifest"] = _file_digest(manifest))
    end
    return Dict{String, Any}(
        "source" => _NUMERICAL_SOURCE_ID,
        "julia" => string(VERSION),
        "machine" => Sys.MACHINE,
        "libraries" => libraries,
        "environment" => environment,
    )
end

function _numerical_request(request)
    config = request.config
    data = Dict{String, Any}(
        "spec" => _spec_data(request.spec),
        "degree" => request.degree,
        "segments" => request.segments,
        "internal_format" => _format_data(request.internal_format),
        "transformation" => string(config.transformation),
        "settings" => _search_config_fields(config)["settings"],
    )
    request.precision === nothing ||
        (data["precision"] = _precision_data(request.precision))
    stored = get(request, :stored_plan, nothing)
    stored === nothing || (data["stored_plan"] = stored)
    data
end

function _cached_certificate(plan, data)
    data["schema"] == "presage-certificate" &&
        data["schema_version"] == 2 &&
        data["status"] == "certified" || throw(ArgumentError("invalid cached certificate"))
    data["expression"] == plan.spec.expression &&
        _read_format(data["input_format"]) == plan.spec.input_format &&
        _read_format(data["output_format"]) == plan.spec.output_format &&
        _parse_rational(data["absolute_error"]) == plan.spec.absolute_error ||
        throw(ArgumentError("cached contract mismatch"))
    paths = map(get(data, "paths", [])) do p
        interval(key) = Tuple(_parse_rational.(p[key]))
        ranges = Tuple(
            map(p["ranges"]) do b
                i, f = b["node"], _read_ir_type(b["format"])
                1 <= i <= length(plan.program.nodes) &&
                    IR.format(plan.program, i) == f ||
                    throw(ArgumentError("cached node mismatch"))
                range = Tuple(_parse_rational.(b["bounds"]))
                length(range) == 2 && range[1] <= range[2] ||
                    throw(ArgumentError("invalid cached range"))
                _node_bound(i, f, range)
            end,
        )
        path = PathCertificate(
            interval("domain"),
            p["upper_inclusive"],
            interval("approximation"),
            _parse_rational(p["coordinate_error"]),
            _parse_rational(p["arithmetic_error"]),
            _parse_rational(p["output_rounding"]),
            _parse_rational(p["total"]),
            ranges,
        )
        0 <= path.approximation[1] <= path.approximation[2] &&
            min(path.coordinate_error, path.arithmetic_error, path.output_rounding) >= 0 &&
            sum((
                path.approximation[2],
                path.coordinate_error,
                path.arithmetic_error,
                path.output_rounding,
            )) <= path.total ||
            throw(ArgumentError("invalid cached error contributions"))
        path
    end
    total = _parse_rational(data["total_bound"])
    tail = haskey(data, "tail") ? _parse_rational(data["tail"]["absolute_error"]) : nothing
    0 <= total <= plan.spec.absolute_error &&
        all(p -> p.total <= total, paths) &&
        (tail === nothing || 0 <= tail <= total) ||
        throw(ArgumentError("cached bound exceeds budget"))
    CertificationResult(
        plan,
        :certified,
        total,
        Tuple(paths),
        tail,
        Dict{String, String}(data["settings"]),
        data["reason"],
    )
end

function _cache_read(cache, key, request_data, identity)
    path = joinpath(cache.directory, key * ".toml")
    isfile(path) || return nothing, :miss
    try
        data = TOML.parsefile(path)
        Set(keys(data)) == Set((
            "schema",
            "schema_version",
            "key",
            "request",
            "identity",
            "payload",
            "checksum",
            "timings",
        )) || throw(ArgumentError("invalid cache fields"))
        data["schema"] == "presage-numerical-cache" &&
            data["schema_version"] == 1 &&
            data["key"] == key &&
            data["request"] == request_data &&
            data["identity"] == identity || throw(ArgumentError("incompatible cache entry"))
        payload = data["payload"]
        _numerical_digest(payload) == data["checksum"] ||
            throw(ArgumentError("damaged cache payload"))
        plan = _read_plan(payload["plan"])
        _spec_data(plan.spec) == request_data["spec"] ||
            throw(ArgumentError("cached request mismatch"))
        _stored_precision(plan) # Audit exact graph and stored coefficients, without native proof.
        result = _cached_certificate(plan, payload["certificate"])
        timings = data["timings"]
        haskey(timings, "compute_seconds") && all(
            k -> k in ("compute_seconds", "generation_seconds", "proof_seconds"),
            keys(timings),
        ) || throw(ArgumentError("incomplete cache timings"))
        all(v -> v isa Real && isfinite(v) && v >= 0, values(timings)) ||
            throw(ArgumentError("invalid cache timings"))
        return (result, timings), :hit
    catch err
        err isa InterruptException && rethrow()
        return nothing, :invalid
    end
end

function _cache_write(cache, key, request_data, identity, attempt; publish = () -> true)
    attempt.status == :certified && attempt.certificate !== nothing || return false
    payload = Dict(
        "plan" => _plan_data(attempt.plan),
        "certificate" => _certificate_data(attempt.certificate),
    )
    timings = Dict{String, Float64}("compute_seconds" => attempt.elapsed_seconds)
    attempt.generation_seconds === nothing ||
        (timings["generation_seconds"] = attempt.generation_seconds)
    attempt.proof_seconds === nothing || (timings["proof_seconds"] = attempt.proof_seconds)
    data = Dict(
        "schema" => "presage-numerical-cache",
        "schema_version" => 1,
        "key" => key,
        "request" => request_data,
        "identity" => identity,
        "payload" => payload,
        "checksum" => _numerical_digest(payload),
        "timings" => timings,
    )
    mkpath(cache.directory)
    mktempdir(cache.directory; prefix = ".presage-cache-") do temporary
        path = joinpath(temporary, "entry.toml")
        write(path, _numerical_text(data))
        publish() || return false
        # Same filesystem: readers see the previous complete entry or this one.
        Base.Filesystem.rename(path, joinpath(cache.directory, key * ".toml"))
        return true
    end
end
