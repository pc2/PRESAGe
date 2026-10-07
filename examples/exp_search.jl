using PRESAGe

destination = isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "exp-search") : only(ARGS)
mkpath(destination)
spec = FunctionSpec(
    "exp(x)";
    input_format = IEEE16,
    domain = (-65504, 5),
    absolute_error = 1 // 8,
)
config = PolynomialSearchConfig(
    degrees = [9],
    internal_formats = [FixedFormat(72, 24)],
    transformation = :exp,
    evaluation = :fma,
    job_timeout = 60,
    total_timeout = 90,
)
write_plan(joinpath(destination, "contract.toml"), PlanArtifact(spec))
write_search_config(joinpath(destination, "search-config.toml"), config)
search = search_polynomial(spec, config)
write_search_report(joinpath(destination, "search.toml"), search)
search.status == :certified || error("Search stopped: $(search.stop_reason)")
result = search.selected
write_plan(joinpath(destination, "plan.toml"), result.plan)
write_certificate(joinpath(destination, "certificate.toml"), result)
emit_cpp(
    joinpath(destination, "evaluator.hpp"),
    result.plan;
    backend = :ac_fixed,
    float_backend = :ac_std_float,
)
emit_harness(joinpath(destination, "evaluate.cpp"), result.plan.program)
println("Certified exp total bound: ", Float64(result.total_bound))
println("Polynomial structure: ", implementation_cost(result.plan))
println("Declared precision: ", precision_cost(result.plan))
