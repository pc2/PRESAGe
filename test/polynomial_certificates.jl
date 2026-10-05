function bounded_polynomial(expression;evaluation=:separate)
    coefficients = Sollya.with_session(Sollya.Session(;precision=256)) do
        f,d = Sollya.sollya(expression),Sollya.interval(-1,1)
        try
            p = Sollya.fpminimax(f,9,26,d;error=:absolute,arithmetic=:fixed)
            try
                Sollya.coefficients(p)
            finally
                close(p)
            end
        finally
            close(f); close(d)
        end
    end
    spec = FunctionSpec(expression;input_format=FixedFormat(9,3),output_format=FixedFormat(24,4),
                        domain=(-1,1),absolute_error=1//(1<<18))
    return polynomial_plan(spec,coefficients;internal_format=FixedFormat(32,6),evaluation)
end

# Compare against an enclosure of the mathematical value, rather than its
# rounded fixed reference. Also exercise every rejected word and node range.
function exhaustive_polynomial_certificate(result;backend=:mpfr,exact=nothing)
    @test result.status == :certified
    plan,path = result.plan,only(result.paths)
    bounds = Dict(b.node=>b.range for b in path.ranges)
    words = BigInt[]
    maxerror = PRESAGe._q(0)
    with_oracle(plan.spec;backend) do oracle
        for word in BigInt(0):PRESAGe._fixed_mask(plan.spec.input_format)
            x = decode_fixed(word,plan.spec.input_format)
            if !(path.domain[1] <= x <= path.domain[2])
                @test_throws DomainError evaluate_bits(plan,word)
                continue
            end
            push!(words,word)
            trace = interpret_trace(plan,word)
            actual = decode_fixed(trace.bits,plan.spec.output_format)
            ref = reference(oracle,word)
            @test ref.status in (:resolved,:special)
            lo,hi = if exact !== nothing
                value = PRESAGe._q(exact(x))
                value,value
            elseif ref.enclosure !== nothing
                a,b = ref.enclosure
                a.significand*PRESAGe._pow2(a.exponent),b.significand*PRESAGe._pow2(b.exponent)
            else
                # The only exact primitive identities in these cases are at 0.
                @test x == 0
                value = plan.spec.expression == "exp(x)" ? PRESAGe._q(1) : PRESAGe._q(0)
                value,value
            end
            error = max(abs(actual-lo),abs(actual-hi))
            maxerror = max(maxerror,error)
            @test error <= result.total_bound
            @test all(haskey(bounds,i) && bounds[i][1] <=
                decode_fixed(value.bits,IR.format(plan.program,i)) <= bounds[i][2]
                for (i,value) in trace.values if IR.format(plan.program,i) isa FixedFormat)
        end
    end
    return words,maxerror
end

@testset "Uniform fixed polynomial certificates" begin
    backends = Symbol[:portable]
    for backend in (:ac_fixed,:ap_fixed)
        try
            vendor_include(backend)
            push!(backends,backend)
        catch
            get(ENV,"PRESAGE_REQUIRE_VENDOR_TESTS","false") == "true" && rethrow()
        end
    end
    for mode in (:separate,:fma)
        for expression in ("erf(x)","exp(x)")
            plan = bounded_polynomial(expression;evaluation=mode)
            result = certify_polynomial(plan)
            @test result.total_bound <= plan.spec.absolute_error
            @test only(result.paths).coordinate_error == 0
            @test only(result.paths).output_rounding == 1//(1<<21)
            @test result.tail_bound === nothing
            words,maximum_error = exhaustive_polynomial_certificate(result)
            @test length(words) == 129
            for backend in backends
                @test cpu_check(plan,words;backend) == length(words)
            end
            println("Bounded $expression ($mode): uniform bound ",Float64(result.total_bound),
                    "; exhaustive enclosed maximum ",Float64(maximum_error))
        end
    end
    # Complete formats, exact affine arithmetic, coarse input conversion, and
    # coordinates above one (where earlier rounding is amplified).
    cases = (
        (FunctionSpec("x/2+1/4";input_format=FixedFormat(9,4),output_format=FixedFormat(13,5)),
            [1//4,1//2],FixedFormat(24,8),x->x/2+1//4),
        (FunctionSpec("x^2+x/4";input_format=FixedFormat(8,3),output_format=FixedFormat(16,6),
            absolute_error=1//4,domain=(-1,1)),[0,1//4,1],FixedFormat(8,4),x->x*x+x/4),
        (FunctionSpec("x^3/8+x/4";input_format=FixedFormat(8,4),output_format=FixedFormat(16,6),
            absolute_error=1//8,domain=(-2,2)),[0,1//4,0,1//8],FixedFormat(12,6),x->x^3/8+x/4),
        (FunctionSpec("x/2+1/4";input_format=FixedFormat(6,3),output_format=FixedFormat(8,3),
            absolute_error=1//4,domain=(-1,1)),[1//4,1//2],FixedFormat(4,2),x->x/2+1//4),
        (FunctionSpec("x/4";input_format=FixedFormat(8,3;signed=false),output_format=FixedFormat(10,3;signed=false),
            absolute_error=1//4),[0,1//4],FixedFormat(10,4;signed=false),x->x/4))
    for (spec,coefficients,format,exact) in cases, mode in (:separate,:fma)
        result = certify_polynomial(polynomial_plan(spec,coefficients;internal_format=format,evaluation=mode))
        _,maximum_error = exhaustive_polynomial_certificate(result;backend=:sollya,exact)
        @test maximum_error <= result.total_bound
        @test only(result.paths).approximation == (0,0)
        if spec.expression == "x/2+1/4" && spec.domain === nothing
            @test result.total_bound == 0
        elseif spec.expression == "x^2+x/4"
            @test only(result.paths).coordinate_error > 0
        end
    end
    tiespec = cases[4][1]
    separate = polynomial_plan(tiespec,[1//4,1//2];internal_format=FixedFormat(4,2))
    fused = polynomial_plan(tiespec,[1//4,1//2];internal_format=FixedFormat(4,2),evaluation=:fma)
    word = round_fixed(1//4,tiespec.input_format)
    @test decode_fixed(evaluate_bits(separate,word),tiespec.output_format) == 1//4
    @test decode_fixed(evaluate_bits(fused,word),tiespec.output_format) == 1//2
    # Inward thresholds, clipped domains, singleton domains, and constants.
    for (domain,expected) in (((-1//3,1//3),(-1//4,1//4)),((-20,20),(-2,7//4)),((1//4,1//4),(1//4,1//4)))
        spec = FunctionSpec("x";input_format=FixedFormat(4,2),domain)
        result = certify_polynomial(polynomial_plan(spec,[0,1]))
        @test result.status == :certified
        @test only(result.paths).domain == expected
        exhaustive_polynomial_certificate(result;backend=:sollya,exact=identity)
    end
    constant = polynomial_plan(FunctionSpec("1/3";input_format=FixedFormat(4,2),
        output_format=FixedFormat(12,3),absolute_error=1//256),[1//3])
    result = certify_polynomial(constant)
    @test result.status == :certified
    @test result.total_bound == abs(decode_fixed(round_fixed(1//3,constant.spec.output_format),constant.spec.output_format)-1//3)
    exhaustive_polynomial_certificate(result;backend=:sollya,exact=x->1//3)
    # A constant does not execute the input conversion. Its input range need
    # not fit that unused internal node's narrow format.
    constant = polynomial_plan(FunctionSpec("1/2";input_format=FixedFormat(9,4),
        output_format=FixedFormat(3,1)),[1//2];internal_format=FixedFormat(2,1))
    result = certify_polynomial(constant)
    @test result.total_bound == 0
    words,_ = exhaustive_polynomial_certificate(result;backend=:sollya,exact=x->1//2)
    for backend in backends
        @test cpu_check(constant,words;backend) == length(words)
    end
    singleton = polynomial_plan(FunctionSpec("exp(x)";input_format=FixedFormat(4,2),
        output_format=FixedFormat(12,3),domain=(1//4,1//4),absolute_error=1//2),[1])
    @test certify_polynomial(singleton).status == :certified
    wide = polynomial_plan(FunctionSpec("x/2";input_format=FixedFormat(137,5),
        output_format=FixedFormat(138,5)),[0,1//2];internal_format=FixedFormat(150,10))
    @test certify_polynomial(wide).total_bound == 0
    @test certify_polynomial(wide;precision=64).total_bound == 0

    # Stored coefficients are the source of truth. Changing them requires a
    # fresh numerical bound; modifying operations or guards fails the audit.
    identityplan = polynomial_plan(FunctionSpec("x";input_format=FixedFormat(6,3),domain=(-1,1)),[0,1])
    nodes = collect(identityplan.program.nodes)
    nodes[2] = IR.constant(1//8,identityplan.spec.input_format)
    changed = PlanArtifact(identityplan.spec;program=IR.Program(nodes),settings=identityplan.settings)
    @test certify_polynomial(changed).status == :bound_exceeds_budget
    for mutation in (:guard,:coordinate,:extra)
        nodes = collect(identityplan.program.nodes)
        if mutation == :guard
            nodes[end] = IR.Guard(length(nodes)-1,1)
        elseif mutation == :coordinate
            i = findfirst(n->n isa IR.Mul,nodes)
            nodes[i] = IR.Mul(nodes[i].a,2,nodes[i].format)
        else
            push!(nodes,IR.Guard(identityplan.program.output-1,identityplan.program.output))
        end
        changed = PlanArtifact(identityplan.spec;program=IR.Program(nodes),settings=identityplan.settings)
        @test certify_polynomial(changed).status == :unsupported_domain
    end
    overflow = polynomial_plan(FunctionSpec("x^2";input_format=FixedFormat(6,3)),[0,0,1])
    result = certify_polynomial(overflow)
    @test result.status == :proof_failed
    @test occursin("node",result.reason) && occursin("overflow",result.reason)
    outputoverflow = polynomial_plan(FunctionSpec("x";input_format=FixedFormat(6,3),output_format=FixedFormat(4,2)),
                                     [0,1];internal_format=FixedFormat(16,6))
    @test certify_polynomial(outputoverflow).status == :proof_failed
    for policy in (:wrap,:saturate)
        spec = FunctionSpec("x";input_format=FixedFormat(6,3;overflow=policy))
        @test certify_polynomial(polynomial_plan(spec,[0,1])).status == :unsupported_domain
    end
    for rounding in (:up,:down,:toward_zero)
        spec = FunctionSpec("x";input_format=FixedFormat(6,3;rounding))
        @test certify_polynomial(polynomial_plan(spec,[0,1])).status == :unsupported_domain
    end
    for expression in ("log(x)","1/x","log(x)-log(x)")
        plan = polynomial_plan(FunctionSpec(expression;input_format=FixedFormat(6,3)),[0])
        @test certify_polynomial(plan).status == :proof_failed
    end
    @test certify_polynomial(polynomial_plan(FunctionSpec("x"),[0,1])).status == :unsupported_domain
    @test certify_polynomial(PlanArtifact(identityplan.spec)).status == :unsupported_domain
    highdegree = polynomial_plan(FunctionSpec("x^33";input_format=FixedFormat(6,3),domain=(-1,1)),
                                 [zeros(Int,33);1])
    @test certify_polynomial(highdegree).status == :unsupported_domain
    @test certify_plan(identityplan).status == :certified
    @test_throws ArgumentError certify_polynomial(identityplan;precision=32)
    @test_throws ArgumentError certify_polynomial(identityplan;accuracy=1)
    @test_throws ArgumentError certify_polynomial(identityplan;max_refinements=9)
    io = IOBuffer(); write_certificate(io,certify_polynomial(identityplan))
    data = TOML.parse(String(take!(io)))
    @test data["schema_version"] == 2
    @test data["paths"][1]["domain"] == ["-1/1","1/1"]
    @test data["coverage"]["inputs"] == "all representable fixed inputs in the interval"
    @test !haskey(data["coverage"],"infinities") && !haskey(data,"tail")
end
