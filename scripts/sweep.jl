#!/usr/bin/env julia
using PRESAGe

function sweep_main(args)
    length(args) >= 3 || error(
        "Usage: scripts/sweep.jl CONTRACT_OR_PLAN.toml SEARCH.toml OUTPUT_DIR [--cache=DIR] [--max-parallel=N] [--checker=EXEC]",
    )
    input, settings, destination = args[1:3]
    cache, parallel, checker = nothing, 1, nothing
    seen = Set{String}()
    for argument in args[4:end]
        parts = split(argument, '='; limit = 2)
        length(parts) == 2 &&
            parts[1] in ("--cache", "--max-parallel", "--checker") &&
            !(parts[1] in seen) || error("Invalid or duplicate option: $argument")
        push!(seen, parts[1])
        if parts[1] == "--cache"
            isempty(parts[2]) && error("Cache directory must not be empty")
            cache = NumericalCache(parts[2])
        elseif parts[1] == "--max-parallel"
            parallel = parse(Int, parts[2])
        else
            isempty(parts[2]) && error("Checker path must not be empty")
            checker = parts[2]
        end
    end
    plan = read_plan(input)
    config = read_search_config(settings)
    result = sweep_polynomial(
        plan.program === nothing ? plan.spec : plan,
        config;
        cache,
        max_parallel = parallel,
    )
    observations = checker === nothing ? Dict() : verify_sweep(result; checker)
    mkpath(destination)
    mktempdir(destination; prefix = ".presage-sweep-") do temporary
        path = joinpath(temporary, "sweep.toml")
        write_sweep_report(path, result; observations)
        Base.Filesystem.rename(path, joinpath(destination, "sweep.toml"))
    end
    passing = count(r -> r.attempt.status == :certified, result.rows)
    hits = count(r -> r.cache_status == :hit, result.rows)
    println(
        "Sweep $(result.status): $(length(result.rows)) candidates, $passing certified, $hits cache hits; $(length(result.pareto_indices)) structural Pareto candidates",
    )
    checked = all(result.rows) do row
        row.attempt.status != :certified ||
            checker === nothing ||
            get(get(observations, row.index, Dict()), "status", "missing") == "passed"
    end
    result.status == :complete && checked ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(sweep_main(ARGS))
end
