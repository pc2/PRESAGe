module PRESAGe

using Libdl
using TOML
import Sollya

export FloatFormat,
    FixedFormat,
    IEEE16,
    IEEE32,
    IEEE64,
    IEEE128,
    IEEE256,
    DecodedFloat,
    decode_ieee,
    round_ieee,
    round_dyadic,
    decode_fixed,
    round_fixed,
    hex_bits,
    FunctionSpec,
    erf_spec,
    PlanArtifact,
    Segment,
    Dispatch,
    write_plan,
    read_plan,
    OracleConfig,
    ReferenceOracle,
    ReferenceResult,
    DyadicBound,
    reference,
    with_oracle,
    generate_references,
    ReferenceFailure,
    IR,
    evaluate_bits,
    interpret_trace,
    EvaluationTrace,
    emit_cpp,
    emit_harness,
    polynomial_plan,
    certified_polynomial,
    erf_candidate,
    erf_fixed_candidate,
    CertificationResult,
    PathCertificate,
    FixedNodeBound,
    FloatNodeBound,
    certify_polynomial,
    certify_plan,
    certify_erf,
    certified_erf,
    certified_lut,
    certify_lut,
    ImplementationModel,
    select_implementation,
    implementation_cost,
    write_certificate

include("formats.jl")
include("fixed.jl")
include("ir.jl")
include("contracts.jl")
include("schema.jl")
include("ir_schema.jl")
include("oracle.jl")
include("streams.jl")
include("interpreter.jl")
include("cpp_fixed.jl")
include("cpp_vendor.jl")
include("cpp.jl")
include("cpp_ac_float.jl")
include("kernels.jl")
include("fixed_kernels.jl")
include("costs.jl")
include("certificates.jl")
include("lut.jl")
include("polynomial_certificates.jl")
include("planning.jl")

end
