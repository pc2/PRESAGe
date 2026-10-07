using PRESAGe

destination = isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "odd-search") : only(ARGS)
mkpath(destination)
spec = FunctionSpec(
    "sin(x)";
    input_format = FixedFormat(9, 3),
    output_format = FixedFormat(24, 4),
    domain = (-1, 1),
    absolute_error = 1 // 2^18,
)
config = PolynomialSearchConfig(
    degrees = [3, 9],
    internal_formats = [FixedFormat(32, 6)],
    transformation = :odd,
    evaluation = :fma,
    job_timeout = 60,
    total_timeout = 120,
)
write_plan(joinpath(destination, "contract.toml"), PlanArtifact(spec))
write_search_config(joinpath(destination, "search-config.toml"), config)
search = search_polynomial(spec, config)
write_search_report(joinpath(destination, "search.toml"), search)
search.status == :certified || error("Search stopped: $(search.stop_reason)")
result = search.selected
write_plan(joinpath(destination, "plan.toml"), result.plan)
write_certificate(joinpath(destination, "certificate.toml"), result)
emit_cpp(joinpath(destination, "evaluator.hpp"), result.plan; backend = :ac_fixed)
emit_harness(joinpath(destination, "evaluate.cpp"), result.plan.program)
println("Certified total bound: ", Float64(result.total_bound))
println("Polynomial structure: ", implementation_cost(result.plan))
println("Declared precision: ", precision_cost(result.plan))
