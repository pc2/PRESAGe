const _GENERATION_OUTPUTS = (
    "evaluator.hpp",
    "evaluate.cpp",
    "plan.toml",
    "certificate.toml",
    "search.toml",
    "certificate-failure.toml",
    "search-failure.toml",
    "resources.toml",
    "resource-model.toml",
    "implementations.toml",
    "implementation-failure.toml",
)
# Remove a previously generated companion header when publishing a new bundle.
const _GENERATION_MANAGED = (_GENERATION_OUTPUTS..., "evaluator_support.hpp")

function _generation_text(writer, value)
    io = IOBuffer()
    writer(io, value)
    return String(take!(io))
end

function _generation_search_failure(directory, search; stage = nothing, reason = "")
    data = PRESAGe._search_data(search)
    stage === nothing ||
        (data["generation_failure"] = Dict("stage" => stage, "reason" => reason))
    mkpath(directory)
    mktempdir(directory; prefix = ".presage-report-") do temporary
        path = joinpath(temporary, "report.toml")
        open(io -> TOML.print(io, data; sorted = true), path, "w")
        mv(path, joinpath(directory, "search-failure.toml"); force = true)
    end
    return nothing
end

# Stage all artifacts before changing the existing bundle. Roll back ordinary
# file-operation failures; keep unrelated files in the output directory intact.
function _publish_generation(directory, artifacts; install = mv)
    all(name -> name in _GENERATION_OUTPUTS, keys(artifacts)) ||
        error("unknown generation artifact")
    mkpath(directory)
    mktempdir(directory; prefix = ".presage-publish-") do temporary
        staged, backup = joinpath(temporary, "staged"), joinpath(temporary, "backup")
        mkpath(staged)
        mkpath(backup)
        for (name, content) in artifacts
            write(joinpath(staged, name), content)
        end
        for name in _GENERATION_MANAGED
            isdir(joinpath(directory, name)) &&
                error("artifact destination is a directory: $name")
        end
        saved, installed = String[], String[]
        try
            for name in _GENERATION_MANAGED
                path = joinpath(directory, name)
                if ispath(path) || islink(path)
                    mv(path, joinpath(backup, name))
                    push!(saved, name)
                end
            end
            for name in sort!(collect(keys(artifacts)))
                install(joinpath(staged, name), joinpath(directory, name))
                push!(installed, name)
            end
        catch
            foreach(name -> rm(joinpath(directory, name)), installed)
            foreach(name -> mv(joinpath(backup, name), joinpath(directory, name)), saved)
            rethrow()
        end
    end
    return nothing
end

function _generation_implementation_failure(directory, result; stage = nothing, reason = "")
    mkpath(directory)
    mktempdir(directory; prefix = ".presage-report-") do temporary
        report = joinpath(temporary, "implementations.toml")
        data =
            result isa ImplementationSelection ?
            PRESAGe._implementation_selection_data(result) : PRESAGe._sweep_data(result)
        stage === nothing ||
            (data["generation_failure"] = Dict("stage" => stage, "reason" => reason))
        open(io -> TOML.print(io, data; sorted = true), report, "w")
        mv(report, joinpath(directory, "implementation-failure.toml"); force = true)
    end
    return nothing
end
