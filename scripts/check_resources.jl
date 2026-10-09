#!/usr/bin/env julia
using PRESAGe
using TOML

function check_resources_main(args)
    length(args) in (3, 4) || error(
        "Usage: scripts/check_resources.jl EXAMPLES.toml MEASURED.toml REPORT.toml [--tolerances=FILE.toml]",
    )
    manifest, actual = TOML.parsefile(args[1]), TOML.parsefile(args[2])
    get(manifest, "schema", nothing) == "presage-resource-examples" &&
        get(manifest, "schema_version", nothing) isa Integer &&
        !(manifest["schema_version"] isa Bool) &&
        manifest["schema_version"] == 1 || error("invalid example manifest")
    PRESAGe._resource_keys(
        actual,
        ("schema", "schema_version", "model", "backend", "toolchain", "examples"),
        "measurements",
    )
    get(actual, "schema", nothing) == "presage-resource-measurements" &&
        get(actual, "schema_version", nothing) isa Integer &&
        !(actual["schema_version"] isa Bool) &&
        actual["schema_version"] == 1 || error("invalid measurement schema")
    for name in ("model", "backend", "toolchain")
        haskey(actual, name) &&
            actual[name] != manifest[name] &&
            error("measurement $name does not match examples")
    end
    tolerance_path =
        length(args) == 3 ?
        joinpath(@__DIR__, "..", "config", "resources", "tolerances.toml") :
        begin
            startswith(args[4], "--tolerances=") || error("expected --tolerances")
            split(args[4], '='; limit = 2)[2]
        end
    tolerances = TOML.parsefile(tolerance_path)
    PRESAGe._resource_keys(tolerances, string.(PRESAGe._RESOURCE_NAMES), "tolerances")
    absolute, relative = Dict{Symbol, BigInt}(), Dict{Symbol, Rational{BigInt}}()
    for name in PRESAGe._RESOURCE_NAMES
        rule = get(tolerances, string(name), Dict())
        PRESAGe._resource_keys(rule, ("absolute", "relative"), "tolerance")
        absolute[name] = PRESAGe._resource_integer(
            PRESAGe._resource_exact_integer(get(rule, "absolute", 0)),
            "absolute tolerance",
        )
        relative[name] = PRESAGe._q(PRESAGe._resource_exact(get(rule, "relative", 0)))
    end
    rows = get(actual, "examples", [])
    names = [row["name"] for row in rows]
    length(unique(names)) == length(names) || error("duplicate measurement name")
    examples = manifest["examples"]
    examples isa AbstractVector && !isempty(examples) ||
        error("example manifest must contain examples")
    example_names = [example["name"] for example in examples]
    length(unique(example_names)) == length(example_names) ||
        error("duplicate example name")
    all(name -> name in [example["name"] for example in examples], names) || error("unknown measurement name")
    reports = map(examples) do example
        row = get(Dict(row["name"] => row for row in rows), example["name"], Dict())
        PRESAGe._resource_keys(
            row,
            ("name", string.(PRESAGe._RESOURCE_NAMES)...),
            "measurement",
        )
        measured = ResourceBudget(;
            (
                name =>
                    haskey(row, string(name)) ?
                    PRESAGe._resource_exact_integer(row[string(name)]) : nothing for
                name in PRESAGe._RESOURCE_NAMES
            )...,
        )
        estimate = TOML.parsefile(joinpath(dirname(args[1]), example["resources"]))
        get(estimate, "schema", nothing) == "presage-resource-estimate" &&
            get(estimate, "schema_version", nothing) === 1 ||
            error("invalid estimate schema")
        report = compare_resources(
            estimate,
            measured;
            absolute = ResourceBudget(; absolute...),
            relative = (; relative...),
        )
        report["name"] = example["name"]
        report
    end
    statuses = [report["status"] for report in reports]
    status =
        "failed" in statuses ? "failed" : "unresolved" in statuses ? "unresolved" : "passed"
    output = Dict(
        "schema" => "presage-resource-suite",
        "schema_version" => 1,
        "status" => status,
        "examples" => reports,
    )
    mkpath(dirname(abspath(args[3])))
    open(io -> TOML.print(io, output; sorted = true), args[3], "w")
    println("Resource comparison $status: $(length(reports)) examples")
    return status == "passed" ? 0 : status == "failed" ? 1 : 2
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(check_resources_main(ARGS))
end
