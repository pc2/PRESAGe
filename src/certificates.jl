struct FixedNodeBound
    node::Int
    format::FixedFormat
    range::_Interval
end
struct PathCertificate
    magnitude_domain::_Interval
    upper_inclusive::Bool
    approximation::_Interval
    coordinate_error::Rational{BigInt}
    arithmetic_error::Rational{BigInt}
    output_rounding::Rational{BigInt}
    total::Rational{BigInt}
    ranges::Tuple{Vararg{FixedNodeBound}}
end
"""Uniform numerical result for the exact program in `plan`; sampled maxima are separate."""
struct CertificationResult
    plan::PlanArtifact
    status::Symbol
    total_bound::Union{Nothing,Rational{BigInt}}
    paths::Tuple{Vararg{PathCertificate}}
    tail_bound::Union{Nothing,Rational{BigInt}}
    settings::Dict{String,String}
    reason::String
end
function _certificate_failure(plan,status,reason;settings=Dict{String,String}())
    return CertificationResult(plan,status,nothing,(),nothing,settings,reason)
end
_quantizer_error(source::FixedFormat,target::FixedFormat) =
    _fraction(target) >= _fraction(source) ? _q(0) : _pow2(-_fraction(target)-1)
function _float_rounding_bound(range,f::FloatFormat)
    magnitude = _interval_magnitude(range)
    maxfinite = decode_ieee(_inf(f)-1,f).value
    magnitude <= maxfinite || throw(OverflowError("output range may overflow"))
    iszero(magnitude) && return _q(0)
    n,d = abs(numerator(magnitude)),denominator(magnitude)
    e = ndigits(n;base=2)-ndigits(d;base=2)
    (e>=0 ? n < d<<e : n<<-e < d) && (e-=1)
    return _pow2(max(e,_emin(f))-f.fraction_bits-1)
end
function _erf_audit(plan)
    plan.program !== nothing && plan.spec.expression == "erf(x)" &&
        plan.spec.input_format == plan.spec.output_format == IEEE32 && plan.spec.domain === nothing ||
        throw(ArgumentError("certificate supports the all-finite IEEE32 erf contract"))
    ss = plan.segments
    n = length(ss)
    1 <= n <= 64 && ispow2(n) || throw(ArgumentError("unsupported segmentation"))
    degree = length(first(ss).coefficients)-1
    1 <= degree <= 32 && all(s -> length(s.coefficients)==degree+1,ss) || throw(ArgumentError("unsupported polynomial layout"))
    width = _q(4)/n
    all(i -> ss[i].lower == (i-1)*width && ss[i].upper == i*width,1:n) ||
        throw(ArgumentError("segments must cover [0,4] without gaps"))
    b = plan.dispatch
    b !== nothing && b.magnitude_threshold == round_ieee(4,IEEE32) && b.comparison == :greater &&
        b.positive_tail == 1 && b.negative_tail == -1 || throw(ArgumentError("unsupported tail dispatch"))
    get(plan.settings,"kernel","") == "erf_fixed_horner" || throw(ArgumentError("unsupported evaluator kernel"))
    fraction = parse(Int,plan.settings["fraction_bits"])
    coefficient_fraction = parse(Int,plan.settings["coefficient_fraction_bits"])
    0 <= fraction <= 256 && 0 <= coefficient_fraction <= 256 || throw(ArgumentError("unsupported fractional widths"))
    fraction >= max(0,trailing_zeros(n)-1) || throw(ArgumentError("inexact segment centres"))
    evaluation = Symbol(plan.settings["evaluation"])
    evaluation in (:separate,:fma) || throw(ArgumentError("unsupported Horner arithmetic"))
    layout = _fixed_erf_layout(ss,fraction,coefficient_fraction,evaluation;spec=plan.spec)
    _program_data(layout.plan.program) == _program_data(plan.program) ||
        throw(ArgumentError("executed graph differs from the supported fixed erf evaluator"))
    for ranges in layout.ranges, (node,range) in ranges
        f = IR.format(plan.program,node)
        lo,hi = _fixed_limits(f)
        quantum = _pow2(-_fraction(f))
        lo*quantum <= range[1] <= range[2] <= hi*quantum || throw(OverflowError("node $node may overflow"))
    end
    return layout
end
function _path_arithmetic(layout,row)
    p = layout.plan.program
    coefficients = layout.plan.segments[row].coefficients
    tbound = _interval_magnitude(layout.domain)
    eta = _pow2(-parse(Int,layout.plan.settings["fraction_bits"])-1)
    exact = _singleton(coefficients[end])
    actual = layout.ranges[row][layout.initial]
    arithmetic = abs(actual[1]-coefficients[end])
    coordinate = _q(0)
    for stage in layout.stages
        coordinate = tbound*coordinate + eta*_interval_magnitude(exact)
        rho = _quantizer_error(IR.format(p,stage.wide),IR.format(p,stage.result))
        if stage.productquantizer !== nothing
            rho += _quantizer_error(IR.format(p,stage.product),IR.format(p,stage.productquantizer))
        end
        arithmetic = tbound*arithmetic+rho
        exact = _interval_add(_interval_mul(exact,layout.domain),_singleton(coefficients[stage.coefficient]))
    end
    output = _float_rounding_bound(layout.ranges[row][layout.final],IEEE32)
    return coordinate,arithmetic,output
end
function _stored_polynomial(coefficients)
    text = join(["($(_rational_text(c)))*x^$(k-1)" for (k,c) in enumerate(coefficients)]," + ")
    p = Sollya.sollya(text)
    try
        actual = Sollya.coefficients(p)
        append!(actual,fill(_q(0),length(coefficients)-length(actual)))
        actual == coefficients || throw(ArgumentError("native polynomial differs from stored coefficients"))
        return p
    catch
        close(p)
        rethrow()
    end
end

"""
    certify_erf(plan; precision=256, accuracy=1//1024, max_refinements=2)

Certify the supported fixed IEEE32 erf graph on every finite input. Sollya
supnorm proves stored-polynomial error; exact rational range/error propagation
covers input quantisation, every arithmetic quantizer and output rounding.
Known oddness and monotonicity cover sign restoration and constant tails.
Graph or domain mismatches are unsupported, and proof failure never falls back
to samples. `accuracy` controls norm tightness, independently of the error target.
"""
function certify_erf(plan::PlanArtifact;precision::Integer=256,accuracy::Union{Integer,Rational}=1//1024,
                     max_refinements::Integer=2)
    precision >= 64 || throw(ArgumentError("proof precision must be at least 64"))
    0 < accuracy < 1 || throw(ArgumentError("norm accuracy must be between zero and one"))
    0 <= max_refinements <= 8 || throw(ArgumentError("refinements must be in 0:8"))
    settings = Dict("precision"=>string(precision),"norm_accuracy"=>_rational_text(_q(accuracy)))
    layout = try
        _erf_audit(plan)
    catch err
        err isa Union{ArgumentError,KeyError} && return _certificate_failure(plan,:unsupported_domain,sprint(showerror,err);settings)
        err isa OverflowError && return _certificate_failure(plan,:proof_failed,sprint(showerror,err);settings)
        rethrow()
    end
    paths = PathCertificate[]
    tail = nothing
    try
        Sollya.with_session(Sollya.Session(;precision)) do
            for row in eachindex(plan.segments)
                owned = Sollya.SollyaObject[]
                try
                    segment = plan.segments[row]
                    coordinate,arithmetic,output = _path_arithmetic(layout,row)
                    p = _stored_polynomial(segment.coefficients); push!(owned,p)
                    f = Sollya.sollya("erf(x+($(_rational_text(layout.centers[row]))))"); push!(owned,f)
                    domain = Sollya.interval(layout.domain...); push!(owned,domain)
                    Sollya.bounds(domain) == layout.domain || throw(ArgumentError("native domain enlargement"))
                    norm = (_q(0),_q(0))
                    tightness = _q(accuracy)
                    for refinement in 0:max_refinements
                        proof = Sollya.supnorm(p,f,domain;error=:absolute,accuracy=tightness)
                        try
                            norm = Sollya.bounds(proof)
                        finally
                            close(proof)
                        end
                        0 <= norm[1] <= norm[2] || throw(ArgumentError("invalid polynomial norm enclosure"))
                        other = coordinate+arithmetic+output
                        norm[1]+other <= plan.spec.absolute_error < norm[2]+other || break
                        tightness /= 4
                    end
                    bounds = Tuple(FixedNodeBound(node,IR.format(plan.program,node),range)
                        for (node,range) in sort!(collect(layout.ranges[row]);by=first))
                    push!(paths,PathCertificate((segment.lower,segment.upper),row==length(plan.segments),norm,
                        coordinate,arithmetic,output,norm[2]+coordinate+arithmetic+output,bounds))
                finally
                    foreach(close,reverse(owned))
                end
            end
            f = Sollya.sollya("erf(x)")
            try
                endpoint = Sollya.enclosure(f,4)
                try
                    lo,hi = Sollya.bounds(endpoint)
                    0 <= lo <= hi <= 1 || throw(ArgumentError("invalid erf tail enclosure"))
                    tail = 1-lo
                finally
                    close(endpoint)
                end
            finally
                close(f)
            end
        end
    catch err
        err isa Union{Sollya.SollyaError,ArgumentError,OverflowError} || rethrow()
        return _certificate_failure(plan,:proof_failed,sprint(showerror,err);settings)
    end
    total = max(tail,maximum(p.total for p in paths))
    status = total <= plan.spec.absolute_error ? :certified : :bound_exceeds_budget
    reason = status == :certified ? "All finite-input paths meet the absolute error target" : "Conservative uniform bound exceeds the target"
    return CertificationResult(plan,status,total,Tuple(paths),tail,settings,reason)
end

"""Bounded width search. Exhaustion reports search_limit, never mathematical infeasibility."""
function certified_erf(;degree::Integer=9,segments::Integer=4,initial_fraction_bits::Integer=23+ndigits(16degree-1;base=2),
                       max_fraction_bits::Integer=47,coefficient_fraction_bits=nothing,evaluation::Symbol=:separate,
                       precision::Integer=256,proof_precision::Integer=256,accuracy::Union{Integer,Rational}=1//1024)
    1 <= degree <= 32 || throw(ArgumentError("degree must be in 1:32"))
    0 <= initial_fraction_bits <= max_fraction_bits <= 256 || throw(ArgumentError("invalid width search bounds"))
    last = nothing
    attempts = 0
    for fraction in initial_fraction_bits:2:max_fraction_bits
        attempts += 1
        plan = try
            erf_fixed_candidate(;degree,segments,fraction_bits=fraction,
                coefficient_fraction_bits=coefficient_fraction_bits === nothing ? fraction : coefficient_fraction_bits,
                evaluation,precision)
        catch err
            err isa Sollya.SollyaError || rethrow()
            return _certificate_failure(PlanArtifact(erf_spec()),:proof_failed,
                "Coefficient generation failed: "*sprint(showerror,err))
        end
        last = certify_erf(plan;precision=proof_precision,accuracy)
        last.status == :certified && return last
        last.status in (:unsupported_domain,:proof_failed) && return last
    end
    settings = merge(last.settings,Dict("search_attempts"=>string(attempts)))
    return CertificationResult(last.plan,:search_limit,last.total_bound,last.paths,last.tail_bound,settings,
        "Width search exhausted: "*last.reason)
end

function _certificate_data(result::CertificationResult)
    d = Dict{String,Any}("schema"=>"presage-certificate","schema_version"=>1,"status"=>string(result.status),
        "expression"=>result.plan.spec.expression,"input_format"=>_format_data(result.plan.spec.input_format),
        "output_format"=>_format_data(result.plan.spec.output_format),"absolute_error"=>_rational_text(result.plan.spec.absolute_error),
        "reason"=>result.reason,"settings"=>result.settings)
    result.total_bound === nothing || (d["total_bound"] = _rational_text(result.total_bound))
    if !isempty(result.paths)
        d["paths"] = [Dict("magnitude_domain"=>_rational_text.(collect(p.magnitude_domain)),
            "upper_inclusive"=>p.upper_inclusive,"approximation"=>_rational_text.(collect(p.approximation)),
            "coordinate_error"=>_rational_text(p.coordinate_error),"arithmetic_error"=>_rational_text(p.arithmetic_error),
            "output_rounding"=>_rational_text(p.output_rounding),"total"=>_rational_text(p.total),
            "ranges"=>[Dict("node"=>b.node,"format"=>_type_data(b.format),
                "bounds"=>_rational_text.(collect(b.range))) for b in p.ranges]) for p in result.paths]
        d["coverage"] = Dict("central_magnitude"=>["0/1","4/1"],"negative_inputs"=>"exact odd sign restoration",
            "zeros"=>"both signed zeros preserved","infinities"=>"signed unit values","nan"=>"canonical quiet NaN",
            "overflow"=>"all fixed nodes and output conversions bounded")
    end
    result.tail_bound === nothing || (d["tail"] = Dict("magnitude_lower"=>"4/1","comparison"=>"greater",
        "absolute_error"=>_rational_text(result.tail_bound),"argument"=>"erf is monotone and bounded above by one"))
    return d
end
"""Write the numerical proof report. Regenerate it whenever evaluator semantics change."""
write_certificate(io::IO,result::CertificationResult) = TOML.print(io,_certificate_data(result);sorted=true)
write_certificate(path::AbstractString,result::CertificationResult) = open(io -> write_certificate(io,result),path,"w")
