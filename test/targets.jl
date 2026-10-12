@testset "Intel arithmetic accepts only supported formats and operations" begin
    target = TargetProfile(:oneapi)
    for (exponent, fraction) in PRESAGe._INTEL_FLOAT_FORMATS, node in (IR.Add, IR.Mul)
        format = FloatFormat(exponent, fraction)
        p = IR.Program([IR.Input(format), node(1, 1, format)])
        @test target_support(p, target).supported
        text = sprint(io -> emit_kernel(io, p; toolchain = :oneapi))
        @test occursin("ac_types/ap_float.hpp", text)
        @test !occursin("ac_std_float", text)
        @test occursin("FP_Subnormal::ON", text)
    end
    for format in (FloatFormat(8, 22), IEEE128), node in (IR.Add, IR.Mul)
        p = IR.Program([IR.Input(format), node(1, 1, format)])
        @test !target_support(p, target).supported
        io = IOBuffer()
        @test_throws ArgumentError emit_kernel(io, p; toolchain = :oneapi)
        @test isempty(take!(io))
    end
    fused = IR.Program([IR.Input(FloatFormat(8, 17)), IR.FMA(1, 1, 1, FloatFormat(8, 17))])
    @test !target_support(fused, target).supported
    @test target_support(fused, TargetProfile(:generic)).supported
    dead = IR.Program(
        [IR.Input(FloatFormat(8, 17)), IR.FMA(1, 1, 1, FloatFormat(8, 17))];
        output = 1,
    )
    @test !target_support(dead, target).supported
    mktempdir() do directory
        path = joinpath(directory, "evaluator.hpp")
        write(path, "preserved")
        @test_throws ArgumentError emit_kernel(path, fused; toolchain = :oneapi)
        @test read(path, String) == "preserved"
    end
end

@testset "Encoded formats remain independent of native arithmetic support" begin
    custom = FloatFormat(8, 22)
    for p in (
        IR.Program([IR.Input(custom)]),
        IR.Program([IR.Input(custom), IR.Convert(1, IEEE32), IR.Mul(2, 2, IEEE32)]),
        IR.Program([IR.Input(custom), IR.Convert(1, FixedFormat(32, 4))]),
    )
        @test target_support(p, TargetProfile(:oneapi)).supported
    end
    intermediate = IR.Program([
        IR.Input(IEEE32),
        IR.Convert(1, custom),
        IR.Mul(2, 2, custom),
        IR.Convert(3, IEEE32),
    ])
    @test !target_support(intermediate, TargetProfile(:oneapi)).supported
end

@testset "Resource costs do not imply target support" begin
    model =
        read_resource_model(joinpath(@__DIR__, "..", "config", "resources", "oneapi.toml"))
    fused = IR.Program([IR.Input(FloatFormat(8, 17)), IR.FMA(1, 1, 1, FloatFormat(8, 17))])
    estimate = estimate_resources(fused; model)
    @test estimate.status == :unsupported
    @test !estimate.support.supported
    @test all(isnothing, estimate.totals)
    multiply = IR.Program([IR.Input(IEEE32), IR.Mul(1, 1, IEEE32)])
    estimate = estimate_resources(multiply; model)
    @test estimate.status == :partial
    @test estimate.support.supported
    @test all(isnothing, estimate.totals)
end

@testset "Unsupported arithmetic does not start a search worker" begin
    spec = FunctionSpec(
        "x";
        input_format = IEEE32,
        domain = (-1, 1),
        absolute_error = 1 // 256,
    )
    config = PolynomialSearchConfig(
        evaluation = :separate,
        degrees = [1],
        internal_formats = [FloatFormat(8, 22)],
    )
    result = PRESAGe._search_polynomial(
        spec,
        config;
        target = TargetProfile(:oneapi),
        worker_command = _ -> error("worker must not run"),
    )
    @test only(result.attempts).status == :target_unsupported
    @test result.selected === nothing
    result = PRESAGe._sweep_polynomial(
        spec,
        config;
        resource_model = ResourceModel(toolchain = :oneapi),
        worker_command = _ -> error("worker must not run"),
    )
    @test only(result.rows).attempt.status == :target_unsupported
    @test only(result.selections).status == :target_unsupported
end
