@testset "Contract and exact versioned artifacts" begin
    spec = erf_spec()
    @test spec.input_format == IEEE32
    @test spec.absolute_error == BigInt(1) // (BigInt(1) << 23)
    @test spec.domain === nothing
    @test_throws ArgumentError FunctionSpec("x"; absolute_error = 0)
    @test_throws ArgumentError FunctionSpec("x"; domain = (2, 1))
    threshold = round_ieee(392 // 100, IEEE32)
    @test threshold == 0x407ae148
    @test decode_ieee(threshold, IEEE32).value == 2055209 // 524288
    coefficient = ((BigInt(1) << 2000) + 7) // ((BigInt(1) << 1900) + 3)
    plan = PlanArtifact(
        spec;
        status = :candidate,
        dispatch = Dispatch(threshold),
        segments = [Segment(0, 1, [0, coefficient, -1 // 8])],
        settings = Dict("proof_precision" => "256"),
    )
    io = IOBuffer()
    write_plan(io, plan)
    text = String(take!(io))
    restored = read_plan(IOBuffer(text))
    @test restored.segments[1].coefficients == plan.segments[1].coefficients
    @test restored.spec.absolute_error == spec.absolute_error
    @test restored.dispatch.magnitude_threshold == threshold
    @test restored.settings == plan.settings
    @test restored.status == :candidate
    @test occursin("0x407ae148", text)
    @test_throws ArgumentError read_plan(
        IOBuffer(replace(text, "schema_version = 1" => "schema_version = 99")),
    )
    @test_throws ArgumentError read_plan(
        IOBuffer(replace(text, "schema_version = 1" => "schema_version = 1.0")),
    )
    @test_throws ArgumentError read_plan(
        IOBuffer(replace(text, "status = \"candidate\"" => "status = \"certified\"")),
    )
    @test_throws ArgumentError read_plan(IOBuffer(replace(text, "binary32" => "binary512")))
    @test_throws ArgumentError PRESAGe._parse_rational("1/0")
    @test_throws MethodError PRESAGe._parse_rational(0.125)
    @test_throws ArgumentError PlanArtifact(spec; status = :certified)
    @test_throws ArgumentError PlanArtifact(spec; dispatch = Dispatch(0x7f800000))
    @test_throws ArgumentError PlanArtifact(
        spec;
        segments = [Segment(0, 2, [1]), Segment(1, 3, [1])],
    )
    compact = IOBuffer()
    write_plan(compact, PlanArtifact(spec))
    @test TOML.parse(String(take!(compact)))["spec"] == Dict(
        "expression" => "erf(x)",
        "input_format" => "binary32",
        "absolute_error" => "1/8388608",
    )
    @test restored.spec.output_format == IEEE32
    bounded = PlanArtifact(
        FunctionSpec(
            "exp(x)";
            input_format = IEEE64,
            output_format = IEEE16,
            domain = (-1 // 3, 2 // 3),
        ),
    )
    mktemp() do path, io
        close(io)
        write_plan(path, bounded)
        @test read_plan(path).spec.domain == bounded.spec.domain
        @test read_plan(path).spec.output_format == IEEE16
        custom = PlanArtifact(FunctionSpec("x"; input_format = FloatFormat(3, 4)))
        write_plan(path, custom)
        @test read_plan(path).spec.input_format == custom.spec.input_format
    end
end
