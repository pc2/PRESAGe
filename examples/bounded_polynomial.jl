using PRESAGe
# Generate coefficients and certify the complete evaluator in one call.
directory = isempty(ARGS) ? joinpath("build", "bounded") : only(ARGS)
mkpath(directory)
for (function_name, expression) in
    (("erf", "erf(x)"), ("exp", "exp(x)"), ("composed", "exp(x)+0.1*x"))
    spec = FunctionSpec(
        expression;
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(24, 4),
        domain = (-1, 1),
        absolute_error = 1 // (1 << 18),
    )
    result = certified_polynomial(
        spec;
        degree = 9,
        internal_format = FixedFormat(32, 6),
        generation_precision = 256,
        proof_precision = 256,
    )
    result.status == :certified || error("$function_name: $(result.reason)")
    write_plan(joinpath(directory, function_name * "-plan.toml"), result.plan)
    write_certificate(joinpath(directory, function_name * "-certificate.toml"), result)
    println(function_name, " uniform absolute bound: ", Float64(result.total_bound))
end
