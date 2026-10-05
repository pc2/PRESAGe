module PRESAGe

using Libdl
using TOML
import Sollya

export FloatFormat, FixedFormat, IEEE16, IEEE32, IEEE64, DecodedFloat,
       decode_ieee, round_ieee, round_dyadic, hex_bits,
       FunctionSpec, erf_spec, PlanArtifact, Segment, Dispatch, write_plan, read_plan,
       OracleConfig, ReferenceOracle, ReferenceResult, DyadicBound,
       reference, with_oracle, generate_references, ReferenceFailure,
       IR, evaluate_bits, interpret_trace, EvaluationTrace, emit_cpp, emit_harness,
       polynomial_plan, erf_candidate

include("formats.jl")
include("ir.jl")
include("contracts.jl")
include("schema.jl")
include("ir_schema.jl")
include("oracle.jl")
include("streams.jl")
include("interpreter.jl")
include("cpp.jl")
include("kernels.jl")

end
