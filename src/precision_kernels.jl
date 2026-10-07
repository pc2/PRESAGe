function _precision_convert!(nodes, source, from, to)
    from == to && return source
    node =
        from isa FixedFormat && to isa FixedFormat ? IR.Quantize(source, to) :
        IR.Convert(source, to)
    return _push!(nodes, node)
end

function _precision_horner!(nodes, coordinate, coefficients, precision, evaluation)
    evaluation in (:separate, :fma) || throw(ArgumentError("unsupported Horner arithmetic"))
    fs, fc = precision.stage_formats, precision.coefficient_formats
    h = _precision_convert!(nodes, coefficients[end], fc[end], fs[end])
    initial = h
    stages = NamedTuple[]
    for k = (length(coefficients) - 1):-1:1
        previous = h
        operand = _precision_convert!(nodes, h, fs[k + 1], fs[k])
        t = _precision_convert!(nodes, coordinate, precision.coordinate_format, fs[k])
        c = _precision_convert!(nodes, coefficients[k], fc[k], fs[k])
        product =
            evaluation == :separate ? _push!(nodes, IR.Mul(operand, t, fs[k])) : nothing
        h =
            evaluation == :separate ? _push!(nodes, IR.Add(product, c, fs[k])) :
            _push!(nodes, IR.FMA(operand, t, c, fs[k]))
        push!(
            stages,
            (
                result = h,
                previous,
                product,
                coefficient = k,
                operand,
                coordinate = t,
                coefficient_value = c,
            ),
        )
    end
    return (; final = h, initial, stages)
end

function _precision_layout(spec, rows, precision, evaluation; segmented)
    count = maximum(length, rows)
    1 <= count <= 33 || throw(ArgumentError("polynomial degrees must be in 0:32"))
    precision = _precision_prefix(precision, count)
    coordinate_format = precision.coordinate_format
    fc = precision.coefficient_formats
    coefficients = [
        [
            _polynomial_value(
                _polynomial_round(k <= length(row) ? _q(row[k]) : _q(0), fc[k]),
                fc[k],
            ) for k = 1:count
        ] for row in rows
    ]
    nodes = IR.Node[IR.Input(spec.input_format)]
    tables = IR.Table[]
    segments = Segment[]
    geometry = nothing
    index = nothing
    converted = 1
    shifted = nothing
    if segmented
        length(rows) >= 2 ||
            throw(ArgumentError("segmented evaluators require at least two rows"))
        geometry = _segment_geometry(spec, length(rows), coordinate_format)
        segments = [
            Segment(geometry.boundaries[i], geometry.boundaries[i + 1], coefficients[i]) for i in eachindex(rows)
        ]
        push!(
            tables,
            IR.Table(
                coordinate_format,
                _polynomial_round.(-geometry.centers, Ref(coordinate_format)),
            ),
        )
        for k = 1:count
            push!(
                tables,
                IR.Table(
                    fc[k],
                    [_polynomial_round(row[k], fc[k]) for row in coefficients];
                    unroll = true,
                ),
            )
        end
        index_format = IR.UIntFormat(6)
        index = _push!(nodes, IR.Const(index_format, 0))
        for (i, word) in enumerate(geometry.thresholds)
            threshold = _push!(nodes, IR.Const(spec.input_format, word))
            condition = _push!(nodes, IR.Compare(:ge, 1, threshold))
            row = _push!(nodes, IR.Const(index_format, i))
            index = _push!(nodes, IR.Select(condition, row, index))
        end
        converted = _precision_convert!(nodes, 1, spec.input_format, coordinate_format)
        center = _push!(nodes, IR.TableLoad(1, index))
        shifted = _push!(nodes, IR.Add(converted, center, coordinate_format))
        coordinate =
            _push!(nodes, IR.ScalePow2(shifted, geometry.exponent, coordinate_format))
        cs = [_push!(nodes, IR.TableLoad(k + 1, index)) for k = 1:count]
    else
        length(rows) == 1 ||
            throw(ArgumentError("untabled precision layout requires one row"))
        coordinate = _precision_convert!(nodes, 1, spec.input_format, coordinate_format)
        cs = [_push!(nodes, IR.constant(coefficients[1][k], fc[k])) for k = 1:count]
    end
    horner = _precision_horner!(nodes, coordinate, cs, precision, evaluation)
    result = _precision_convert!(
        nodes,
        horner.final,
        precision.stage_formats[1],
        spec.output_format,
    )
    output = _polynomial_guard!(nodes, result, spec)
    program = IR.Program(nodes; output, tables)
    paths = [
        begin
            path = merge(
                horner,
                (;
                    coefficients = coefficients[i],
                    coordinate,
                    result,
                    domain = segmented ? geometry.normalized_domains[i] :
                             _polynomial_domain(spec),
                ),
            )
            segmented ?
            merge(
                path,
                (;
                    converted,
                    shifted,
                    index,
                    row = i,
                    center = geometry.centers[i],
                    exponent = geometry.exponent,
                    input_domain = geometry.domains[i],
                ),
            ) : path
        end for i in eachindex(rows)
    ]
    return (; program, segments, paths, geometry, precision, coefficient_nodes = cs)
end

function _precision_plan(spec, rows, precision, evaluation; segmented)
    layout = _precision_layout(spec, rows, precision, evaluation; segmented)
    return PlanArtifact(
        spec;
        program = layout.program,
        segments = layout.segments,
        precision = layout.precision,
        settings = Dict(
            "kernel" => "precision_polynomial_horner",
            "evaluation" => string(evaluation),
        ),
    )
end

function _precision_audit(plan)
    get(plan.settings, "transformation", "none") == "odd" && return _odd_audit(plan)
    get(plan.settings, "transformation", "none") == "atan" && return _atan_audit(plan)
    get(plan.settings, "transformation", "none") == "log" && return _log_audit(plan)
    get(plan.settings, "transformation", "none") == "reciprocal" &&
        return _reciprocal_audit(plan)
    get(plan.settings, "transformation", "none") in ("sqrt", "rsqrt", "cbrt") &&
        return _root_audit(plan)
    p, precision = plan.program, plan.precision
    p !== nothing && precision !== nothing ||
        throw(ArgumentError("missing precision evaluator"))
    plan.dispatch === nothing || throw(ArgumentError("unsupported external dispatch"))
    all(p.types) do f
        !(f isa FixedFormat) || (f.rounding == :nearest_even && f.overflow == :reject)
    end || throw(
        ArgumentError(
            "precision proofs require nearest-even rounding and rejected fixed overflow",
        ),
    )
    segmented = !isempty(plan.segments)
    rows, words = if segmented
        [s.coefficients for s in plan.segments], nothing
    else
        offset = precision.coordinate_format == plan.spec.input_format ? 1 : 2
        length(p.nodes) >= offset + length(precision.coefficient_formats) ||
            throw(ArgumentError("missing stored coefficients"))
        constants =
            p.nodes[(offset + 1):(offset + length(precision.coefficient_formats))]
        all(zip(constants, precision.coefficient_formats)) do (n, f)
            n isa IR.Const && n.format == f
        end || throw(ArgumentError("unsupported coefficient storage"))
        [[
            _polynomial_value(n.bits, f) for
            (n, f) in zip(constants, precision.coefficient_formats)
        ]],
        [n.bits for n in constants]
    end
    layout = _precision_layout(
        plan.spec,
        rows,
        precision,
        Symbol(get(plan.settings, "evaluation", ""));
        segmented,
    )
    layout.precision == precision ||
        throw(ArgumentError("precision metadata exceeds the polynomial degree"))
    if segmented
        all(zip(plan.segments, layout.segments)) do (stored, canonical)
            stored.lower == canonical.lower &&
                stored.upper == canonical.upper &&
                stored.coefficients == canonical.coefficients
        end || throw(ArgumentError("segment metadata differs from the supported partition"))
    end
    canonical = layout.program
    if words !== nothing
        nodes = collect(canonical.nodes)
        for (node, word, f) in
            zip(layout.coefficient_nodes, words, precision.coefficient_formats)
            nodes[node] = IR.Const(f, word)
        end
        canonical = IR.Program(nodes; output = canonical.output, tables = canonical.tables)
    end
    _program_data(p) == _program_data(canonical) || throw(
        ArgumentError(
            "executed graph or tables differ from the supported precision evaluator",
        ),
    )
    return layout
end

function _stored_precision(plan)
    plan.precision !== nothing && return _precision_audit(plan).precision
    path =
        isempty(plan.segments) ? _polynomial_audit(plan) :
        first(_segmented_audit(plan).paths)
    f = IR.format(plan.program, path.coordinate)
    return PolynomialPrecision(
        f;
        coefficient_formats = fill(f, length(path.coefficients)),
        stage_formats = fill(f, length(path.coefficients)),
    )
end

function _reformat_polynomial(plan, precision)
    get(plan.settings, "transformation", "none") == "odd" &&
        return _reformat_odd(plan, precision)
    get(plan.settings, "transformation", "none") == "atan" &&
        return _reformat_atan(plan, precision)
    get(plan.settings, "transformation", "none") == "log" &&
        return _reformat_log(plan, precision)
    get(plan.settings, "transformation", "none") == "reciprocal" &&
        return _reformat_reciprocal(plan, precision)
    get(plan.settings, "transformation", "none") in ("sqrt", "rsqrt", "cbrt") &&
        return _reformat_root(plan, precision)
    old = _stored_precision(plan)
    old.coordinate_format == precision.coordinate_format &&
        old.coefficient_formats == precision.coefficient_formats || throw(
        ArgumentError(
            "stored coefficients require unchanged coordinate and coefficient formats",
        ),
    )
    rows =
        isempty(plan.segments) ? [_polynomial_audit(plan).coefficients] :
        [s.coefficients for s in plan.segments]
    candidate = _precision_plan(
        plan.spec,
        rows,
        precision,
        Symbol(plan.settings["evaluation"]);
        segmented = !isempty(plan.segments),
    )
    program = candidate.program
    if isempty(plan.segments)
        # Preserve raw coefficient words too: rational export cannot retain -0.
        first_constant = old.coordinate_format == plan.spec.input_format ? 2 : 3
        originals = first_constant:(first_constant + length(old.coefficient_formats) - 1)
        targets = _precision_audit(candidate).coefficient_nodes
        nodes = collect(program.nodes)
        for (source, target, format) in zip(originals, targets, old.coefficient_formats)
            nodes[target] = IR.Const(format, plan.program.nodes[source].bits)
        end
        program = IR.Program(nodes; output = program.output, tables = program.tables)
    end
    return PlanArtifact(
        plan.spec;
        program,
        segments = candidate.segments,
        precision = candidate.precision,
        settings = merge(plan.settings, candidate.settings),
    )
end
