"""
    write_sweep_artifacts(directory, result; observations=Dict())

Publish `sweep.toml` and each selected contract's exact `selected/N/plan.toml`
and `certificate.toml`. Stage the complete bundle and roll back ordinary file
operation failures. The report and `selected/` directory are managed outputs:
replace them on every run, removing stale selections while preserving unrelated
files in `directory`. An incomplete sweep can export its best examined designs;
its limit status remains explicit in the report.
"""
write_sweep_artifacts(
    directory::AbstractString,
    result::PolynomialSweepResult;
    observations = Dict(),
) = _write_sweep_artifacts(directory, result; observations)

function _write_sweep_artifacts(directory, result; observations = Dict(), install = mv)
    report = sprint(io -> write_sweep_report(io, result; observations))
    mkpath(directory)
    mktempdir(directory; prefix = ".presage-sweep-") do temporary
        staged, backup = joinpath(temporary, "staged"), joinpath(temporary, "backup")
        mkpath(joinpath(staged, "selected"))
        mkpath(backup)
        write(joinpath(staged, "sweep.toml"), report)
        for selection in result.selections
            selection.status == :selected || continue
            row = only(
                r for r in result.rows if
                r.index == selection.row_index && r.spec_index == selection.spec_index
            )
            paths = _sweep_selection_paths(selection)
            mkpath(dirname(joinpath(staged, paths.plan)))
            write_plan(joinpath(staged, paths.plan), row.attempt.plan)
            write_certificate(joinpath(staged, paths.certificate), row.attempt.certificate)
            if result.resource_model !== nothing
                root = dirname(joinpath(staged, paths.plan))
                write_resource_report(
                    joinpath(root, "resources.toml"),
                    estimate_resources(
                        row.attempt.plan;
                        model = result.resource_model,
                        memory_model = result.memory_model,
                    ),
                )
                model_data = _resource_model_data(result.resource_model)
                model_data["memory"]["depth"] = result.memory_model.depth
                model_data["memory"]["word_bits"] = result.memory_model.word_bits
                open(
                    io -> TOML.print(io, model_data; sorted = true),
                    joinpath(root, "resource-model.toml"),
                    "w",
                )
            end
        end
        managed = ("sweep.toml", "selected")
        isdir(joinpath(directory, "sweep.toml")) &&
            throw(ArgumentError("sweep report destination is a directory"))
        selected = joinpath(directory, "selected")
        (ispath(selected) || islink(selected)) &&
            (!isdir(selected) || islink(selected)) &&
            throw(ArgumentError("selected destination must be a managed directory"))
        saved, installed = String[], String[]
        try
            for name in managed
                path = joinpath(directory, name)
                if ispath(path) || islink(path)
                    mv(path, joinpath(backup, name))
                    push!(saved, name)
                end
            end
            for name in managed
                install(joinpath(staged, name), joinpath(directory, name))
                push!(installed, name)
            end
        catch
            foreach(name -> rm(joinpath(directory, name); recursive = true), installed)
            foreach(name -> mv(joinpath(backup, name), joinpath(directory, name)), saved)
            rethrow()
        end
    end
    return nothing
end
