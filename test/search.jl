@testset "Ordered bounded polynomial search" begin
    spec = FunctionSpec(
        "exp(x)";
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(24, 4),
        domain = (-1, 1),
        absolute_error = 1 // (1 << 18),
    )
    format = FixedFormat(32, 6)
    config = PolynomialSearchConfig(degrees = [1, 9], internal_formats = [format])
    result = search_polynomial(spec, config)
    @test result.status == :certified
    @test result.stop_reason == :certified
    @test [(a.degree, a.status) for a in result.attempts] == [(1, :bound_exceeds_budget), (9, :certified)]
    @test result.selected === last(result.attempts).certificate
    @test first(result.attempts).certificate.total_bound > spec.absolute_error
    @test result.selected.total_bound <= spec.absolute_error
    @test all(a -> 0 < a.elapsed_seconds <= config.job_timeout, result.attempts)
    @test result.elapsed_seconds >= sum(a.elapsed_seconds for a in result.attempts)

    # Replay exact coefficients from the report without another generation call.
    io = IOBuffer()
    write_search_report(io, result)
    report = TOML.parse(String(take!(io)))
    @test report["schema"] == "presage-search"
    @test report["schema_version"] == 1
    @test report["order"] == "degree_then_format"
    @test report["degrees"] == [1, 9]
    @test report["selected_attempt"] == 2
    @test report["limits"]["job_timeout_seconds"] == config.job_timeout
    @test report["settings"]["norm_accuracy"] == "1/1024"
    @test report["attempts"][1]["certificate"]["status"] == "bound_exceeds_budget"
    replay = PRESAGe._read_plan(report["attempts"][2]["plan"])
    @test PRESAGe._plan_data(replay) == PRESAGe._plan_data(result.selected.plan)
    proof = certify_polynomial(replay)
    @test proof.status == :certified
    @test proof.total_bound == result.selected.total_bound
    @test !isempty(report["attempts"][2]["certificate"]["paths"])
    # The existing generation tests cover mathematical and CPU execution of
    # this contract. Here check the exact selected-plan round trip for all words.
    @test all(0:511) do word
        input = decode_fixed(word, spec.input_format)
        -1 <= input <= 1 || return true
        evaluate_bits(replay, word) == evaluate_bits(result.selected.plan, word)
    end

    coarse = FixedFormat(16, 6)
    config = PolynomialSearchConfig(degrees = [9], internal_formats = [coarse, format])
    result = search_polynomial(spec, config)
    @test result.status == :certified
    @test [a.internal_format for a in result.attempts] == [coarse, format]
    @test first(result.attempts).status == :bound_exceeds_budget
    @test all(f -> f.integer_bits == 6, config.internal_formats)

    floats = (FloatFormat(8, 15), FloatFormat(8, 27))
    floating =
        FunctionSpec("exp(x)+0.1*x"; domain = (-1, 1), absolute_error = 1 // (1 << 21))
    result = search_polynomial(
        floating,
        PolynomialSearchConfig(
            degrees = [13],
            internal_formats = floats,
            evaluation = :fma,
        ),
    )
    @test result.status == :certified
    @test length(result.attempts) == 2
    @test first(result.attempts).status == :bound_exceeds_budget
    @test all(f -> f.exponent_bits == 8, floats)

    # Degree order is caller order, not ascending degree or estimated cost.
    result = search_polynomial(
        spec,
        PolynomialSearchConfig(degrees = [9, 1], internal_formats = [format, coarse]),
    )
    @test result.status == :certified
    @test length(result.attempts) == 1
    @test only(result.attempts).degree == 9
    @test only(result.attempts).internal_format == format

    limited = search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [1, 9],
            internal_formats = [format],
            max_attempts = 1,
        ),
    )
    @test limited.status == :search_limit
    @test limited.selected === nothing
    @test limited.stop_reason == :attempt_limit
    @test length(limited.attempts) == 1
    @test only(limited.attempts).plan.program !== nothing
    exhausted = search_polynomial(
        spec,
        PolynomialSearchConfig(degrees = [1], internal_formats = [format]),
    )
    @test exhausted.status == :search_limit
    @test exhausted.stop_reason == :choices_exhausted
    @test !isempty(only(exhausted.attempts).reason)
    mktempdir() do directory
        path = joinpath(directory, "search.toml")
        write_search_report(path, exhausted)
        @test TOML.parsefile(path)["status"] == "search_limit"
        @test !haskey(TOML.parsefile(path), "selected_attempt")
    end

    # A coefficient-range failure is distinct from a budget failure and does
    # not poison subsequent Sollya computations.
    constant = FunctionSpec(
        "4";
        input_format = FixedFormat(6, 3),
        output_format = FixedFormat(12, 4),
        domain = (-1, 1),
    )
    result = search_polynomial(
        constant,
        PolynomialSearchConfig(
            degrees = [0],
            internal_formats = [FixedFormat(8, 3), format],
        ),
    )
    @test [a.status for a in result.attempts] == [:generation_failed, :certified]
    @test first(result.attempts).plan.status == :contract
    @test occursin("coefficient", first(result.attempts).reason)

    # Traversal is degree-major, including mixed fixed/floating choices.
    impossible = FunctionSpec(
        "exp(x)";
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(24, 4),
        domain = (-1, 1),
        absolute_error = 1 // (big(1) << 100),
    )
    result = search_polynomial(
        impossible,
        PolynomialSearchConfig(
            degrees = [1, 2],
            internal_formats = [format, FloatFormat(8, 27)],
        ),
    )
    @test result.stop_reason == :choices_exhausted
    @test [(a.degree, a.internal_format) for a in result.attempts] == [(1, format), (1, FloatFormat(8, 27)), (2, format), (2, FloatFormat(8, 27))]
    io = IOBuffer()
    write_search_report(io, result)
    @test length(TOML.parse(String(take!(io)))["internal_formats"]) == 2

    # Wide coefficient words and exact rationals survive the process boundary.
    tiny = FunctionSpec(
        "1/$(big(1) << 150)";
        input_format = IEEE128,
        output_format = IEEE256,
        domain = (-1, 1),
        absolute_error = 1 // (big(1) << 200),
    )
    result = search_polynomial(
        tiny,
        PolynomialSearchConfig(degrees = [0], internal_formats = [FloatFormat(15, 160)]),
    )
    @test result.status == :certified
    @test result.selected.total_bound == 0
    @test any(result.selected.plan.program.nodes) do node
        node isa IR.Const && node.bits isa BigInt
    end
    io = IOBuffer()
    write_search_report(io, result)
    report = TOML.parse(String(take!(io)))
    replay = PRESAGe._read_plan(report["attempts"][1]["plan"])
    @test evaluate_bits(replay, round_ieee(0, IEEE128)) ==
          round_ieee(1 // (big(1) << 150), IEEE256)
end

@testset "Search request validation" begin
    format = FixedFormat(24, 6)
    defaults = (; degrees = [0, 1], internal_formats = [format])
    for degrees in ([], [0, 0], [-1, 1], [33], [1.0], [true], Iterators.countfrom(0))
        @test_throws ArgumentError PolynomialSearchConfig(; defaults..., degrees)
    end
    for internal_formats in (
        [],
        [format, format],
        ["binary32"],
        [FixedFormat(8, 3; rounding = :down)],
        [FixedFormat(8, 3; overflow = :wrap)],
    )
        @test_throws ArgumentError PolynomialSearchConfig(; defaults..., internal_formats)
    end
    for max_attempts in (0, -1, big(typemax(Int)) + 1)
        @test_throws ArgumentError PolynomialSearchConfig(; defaults..., max_attempts)
    end
    for timeout in (0, -1, Inf, NaN, big(1) // (big(1) << 2000))
        @test_throws ArgumentError PolynomialSearchConfig(;
            defaults...,
            job_timeout = timeout,
        )
        @test_throws ArgumentError PolynomialSearchConfig(;
            defaults...,
            total_timeout = timeout,
        )
    end
    @test_throws ArgumentError PolynomialSearchConfig(; defaults..., evaluation = :other)
    for generation_precision in (11, big(typemax(Cint)) + 1)
        @test_throws ArgumentError PolynomialSearchConfig(;
            defaults...,
            generation_precision,
        )
    end
    for proof_precision in (63, big(typemax(Cint)) + 1)
        @test_throws ArgumentError PolynomialSearchConfig(; defaults..., proof_precision)
    end
    @test_throws ArgumentError PolynomialSearchConfig(; defaults..., max_refinements = 9)
    @test_throws ArgumentError PolynomialSearchConfig(; defaults..., accuracy = 0)
    @test_throws ArgumentError PolynomialSearchConfig(; defaults..., accuracy = 1)
    @test PolynomialSearchConfig(degrees = 0:2, internal_formats = (IEEE32,)).degrees ==
          (0, 1, 2)
    # All formats are validated before any worker, even beyond max_attempts.
    launched = Ref(false)
    started = (process, directory) -> (launched[] = true)
    config = PolynomialSearchConfig(; defaults..., max_attempts = 1)
    for spec in (
        FunctionSpec("x"),
        FunctionSpec("x"; input_format = FixedFormat(8, 3), domain = (1 // 128, 1 // 64)),
        FunctionSpec(
            "x";
            domain = (-1, 1),
            output_format = FixedFormat(8, 3; overflow = :wrap),
        ),
    )
        @test_throws ArgumentError PRESAGe._search_polynomial(
            spec,
            config;
            process_started = started,
        )
    end
    @test !launched[]
    # Config captures the choice lists, independent of later caller mutation.
    degrees, formats = [1, 9], [format]
    config = PolynomialSearchConfig(; degrees, internal_formats = formats)
    degrees[1] = 32
    formats[1] = FixedFormat(8, 3)
    @test config.degrees == (1, 9)
    @test config.internal_formats == (format,)
end

@testset "Isolated numerical worker supervision" begin
    spec = FunctionSpec(
        "x";
        input_format = FixedFormat(8, 3),
        output_format = FixedFormat(16, 4),
        domain = (-1, 1),
    )
    format = FixedFormat(24, 6)
    fixture = joinpath(@__DIR__, "fixtures", "polynomial_worker.jl")
    # Fresh workers include Julia compilation. Leave enough time for successful
    # numerical jobs; the controlled hang still exceeds this bounded deadline.
    fixture_timeout = 30
    for (mode, expected) in (
        ("timeout", :timeout),
        ("crash", :worker_crashed),
        ("bad_result", :worker_failed),
        ("no_result", :worker_failed),
        ("exception", :worker_failed),
    )
        processes, directories = Base.Process[], String[]
        ready = Bool[]
        config = PolynomialSearchConfig(
            degrees = [0, 1],
            internal_formats = [format],
            job_timeout = fixture_timeout,
            total_timeout = 90,
        )
        command =
            directory -> addenv(
                PRESAGe._polynomial_worker_command(directory; script = fixture),
                "PRESAGE_WORKER_TEST_MODE" => mode,
            )
        result = PRESAGe._search_polynomial(
            spec,
            config;
            worker_command = command,
            process_started = (process, directory) -> begin
                push!(processes, process)
                push!(directories, directory)
                if length(directories) > 1
                    push!(ready, !isdir(directories[end - 1]))
                    @test process_exited(processes[end - 1])
                end
            end,
        )
        @test result.status == :certified
        @test [a.status for a in result.attempts] == [expected, :certified]
        @test first(result.attempts).plan !== nothing # Survived interrupted proof.
        @test first(result.attempts).plan.program !== nothing
        @test first(result.attempts).certificate === nothing
        @test result.selected.total_bound == 0
        @test length(processes) == 2
        @test all(process_exited, processes)
        @test all(path -> !isdir(path), directories)
        @test all(ready)
        @test !isempty(first(result.attempts).reason)
        if mode == "crash"
            @test processes[1].exitcode == 7
            @test occursin("controlled native-worker crash", first(result.attempts).reason)
        elseif mode == "timeout"
            @test processes[1].termsignal == Base.SIGKILL
            @test fixture_timeout <=
                  first(result.attempts).elapsed_seconds <
                  fixture_timeout + 4
            @test occursin("Job wall-time", first(result.attempts).reason)
        end
        io = IOBuffer()
        write_search_report(io, result)
        report = TOML.parse(String(take!(io)))
        @test haskey(report["attempts"][1], "plan")
        @test !haskey(report["attempts"][1], "certificate")
    end

    processes, directories = Base.Process[], String[]
    command =
        directory -> addenv(
            PRESAGe._polynomial_worker_command(directory; script = fixture),
            "PRESAGE_WORKER_TEST_MODE" => "total",
        )
    result = PRESAGe._search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [0, 1, 2],
            internal_formats = [format],
            job_timeout = 30,
            total_timeout = fixture_timeout,
        );
        worker_command = command,
        process_started = (process, directory) -> begin
            push!(processes, process)
            push!(directories, directory)
        end,
    )
    @test result.status == :search_limit
    @test result.stop_reason == :total_deadline
    @test result.selected === nothing
    @test [a.status for a in result.attempts] == [:bound_exceeds_budget, :timeout]
    @test fixture_timeout <= result.elapsed_seconds < fixture_timeout + 4
    @test length(processes) == 2 # Third choice never launched.
    @test all(process_exited, processes)
    @test all(path -> !isdir(path), directories)
    @test occursin("Total search deadline", last(result.attempts).reason)

    # An already-expired total budget starts no job and still has a valid report.
    empty!(processes)
    result = PRESAGe._search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [1],
            internal_formats = [format],
            total_timeout = 1e-300,
        );
        process_started = (process, directory) -> push!(processes, process),
    )
    @test result.stop_reason == :total_deadline
    @test isempty(result.attempts)
    @test isempty(processes)
    io = IOBuffer()
    write_search_report(io, result)
    @test isempty(TOML.parse(String(take!(io)))["attempts"])

    # A completed proof does not authorize selection if its worker fails to
    # finish within the job limit. Its exact data remains inspectable.
    result = PRESAGe._search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [1],
            internal_formats = [format],
            job_timeout = fixture_timeout,
            total_timeout = 90,
        );
        worker_command = directory -> addenv(
            PRESAGe._polynomial_worker_command(directory; script = fixture),
            "PRESAGE_WORKER_TEST_MODE" => "late_result",
        ),
    )
    @test result.status == :search_limit
    @test result.selected === nothing
    @test result.stop_reason == :choices_exhausted
    @test only(result.attempts).status == :timeout
    @test only(result.attempts).certificate.status == :certified
    io = IOBuffer()
    write_search_report(io, result)
    report = TOML.parse(String(take!(io)))
    @test !haskey(report, "selected_attempt")
    @test report["attempts"][1]["certificate"]["status"] == "certified"

    # Startup is also bounded. A timed-out launch leaves no live process.
    empty!(processes)
    result = PRESAGe._search_polynomial(
        spec,
        PolynomialSearchConfig(
            degrees = [1],
            internal_formats = [format],
            job_timeout = 30,
            total_timeout = 0.05,
        );
        process_started = (process, directory) -> push!(processes, process),
    )
    @test result.stop_reason == :total_deadline
    @test only(result.attempts).status == :timeout
    @test result.elapsed_seconds < 3
    @test all(process_exited, processes)

    # Parent exceptions propagate after worker cleanup, rather than becoming
    # candidate numerical failures.
    empty!(processes)
    empty!(directories)
    @test_throws ErrorException PRESAGe._search_polynomial(
        spec,
        PolynomialSearchConfig(degrees = [1], internal_formats = [format]);
        process_started = (process, directory) -> begin
            push!(processes, process)
            push!(directories, directory)
            error("controlled parent interruption")
        end,
    )
    @test all(process_exited, processes)
    @test all(path -> !isdir(path), directories)
end
