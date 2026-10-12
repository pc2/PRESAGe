@testset "Search configuration artifacts" begin
    for formats in (
        (IEEE32, FloatFormat(8, 27)),
        (FixedFormat(16, 6), FixedFormat(32, 6)),
        (FixedFormat(140, 6; signed = false), FloatFormat(19, 300), IEEE256),
    )
        config = PolynomialSearchConfig(
            degrees = [9, 1, 0],
            internal_formats = formats,
            evaluation = :fma,
            generation_precision = 1024,
            proof_precision = 768,
            accuracy = 3 // (big(1) << 400),
            max_refinements = 5,
            max_attempts = 7,
            job_timeout = 1.25,
            total_timeout = 11.5,
        )
        io = IOBuffer()
        write_search_config(io, config)
        text = String(take!(io))
        decoded = read_search_config(IOBuffer(text))
        @test all(
            key -> getfield(decoded, key) == getfield(config, key),
            fieldnames(PolynomialSearchConfig),
        )
        mktempdir() do directory
            path = joinpath(directory, "search.toml")
            write_search_config(path, config)
            @test read_search_config(path).internal_formats == config.internal_formats
            @test read(path, String) == text
        end
    end
    io = IOBuffer()
    write_search_config(
        io,
        PolynomialSearchConfig(
            evaluation = :separate,
            degrees = [1, 9],
            internal_formats = [IEEE32],
        ),
    )
    data = TOML.parse(String(take!(io)))
    minimal = deepcopy(data)
    foreach(key -> delete!(minimal, key), ("order", "settings", "limits"))
    @test PRESAGe._read_search_config(minimal).degrees == (1, 9)
    @test PRESAGe._read_search_config(minimal).max_attempts == 64
    @test PRESAGe._read_search_config(minimal).accuracy == 1 // 1024
    for (key, value) in (
        ("schema", "presage-search"),
        ("schema_version", 2),
        ("schema_version", true),
        ("order", "format_then_degree"),
        ("degrees", "1,9"),
        ("degrees", [1, 1]),
        ("internal_formats", "binary32"),
        ("internal_formats", []),
        ("internal_formats", [Dict("wrong" => "binary32")]),
        ("internal_formats", [Dict("format" => "binary17")]),
        ("extra", 1),
    )
        invalid = deepcopy(data)
        invalid[key] = value
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
    end
    for key in ("degrees", "internal_formats")
        invalid = deepcopy(data)
        delete!(invalid, key)
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
    end
    for (section, key, value) in (
        ("settings", "proof_precision", "256"),
        ("settings", "evaluation", 1),
        ("settings", "norm_accuracy", 0.001),
        ("settings", "max_refinements", 9),
        ("settings", "typo", 1),
        ("limits", "max_attempts", 0),
        ("limits", "job_timeout_seconds", Inf),
        ("limits", "total_timeout_seconds", "60"),
        ("limits", "typo", 1),
    )
        invalid = deepcopy(data)
        invalid[section][key] = value
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
    end
    for section in ("settings", "limits")
        invalid = deepcopy(data)
        invalid[section] = []
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
    end
    fixed = PRESAGe._format_data(FixedFormat(32, 6))
    for format in (
        merge(fixed, Dict("width" => "32")),
        merge(fixed, Dict("typo" => 1)),
        Dict("kind" => "fixed"),
    )
        invalid = deepcopy(data)
        invalid["internal_formats"] = [Dict("format" => format)]
        @test_throws ArgumentError PRESAGe._read_search_config(invalid)
    end
end
