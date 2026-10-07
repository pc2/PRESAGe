using PRESAGe

destination = isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "root-search") : only(ARGS)
for transformation in (:sqrt, :rsqrt)
    directory = joinpath(destination, string(transformation))
    mkpath(directory)
    spec = FunctionSpec(
        transformation == :sqrt ? "sqrt(x)" : "1/sqrt(x)";
        input_format = IEEE16,
        domain = (0, 65504),
        absolute_error = transformation == :sqrt ? 1 // 4 : 4,
    )
    config = PolynomialSearchConfig(
        degrees = [11],
        internal_formats = [FixedFormat(80, 24)],
        transformation = transformation,
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
    println(transformation, " certified total bound: ", Float64(result.total_bound))
    println("Polynomial structure: ", implementation_cost(result.plan))
end
