# Recover the stored polynomial, then reconstruct the entire supported program.
# No coefficient metadata or kernel label can substitute for this graph audit.
function _polynomial_audit(plan)
    if plan.precision !== nothing
        isempty(plan.segments) || throw(ArgumentError("expected an untabled polynomial"))
        return only(_precision_audit(plan).paths)
    end
    spec, p = plan.spec, plan.program
    p !== nothing || throw(ArgumentError("missing polynomial program"))
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
    result = if spec.output_format isa FixedFormat
        guard isa IR.Guard || throw(ArgumentError("missing polynomial domain guard"))
        guard.source
    else
        guard isa IR.Select || throw(ArgumentError("missing polynomial domain guard"))
        spec.domain === nothing ? guard.no : guard.yes
    end
    final = result
    p.nodes[final] isa IR.Convert && (final = p.nodes[final].source)
    f = IR.format(p, final)
    f isa Union{FixedFormat, FloatFormat} ||
        throw(ArgumentError("unsupported internal arithmetic"))
    coordinate = f == spec.input_format ? p.input : 2
    coefficients, words, stages = Rational{BigInt}[], IR.Word[], NamedTuple[]
    h = final
    while true
        n = p.nodes[h]
        if n isa IR.Const && n.format == f
            push!(coefficients, _polynomial_value(n.bits, f))
            push!(words, n.bits)
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
        push!(coefficients, _polynomial_value(constant.bits, f))
        push!(words, constant.bits)
        push!(stages, (result = h, previous, product, coefficient = length(coefficients)))
        h = previous
    end
    canonical = polynomial_plan(spec, coefficients; internal_format = f, evaluation)
    # Rational coefficients cannot retain negative zero. Reuse the audited
    # coefficient payloads in their canonical positions before graph comparison.
    nodes = collect(canonical.program.nodes)
    first_coefficient = f == spec.input_format ? 2 : 3
    for (i, word) in enumerate(words)
        nodes[first_coefficient + i - 1] = IR.Const(f, word)
    end
    canonical_program = IR.Program(nodes; output = canonical.program.output)
    _program_data(canonical_program) == _program_data(p) || throw(
        ArgumentError("executed graph differs from the supported polynomial evaluator"),
    )
    return (;
        coefficients,
        stages = reverse(stages),
        coordinate,
        final,
        result,
        domain = _polynomial_domain(spec),
    )
end

_polynomial_round(q, f::FixedFormat; mode = :nearest_even) = round_fixed(q, f; mode)
_polynomial_round(q, f::FloatFormat; mode = :nearest_even) = round_ieee(q, f; mode)
_polynomial_value(bits, f::FixedFormat) = decode_fixed(bits, f)
function _polynomial_value(bits, f::FloatFormat)
    value = decode_ieee(bits, f).value
    value === nothing && throw(ArgumentError("nonfinite stored polynomial coefficient"))
    return value
end
function _interval_round(a, f::FloatFormat)
    values = map(q -> decode_ieee(round_ieee(q, f), f).value, a)
    any(isnothing, values) && throw(OverflowError("floating range may overflow"))
    return values
end

# A guaranteed dyadic grid bounds exactness. Floating spacing varies by binade;
# use the finest spacing for propagated grids and the coarsest for local error.
function _polynomial_binade(q)
    n, d = abs(numerator(q)), denominator(q)
    e = ndigits(n; base = 2) - ndigits(d; base = 2)
    (e >= 0 ? n < d << e : n << -e < d) && (e -= 1)
    return e
end
_polynomial_grid(f::FixedFormat, range) = _fraction(f)
function _polynomial_grid(f::FloatFormat, range)
    lo, hi = range
    smallest = lo <= 0 <= hi ? _q(0) : min(abs(lo), abs(hi))
    exponent = iszero(smallest) ? _emin(f) : max(_emin(f), _polynomial_binade(smallest))
    return f.fraction_bits - exponent
end
_polynomial_grid_exact(scale, range, f::FixedFormat) = scale <= _fraction(f)
function _polynomial_grid_exact(scale, range, f::FloatFormat)
    magnitude = _interval_magnitude(range)
    iszero(magnitude) && return true
    return scale <= f.fraction_bits - max(_emin(f), _polynomial_binade(magnitude))
end

# Format-preserving zero/unit identities and widening conversions are exact even
# when a single grid for an interval crossing zero loses significand information.
function _polynomial_node_exact(p, n, f, ranges)
    if n isa Union{IR.Convert, IR.Quantize}
        source = IR.format(p, n.source)
        source == f && return true
        return source isa FloatFormat &&
               f isa FloatFormat &&
               f.fraction_bits >= source.fraction_bits &&
               _emin(f) - f.fraction_bits <= _emin(source) - source.fraction_bits
    elseif n isa IR.Add
        return (ranges[n.a] == (0, 0) && IR.format(p, n.b) == f) ||
               (ranges[n.b] == (0, 0) && IR.format(p, n.a) == f)
    elseif n isa Union{IR.Mul, IR.FMA}
        n isa IR.FMA && ranges[n.c] != (0, 0) && return false
        return ranges[n.a] == (0, 0) ||
               ranges[n.b] == (0, 0) ||
               (ranges[n.a] in ((1, 1), (-1, -1)) && IR.format(p, n.b) == f) ||
               (ranges[n.b] in ((1, 1), (-1, -1)) && IR.format(p, n.a) == f)
    end
    return false
end

# Endpoint rounding is monotone under the audited policy. Overflow at an
# interval endpoint refuses the proof, even if the interval is conservative.
_dyadic_fraction(q) =
    iszero(q) ? 0 :
    ndigits(denominator(q); base = 2) - 1 - trailing_zeros(abs(numerator(q)))
function _polynomial_ranges(p, layout; stop_before = nothing, range_overrides = Dict())
    ranges, rho = Dict{Int, _Interval}(), Dict{Int, Rational{BigInt}}()
    grids = Dict{Int, Int}()
    choices = get(layout, :range_choices, Dict{Int, Int}())
    needed = Set(get(layout, :range_roots, (p.output,)))
    for i in reverse(eachindex(p.nodes))
        if i in needed
            union!(needed, haskey(choices, i) ? (choices[i],) : IR.refs(p.nodes[i]))
        end
    end
    for (i, n) in enumerate(p.nodes)
        i == stop_before && break
        i in needed || continue
        f = IR.format(p, i)
        f isa Union{FixedFormat, FloatFormat} || continue
        if i == p.output
            source = get(layout, :output_source, layout.result)
            ranges[i] = ranges[source]
            grids[i] = grids[source]
            continue
        elseif haskey(get(layout, :exact_branches, Dict()), i)
            ranges[i] = layout.exact_branches[i]
            grids[i] = _dyadic_fraction(ranges[i][1])
            rho[i] = _q(0)
            continue
        elseif haskey(choices, i)
            source = choices[i]
            n isa IR.Select && source in (n.yes, n.no) ||
                throw(ArgumentError("invalid audited range choice"))
            ranges[i], grids[i], rho[i] = ranges[source], grids[source], _q(0)
            continue
        elseif n isa IR.Input
            ranges[i] = get(layout, :input_domain, layout.domain)
            grids[i] =
                ranges[i][1] == ranges[i][2] ? _dyadic_fraction(ranges[i][1]) :
                _polynomial_grid(f, ranges[i])
            continue
        elseif n isa IR.Const
            # The audited floating guard's NaN branch is outside the numerical
            # domain. Its payload is verified by canonical graph comparison.
            f isa FloatFormat && decode_ieee(n.bits, f).value === nothing && continue
            ranges[i] = _singleton(_polynomial_value(n.bits, f))
            grids[i] = _dyadic_fraction(ranges[i][1])
            continue
        elseif n isa IR.TableLoad
            ranges[i] =
                _singleton(_polynomial_value(p.tables[n.table].values[layout.row], f))
            grids[i] = _dyadic_fraction(ranges[i][1])
            continue
        elseif n isa IR.Guard
            ranges[i] = ranges[n.source]
            grids[i] = grids[n.source]
            continue
        elseif n isa Union{IR.FloatMantissa, IR.RootArgument}
            ranges[i] = layout.mantissa_domain
            grids[i] = IR.format(p, n.source).fraction_bits
            rho[i] = _q(0)
            continue
        elseif n isa IR.FloatReciprocal
            lo, hi = ranges[n.source]
            0 < lo <= hi ||
                throw(ArgumentError("reciprocal proof requires a positive range"))
            exact = (inv(hi), inv(lo))
            # A reciprocal is generally not dyadic. Do not infer an exact grid
            # from the input; only its rounded result has the format's grid.
            scale = _polynomial_grid(f, exact) + 1
        elseif n isa IR.FloatExponent
            ranges[i] = _q.(layout.exponents)
            grids[i] = 0
            rho[i] = _q(0)
            continue
        elseif n isa IR.ScaleByInputExponent
            exact = _interval_mul(ranges[n.source], layout.scale_domain)
            scale = grids[n.source] - layout.scale_exponents[1]
        elseif n isa IR.CopySign
            lo, hi = ranges[n.source]
            magnitude =
                (lo <= 0 <= hi ? _q(0) : min(abs(lo), abs(hi)), max(abs(lo), abs(hi)))
            sign = p.nodes[n.sign]
            ranges[i] =
                sign isa IR.Const ?
                (
                    decode_ieee(sign.bits, sign.format).negative ?
                    (-magnitude[2], -magnitude[1]) : magnitude
                ) :
                get(layout, :both_signs, false) ? (-magnitude[2], magnitude[2]) :
                layout.negative ? (-magnitude[2], -magnitude[1]) : magnitude
            grids[i] = grids[n.source]
            rho[i] = _q(0)
            continue
        elseif n isa Union{IR.Convert, IR.Quantize}
            exact, scale = ranges[n.source], grids[n.source]
        elseif n isa IR.ScalePow2
            exact = _interval_mul(ranges[n.source], _singleton(_pow2(n.exponent)))
            scale = grids[n.source] - n.exponent
        elseif n isa IR.Mul
            exact =
                n.a == n.b ? _odd_square_domain(ranges[n.a]) :
                _interval_mul(ranges[n.a], ranges[n.b])
            scale = grids[n.a] + grids[n.b]
        elseif n isa IR.Add
            exact = _interval_add(ranges[n.a], ranges[n.b])
            scale = max(grids[n.a], grids[n.b])
        elseif n isa IR.FMA
            exact = _interval_add(_interval_mul(ranges[n.a], ranges[n.b]), ranges[n.c])
            scale = max(grids[n.a] + grids[n.b], grids[n.c])
        elseif n isa IR.Select && i == get(layout, :zero_select, nothing)
            a, b = ranges[n.yes], ranges[n.no]
            ranges[i] = (min(a[1], b[1]), max(a[2], b[2]))
            grids[i] = max(grids[n.yes], grids[n.no])
            rho[i] = _q(0)
            continue
        else
            throw(ArgumentError("unsupported arithmetic node $i"))
        end
        ranges[i] = try
            _interval_round(exact, f)
        catch err
            err isa OverflowError || rethrow()
            throw(OverflowError("node $i may overflow after rounding"))
        end
        if haskey(range_overrides, i)
            lo, hi = range_overrides[i]
            ranges[i] = (max(ranges[i][1], lo), min(ranges[i][2], hi))
            ranges[i][1] <= ranges[i][2] ||
                throw(ArgumentError("inconsistent certified node range"))
        end
        grids[i] =
            ranges[i][1] == ranges[i][2] ? _dyadic_fraction(ranges[i][1]) :
            min(scale, _polynomial_grid(f, ranges[i]))
        rho[i] = if exact[1] == exact[2]
            abs(ranges[i][1] - exact[1])
        elseif _polynomial_grid_exact(scale, exact, f) ||
               _polynomial_node_exact(p, n, f, ranges)
            _q(0)
        else
            f isa FixedFormat ? _pow2(-_fraction(f) - 1) : _float_rounding_bound(exact, f)
        end
    end
    if stop_before === nothing
        for (node, source) in
            sort!(collect(get(layout, :range_aliases, Dict())); by = first)
            ranges[node], grids[node] = ranges[source], grids[source]
            rho[node] = _q(0)
        end
        ranges[p.output] = ranges[get(layout, :output_source, layout.result)]
    end
    return ranges, rho
end

function _polynomial_arithmetic(p, layout, ranges, rho)
    output = layout.result == layout.final ? _q(0) : rho[layout.result]
    seed_error = haskey(layout, :initial) ? get(rho, layout.initial, _q(0)) : _q(0)
    isempty(layout.stages) && return _q(0), seed_error, output
    eta = if haskey(layout, :exponent)
        # The stored centre is exact in the ideal transformation. Input
        # conversion and subtraction errors scale together; scaling adds its
        # own local rounding error. Horner then uses the actual coordinate bound.
        _pow2(layout.exponent) *
        (get(rho, layout.converted, _q(0)) + get(rho, layout.shifted, _q(0))) +
        get(rho, layout.coordinate, _q(0))
    else
        get(rho, layout.coordinate, _q(0))
    end
    eta = get(layout, :coordinate_formation_error, eta)
    exact = _singleton(layout.coefficients[end])
    coordinate, arithmetic = _q(0), seed_error
    for stage in layout.stages
        coordinate_node = get(stage, :coordinate, layout.coordinate)
        tbound = _interval_magnitude(ranges[coordinate_node])
        stage_eta =
            eta + (
                coordinate_node == layout.coordinate ? _q(0) :
                get(rho, coordinate_node, _q(0))
            )
        coordinate = tbound * coordinate + stage_eta * _interval_magnitude(exact)
        rounding =
            rho[stage.result] + (stage.product === nothing ? _q(0) : rho[stage.product])
        if haskey(stage, :operand)
            stage.operand == stage.previous ||
                (rounding += tbound * get(rho, stage.operand, _q(0)))
            rounding += get(rho, stage.coefficient_value, _q(0))
        end
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

Certify a float/fixed `polynomial_plan` (degree 0:32), using nearest-even
rounding and rejected fixed overflow. Audit the entire stored graph,
prove its stored-polynomial error with Sollya, and propagate exact rational
ranges and rounding bounds. Coverage includes every representable input in the
contract, or all finite inputs when no domain is given. Floating proofs include
subnormals and finite exponent limits. Proof failure
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
    get(plan.settings, "transformation", "none") == "odd" &&
        return _certify_odd(plan; precision, accuracy, max_refinements)
    get(plan.settings, "transformation", "none") == "atan" &&
        return _certify_atan(plan; precision, accuracy, max_refinements)
    get(plan.settings, "transformation", "none") == "log" &&
        return _certify_log(plan; precision, accuracy, max_refinements)
    get(plan.settings, "transformation", "none") == "reciprocal" &&
        return _certify_reciprocal(plan; precision, accuracy, max_refinements)
    get(plan.settings, "transformation", "none") in ("sqrt", "rsqrt", "cbrt") &&
        return _certify_root(plan; precision, accuracy, max_refinements)
    if _primitive(plan.spec.expression) == :cbrt &&
       (plan.spec.domain === nothing || plan.spec.domain[1] < 0)
        return _certificate_failure(
            plan,
            :unsupported_domain,
            "signed cbrt domains require transformation=:cbrt";
            settings = Dict(
                "precision" => string(precision),
                "norm_accuracy" => _rational_text(_q(accuracy)),
            ),
        )
    end
    (
        plan.precision !== nothing ||
        get(plan.settings, "kernel", "") == "normalized_segmented_horner"
    ) && return _certify_segmented(plan; precision, accuracy, max_refinements)
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
    if any(f -> f isa FloatFormat, plan.program.types)
        settings["method"] = "floating_polynomial_horner"
    end
    path = try
        ranges, rho = _polynomial_ranges(plan.program, layout)
        coordinate, arithmetic, output =
            _polynomial_arithmetic(plan.program, layout, ranges, rho)
        norm = Sollya.with_session(Sollya.Session(; precision)) do
            owned = Sollya.SollyaObject[]
            try
                p = _stored_polynomial(layout.coefficients)
                push!(owned, p)
                # Match the oracle's exact decimal/scientific literal semantics.
                f = Sollya.sollya(_exact_expression(plan.spec.expression))
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
            _node_bound(node, IR.format(plan.program, node), range) for
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

"""Certify a supported stored evaluator: fixed erf, float/fixed polynomial or binary16 LUT."""
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
    plan.precision !== nothing && return true
    get(plan.settings, "kernel", "") in (
        "erf_fixed_horner",
        "fixed_polynomial_horner",
        "floating_polynomial_horner",
        "normalized_segmented_horner",
        "precision_polynomial_horner",
        "binary16_lut",
    ) && return true
    try
        _polynomial_audit(plan)
        return true
    catch err
        err isa Union{ArgumentError, KeyError} || rethrow()
        return false
    end
end
