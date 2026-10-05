using PRESAGe
import Sollya

# Generate actual fixed coefficients, then certify the complete evaluator.
directory = isempty(ARGS) ? joinpath("build", "bounded") : only(ARGS)
mkpath(directory)
for function_name in ("erf", "exp")
    expression = function_name * "(x)"
    coefficients = Sollya.with_session(Sollya.Session(; precision = 256)) do
        f, domain = Sollya.sollya(expression), Sollya.interval(-1, 1)
        try
            polynomial = Sollya.fpminimax(
                f,
                9,
                26,
                domain;
                error = :absolute,
                arithmetic = :fixed,
            )
            try
                Sollya.coefficients(polynomial)
            finally
                close(polynomial)
            end
        finally
            close(f)
            close(domain)
        end
    end
    spec = FunctionSpec(
        expression;
        input_format = FixedFormat(9, 3),
        output_format = FixedFormat(24, 4),
        domain = (-1, 1),
        absolute_error = 1 // (1 << 18),
    )
    plan = polynomial_plan(spec, coefficients; internal_format = FixedFormat(32, 6))
    result = certify_polynomial(plan)
    result.status == :certified || error("$function_name: $(result.reason)")
    write_plan(joinpath(directory, function_name * "-plan.toml"), plan)
    write_certificate(joinpath(directory, function_name * "-certificate.toml"), result)
    println(function_name, " uniform absolute bound: ", Float64(result.total_bound))
end
