using PRESAGe

# A fully fixed evaluator; the declared output grid represents this affine
# polynomial exactly for every input word. No generic certificate is emitted.
spec = FunctionSpec("x/2+1/4";
    input_format=FixedFormat(9,4),output_format=FixedFormat(13,5),absolute_error=1//256)
plan = polynomial_plan(spec,[1//4,1//2];internal_format=FixedFormat(24,8))
path = isempty(ARGS) ? joinpath("build","fixed-plan.toml") : only(ARGS)
mkpath(dirname(abspath(path)))
write_plan(path,plan)
println("Wrote fixed polynomial plan to ",path)
