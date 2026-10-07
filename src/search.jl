"""
    PolynomialSearchConfig(; degrees, internal_formats, precisions=nothing, transformation=:none,
        segments=(1,), evaluation=:separate,
        generation_precision=256, proof_precision=256, accuracy=1//1024,
        max_refinements=2, max_attempts=64, job_timeout=60, total_timeout=300)

Finite, ordered choices and limits for `search_polynomial`. Visit segment counts,
then degrees, then internal formats, each in the supplied order.
Formats are explicit: no integer or exponent range is changed automatically.
Optional `precisions` align one `PolynomialPrecision` (or `nothing` for shared
formats) with each internal format choice. Their lists cover the largest degree.
For `transformation=:odd`, degrees are odd original-function degrees in `1:31`,
precision lists describe q in `x*q(x²)`, and segments must be `(1,)`.
For `transformation=:reciprocal`, degrees and precision lists describe `1/m` on
`[1,2]`; one mantissa kernel uses exact exponent reconstruction. Floating
interfaces and a bounded domain strictly on one side of zero are required.
Timeouts are positive, finite seconds and include process startup.
"""
struct PolynomialSearchConfig
    degrees::Tuple{Vararg{Int}}
    internal_formats::Tuple{Vararg{Union{FloatFormat, FixedFormat}}}
    precisions::Tuple{Vararg{Union{Nothing, PolynomialPrecision}}}
    transformation::Symbol
    segments::Tuple{Vararg{Int}}
    evaluation::Symbol
    generation_precision::Int
    proof_precision::Int
    accuracy::Rational{BigInt}
    max_refinements::Int
    max_attempts::Int
    job_timeout::Float64
    total_timeout::Float64
    function PolynomialSearchConfig(;
        degrees,
        internal_formats,
        precisions = nothing,
        transformation::Symbol = :none,
        segments = (1,),
        evaluation::Symbol = :separate,
        generation_precision::Integer = 256,
        proof_precision::Integer = 256,
        accuracy::Union{Integer, Rational} = 1 // 1024,
        max_refinements::Integer = 2,
        max_attempts::Integer = 64,
        job_timeout::Real = 60,
        total_timeout::Real = 300,
    )
        degrees isa Union{Tuple, AbstractVector} && !isempty(degrees) ||
            throw(ArgumentError("degrees must be a nonempty finite vector or tuple"))
        all(d -> d isa Integer && !(d isa Bool) && 0 <= d <= 32, degrees) ||
            throw(ArgumentError("degrees must be integers in 0:32"))
        internal_formats isa Union{Tuple, AbstractVector} && !isempty(internal_formats) ||
            throw(
                ArgumentError("internal formats must be a nonempty finite vector or tuple"),
            )
        all(f -> f isa Union{FloatFormat, FixedFormat}, internal_formats) ||
            throw(ArgumentError("internal choices must be floating or fixed formats"))
        length(unique(degrees)) == length(degrees) ||
            throw(ArgumentError("search choices must not contain duplicates"))
        layouts =
            precisions === nothing ? fill(nothing, length(internal_formats)) : precisions
        layouts isa Union{Tuple, AbstractVector} &&
            length(layouts) == length(internal_formats) &&
            all(p -> p isa Union{Nothing, PolynomialPrecision}, layouts) ||
            throw(ArgumentError("precision choices must match the internal format list"))
        length(unique(collect(zip(internal_formats, layouts)))) ==
        length(internal_formats) ||
            throw(ArgumentError("search choices must not contain duplicates"))
        for (format, layout) in zip(internal_formats, layouts)
            _validate_precision_request(
                layout,
                _coefficient_degree(maximum(degrees), transformation),
                format,
            )
        end
        segments isa Union{Tuple, AbstractVector} && !isempty(segments) ||
            throw(ArgumentError("segments must be a nonempty finite vector or tuple"))
        foreach(_validate_segment_count, segments)
        for degree in degrees, count in segments
            _validate_transformation(transformation, degree, count)
        end
        length(unique(segments)) == length(segments) ||
            throw(ArgumentError("segment choices must not contain duplicates"))
        # The same numerical/policy validation is used by the one-attempt API.
        for format in internal_formats
            any(>(1), segments) &&
                format isa FixedFormat &&
                !format.signed &&
                throw(
                    ArgumentError("normalized coordinates require signed fixed internals"),
                )
            _validate_polynomial_settings(
                first(degrees),
                format,
                evaluation,
                generation_precision,
                proof_precision,
                accuracy,
                max_refinements,
            )
        end
        1 <= max_attempts <= typemax(Int) ||
            throw(ArgumentError("maximum attempts must be a positive Int"))
        job = Float64(job_timeout)
        total = Float64(total_timeout)
        isfinite(job) && job > 0 && isfinite(total) && total > 0 ||
            throw(ArgumentError("timeouts must be positive finite seconds"))
        new(
            Tuple(Int.(degrees)),
            Tuple(internal_formats),
            Tuple(layouts),
            transformation,
            Tuple(Int.(segments)),
            evaluation,
            Int(generation_precision),
            Int(proof_precision),
            _q(accuracy),
            Int(max_refinements),
            Int(max_attempts),
            job,
            total,
        )
    end
end

"""One attempted configuration, with exact stored data when available."""
struct SearchAttempt
    degree::Int
    internal_format::Union{FloatFormat, FixedFormat}
    segments::Int
    precision::Union{Nothing, PolynomialPrecision}
    status::Symbol
    elapsed_seconds::Float64
    plan::Union{Nothing, PlanArtifact}
    certificate::Union{Nothing, CertificationResult}
    reason::String
end

"""First certified candidate, or `search_limit` with the complete attempt history."""
struct PolynomialSearchResult
    spec::FunctionSpec
    config::PolynomialSearchConfig
    status::Symbol
    selected::Union{Nothing, CertificationResult}
    attempts::Tuple{Vararg{SearchAttempt}}
    elapsed_seconds::Float64
    stop_reason::Symbol
end

_elapsed(start::UInt64) = Float64(time_ns() - start) / 1e9
# A budget below one nanosecond cannot survive one clock tick. Treat it as
# expired even when two successive clock reads happen to return the same value.
_search_remaining(start, seconds) = seconds < 1e-9 ? 0.0 : seconds - _elapsed(start)

# Serialization is an ephemeral protocol between processes using this same Julia
# environment. Public artifacts use versioned, exact TOML instead.
function _worker_save(path, value)
    temporary = path * ".tmp"
    serialize(temporary, value)
    mv(temporary, path; force = true)
    return nothing
end

function _polynomial_worker_main(args)
    directory = only(args)
    request = deserialize(joinpath(directory, "request"))
    config = request.config
    try
        stored = get(request, :stored_plan, nothing)
        result = if stored === nothing
            _certified_polynomial(
                request.spec,
                request.domain,
                request.degree,
                request.internal_format,
                config.evaluation,
                config.generation_precision,
                config.proof_precision,
                config.accuracy,
                config.max_refinements;
                segments = request.segments,
                precision_layout = request.precision,
                transformation = config.transformation,
                candidate_ready = plan ->
                    _worker_save(joinpath(directory, "candidate"), _plan_data(plan)),
            )
        else
            plan = _reformat_polynomial(_read_plan(stored), request.precision)
            _worker_save(joinpath(directory, "candidate"), _plan_data(plan))
            certify_plan(
                plan;
                precision = config.proof_precision,
                accuracy = config.accuracy,
                max_refinements = config.max_refinements,
            )
        end
        # Encode the IR with its existing schema: raw Julia serialization does
        # not reliably reconstruct tuples containing Type{Bool} in IR.Program.
        _worker_save(
            joinpath(directory, "result"),
            (
                plan = _plan_data(result.plan),
                status = result.status,
                total_bound = result.total_bound,
                paths = result.paths,
                tail_bound = result.tail_bound,
                settings = result.settings,
                reason = result.reason,
            ),
        )
    catch err
        err isa InterruptException && rethrow()
        _worker_save(joinpath(directory, "error"), sprint(showerror, err))
    end
    return nothing
end

function _polynomial_worker_command(
    directory;
    script = joinpath(@__DIR__, "..", "scripts", "polynomial_worker.jl"),
)
    project = Base.active_project()
    project === nothing && throw(ArgumentError("search requires an active Julia project"))
    command = `$(Base.julia_cmd()) --startup-file=no --history-file=no --threads=1 --project=$(dirname(project)) $script $directory`
    return addenv(
        command,
        "JULIA_DEPOT_PATH" => join(DEPOT_PATH, Sys.iswindows() ? ';' : ':'),
        "JULIA_LOAD_PATH" => join(LOAD_PATH, Sys.iswindows() ? ';' : ':'),
    )
end

function _worker_log(path)
    isfile(path) || return ""
    return open(path, "r") do io
        # Retain a bounded diagnostic tail, even for noisy native failures.
        seek(io, max(0, filesize(path) - 4096))
        strip(String(read(io)))
    end
end

function _worker_candidate(directory)
    path = joinpath(directory, "candidate")
    isfile(path) || return nothing
    return _read_plan(deserialize(path))
end

function _stop_polynomial_worker(process)
    process_running(process) && kill(process, Base.SIGKILL)
    wait(process) # Reap this owned process before its files can be removed.
    return nothing
end

function _run_polynomial_job(request, search_started; worker_command, process_started)
    started = time_ns()
    return mktempdir(; prefix = "presage-worker-") do directory
        serialize(joinpath(directory, "request"), request)
        log = joinpath(directory, "worker.log")
        process = nothing
        timed_out = false
        deadline = false
        try
            total_remaining =
                _search_remaining(search_started, request.config.total_timeout)
            job_remaining = _search_remaining(started, request.config.job_timeout)
            if min(total_remaining, job_remaining) <= 0
                deadline = total_remaining <= 0
                return SearchAttempt(
                    request.degree,
                    request.internal_format,
                    request.segments,
                    request.precision,
                    :timeout,
                    _elapsed(started),
                    nothing,
                    nothing,
                    deadline ? "Total search deadline expired before launch" :
                    "Job wall-time limit expired before launch",
                ),
                deadline
            end
            process = open(log, "w") do io
                run(pipeline(worker_command(directory); stdout = io, stderr = io); wait = false)
            end
            process_started(process, directory)
            while process_running(process)
                job_remaining = _search_remaining(started, request.config.job_timeout)
                total_remaining =
                    _search_remaining(search_started, request.config.total_timeout)
                if min(job_remaining, total_remaining) <= 0
                    timed_out = true
                    deadline = total_remaining <= 0
                    break
                end
                sleep(min(0.01, job_remaining, total_remaining))
            end
            # Reject late results too, rather than accepting a result after a limit.
            deadline |= _search_remaining(search_started, request.config.total_timeout) <= 0
            timed_out |=
                deadline || _search_remaining(started, request.config.job_timeout) <= 0
        finally
            process === nothing || _stop_polynomial_worker(process)
        end
        elapsed = _elapsed(started)
        plan, certificate = nothing, nothing
        worker_error = nothing
        read_error = nothing
        try
            plan = _worker_candidate(directory)
            error_path = joinpath(directory, "error")
            if isfile(error_path)
                worker_error = deserialize(error_path)
                worker_error isa String || throw(ArgumentError("invalid worker error"))
            end
            path = joinpath(directory, "result")
            if isfile(path)
                data = deserialize(path)
                certificate = CertificationResult(
                    _read_plan(data.plan),
                    data.status,
                    data.total_bound,
                    data.paths,
                    data.tail_bound,
                    data.settings,
                    data.reason,
                )
                plan = certificate.plan
            end
        catch err
            err isa InterruptException && rethrow()
            read_error = "Invalid worker result: " * sprint(showerror, err)
        end
        status, reason = if timed_out
            :timeout, deadline ? "Total search deadline expired" : "Job wall-time limit expired"
        elseif !success(process)
            :worker_crashed,
            "Worker exited with code $(process.exitcode), signal $(process.termsignal)"
        elseif read_error !== nothing
            :worker_failed, read_error
        elseif worker_error !== nothing
            :worker_failed, worker_error
        elseif certificate !== nothing
            certificate.status, certificate.reason
        else
            :worker_failed, "Worker exited without a result"
        end
        if certificate === nothing
            diagnostic = _worker_log(log)
            isempty(diagnostic) || (reason *= "\n" * diagnostic)
        end
        return SearchAttempt(
            request.degree,
            request.internal_format,
            request.segments,
            request.precision,
            status,
            elapsed,
            plan,
            certificate,
            reason,
        ),
        deadline
    end
end

"""
    search_polynomial(spec, config::PolynomialSearchConfig)

Try segment counts in order, then degrees, then formats. Return the first
complete certificate that meets the contract. Each attempt runs in a fresh Julia
process; timed-out processes are killed and reaped before continuing. All native
Sollya objects remain in the worker. Startup counts toward both wall-time limits.

Invalid requests throw `ArgumentError` before any worker starts. Candidate failures
(including timeout and crash) can advance the search. Exhausting choices, attempts
or the total deadline returns `search_limit`, not a claim of infeasibility. Attempts
retain exact plans, proof contributions and reasons when available, including a
candidate checkpoint if proof was interrupted. No global cost optimality is claimed.
"""
search_polynomial(spec::FunctionSpec, config::PolynomialSearchConfig) =
    _search_polynomial(spec, config)

function _search_polynomial(
    spec,
    config;
    worker_command = _polynomial_worker_command,
    process_started = (process, directory) -> nothing,
)
    # Validate all choices, including ones beyond the attempt limit.
    config.transformation == :odd && _validate_odd_spec(spec)
    config.transformation == :reciprocal && _reciprocal_geometry(spec)
    domain = nothing
    for format in config.internal_formats
        domain = _validate_polynomial_request(
            spec,
            first(config.degrees),
            format,
            config.evaluation,
            config.generation_precision,
            config.proof_precision,
            config.accuracy,
            config.max_refinements,
        )
        for segments in config.segments
            _validate_segment_request(spec, segments, format)
        end
    end
    started = time_ns()
    attempts = SearchAttempt[]
    finish(status, selected, reason) = PolynomialSearchResult(
        spec,
        config,
        status,
        selected,
        Tuple(attempts),
        _elapsed(started),
        reason,
    )
    for segments in config.segments,
        degree in config.degrees,
        (internal_format, precision) in zip(config.internal_formats, config.precisions)

        _search_remaining(started, config.total_timeout) <= 0 &&
            return finish(:search_limit, nothing, :total_deadline)
        length(attempts) >= config.max_attempts &&
            return finish(:search_limit, nothing, :attempt_limit)
        request = (; spec, config, domain, degree, internal_format, segments, precision)
        attempt, deadline =
            _run_polynomial_job(request, started; worker_command, process_started)
        push!(attempts, attempt)
        (deadline || _search_remaining(started, config.total_timeout) <= 0) &&
            return finish(:search_limit, nothing, :total_deadline)
        attempt.status == :certified &&
            return finish(:certified, attempt.certificate, :certified)
    end
    return finish(:search_limit, nothing, :choices_exhausted)
end

function _search_data(result::PolynomialSearchResult)
    config = result.config
    attempts = map(enumerate(result.attempts)) do (index, attempt)
        data = Dict{String, Any}(
            "index" => index,
            "degree" => attempt.degree,
            "internal_format" => _format_data(attempt.internal_format),
            "status" => string(attempt.status),
            "elapsed_seconds" => attempt.elapsed_seconds,
            "reason" => attempt.reason,
        )
        config.segments == (1,) || (data["segments"] = attempt.segments)
        attempt.precision === nothing ||
            (data["precision"] = _precision_data(attempt.precision))
        attempt.plan === nothing || (data["plan"] = _plan_data(attempt.plan))
        attempt.certificate === nothing ||
            (data["certificate"] = _certificate_data(attempt.certificate))
        data
    end
    data = Dict{String, Any}(
        "schema" => "presage-search",
        "schema_version" => _search_schema_version(config),
        "spec" => _spec_data(result.spec),
        "status" => string(result.status),
        "stop_reason" => string(result.stop_reason),
        "elapsed_seconds" => result.elapsed_seconds,
        "attempts" => collect(attempts),
    )
    merge!(data, _search_config_fields(config))
    result.selected === nothing || (data["selected_attempt"] = length(result.attempts))
    return data
end

"""Write the ordered search history, exact available plans and proof reports as TOML."""
write_search_report(io::IO, result::PolynomialSearchResult) =
    TOML.print(io, _search_data(result); sorted = true)
write_search_report(path::AbstractString, result::PolynomialSearchResult) =
    open(io -> write_search_report(io, result), path, "w")
