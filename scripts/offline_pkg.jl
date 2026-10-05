# Julia 1.10's public Pkg entry points fetch a default registry in an empty
# depot even with Pkg.offline(true). A temporary empty local registry prevents
# that fetch. All dependencies here are stdlibs or an explicit development path.
# Keep this depot temporary so the user's registries are never changed.
using Pkg
function with_offline_pkg(f)
    original = copy(DEPOT_PATH)
    mktempdir() do depot
        registry = joinpath(depot, "registries", "PRESAGeOffline")
        mkpath(registry)
        write(joinpath(registry, "Registry.toml"), """
            name = "PRESAGeOffline"
            uuid = "b37830c6-dca1-4a44-b164-a26dfd3e7fbd"
            repo = ""
            description = "Temporary registry for local PRESAGe development"
            [packages]
            """)
        pushfirst!(DEPOT_PATH, depot)
        try
            Pkg.offline(true)
            return f()
        finally
            empty!(DEPOT_PATH)
            append!(DEPOT_PATH, original)
        end
    end
end
