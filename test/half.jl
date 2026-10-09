@testset "Binary16 CPU interfaces and conversions" begin
    words = UInt64.(0:65535)
    identity = PlanArtifact(
        FunctionSpec("x"; input_format = IEEE16);
        program = IR.Program([IR.Input(IEEE16)]),
    )
    @test cpu_check(identity, words; public_api = true) == 65536
    @test cpu_check(
        identity,
        UInt64[];
        expected_error = "truncated input word",
        input_bytes = UInt8[1],
    ) == 0
    for f in (IEEE32, IEEE64)
        roundtrip = PlanArtifact(
            FunctionSpec("x"; input_format = IEEE16);
            program = IR.Program([
                IR.Input(IEEE16),
                IR.Convert(1, f),
                IR.Convert(2, IEEE16),
            ]),
        )
        @test cpu_check(roundtrip, words; public_api = true) == 65536
        narrow = PlanArtifact(
            FunctionSpec("x"; input_format = f, output_format = IEEE16);
            program = IR.Program([IR.Input(f), IR.Convert(1, IEEE16)]),
        )
        directed = verification_inputs(narrow)
        for word in (0, 1, 2, 0x03ff, 0x0400, 0x0401, 0x3bff, 0x3c00, 0x3c01, 0x7bfe)
            midpoint =
                (decode_ieee(word, IEEE16).value + decode_ieee(word + 1, IEEE16).value) / 2
            center = round_ieee(midpoint, f)
            for bit in (center - 1, center, center + 1)
                append!(directed, [bit, bit | PRESAGe._sign(f)])
            end
        end
        overflow = round_ieee(65520, f)
        append!(directed, [overflow - 1, overflow, overflow + 1])
        append!(
            directed,
            [word | PRESAGe._sign(f) for word in (overflow - 1, overflow, overflow + 1)],
        )
        @test cpu_check(narrow, directed; public_api = true) == length(directed)
    end
    # No implicit float arithmetic may masquerade as binary16 arithmetic.
    half_arithmetic = IR.Program([IR.Input(IEEE16), IR.Mul(1, 1, IEEE16)])
    @test_throws ArgumentError emit_cpp(IOBuffer(), half_arithmetic)
end

@testset "Binary16 fixed bridges" begin
    # This covers the complete finite half range, including negative values and
    # subnormals, rather than just the erf central path. Guards skip nonfinites.
    spec = FunctionSpec("x"; input_format = IEEE16, domain = (-65504, 65504))
    roundtrip = polynomial_plan(spec, [0, 1]; internal_format = FixedFormat(42, 18))
    fixed = FixedFormat(45, 20)
    quantum = PRESAGe._pow2(-25)
    values = Rational{BigInt}[]
    for center in
        (0, quantum, PRESAGe._pow2(-14) - quantum, 1 // 2 + 1 // 4096, 1 + 1 // 2048, 65520)
        for delta in (-quantum, 0, quantum)
            value = PRESAGe._q(center + delta)
            append!(values, [value, -value])
        end
    end
    u = IR.UIntFormat(16)
    nodes = IR.Node[
        IR.Input(IEEE16),
        IR.BitCast(1, u),
        IR.ExtractBits(2, 0, 8),
        IR.ExtractBits(2, 8, 2),
        IR.TableLoad(1, 3),
    ]
    results = Int[]
    for mode in (:nearest_even, :toward_zero, :up, :down)
        push!(nodes, IR.Convert(5, IEEE16; rounding = mode))
        push!(results, length(nodes))
    end
    selected = results[end]
    for mode = 2:-1:0
        push!(
            nodes,
            IR.Const(IR.UIntFormat(2), mode),
            IR.Compare(:eq, 4, length(nodes) + 1),
        )
        push!(nodes, IR.Select(length(nodes), results[mode + 1], selected))
        selected = length(nodes)
    end
    matrix = PlanArtifact(
        FunctionSpec("x"; input_format = IEEE16);
        program = IR.Program(
            nodes;
            tables = [IR.Table(fixed, round_fixed.(values, Ref(fixed)))],
        ),
    )
    words = UInt64[(mode << 8) | row for mode = 0:3 for row = 0:(length(values) - 1)]
    for backend in (:portable, :ac_fixed, :ap_fixed)
        if backend != :portable
            available = try
                vendor_include(backend)
                true
            catch
                false
            end
            if !available
                get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" &&
                    error("$backend headers required")
                @test_skip available
                continue
            end
        end
        @test cpu_check(roundtrip, UInt64.(0:65535); backend, public_api = true) == 65536
        @test cpu_check(matrix, words; backend, public_api = true) == length(words)
    end
end

@testset "Binary16 implementation selection and exhaustive certificates" begin
    spec = erf_spec(; format = IEEE16)
    @test spec.absolute_error == 1 // 1024
    @test select_implementation(spec) == :lut
    @test select_implementation(
        spec;
        model = ImplementationModel(; lut_max_bits = (1 << 20) - 1),
    ) == :polynomial
    @test select_implementation(
        spec;
        model = ImplementationModel(; lut_max_bits = 1 << 20),
    ) == :lut
    @test select_implementation(spec; implementation = :polynomial) == :polynomial
    @test select_implementation(erf_spec()) == :polynomial
    @test_throws ArgumentError select_implementation(erf_spec(); implementation = :lut)
    @test_throws ArgumentError ImplementationModel(; lut_max_bits = -1)
    @test_throws ArgumentError select_implementation(spec; implementation = :unknown)
    lut = certified_erf(; spec)
    @test lut.status == :certified
    @test lut.settings["method"] == "exhaustive_lut"
    @test lut.total_bound <= spec.absolute_error
    @test length(only(lut.plan.program.tables).values) == 65536
    cost = implementation_cost(lut.plan)
    @test cost.table_bits == 1 << 20
    @test cost.table_reads == 1
    @test cost.multiplications == cost.additions == cost.fmas == 0
    @test certify_plan(lut.plan).status == :certified
    header = IOBuffer()
    emit_cpp(header, lut.plan)
    text = String(take!(header))
    @test occursin("constexpr std::uint16_t table1[]", text)
    @test !occursin("requires FE_TONEAREST", text)
    @test cpu_check(lut.plan; public_api = true, host_rounding = :down) == 65536
    # Recertification must reject changed entries, graphs, missing rows and labels
    # that attempt to turn a contract into an evaluator.
    values = collect(only(lut.plan.program.tables).values)
    values[1] = 1
    changed = PRESAGe._lut_plan(spec, values)
    @test certify_lut(changed).status == :proof_failed
    p = lut.plan.program
    nodes = collect(p.nodes)
    nodes[2] = IR.Const(IR.UIntFormat(16), 0)
    changed = PlanArtifact(
        spec;
        program = IR.Program(nodes; tables = p.tables),
        settings = lut.plan.settings,
    )
    @test certify_plan(changed).status == :unsupported_domain
    missing = PlanArtifact(
        spec;
        program = IR.Program(collect(p.nodes); tables = [IR.Table(IEEE16, [0])]),
        settings = lut.plan.settings,
    )
    @test certify_lut(missing).status == :unsupported_domain
    tiny = FunctionSpec("erf(x)"; input_format = IEEE16, absolute_error = 1 // (1 << 30))
    changed = PlanArtifact(tiny; program = p, settings = lut.plan.settings)
    @test certify_lut(changed).status == :bound_exceeds_budget
    @test certified_lut(
        spec;
        config = OracleConfig(; initial_precision = 12, max_precision = 12),
    ).status == :proof_failed
    @test certified_lut(FunctionSpec("sqrt(x)"; input_format = IEEE16)).status ==
          :unsupported_domain
    @test certified_lut(erf_spec()).status == :unsupported_domain
    io = IOBuffer()
    write_certificate(io, lut)
    report = TOML.parse(String(take!(io)))
    @test report["coverage"]["table_bits"] == 1 << 20
    @test report["coverage"]["inputs"] == "all 65536 input encodings"
    words = UInt64.(0:65535)
    polynomials = CertificationResult[]
    for evaluation in (:separate, :fma)
        result = certified_erf(; spec, implementation = :polynomial, evaluation)
        @test result.status == :certified
        @test result.total_bound <= spec.absolute_error
        @test result.plan.settings["kernel"] == "erf_fixed_horner"
        @test implementation_cost(result.plan).table_bits < cost.table_bits
        @test cpu_check(result.plan, words; public_api = true) == 65536
        push!(polynomials, result)
    end
    with_oracle(spec; backend = :mpfr) do oracle
        maximum_errors = fill(PRESAGe._q(0), length(polynomials))
        for word in words
            ref = reference(oracle, word)
            @test evaluate_bits(lut.plan, word) == ref.bits
            for (i, result) in enumerate(polynomials)
                actual = evaluate_bits(result.plan, word)
                if ref.enclosure === nothing
                    @test actual == ref.bits
                else
                    y = decode_ieee(actual, IEEE16).value
                    lo, hi = ref.enclosure
                    error = max(
                        abs(y - lo.significand * PRESAGe._pow2(lo.exponent)),
                        abs(y - hi.significand * PRESAGe._pow2(hi.exponent)),
                    )
                    maximum_errors[i] = max(maximum_errors[i], error)
                    @test error <= result.total_bound
                end
            end
        end
        println("Binary16 erf LUT bound: ", Float64(lut.total_bound))
        for (result, error) in zip(polynomials, maximum_errors)
            println(
                "Binary16 erf ",
                result.plan.settings["evaluation"],
                ": uniform bound ",
                Float64(result.total_bound),
                "; exhaustive enclosed maximum ",
                Float64(error),
            )
        end
    end
    for backend in (:ac_fixed, :ap_fixed)
        available = try
            vendor_include(backend)
            true
        catch
            false
        end
        if !available
            get(ENV, "PRESAGE_REQUIRE_VENDOR_TESTS", "false") == "true" &&
                error("$backend headers required")
            @test_skip available
            continue
        end
        @test cpu_check(lut.plan, words; backend, public_api = true) == 65536
        for result in polynomials
            @test cpu_check(result.plan, words; backend, public_api = true) == 65536
        end
    end
end
