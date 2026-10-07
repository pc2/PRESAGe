using PRESAGe

destination =
    isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "precision-search") : only(ARGS)
mkpath(destination)
spec = read_plan(joinpath(@__DIR__, "exp-contract.toml")).spec
coordinate = FixedFormat(32, 6)
precision = PolynomialPrecision(
    coordinate;
    coefficient_formats = [
        FixedFormat(25, 4),
        FixedFormat(23, 3),
        FixedFormat(22, 2),
        FixedFormat(21, 2),
        FixedFormat(20, 2),
        FixedFormat(19, 2),
    ],
    stage_formats = [
        FixedFormat(29, 4),
        FixedFormat(28, 4),
        FixedFormat(27, 4),
        FixedFormat(26, 4),
        FixedFormat(25, 4),
        FixedFormat(24, 4),
    ],
)
config = PolynomialSearchConfig(
    degrees = [5],
    segments = [4],
    internal_formats = [coordinate],
    precisions = [precision],
    evaluation = :fma,
    job_timeout = 60,
    total_timeout = 120,
)
write_search_config(joinpath(destination, "search-config.toml"), config)
result = search_polynomial(spec, config)
write_search_report(joinpath(destination, "search.toml"), result)
result.status == :certified || error("Search stopped: $(result.stop_reason)")
baseline = certified_polynomial(
    spec;
    degree = 5,
    segments = 4,
    internal_format = coordinate,
    evaluation = :fma,
)
baseline.status == :certified || error(baseline.reason)
println("Common-format cost: ", precision_cost(baseline.plan))
println("Individual-format cost: ", precision_cost(result.selected.plan))
println("Certified total bound: ", Float64(result.selected.total_bound))
write_plan(joinpath(destination, "exp.toml"), result.selected.plan)
write_certificate(joinpath(destination, "certificate.toml"), result.selected)
emit_cpp(joinpath(destination, "evaluator.hpp"), result.selected.plan; backend = :ac_fixed)
emit_harness(joinpath(destination, "evaluate.cpp"), result.selected.plan.program)
