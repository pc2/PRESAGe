using PRESAGe

destination = isempty(ARGS) ? joinpath(@__DIR__, "..", "build", "memory-sweep") : only(ARGS)
spec = FunctionSpec(
    "exp(x)";
    input_format = FixedFormat(12, 3),
    output_format = FixedFormat(32, 6),
    domain = (-1, 1),
    absolute_error = 1 // 2^18,
)
config = PolynomialSearchConfig(
    degrees = [1, 3],
    segments = [128, 512],
    internal_formats = [FixedFormat(32, 6)],
    job_timeout = 180,
    total_timeout = 360,
)
result = sweep_polynomial(spec, config; max_parallel = 2, max_table_blocks = 5)
write_sweep_artifacts(destination, result)
result.status == :complete || error("Sweep stopped: $(result.stop_reason)")
only(result.selections).status == :selected || error(only(result.selections).reason)
println("512-row memory model: ", only(result.selections).reason)

# Reuse the same coefficients and proofs when exploring another block depth.
tiled = select_sweep(result; memory_model = BlockMemoryModel(depth = 128))
write_sweep_artifacts(joinpath(destination, "depth-128"), tiled)
println("128-row memory model: ", only(tiled.selections).reason)
arithmetic = select_sweep(tiled; max_table_blocks = nothing, objective = :arithmetic)
write_sweep_artifacts(joinpath(destination, "arithmetic"), arithmetic)
println("Arithmetic priority: ", only(arithmetic.selections).reason)
