using PRESAGe

destination = isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "design-sweep") : only(ARGS)
mkpath(destination)
cache = NumericalCache(joinpath(destination, "cache"))
guards = (0, 3, 6, 8, 10)
spec = FunctionSpec(
    "exp(x)";
    input_format = IEEE16,
    output_format = IEEE32,
    domain = (-1, 1),
    absolute_error = 1 // 2^20,
)

# Regenerate coefficients and coordinates for each degree and guard choice.
formats = [FixedFormat(24 + g, 6) for g in guards]
config = PolynomialSearchConfig(
    degrees = [5, 9],
    internal_formats = formats,
    precisions = [
        PolynomialPrecision(
            f;
            coefficient_formats = fill(f, 10),
            stage_formats = fill(f, 10),
        ) for f in formats
    ],
    evaluation = :fma,
    max_attempts = 10,
    job_timeout = 60,
    total_timeout = 300,
)
regenerated = sweep_polynomial(spec, config; cache, max_parallel = 2)
write_sweep_report(joinpath(destination, "regenerated.toml"), regenerated)
regenerated.status == :complete || error("Sweep stopped: $(regenerated.stop_reason)")
passing =
    [r.attempt.certificate for r in regenerated.rows if r.attempt.status == :certified]
isempty(passing) && error("No passing baseline for the stored-coefficient experiment")
baseline = last(passing)
p = baseline.plan.precision

# Hold degree, segmentation, coordinates and both coefficient payloads/formats
# fixed. The guard count changes only the stage fractional precision.
layouts = [
    PolynomialPrecision(
        p.coordinate_format;
        coefficient_formats = p.coefficient_formats,
        stage_formats = fill(FixedFormat(24 + g, 6), length(p.stage_formats)),
    ) for g in guards
]
frozen_config = PolynomialSearchConfig(
    degrees = [9],
    internal_formats = fill(p.coordinate_format, length(guards)),
    precisions = layouts,
    evaluation = :fma,
    max_attempts = 5,
    job_timeout = 60,
    total_timeout = 180,
)
frozen = sweep_polynomial(baseline.plan, frozen_config; cache, max_parallel = 2)
write_sweep_report(joinpath(destination, "stored.toml"), frozen)
frozen.status == :complete || error("Stored sweep stopped: $(frozen.stop_reason)")

# Adaptive precision reduction is a separate bounded experiment with its own
# fresh certificate and report, using the established precision optimizer.
adaptive =
    optimize_precision(baseline; max_attempts = 4, job_timeout = 60, total_timeout = 180)
write_precision_report(joinpath(destination, "adaptive.toml"), adaptive)
adaptive.status == :certified || error("Adaptive precision search failed")
write_plan(joinpath(destination, "selected-plan.toml"), adaptive.selected.plan)
write_certificate(joinpath(destination, "selected-certificate.toml"), adaptive.selected)
println("Regenerated Pareto rows: ", regenerated.pareto_indices)
println("Stored-coefficient Pareto rows: ", frozen.pareto_indices)
println("Adaptive bound: ", Float64(adaptive.selected.total_bound))
