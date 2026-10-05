@testset "Fixed I/O contracts, execution and references" begin
    input = FixedFormat(8,4)
    s = FunctionSpec("x";input_format=input)
    @test s.output_format == input
    @test s.domain === nothing
    @test_throws ArgumentError PlanArtifact(s;dispatch=Dispatch(1))
    @test_throws ArgumentError IR.Program([IR.Input(input),IR.Const(Bool,1)])
    @test_throws ArgumentError IR.Program([IR.Input(input),IR.Guard(1,1)])
    @test_throws ArgumentError IR.Program([IR.Input(input),IR.Const(Bool,1),IR.Const(IR.UIntFormat(8),0),IR.Guard(2,3)])
    @test_throws ArgumentError ReferenceOracle(FunctionSpec("x";input_format=FixedFormat(65,4));
        config=OracleConfig(initial_precision=12,max_precision=64))
    for infmt in (input,IEEE32),outfmt in (input,IEEE64)
        spec = FunctionSpec("x";input_format=infmt,output_format=outfmt)
        program = IR.Program([IR.Input(infmt),IR.Convert(1,outfmt)])
        io = IOBuffer();write_plan(io,PlanArtifact(spec;program));text = String(take!(io))
        restored = read_plan(IOBuffer(text))
        @test restored.spec.input_format == infmt
        @test restored.spec.output_format == outfmt
        expected_version = infmt isa FixedFormat || outfmt isa FixedFormat ? 4 : 2
        @test TOML.parse(text)["schema_version"] == expected_version
        if expected_version == 4
            @test_throws ArgumentError read_plan(IOBuffer(replace(text,"schema_version = 4"=>"schema_version = 3")))
        end
    end
    compact = IOBuffer(); write_plan(compact,PlanArtifact(s))
    data = TOML.parse(String(take!(compact)))
    @test data["schema_version"] == 4
    @test !haskey(data["spec"],"output_format")
    @test read_plan(IOBuffer(sprint(write_plan,PlanArtifact(s)))).spec.input_format == input

    # All input words, including both signed extrema. The wide evaluator makes
    # the affine polynomial exact until the declared output conversion.
    internal = FixedFormat(28,12)
    for signed in (true,false),mode in (:nearest_even,:toward_zero,:up,:down),overflow in (:reject,:saturate,:wrap)
        out = FixedFormat(5,2;signed,rounding=mode,overflow)
        spec = FunctionSpec("x/2+1/4";input_format=input,output_format=out)
        plan = polynomial_plan(spec,[1//4,1//2];internal_format=internal)
        with_oracle(spec) do oracle
            for bits in 0:255
                q = decode_fixed(bits,input)/2+1//4
                expected = try round_fixed(q,out) catch error
                    error isa OverflowError || rethrow()
                    nothing
                end
                ref = reference(oracle,bits)
                if expected === nothing
                    @test ref.status == :overflow
                    @test ref.bits === nothing
                    @test_throws OverflowError evaluate_bits(plan,bits)
                else
                    @test ref.bits == expected
                    @test ref.status == :resolved
                    @test evaluate_bits(plan,bits) == expected
                    @test interpret_trace(plan,bits).bits == expected
                end
            end
        end
    end
    @test_throws ArgumentError evaluate_bits(IR.Program([IR.Input(input)]),256)
    @test_throws ArgumentError evaluate_bits(IR.Program([IR.Input(input)]),-1)
    bounded = polynomial_plan(FunctionSpec("x";input_format=input,domain=(-1//3,1//3)),[0,1])
    @test decode_fixed(evaluate_bits(bounded,round_fixed(5//16,input)),input) == 5//16
    @test_throws DomainError evaluate_bits(bounded,round_fixed(3//8,input))
    @test reference(bounded.spec,round_fixed(3//8,input)).status == :outside_domain
    @test_throws ArgumentError polynomial_plan(FunctionSpec("x";input_format=input,domain=(1//100,1//50)),[0,1])
    clipped = polynomial_plan(FunctionSpec("x";input_format=input,domain=(-100,100)),[0,1])
    @test evaluate_bits(clipped,128) == 128
    @test evaluate_bits(clipped,127) == 127
    # Domain rejection executes before a source whose conversion would overflow.
    p = IR.Program([IR.Input(input),IR.Const(Bool,0),IR.constant(100,IEEE32),
        IR.Convert(3,FixedFormat(3,1)),IR.Guard(2,4)])
    @test_throws DomainError evaluate_bits(p,0)

    small = FixedFormat(9,3)
    out = FixedFormat(10,2)
    spec = FunctionSpec("erf(x)";input_format=small,output_format=out)
    with_oracle(spec) do sollya
        with_oracle(spec;backend=:mpfr) do mpfr
            for bits in 0:511
                a,b = reference(sollya,bits),reference(mpfr,bits)
                @test a.status in (:resolved,:special)
                @test b.status in (:resolved,:special)
                @test a.bits == b.bits
            end
        end
    end
    @test reference(FunctionSpec("sqrt(x)";input_format=input),round_fixed(-1,input)).status == :domain_error
    @test reference(FunctionSpec("sqrt(x)";input_format=input),round_fixed(-1,input)).bits === nothing
    for expression in ("log(x)","1/x","1/sqrt(x)")
        @test reference(FunctionSpec(expression;input_format=input),0).status == :nonfinite_output
    end
    @test reference(FunctionSpec("x";output_format=input),0x7fc00000).status == :nonfinite_output
    @test reference(FunctionSpec("erf(x)";output_format=input),0x7f800000).bits == round_fixed(1,input)
    @test reference(FunctionSpec("erf(x)";input_format=input,output_format=IEEE32),128;backend=:mpfr).bits ==
        reference(FunctionSpec("erf(x)";input_format=input,output_format=IEEE32),128).bits

    config = OracleConfig(initial_precision=12,max_precision=12)
    # Wrapped endpoints both encode zero, but the enclosure spans a full period.
    wrap = FixedFormat(3,1;signed=false,overflow=:wrap)
    bounds = _ -> (DyadicBound(0,0),DyadicBound(2,0))
    @test PRESAGe._adaptive(bounds,wrap,config,12,:test).status == :unresolved
    bounds = _ -> (DyadicBound(257,-7),DyadicBound(259,-7))
    @test PRESAGe._adaptive(bounds,wrap,config,12,:test).bits == 0
    bounds = _ -> (DyadicBound(119,-6),DyadicBound(121,-6))
    @test PRESAGe._adaptive(bounds,FixedFormat(4,2),config,12,:test).status == :unresolved
    # Huge bounds classify overflow without allocating enormous integers.
    for overflow in (:reject,:saturate)
        f = FixedFormat(8,4;overflow)
        bounds = _ -> (DyadicBound(1,1_000_000_000),DyadicBound(3,1_000_000_000))
        result = PRESAGe._adaptive(bounds,f,config,12,:test)
        @test result.status == (overflow == :reject ? :overflow : :resolved)
        @test result.bits == (overflow == :reject ? nothing : BigInt(127))
    end
end

@testset "Fixed I/O binary streams and commands" begin
    mktempdir() do directory
        for order in (:little,:big),width in (9,137)
            f = FixedFormat(width,4)
            spec = FunctionSpec("x";input_format=f)
            words = BigInt[0,1,(BigInt(1)<<width)-1,BigInt(1)<<(width-1)]
            input,output = joinpath.(Ref(directory),("in_$(order)_$width.bin","out_$(order)_$width.bin"))
            open(input,"w") do io
                foreach(w -> PRESAGe._write_word(io,w,cld(width,8),order),words)
            end
            summary = generate_references(spec,input,output;byteorder=order,chunk_elements=3)
            @test read(input) == read(output)
            @test summary["complete"]
            @test summary["schema_version"] == 2
            @test summary["input_word_bytes"] == cld(width,8)
            @test summary["padding"] == "zero_high_bits"
            @test summary["maximum_chunk_elements"] == 3
            @test summary["input_format"]["width"] == width
            @test summary["output_format"] == summary["input_format"]
        end
        input,output = joinpath.(Ref(directory),("cli_in.bin","cli_out.bin"))
        write(input,UInt8[0x04,0x1c]) # Signed fixed(5,2): +1/2 and -1/2.
        main(["x/2",input,output,"--input-format=fixed(5,2)","--output-format=fixed(7,2)"])
        @test read(output) == UInt8[0x08,0x78]
        @test_throws ErrorException main(["x",input,output,"--format=fixed(5,2)","--input-format=single"])
        @test_throws ErrorException main(["x",input,output,"--output-format=single","--rounding=up"])
        @test reference_format("ufixed(7,3)").signed == false
        @test_throws ArgumentError reference_format("fixed(3,4)")
        bad = joinpath(directory,"bad.bin");write(bad,UInt8[0xff])
        failed = joinpath(directory,"bad_out.bin")
        @test_throws ArgumentError generate_references(FunctionSpec("x";input_format=FixedFormat(5,2)),bad,failed)
        @test !isfile(failed)
        @test !TOML.parsefile(failed*".toml")["complete"]
        f = FixedFormat(8,4)
        write(bad,UInt8[0x7f])
        failed = joinpath(directory,"overflow.bin")
        @test_throws ReferenceFailure generate_references(FunctionSpec("2*x";input_format=f),bad,failed)
        @test !isfile(failed)
        @test TOML.parsefile(failed*".toml")["status_counts"]["overflow"] == 1
        write(bad,UInt8[0])
        failed = joinpath(directory,"pole.bin")
        @test_throws ReferenceFailure generate_references(FunctionSpec("1/x";input_format=f),bad,failed)
        @test TOML.parsefile(failed*".toml")["status_counts"]["nonfinite_output"] == 1
        write(bad,UInt8[0,0,0])
        @test_throws ArgumentError generate_references(FunctionSpec("x";input_format=FixedFormat(9,4)),bad,joinpath(directory,"truncated.bin"))
    end
end

@testset "Fixed I/O CPU conformance" begin
    backends = Symbol[:portable]
    for backend in (:ap_fixed,:ac_fixed)
        try vendor_include(backend);push!(backends,backend) catch
            get(ENV,"PRESAGE_REQUIRE_VENDOR_TESTS","false") == "true" && rethrow()
        end
    end
    for backend in backends
        @testset "$backend" begin
            for width in (1,7,64,65,137),signed in (true,false)
                f = FixedFormat(width,min(width,4);signed)
                plan = PlanArtifact(FunctionSpec("x";input_format=f);program=IR.Program([IR.Input(f)]))
                words = verification_inputs(plan;random_count=32)
                @test cpu_check(plan,words;backend,public_api=true) == length(words)
            end
            internal = FixedFormat(28,12)
            input = FixedFormat(9,4)
            for mode in (:nearest_even,:toward_zero,:up,:down)
                out = FixedFormat(5,2;rounding=mode,overflow=:saturate)
                plan = polynomial_plan(FunctionSpec("x/2+1/4";input_format=input,output_format=out),[1//4,1//2];internal_format=internal)
                @test cpu_check(plan;backend,public_api=true) == 512
            end
            out = FixedFormat(5,2;signed=false,overflow=:wrap)
            plan = polynomial_plan(FunctionSpec("x/2+1/4";input_format=input,output_format=out),[1//4,1//2];internal_format=internal)
            @test cpu_check(plan;backend) == 512
            # Full-span unsigned input; signed output and exact narrow rounding.
            u = FixedFormat(8,4;signed=false)
            plan = polynomial_plan(FunctionSpec("x/16-1";input_format=u,output_format=FixedFormat(5,2)),[-1,1//16];internal_format=internal)
            @test cpu_check(plan;backend) == 256
            mixed = polynomial_plan(FunctionSpec("x/2";input_format=input,output_format=IEEE64),[0,1//2];internal_format=internal)
            @test cpu_check(mixed;backend) == 512
            mixed = polynomial_plan(FunctionSpec("x";output_format=FixedFormat(12,4;overflow=:saturate)),[0,1];internal_format=IEEE64)
            @test cpu_check(mixed;backend) > 2048
            bounded = polynomial_plan(FunctionSpec("x";input_format=input,domain=(-1//3,1//3)),[0,1])
            @test cpu_check(bounded;backend) == 21
            @test cpu_check(bounded,[round_fixed(3//8,input)];backend,expected_error="input outside declared domain") == 1
            identity = PlanArtifact(FunctionSpec("x";input_format=input);program=IR.Program([IR.Input(input)]))
            @test cpu_check(identity,BigInt[];backend) == 0
            @test cpu_check(identity,BigInt[];backend,input_bytes=UInt8[0],expected_error="truncated input word") == 0
            @test cpu_check(identity,[BigInt(512)];backend,expected_error="bits exceed fixed format width") == 1
            # Width validation also applies when the numerical input is unused.
            unused = IR.Program([IR.Input(input),IR.constant(0,input)];output=2)
            @test cpu_check(PlanArtifact(identity.spec;program=unused),[BigInt(512)];backend,
                expected_error="bits exceed fixed format width") == 1
            rejected = polynomial_plan(FunctionSpec("2*x";input_format=input),[0,2];internal_format=internal)
            @test cpu_check(rejected,[round_fixed(7,input)];backend,expected_error="fixed result exceeds declared format") == 1
            # Fixed tables and a fixed input drive lazy selection/index tracing.
            f = FixedFormat(7,3); out = FixedFormat(2,2)
            nodes = IR.Node[IR.Input(f),IR.Classify(:negative,1),IR.Const(IR.UIntFormat(8),0),
                IR.Const(IR.UIntFormat(8),1),IR.Select(2,3,4),IR.TableLoad(1,5)]
            table = IR.Table(out,round_fixed.([-1,1],Ref(out)))
            plan = PlanArtifact(FunctionSpec("x";input_format=f,output_format=out);program=IR.Program(nodes;tables=[table]))
            @test cpu_check(plan;backend) == 128
        end
    end
end
