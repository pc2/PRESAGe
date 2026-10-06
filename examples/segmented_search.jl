using PRESAGe

destination =
    isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "segmented-search") : only(ARGS)
mkpath(destination)
spec = read_plan(joinpath(@__DIR__, "exp-contract.toml")).spec
config = read_search_config(joinpath(@__DIR__, "segmented-search.toml"))
result = search_polynomial(spec, config)
write_search_report(joinpath(destination, "search.toml"), result)
for attempt in result.attempts
    println("segments=$(attempt.segments), degree=$(attempt.degree): $(attempt.status)")
end
result.status == :certified || error("Search stopped: $(result.stop_reason)")
write_plan(joinpath(destination, "exp.toml"), result.selected.plan)
write_certificate(joinpath(destination, "certificate.toml"), result.selected)
println("Certified total bound: ", Float64(result.selected.total_bound))
