# Recover the stored polynomial, then reconstruct the entire supported program.
# No coefficient metadata or kernel label can substitute for this graph audit.
function _polynomial_audit(plan)
    spec, p = plan.spec, plan.program
    p !== nothing &&
        spec.input_format isa FixedFormat &&
        spec.output_format isa FixedFormat ||
        throw(ArgumentError("polynomial certification requires fixed input and output"))
    isempty(plan.segments) && plan.dispatch === nothing && isempty(p.tables) ||
        throw(ArgumentError("polynomial certification supports one untabled Horner path"))
    all(
        f -> !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject),
        p.types,
    ) || throw(
        ArgumentError(
            "polynomial certification requires nearest-even rounding and rejected overflow",
        ),
    )
    evaluation = Symbol(get(plan.settings, "evaluation", ""))
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported Horner arithmetic"))
    guard = p.nodes[p.output]
    guard isa IR.Guard || throw(ArgumentError("missing polynomial domain guard"))
    final = guard.source
    p.nodes[final] isa IR.Convert && (final = p.nodes[final].source)
    f = IR.format(p, final)
    f isa FixedFormat ||
        throw(ArgumentError("polynomial certification requires fixed internal arithmetic"))
    coordinate = f == spec.input_format ? p.input : 2
    coefficients, stages = Rational{BigInt}[], NamedTuple[]
    h = final
    while true
        n = p.nodes[h]
        if n isa IR.Const && n.format == f
            push!(coefficients, decode_fixed(n.bits, f))
            break
        end
        length(stages) < 32 || throw(ArgumentError("polynomial degree exceeds 32"))
        if evaluation == :fma && n isa IR.FMA && n.b == coordinate
            c, previous, product = n.c, n.a, nothing
        elseif evaluation == :separate && n isa IR.Add && p.nodes[n.a] isa IR.Mul
            mul = p.nodes[n.a]
            mul.b == coordinate || throw(ArgumentError("unsupported polynomial coordinate"))
            c, previous, product = n.b, mul.a, n.a
        else
            throw(ArgumentError("executed graph is not the supported Horner evaluator"))
        end
        constant = p.nodes[c]
        constant isa IR.Const && constant.format == f ||
            throw(ArgumentError("unsupported stored coefficient"))
        push!(coefficients, decode_fixed(constant.bits, f))
        push!(stages, (result = h, previous, product, coefficient = length(coefficients)))
        h = previous
    end
    canonical = polynomial_plan(spec, coefficients; internal_format = f, evaluation)
    _program_data(canonical.program) == _program_data(p) || throw(
        ArgumentError("executed graph differs from the supported polynomial evaluator"),
    )
    a, b = _fixed_limits(spec.input_format)
    quantum = _pow2(-_fraction(spec.input_format))
    lo, hi = a * quantum, b * quantum
    if spec.domain !== nothing
        lo, hi = max(lo, spec.domain[1]), min(hi, spec.domain[2])
        lo = decode_fixed(round_fixed(lo, spec.input_format; mode = :up), spec.input_format)
        hi = decode_fixed(
            round_fixed(hi, spec.input_format; mode = :down),
            spec.input_format,
        )
    end
    return (; coefficients, stages = reverse(stages), coordinate, final, domain = (lo, hi))
end

# Endpoint rounding is monotone under the audited policy. Overflow at an
# interval endpoint refuses the proof, even if the interval is conservative.
_dyadic_fraction(q) =
    iszero(q) ? 0 :
    ndigits(denominator(q); base = 2) - 1 - trailing_zeros(abs(numerator(q)))
function _polynomial_ranges(p, domain)
    ranges, rho = Dict{Int, _Interval}(), Dict{Int, Rational{BigInt}}()
    grids = Dict{Int, Int}()
    needed = Set([p.output])
    for i in reverse(eachindex(p.nodes))
        i in needed && union!(needed, IR.refs(p.nodes[i]))
    end
    for (i, n) in enumerate(p.nodes)
        i in needed || continue
        f = IR.format(p, i)
        f isa FixedFormat || continue
        if n isa IR.Input
            ranges[i] = domain
            grids[i] = domain[1] == domain[2] ? _dyadic_fraction(domain[1]) : _fraction(f)
            continue
        elseif n isa IR.Const
            ranges[i] = _singleton(decode_fixed(n.bits, f))
            grids[i] = _dyadic_fraction(ranges[i][1])
            continue
        elseif n isa IR.Guard
            ranges[i] = ranges[n.source]
            grids[i] = grids[n.source]
            continue
        elseif n isa IR.Convert
            exact, scale = ranges[n.source], grids[n.source]
        elseif n isa IR.Mul
            exact = _interval_mul(ranges[n.a], ranges[n.b])
            scale = grids[n.a] + grids[n.b]
        elseif n isa IR.Add
            exact = _interval_add(ranges[n.a], ranges[n.b])
            scale = max(grids[n.a], grids[n.b])
        elseif n isa IR.FMA
            exact = _interval_add(_interval_mul(ranges[n.a], ranges[n.b]), ranges[n.c])
            scale = max(grids[n.a] + grids[n.b], grids[n.c])
        else
            throw(ArgumentError("unsupported fixed node $i"))
        end
        ranges[i] = try
            _interval_round(exact, f)
        catch err
            err isa OverflowError || rethrow()
            throw(OverflowError("node $i may overflow after rounding"))
        end
        grids[i] =
            ranges[i][1] == ranges[i][2] ? _dyadic_fraction(ranges[i][1]) :
            min(scale, _fraction(f))
        rho[i] = if exact[1] == exact[2]
            abs(ranges[i][1] - exact[1])
        elseif scale <= _fraction(f)
            _q(0)
        else
            _pow2(-_fraction(f) - 1)
        end
    end
    return ranges, rho
end

function _polynomial_arithmetic(p, layout, ranges, rho)
    guard = p.nodes[p.output]
    output = guard.source == layout.final ? _q(0) : rho[guard.source]
    isempty(layout.stages) && return _q(0), _q(0), output
    eta = get(rho, layout.coordinate, _q(0))
    tbound = _interval_magnitude(ranges[layout.coordinate])
    exact = _singleton(layout.coefficients[end])
    coordinate, arithmetic = _q(0), _q(0)
    for stage in layout.stages
        coordinate = tbound * coordinate + eta * _interval_magnitude(exact)
        rounding =
            rho[stage.result] + (stage.product === nothing ? _q(0) : rho[stage.product])
        arithmetic = tbound * arithmetic + rounding
        exact = _interval_add(
            _interval_mul(exact, layout.domain),
            _singleton(layout.coefficients[stage.coefficient]),
        )
    end
    return coordinate, arithmetic, output
end

function _polynomial_norm(p, f, domain, accuracy)
    # supnorm cannot certify an identically zero error. Error-free symbolic
    # canonicalization/simplification proves identities and constant differences.
    difference = p - f
    simplified = try
        canonical = Sollya.canonical(difference)
        try
            Sollya.simplify(canonical)
        finally
            close(canonical)
        end
    finally
        close(difference)
    end
    try
        value = try
            abs(Sollya.exact_rational(simplified))
        catch err
            err isa Sollya.SollyaError || rethrow()
            nothing # Nonconstant or irrational errors still need a proof.
        end
        value === nothing || return (value, value)
        lo, hi = Sollya.bounds(domain)
        if lo == hi
            image = Sollya.enclosure(simplified, domain)
            try
                lo, hi = Sollya.bounds(image)
                return (
                    lo <= 0 <= hi ? _q(0) : min(abs(lo), abs(hi)),
                    max(abs(lo), abs(hi)),
                )
            finally
                close(image)
            end
        end
        proof = Sollya.supnorm(p, f, domain; error = :absolute, accuracy)
        try
            return Sollya.bounds(proof)
        finally
            close(proof)
        end
    finally
        close(simplified)
    end
end

"""
    certify_polynomial(plan; precision=256, accuracy=1//1024, max_refinements=2)

Certify a fixed-input/fixed-output `polynomial_plan` (degree 0:32), using
nearest-even rounding and rejected overflow. Audit the entire stored graph,
prove its stored-polynomial error with Sollya, and propagate exact rational
ranges and rounding bounds. Coverage includes every representable input in the
contract, or the complete input format when no domain is given. Proof failure
never falls back to sampling. `accuracy` controls norm tightness.
"""
function certify_polynomial(
    plan::PlanArtifact;
    precision::Integer = 256,
    accuracy::Union{Integer, Rational} = 1 // 1024,
    max_refinements::Integer = 2,
)
    precision >= 64 || throw(ArgumentError("proof precision must be at least 64"))
    0 < accuracy < 1 || throw(ArgumentError("norm accuracy must be between zero and one"))
    0 <= max_refinements <= 8 || throw(ArgumentError("refinements must be in 0:8"))
    settings = Dict(
        "method" => "fixed_polynomial_horner",
        "precision" => string(precision),
        "norm_accuracy" => _rational_text(_q(accuracy)),
    )
    layout = try
        _polynomial_audit(plan)
    catch err
        err isa Union{ArgumentError, KeyError} || rethrow()
        return _certificate_failure(
            plan,
            :unsupported_domain,
            sprint(showerror, err);
            settings,
        )
    end
    path = try
        ranges, rho = _polynomial_ranges(plan.program, layout.domain)
        coordinate, arithmetic, output =
            _polynomial_arithmetic(plan.program, layout, ranges, rho)
        norm = Sollya.with_session(Sollya.Session(; precision)) do
            owned = Sollya.SollyaObject[]
            try
                p = _stored_polynomial(layout.coefficients)
                push!(owned, p)
                f = Sollya.sollya(plan.spec.expression)
                push!(owned, f)
                domain = Sollya.interval(layout.domain...)
                push!(owned, domain)
                Sollya.bounds(domain) == layout.domain || throw(
                    ArgumentError("native domain enlargement; increase proof precision"),
                )
                image = Sollya.enclosure(f, domain)
                push!(owned, image)
                Sollya.bounds(image) # Require a finite function image on the proof domain.
                norm, tightness = (_q(0), _q(0)), _q(accuracy)
                for refinement = 0:max_refinements
                    norm = _polynomial_norm(p, f, domain, tightness)
                    0 <= norm[1] <= norm[2] ||
                        throw(ArgumentError("invalid polynomial norm enclosure"))
                    other = coordinate + arithmetic + output
                    norm[1] + other <= plan.spec.absolute_error < norm[2] + other ||
                        break
                    tightness /= 4
                end
                norm
            finally
                foreach(close, reverse(owned))
            end
        end
        bounds = Tuple(
            FixedNodeBound(node, IR.format(plan.program, node), range) for
            (node, range) in sort!(collect(ranges); by = first)
        )
        PathCertificate(
            layout.domain,
            true,
            norm,
            coordinate,
            arithmetic,
            output,
            norm[2] + coordinate + arithmetic + output,
            bounds,
        )
    catch err
        err isa Union{Sollya.SollyaError, ArgumentError, OverflowError} || rethrow()
        return _certificate_failure(plan, :proof_failed, sprint(showerror, err); settings)
    end
    status = path.total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    reason =
        status == :certified ?
        "All representable inputs in the contract meet the absolute error target" :
        "Conservative uniform bound exceeds the target"
    return CertificationResult(plan, status, path.total, (path,), nothing, settings, reason)
end

"""Certify a supported stored evaluator: fixed erf, fixed polynomial or binary16 LUT."""
function certify_plan(
    plan::PlanArtifact;
    precision::Integer = 256,
    accuracy = 1 // 1024,
    max_refinements::Integer = 2,
)
    if get(plan.settings, "kernel", "") == "binary16_lut"
        precision >= 64 || throw(ArgumentError("proof precision must be at least 64"))
        0 < accuracy < 1 ||
            throw(ArgumentError("norm accuracy must be between zero and one"))
        0 <= max_refinements <= 8 || throw(ArgumentError("refinements must be in 0:8"))
        config = OracleConfig(;
            initial_precision = precision,
            max_precision = max(4096, precision),
        )
        return certify_lut(plan; config)
    end
    return get(plan.settings, "kernel", "") == "erf_fixed_horner" ?
           certify_erf(plan; precision, accuracy, max_refinements) :
           certify_polynomial(plan; precision, accuracy, max_refinements)
end

function _has_supported_certificate(plan)
    get(plan.settings, "kernel", "") in
    ("erf_fixed_horner", "fixed_polynomial_horner", "binary16_lut") && return true
    try
        _polynomial_audit(plan)
        return true
    catch err
        err isa Union{ArgumentError, KeyError} || rethrow()
        return false
    end
end
