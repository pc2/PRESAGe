using PRESAGe

destination =
    isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "inverse-trig-search") : only(ARGS)
for kind in (:asin, :acos)
    directory = joinpath(destination, string(kind))
    mkpath(directory)
    spec = FunctionSpec(
        "$kind(x)";
        input_format = IEEE16,
        domain = (-1, 1),
        absolute_error = 1 // 512,
    )
    config = PolynomialSearchConfig(
        degrees = [9],
        internal_formats = [FixedFormat(72, 24)],
        transformation = kind,
        evaluation = :fma,
        job_timeout = 60,
        total_timeout = 90,
    )
    write_plan(joinpath(directory, "contract.toml"), PlanArtifact(spec))
    write_search_config(joinpath(directory, "search-config.toml"), config)
    search = search_polynomial(spec, config)
    write_search_report(joinpath(directory, "search.toml"), search)
    search.status == :certified || error("Search stopped: $(search.stop_reason)")
    result = search.selected
    write_plan(joinpath(directory, "plan.toml"), result.plan)
    write_certificate(joinpath(directory, "certificate.toml"), result)
    emit_cpp(
        joinpath(directory, "evaluator.hpp"),
        result.plan;
        backend = :ac_fixed,
        float_backend = :ac_std_float,
    )
    emit_harness(joinpath(directory, "evaluate.cpp"), result.plan.program)
    println("Certified $kind total bound: ", Float64(result.total_bound))
    println("Polynomial structure: ", implementation_cost(result.plan))
    println("Declared precision: ", precision_cost(result.plan))
end
