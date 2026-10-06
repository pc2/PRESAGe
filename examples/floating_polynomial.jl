using PRESAGe
import Sollya

directory = isempty(ARGS) ? joinpath("build", "floating-polynomial") : only(ARGS)
mkpath(directory)
for function_name in ("erf", "exp")
    expression = function_name * "(x)"
    coefficients = Sollya.with_session(Sollya.Session(; precision = 256)) do
        f, domain = Sollya.sollya(expression), Sollya.interval(-1, 1)
        try
            polynomial = Sollya.fpminimax(
                f,
                13,
                32,
                domain;
                error = :absolute,
                arithmetic = :floating,
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
        input_format = IEEE32,
        domain = (-1, 1),
        absolute_error = 1 // (1 << 21),
    )
    for (name, internal_format) in (
        ("fixed", FixedFormat(36, 6)),
        ("float", FloatFormat(8, 27)), # Four extra fraction bits.
    )
        plan = polynomial_plan(spec, coefficients; internal_format, evaluation = :fma)
        result = certify_polynomial(plan)
        result.status == :certified || error("$function_name/$name: $(result.reason)")
        prefix = joinpath(directory, function_name * "-" * name)
        write_plan(prefix * "-plan.toml", plan)
        write_certificate(prefix * "-certificate.toml", result)
        println(function_name, " (", name, ") uniform bound: ", Float64(result.total_bound))
    end
end
