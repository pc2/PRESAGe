"""Reproducible boundary, domain-grid, exponent and random sampling; small formats can be exhausted."""
struct VerificationSampling
    exhaustive_bits::Int
    grid_points::Int
    exponent_points::Int
    random_points::Int
    seed::UInt64
    function VerificationSampling(;
        exhaustive_bits::Integer = 12,
        grid_points::Integer = 257,
        exponent_points::Integer = 64,
        random_points::Integer = 512,
        seed::Integer = 0x8baf672eb17227d9,
    )
        !(exhaustive_bits isa Bool) && 0 <= exhaustive_bits <= 16 ||
            throw(ArgumentError("exhaustive_bits must be in 0:16"))
        all(
            n -> !(n isa Bool) && 0 <= n <= 1_000_000,
            (grid_points, exponent_points, random_points),
        ) || throw(ArgumentError("sample counts must be integers in 0:1000000"))
        0 <= seed <= typemax(UInt64) || throw(ArgumentError("seed must fit UInt64"))
        new(
            Int(exhaustive_bits),
            Int(grid_points),
            Int(exponent_points),
            Int(random_points),
            UInt64(seed),
        )
    end
end

_verification_plan(p::PlanArtifact) = p
_verification_plan(c::CertificationResult) = c.plan

function _sample_transitions!(points, plan, count)
    count == 0 && return
    # Half-integer transitions of the actual stored reduction multiplier.
    kernel = get(plan.settings, "kernel", "")
    multiplier = if kernel == "exp_polynomial_horner"
        first(_exp_audit(plan).paths).inverse_log2
    elseif kernel == "periodic_polynomial_horner"
        first(_periodic_audit(plan).paths).inverse_pi2
    else
        nothing
    end
    multiplier === nothing && return
    lo, hi = plan.spec.domain
    first_index, last_index =
        ceil(BigInt, lo * multiplier - 1 // 2), floor(BigInt, hi * multiplier - 1 // 2)
    last_index < first_index && return
    n = Int(min(BigInt(count), last_index - first_index + 1))
    for i = 0:(n - 1)
        k = first_index + (n == 1 ? 0 : fld(i * (last_index - first_index), n - 1))
        push!(points, (k + 1 // 2) / multiplier)
    end
end

"""Choose exact input words for a plan. Fixed-output samples stay inside its finite contract."""
function sample_inputs(candidate; sampling::VerificationSampling = VerificationSampling())
    plan = _verification_plan(candidate)
    plan.program === nothing && throw(ArgumentError("plan has no evaluator"))
    f = plan.spec.input_format
    width, mask = _width(f), BigInt(_word_mask(_width(f)))
    words = BigInt[]
    if width <= sampling.exhaustive_bits
        append!(words, BigInt.(0:Int(mask)))
    else
        function neighbors(word)
            for b in (BigInt(word) - 1, BigInt(word), BigInt(word) + 1)
                0 <= b <= mask && push!(words, b)
            end
        end
        neighbors(0)
        neighbors(mask)
        neighbors(BigInt(1) << (width - 1))
        points = Rational{BigInt}[_q(x) for x in (0, -4, -2, -1, -1 // 2, 1 // 2, 1, 2, 4)]
        if f isa FloatFormat
            for b in (
                0,
                _sign(f),
                _inf(f),
                _inf(f) | _sign(f),
                _nan(f),
                _nan(f) | _sign(f),
                BigInt(1) << f.fraction_bits,
            )
                neighbors(b)
            end
            lastfield = (BigInt(1) << f.exponent_bits) - 2
            fractions = (
                BigInt(0),
                BigInt(1),
                BigInt(1) << (f.fraction_bits - 1),
                (BigInt(1) << f.fraction_bits) - 1,
            )
            for i = 0:(sampling.exponent_points - 1)
                field =
                    sampling.exponent_points == 1 ? BigInt(_bias(f)) :
                    fld(i * lastfield, sampling.exponent_points - 1)
                for fraction in fractions, sign in (BigInt(0), BigInt(_sign(f)))
                    neighbors(sign | (field << f.fraction_bits) | fraction)
                end
            end
        end
        for segment in plan.segments
            append!(
                points,
                (segment.lower, segment.upper, (segment.lower + segment.upper) / 2),
            )
        end
        plan.dispatch === nothing ||
            push!(points, decode_ieee(plan.dispatch.magnitude_threshold, f).value)
        # Constants used by comparisons include special/tail and parity boundaries.
        for node in plan.program.nodes
            node isa IR.Compare || continue
            for index in (node.a, node.b)
                constant = plan.program.nodes[index]
                constant isa IR.Const &&
                    constant.format isa Union{FloatFormat, FixedFormat} || continue
                x = _decode_input(constant.bits, constant.format)
                x.value === nothing || push!(points, x.value)
            end
        end
        if plan.spec.domain !== nothing
            lo, hi = plan.spec.domain
            append!(points, (lo, hi))
            for i = 0:(sampling.grid_points - 1)
                push!(
                    points,
                    sampling.grid_points == 1 ? (lo + hi) / 2 :
                    lo + (hi - lo) * i / (sampling.grid_points - 1),
                )
            end
            _sample_transitions!(points, plan, sampling.grid_points)
        end
        state = sampling.seed
        for _ = 1:(sampling.random_points)
            word = BigInt(0)
            for _ = 1:cld(width, 64)
                state = state * UInt64(6364136223846793005) + UInt64(1442695040888963407)
                word = (word << 64) | state
            end
            push!(words, word & mask)
            if plan.spec.domain !== nothing
                lo, hi = plan.spec.domain
                push!(points, lo + (hi - lo) * BigInt(state) / (BigInt(1) << 64))
            end
        end
        sample_format =
            f isa FixedFormat ?
            FixedFormat(
                f.width,
                f.integer_bits;
                signed = f.signed,
                rounding = f.rounding,
                overflow = :saturate,
            ) : f
        for point in points
            word = _round_output(point, sample_format)
            neighbors(word)
            f isa FloatFormat && neighbors(xor(word, _sign(f)))
        end
    end
    if plan.spec.output_format isa FixedFormat
        filter!(words) do word
            x = _decode_input(word, f)
            x.value !== nothing && (
                plan.spec.domain === nothing ||
                plan.spec.domain[1] <= x.value <= plan.spec.domain[2]
            )
        end
    end
    unique!(words)
    return words
end

_verification_endpoint(b::DyadicBound) =
    b.kind == :finite ? "$(b.significand)@$(b.exponent)" : b.negative ? "-inf" : "+inf"

function _verification_enclosure(oracle, bits, result)
    result.enclosure === nothing || return _verification_endpoint.(result.enclosure)
    if result.status in (:resolved, :overflow) && oracle.polynomial
        value = Sollya.substitute(
            oracle.expression,
            _decode_input(bits, oracle.spec.input_format).value,
        )
        try
            q = Sollya.exact_rational(value)
            return (_rational_text(q), _rational_text(q))
        finally
            close(value)
        end
    elseif result.status in (:special, :overflow)
        x = _decode_input(bits, oracle.spec.input_format)
        p = oracle.primitive
        # Keep the mathematical identity before fixed saturation/wrap or output rounding.
        q = if x.kind == :zero
            p in _ODD_ZERO ? 0 : p in (:exp, :erfc, :cos, :cosh) ? 1 : nothing
        elseif x.kind == :infinity
            p in (:erf, :tanh) ? (x.negative ? -1 : 1) :
            p == :erfc ? (x.negative ? 2 : 0) :
            p == :expm1 && x.negative ? -1 :
            p == :recip || p == :rsqrt && !x.negative || p == :exp && x.negative ? 0 :
            nothing
        else
            nothing
        end
        q === nothing || return (_rational_text(_q(q)), _rational_text(_q(q)))
    end
    return ("-", "-")
end

function _verification_branch(plan, trace)
    labels = String[]
    for (index, node) in enumerate(plan.program.nodes)
        haskey(trace.values, index) || continue
        if node isa IR.Select
            push!(labels, "select:$index=$(trace.values[node.condition] ? "yes" : "no")")
        elseif node isa IR.TableLoad
            push!(labels, "table:$index=$(trace.values[node.index])")
        elseif node isa IR.Convert &&
               node.format isa FixedFormat &&
               _fraction(node.format) == 0
            push!(
                labels,
                "integer:$index=$(_fixed_units(trace.values[index].bits, node.format))",
            )
        end
    end
    return isempty(labels) ? "straight" : join(labels, ',')
end

function _verification_format_line(io, label, f::FloatFormat)
    println(io, label, "\tfloat\t", f.exponent_bits, '\t', f.fraction_bits, "\t0")
end
function _verification_format_line(io, label, f::FixedFormat)
    println(io, label, "\tfixed\t", f.width, '\t', f.integer_bits, '\t', Int(f.signed))
end

"""
    write_verification_bundle(candidate, directory; inputs=nothing, sampling=VerificationSampling(),
                              backend=:sollya, config=OracleConfig(), byteorder=:little)

Publish exact raw inputs, interpreter outputs and reference enclosures for the standalone
C++ checker. A CertificationResult also supplies its global bound. Existing directories
are refused; a failed generation leaves no partial bundle. Sampling never creates a proof.
"""
function write_verification_bundle(
    candidate,
    directory::AbstractString;
    inputs = nothing,
    sampling::VerificationSampling = VerificationSampling(),
    backend::Symbol = :sollya,
    config::OracleConfig = OracleConfig(),
    byteorder::Symbol = :little,
)
    plan = _verification_plan(candidate)
    plan.program === nothing && throw(ArgumentError("plan has no evaluator"))
    byteorder in (:little, :big) || throw(ArgumentError("invalid byte order"))
    destination = abspath(directory)
    ispath(destination) && throw(ArgumentError("refusing to overwrite $destination"))
    words = inputs === nothing ? sample_inputs(plan; sampling) : collect(inputs)
    all(
        w -> w isa Integer && 0 <= w <= _word_mask(_width(plan.spec.input_format)),
        words,
    ) || throw(ArgumentError("invalid input words"))
    certificate = candidate isa CertificationResult ? candidate : nothing
    bound = certificate === nothing ? nothing : certificate.total_bound
    metadata = Dict{String, Any}(
        "schema" => "presage-verification-bundle",
        "schema_version" => 1,
        "spec" => _spec_data(plan.spec),
        "byteorder" => string(byteorder),
        "count" => length(words),
        "input_word_bytes" => _word_bytes(plan.spec.input_format),
        "output_word_bytes" => _word_bytes(plan.spec.output_format),
        "padding" => "zero_high_bits",
        "input_order" => "record_order",
        "reference_backend" => string(backend),
        "sampling" =>
            inputs === nothing ?
            Dict(
                "mode" => "generated",
                "exhaustive_bits" => sampling.exhaustive_bits,
                "grid_points" => sampling.grid_points,
                "exponent_points" => sampling.exponent_points,
                "random_points" => sampling.random_points,
                "seed" => string(sampling.seed),
            ) : Dict("mode" => "explicit"),
    )
    bound === nothing || (metadata["certificate_bound"] = _rational_text(bound))
    metadata["certificate_scope"] = "global_finite_contract"
    mkpath(dirname(destination))
    temporary = mktempdir(dirname(destination); prefix = ".presage-verification-")
    try
        write_plan(joinpath(temporary, "plan.toml"), plan)
        certificate === nothing ||
            write_certificate(joinpath(temporary, "certificate.toml"), certificate)
        with_oracle(plan.spec; backend, config) do oracle
            open(joinpath(temporary, "cases.tsv"), "w") do cases
                println(cases, "PRESAGE_VERIFICATION\t1")
                _verification_format_line(cases, "input", plan.spec.input_format)
                _verification_format_line(cases, "output", plan.spec.output_format)
                println(cases, "byteorder\t", byteorder)
                println(cases, "absolute_error\t", _rational_text(plan.spec.absolute_error))
                println(cases, "count\t", length(words))
                println(
                    cases,
                    "index\tinput_bits\texpected_bits\treference_status\treference_bits\treference_lower\treference_upper\treference_precision\tcertificate_bound\tbranch",
                )
                open(joinpath(temporary, "inputs.bin"), "w") do input_io
                    open(joinpath(temporary, "expected.bin"), "w") do expected_io
                        for (index, bits) in enumerate(words)
                            trace = interpret_trace(plan, bits)
                            x = _decode_input(bits, plan.spec.input_format)
                            covered =
                                x.value !== nothing && (
                                    plan.spec.domain === nothing ||
                                    plan.spec.domain[1] <= x.value <= plan.spec.domain[2]
                                )
                            # Accuracy is a finite-contract check. Nonfinite/outside words
                            # still exercise the exact IR special and rejection branches.
                            result =
                                covered ? reference(oracle, bits) :
                                _result(
                                    :outside_domain,
                                    nothing,
                                    backend,
                                    "outside finite accuracy contract",
                                )
                            lower, upper = _verification_enclosure(oracle, bits, result)
                            case_bound =
                                covered && bound !== nothing ? _rational_text(bound) : "-"
                            row = (
                                index,
                                hex_bits(bits, plan.spec.input_format),
                                hex_bits(trace.bits, plan.spec.output_format),
                                result.status,
                                result.bits === nothing ? "-" :
                                hex_bits(result.bits, plan.spec.output_format),
                                lower,
                                upper,
                                result.precision,
                                case_bound,
                                _verification_branch(plan, trace),
                            )
                            println(cases, join(row, '\t'))
                            _write_word(
                                input_io,
                                bits,
                                _word_bytes(plan.spec.input_format),
                                byteorder,
                            )
                            _write_word(
                                expected_io,
                                trace.bits,
                                _word_bytes(plan.spec.output_format),
                                byteorder,
                            )
                        end
                    end
                end
            end
        end
        open(
            io -> TOML.print(io, metadata; sorted = true),
            joinpath(temporary, "manifest.toml"),
            "w",
        )
        mv(temporary, destination)
    finally
        ispath(temporary) && rm(temporary; recursive = true)
    end
    return metadata
end

# Refine only references flagged by the C++ checker, preserving input/output words.
# No error or acceptance calculation is duplicated in Julia.
function _refine_verification_bundle!(candidate, destination, report, config, backend)
    indices = Set(
        issue["index"] for issue in get(report, "issues", []) if
        get(issue, "accuracy", "") == "unresolved" ||
        get(issue, "certificate", "") == "unresolved"
    )
    isempty(indices) && return false
    path = joinpath(destination, "cases.tsv")
    lines = readlines(path)
    changed = false
    with_oracle(_verification_plan(candidate).spec; backend, config) do oracle
        for index in indices
            fields = split(lines[7 + index], '\t')
            previous = parse(Int, fields[8])
            previous >= config.max_precision && continue
            bits = parse(BigInt, fields[2][3:end]; base = 16)
            result = reference(oracle, bits)
            lower, upper = _verification_enclosure(oracle, bits, result)
            fields[4] = string(result.status)
            fields[5] =
                result.bits === nothing ? "-" :
                hex_bits(result.bits, oracle.spec.output_format)
            fields[6], fields[7], fields[8] = lower, upper, string(result.precision)
            updated = join(fields, '\t')
            changed |= updated != lines[7 + index]
            lines[7 + index] = updated
        end
    end
    if changed
        temporary, io = mktemp(destination)
        try
            foreach(line -> println(io, line), lines)
            close(io)
            mv(temporary, path; force = true)
        finally
            isopen(io) && close(io)
            ispath(temporary) && rm(temporary)
        end
    end
    return changed
end

"""Compile the standalone host checker; requires a C++20 compiler, GMP and MPFR."""
function build_verification_checker(
    path::AbstractString;
    compiler::AbstractString = get(
        ENV,
        "CXX",
        isfile("/opt/homebrew/opt/llvm/bin/clang++") ?
        "/opt/homebrew/opt/llvm/bin/clang++" : "c++",
    ),
    gmp_prefix::AbstractString = get(
        ENV,
        "GMP_PREFIX",
        isdir("/opt/homebrew/opt/gmp") ? "/opt/homebrew/opt/gmp" : "",
    ),
    mpfr_prefix::AbstractString = get(
        ENV,
        "MPFR_PREFIX",
        isdir("/opt/homebrew/opt/mpfr") ? "/opt/homebrew/opt/mpfr" : "",
    ),
)
    destination = abspath(path)
    mkpath(dirname(destination))
    options = String[]
    for prefix in unique((gmp_prefix, mpfr_prefix))
        isempty(prefix) && continue
        append!(
            options,
            ["-isystem", joinpath(prefix, "include"), "-L" * joinpath(prefix, "lib")],
        )
    end
    source = joinpath(@__DIR__, "..", "tools", "verification", "check.cpp")
    run(
        `$compiler -std=c++20 -O2 -Wall -Wextra -Werror -I$(@__DIR__) $source $options -lmpfr -lgmpxx -lgmp -o $destination`,
    )
    return destination
end

"""Check raw outputs in bundle order using the single C++ implementation. Return its TOML report."""
function check_outputs(
    bundle::AbstractString,
    outputs::AbstractString;
    checker::AbstractString,
    precision::Integer = 256,
    report_path = nothing,
)
    !(precision isa Bool) && 32 <= precision <= typemax(Clong) ||
        throw(ArgumentError("invalid checker precision"))
    if report_path !== nothing
        protected = [
            abspath(outputs)
            joinpath.(
                Ref(abspath(bundle)),
                (
                    "inputs.bin",
                    "expected.bin",
                    "cases.tsv",
                    "manifest.toml",
                    "plan.toml",
                    "certificate.toml",
                ),
            )...
        ]
        abspath(report_path) in protected &&
            throw(ArgumentError("report would overwrite verification data"))
    end
    report, errors = IOBuffer(), IOBuffer()
    process = run(
        pipeline(
            ignorestatus(
                `$(abspath(checker)) $(abspath(bundle)) $(abspath(outputs)) $precision`,
            );
            stdout = report,
            stderr = errors,
        ),
    )
    process.exitcode in (0, 1, 2) || error("C++ checker failed: " * String(take!(errors)))
    text = String(take!(report))
    data = TOML.parse(text)
    data["schema"] == "presage-verification-report" &&
        data["schema_version"] == 1 &&
        data["status"] == ("passed", "failed", "unresolved")[process.exitcode + 1] ||
        error("invalid C++ checker report")
    if report_path !== nothing
        destination = abspath(report_path)
        mkpath(dirname(destination))
        temporary, io = mktemp(dirname(destination))
        try
            write(io, text)
            close(io)
            mv(temporary, destination; force = true)
        finally
            isopen(io) && close(io)
            ispath(temporary) && rm(temporary)
        end
    end
    return data
end

"""
    verify_samples(candidate; checker, evaluator=nothing, directory=nothing, kwargs...)

Prepare a bundle and check either interpreter outputs or the raw output of a CPU runner.
With `directory`, retain the bundle, outputs and report for replay on another host/device.
Otherwise use temporary storage. `kwargs` are passed to write_verification_bundle.
"""
function verify_samples(
    candidate;
    checker::AbstractString,
    evaluator = nothing,
    directory = nothing,
    precision::Integer = 256,
    max_refinements::Integer = 3,
    config::OracleConfig = OracleConfig(),
    backend::Symbol = :sollya,
    kwargs...,
)
    !(max_refinements isa Bool) && 0 <= max_refinements <= 8 ||
        throw(ArgumentError("max_refinements must be in 0:8"))
    function verify(destination)
        write_verification_bundle(candidate, destination; config, backend, kwargs...)
        outputs = if evaluator === nothing
            joinpath(destination, "expected.bin")
        else
            manifest = TOML.parsefile(joinpath(destination, "manifest.toml"))
            manifest["byteorder"] == "little" || throw(
                ArgumentError("generated CPU runners require little endian input"),
            )
            output = joinpath(destination, "outputs.bin")
            run(
                pipeline(
                    `$(abspath(evaluator))`;
                    stdin = joinpath(destination, "inputs.bin"),
                    stdout = output,
                ),
            )
            output
        end
        report = check_outputs(destination, outputs; checker, precision)
        reference_precision = config.initial_precision
        for _ = 1:max_refinements
            get(report["counts"], "accuracy_unresolved", 0) +
            get(report["counts"], "certificate_unresolved", 0) == 0 && break
            next = Int(
                min(
                    BigInt(config.max_precision),
                    BigInt(reference_precision) * config.growth,
                ),
            )
            next == reference_precision && break
            refinement = OracleConfig(
                initial_precision = next,
                max_precision = config.max_precision,
                growth = config.growth,
            )
            _refine_verification_bundle!(
                candidate,
                destination,
                report,
                refinement,
                backend,
            )
            reference_precision = next
            report = check_outputs(
                destination,
                outputs;
                checker,
                precision = max(precision, next),
            )
        end
        report["runner"] = evaluator === nothing ? "interpreter" : "external"
        open(
            io -> TOML.print(io, report; sorted = true),
            joinpath(destination, "report.toml"),
            "w",
        )
        return report
    end
    directory === nothing || return verify(abspath(directory))
    return mktempdir() do temporary
        verify(joinpath(temporary, "bundle"))
    end
end

"""Sample available sweep evaluators after the bounded search. Reports never change proof status or Pareto membership."""
function verify_sweep(
    result::PolynomialSweepResult;
    checker::AbstractString,
    directory = nothing,
    kwargs...,
)
    observations = Dict{Int, Dict{String, Any}}()
    for row in result.rows
        attempt = row.attempt
        attempt.plan === nothing && continue
        attempt.plan.program === nothing && continue
        candidate = attempt.certificate === nothing ? attempt.plan : attempt.certificate
        path =
            directory === nothing ? nothing : joinpath(directory, "candidate-$(row.index)")
        try
            observations[row.index] =
                verify_samples(candidate; checker, directory = path, kwargs...)
        catch error
            error isa Union{DomainError, OverflowError} || rethrow()
            observations[row.index] =
                Dict("status" => "evaluation_failed", "reason" => sprint(showerror, error))
        end
    end
    return observations
end
