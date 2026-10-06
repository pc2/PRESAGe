using PRESAGe

destination =
    isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "bounded-search") : only(ARGS)
mkpath(destination)

spec = FunctionSpec(
    "exp(x)";
    input_format = FixedFormat(9, 3),
    output_format = FixedFormat(24, 4),
    domain = (-1, 1),
    absolute_error = 1 // (1 << 18),
)
config = PolynomialSearchConfig(
    degrees = [1, 9],
    internal_formats = [FixedFormat(16, 6), FixedFormat(32, 6)],
    max_attempts = 4,
    job_timeout = 60,
    total_timeout = 300,
)
result = search_polynomial(spec, config)
write_search_report(joinpath(destination, "search.toml"), result)
for attempt in result.attempts
    println(
        "degree=$(attempt.degree), format=$(attempt.internal_format): $(attempt.status)",
    )
end
result.status == :certified || error("Search stopped: $(result.stop_reason)")
write_plan(joinpath(destination, "exp.toml"), result.selected.plan)
write_certificate(joinpath(destination, "certificate.toml"), result.selected)
println("Certified total bound: ", Float64(result.selected.total_bound))
