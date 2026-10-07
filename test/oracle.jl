@testset "Adaptive references and mathematical cases" begin
    sollya_precision = Sollya.working_precision()
    @test_throws ArgumentError OracleConfig(initial_precision = 11)
    @test_throws ArgumentError OracleConfig(initial_precision = 256, max_precision = 128)
    @test_throws ArgumentError ReferenceOracle(FunctionSpec("exp(x)+x"); backend = :mpfr)
    @test_throws ArgumentError ReferenceOracle(
        FunctionSpec("x"; input_format = IEEE64);
        config = OracleConfig(initial_precision = 24, max_precision = 24),
    )
    for backend in (:sollya, :mpfr)
        r = reference(FunctionSpec("exp(x)"), 0xc2af0001; backend)
        @test r.status == :resolved
        @test r.bits == 0x006cb285 # Correct rounding of a subnormal, directly from bounds.
        @test r.enclosure !== nothing
        @test r.precision == 256
        for (input, expected) in (
            (0x00000000, 0x00000000),
            (0x80000000, 0x80000000),
            (0x7f800000, 0x3f800000),
            (0xff800000, 0xbf800000),
            (0x7fa00001, 0x7fc00000),
            (0xffc12345, 0x7fc00000),
        )
            @test reference(erf_spec(), input; backend).bits == expected
        end
        @test reference(FunctionSpec("sqrt(x)"), 0xbf800000; backend).status ==
              :domain_error
        @test reference(FunctionSpec("log(x)"), 0xbf800000; backend).bits == 0x7fc00000
        @test reference(FunctionSpec("log(x)"), 0x80000000; backend).bits == 0xff800000
        @test reference(FunctionSpec("log1p(x)"), 0xbf800000; backend).bits == 0xff800000
        @test reference(FunctionSpec("1/x"), 0x80000000; backend).bits == 0xff800000
        @test reference(FunctionSpec("exp(x)"), 0xff800000; backend).bits == 0
        @test reference(FunctionSpec("exp(x)"), 0x7f800000; backend).bits == 0x7f800000
        @test reference(FunctionSpec("exp(x)"), 0x42c80000; backend).bits == 0x7f800000
        @test reference(FunctionSpec("exp(x)"), 0xc2c80000; backend).bits == 0x0000001b
        @test reference(FunctionSpec("exp(x)"), 0x7f7fffff; backend).bits == 0x7f800000
        @test reference(FunctionSpec("exp(x)"), 0xff7fffff; backend).bits == 0
        @test reference(erf_spec(), 0x00000001; backend).bits == 0x00000001
        @test reference(erf_spec(), 0x80000001; backend).bits == 0x80000001
        @test reference(
            FunctionSpec("erf(x)"; domain = (-1, 1)),
            0x40000000;
            backend,
        ).status == :outside_domain
        config = OracleConfig(initial_precision = 24, max_precision = 24)
        unresolved = reference(
            FunctionSpec("exp(x)"; output_format = IEEE64),
            0x3f800000;
            backend,
            config,
        )
        @test unresolved.status == :unresolved
        @test unresolved.bits === nothing
        @test unresolved.precision == 24
        adaptive = reference(
            FunctionSpec("exp(x)"; output_format = IEEE64),
            0x3f800000;
            backend,
            config = OracleConfig(initial_precision = 24, max_precision = 96),
        )
        @test adaptive.status == :resolved
        @test adaptive.precision == 96
        @test adaptive.bits == 0x4005bf0a8b145769
    end
    @test reference(FunctionSpec("1+1b-24"), 0).bits == 0x3f800000
    @test reference(FunctionSpec("1+3*1b-24"), 0).bits == 0x3f800002
    @test reference(FunctionSpec("x-x"), 0x80000000).bits == 0
    @test reference(FunctionSpec("0.1*x+1e-4"), 0x3f800000).bits ==
          round_ieee(1001 // 10000, IEEE32)
    @test reference(FunctionSpec("1.000000059604644775390625"), 0).bits == 0x3f800000
    @test reference(FunctionSpec("exp(x)+sin(x)/3"), 0x3f800000).status == :resolved
    @test reference(FunctionSpec("pi"), 0).bits == 0x40490fdb
    @test reference(FunctionSpec("pi*x"), 0x3f800000).bits == 0x40490fdb
    @test reference(FunctionSpec("exp(1)"), 0).bits == 0x402df854
    @test reference(FunctionSpec("sqrt(x)+1"), 0xbf800000).status == :evaluation_failed
    @test reference(FunctionSpec("atan(x)"), 0x7f800000).status == :resolved
    @test PRESAGe._exact_expression("log2(x)+0.1+1b-24+0x1p-2") ==
          "log2(x)+(1/10)+1b-24+0x1p-2"
    @test_throws ArgumentError PRESAGe._exact_expression("1e1000000*x")
    oracle = ReferenceOracle(erf_spec())
    close(oracle)
    close(oracle)
    @test !isopen(oracle)
    @test_throws ArgumentError reference(oracle, 0)
    # Independent native primitive checks on deterministic binary inputs.
    for name in ("erf", "erfc", "exp", "expm1", "sin", "cos", "tanh", "atan")
        spec = FunctionSpec("$name(x)")
        with_oracle(spec) do sollya
            with_oracle(spec; backend = :mpfr) do mpfr
                for value in (-8.0f0, -1.0f0, -0.125f0, 0.0f0, 0.125f0, 1.0f0, 8.0f0)
                    bits = reinterpret(UInt32, value)
                    a, b = reference(sollya, bits), reference(mpfr, bits)
                    @test a.bits !== nothing && a.bits == b.bits
                end
            end
        end
    end
    # Per-object native MPFR precision and rounding are safe across Julia versions.
    before = precision(BigFloat)
    tasks = [
        Threads.@spawn reference(FunctionSpec("exp(x)"), 0xc2af0001; backend = :mpfr)
        for _ = 1:8
    ]
    @test all(r -> r.bits == 0x006cb285, fetch.(tasks))
    @test precision(BigFloat) == before
    @test Sollya.working_precision() == sollya_precision
end
