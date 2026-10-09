#!/usr/bin/env julia
using PRESAGe

function sweep_main(args)
    length(args) >= 3 || error(
        "Usage: scripts/sweep.jl CONTRACT_OR_PLAN.toml SEARCH.toml OUTPUT_DIR [--implementation=auto|lut|polynomial] [--lut-max-entries=65536] [--cache=DIR] [--max-parallel=N] [--checker=EXEC] [--memory-depth=N] [--memory-word-bits=N] [--max-table-blocks=N] [--resource-model=MODEL.toml] [--max-luts=N] [--max-ffs=N] [--max-dsps=N] [--max-rams=N] [--objective=memory|arithmetic|resources|luts|ffs|dsps|rams]",
    )
    input, settings, destination = args[1:3]
    cache, parallel, checker = nothing, 1, nothing
    depth, word_bits, budget, objective = nothing, nothing, nothing, :memory
    resource_model = nothing
    implementation, lut_max_entries = nothing, 65536
    limits = Dict{Symbol, BigInt}()
    seen = Set{String}()
    for argument in args[4:end]
        parts = split(argument, '='; limit = 2)
        length(parts) == 2 &&
            parts[1] in (
                "--cache",
                "--max-parallel",
                "--checker",
                "--memory-depth",
                "--memory-word-bits",
                "--max-table-blocks",
                "--objective",
                "--resource-model",
                "--max-luts",
                "--max-ffs",
                "--max-dsps",
                "--max-rams",
                "--implementation",
                "--lut-max-entries",
            ) &&
            !(parts[1] in seen) || error("Invalid or duplicate option: $argument")
        push!(seen, parts[1])
        if parts[1] == "--cache"
            isempty(parts[2]) && error("Cache directory must not be empty")
            cache = NumericalCache(parts[2])
        elseif parts[1] == "--max-parallel"
            parallel = parse(Int, parts[2])
        elseif parts[1] == "--checker"
            isempty(parts[2]) && error("Checker path must not be empty")
            checker = parts[2]
        elseif parts[1] == "--memory-depth"
            depth = parse(Int, parts[2])
        elseif parts[1] == "--memory-word-bits"
            word_bits = parse(Int, parts[2])
        elseif parts[1] == "--max-table-blocks"
            budget = parse(BigInt, parts[2])
        elseif parts[1] == "--resource-model"
            resource_model = read_resource_model(parts[2])
        elseif parts[1] == "--implementation"
            implementation = Symbol(parts[2])
            implementation in (:auto, :lut, :polynomial) ||
                error("implementation must be auto, lut or polynomial")
        elseif parts[1] == "--lut-max-entries"
            lut_max_entries = PRESAGe._lut_entry_limit(parse(BigInt, parts[2]))
        elseif startswith(parts[1], "--max-")
            limits[Symbol(parts[1][7:end])] = parse(BigInt, parts[2])
        else
            objective = Symbol(parts[2])
        end
    end
    plan = read_plan(input)
    config = read_search_config(settings)
    memory = resource_model === nothing ? BlockMemoryModel() : resource_model.memory
    implementation === nothing &&
        "--lut-max-entries" in seen &&
        error("lut-max-entries requires implementation selection")
    if !("--objective" in seen) && resource_model !== nothing && implementation !== nothing
        objective = :resources
    end
    sweep = implementation === nothing ? sweep_polynomial : sweep_implementations
    extra =
        implementation === nothing ? (;) :
        (;
            implementations = implementation == :auto ? (:lut, :polynomial) :
                              (implementation,),
            lut_max_entries,
        )
    result = sweep(
        plan.program === nothing ? plan.spec : plan,
        config;
        cache,
        max_parallel = parallel,
        memory_model = BlockMemoryModel(
            depth = depth === nothing ? memory.depth : depth,
            word_bits = word_bits === nothing ? memory.word_bits : word_bits,
        ),
        resource_model,
        resource_budget = ResourceBudget(; limits...),
        max_table_blocks = budget,
        objective,
        extra...,
    )
    observations = checker === nothing ? Dict() : verify_sweep(result; checker)
    write_sweep_artifacts(destination, result; observations)
    passing = count(r -> r.attempt.status == :certified, result.rows)
    hits = count(r -> r.cache_status == :hit, result.rows)
    selected = count(s -> s.status == :selected, result.selections)
    println(
        "Sweep $(result.status): $(length(result.rows)) candidates, $passing certified, $hits cache hits; $(length(result.pareto_indices)) eligible Pareto candidates; $selected/$(length(result.specs)) contracts selected",
    )
    foreach(s -> println("Contract $(s.spec_index): $(s.reason)"), result.selections)
    checked = all(result.rows) do row
        row.attempt.status != :certified ||
            checker === nothing ||
            get(get(observations, row.index, Dict()), "status", "missing") == "passed"
    end
    result.status == :complete && selected == length(result.specs) && checked ? 0 : 1
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(sweep_main(ARGS))
end
