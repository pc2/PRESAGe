# LUT and polynomial selection

`certified_lut` supports small fixed and custom floating inputs, any supported
fixed/floating output format, and expressions handled by the reference oracle.
`sweep_implementations` compares LUTs with every configured polynomial candidate.
Both use the same resource profile, budgets, priorities and Pareto comparison.

## Generate and compare

```julia
using PRESAGe
spec = FunctionSpec("sin(x)";
    input_format=FixedFormat(10, 3), output_format=FixedFormat(18, 3),
    domain=(-1, 1), absolute_error=1//256)
config = PolynomialSearchConfig(
    degrees=(3, 5), segments=(1, 4),
    internal_formats=(FixedFormat(24, 4),),
    max_attempts=16, total_timeout=120)
model = read_resource_model("config/resources/vitis.toml")
result = sweep_implementations(spec, config;
    resource_model=model, objective=:rams, max_parallel=2)
write_sweep_artifacts("build/sin-selection", result)
```

Contracts can be supplied individually or as a list. Each contract gets one
selected evaluator. Existing artifact publication and C++ replay work for both
backends. `select_sweep` changes budgets or priorities without repeating proofs.
`implementations=(:lut,)` or `(:polynomial,)` restricts candidate generation.
The existing `sweep_polynomial` API retains its polynomial-only behavior.

For already certified candidates, including canonical all-finite erf kernels:

```julia
lut = certified_lut(spec)
polynomial = certified_polynomial(spec;
    degree=5, internal_format=FixedFormat(24, 4))
choice = select_implementation((lut, polynomial);
    resource_model=model, objective=:rams,
    resource_budget=ResourceBudget(dsps=8))
write_implementation_report("build/choice.toml", choice)
# choice.selected is a CertificationResult or nothing.
```

Selection first requires a numerical certificate meeting the exact contract.
Candidates must share the expression, domain, formats and error target.
Required unknown resource estimates cannot satisfy a budget or ranking objective.
An explicit backend override also obeys numerical and resource requirements.
Exact ties use candidate order. Without a profile, selection defaults to modeled
memory blocks. Profile priorities are estimates pending synthesis calibration;
there is no latency or throughput prediction.

## CLI

```sh
julia --startup-file=no --project=. scripts/sweep.jl \
  contract.toml search.toml build/designs \
  --implementation=auto --resource-model=config/resources/vitis.toml \
  --max-rams=8 --max-parallel=2

julia --startup-file=no --project=. scripts/generate.jl \
  contract.toml build/evaluator --search-config=search.toml \
  --implementation=auto --resource-model=config/resources/vitis.toml \
  --target=kernel --backend=ap_fixed --toolchain=vitis

# A LUT contract needs no polynomial search configuration.
julia --startup-file=no --project=. scripts/generate.jl \
  contract.toml build/lut --implementation=lut
```

Generation with a search configuration and resource profile compares both
backends by default. Polynomial settings stay in `search.toml`. Generation
writes `implementations.toml` with candidate certificates, costs and reasons.
A selection failure writes `implementation-failure.toml`, preserving a previously
published evaluator. Successful publication removes stale managed reports.

The fixed `erf` shortcut also compares certified LUT/polynomial candidates when a
resource profile or selection objective/budget is supplied. Without those
settings its lightweight `ImplementationModel(lut_max_bits=...)` storage policy
remains available. That policy selects a backend before numerical generation;
resource selection compares actual certified programs afterward.

## LUT limits and semantics

A full LUT has `2^input_bits` entries indexed by the raw input encoding. It does
not compress entries outside a bounded domain. Output width sets each stored
word's width, independently of input width. ROM allocation and emission use the
same block/distributed-memory policy as coefficient tables.

`lut_max_entries=65536` in sweeps and `max_entries=65536` in `certified_lut` are
explicit generation limits, checked before allocation. They allow up to 16 input
bits by default; this is a practical enumeration limit rather than an arithmetic
precision restriction. Change it with `--lut-max-entries=N`. Wider inputs skip
LUT generation and retain polynomial candidates; availability and its reason are
recorded. `certify_plan` can recertify a stored table larger than this default,
using its declared entry count after loading it.

Every covered finite input must have a resolved reference and finite output.
MPFR handles primitives; Sollya handles compositions and exact rational
polynomials. Fixed output rounding, saturation and wrapping are included in the
exhaustive absolute error bound. Unresolved references, mathematical domain
errors and poles inside the finite contract prevent certification.

Bounded LUTs use the same exact representable-domain guards as polynomials:
floating outputs return canonical NaN outside the finite contract, while fixed
outputs reject. Fixed outputs reject nonfinite inputs. Unbounded floating LUTs
store established primitive special values, including signed zeros and canonical
NaNs. Recertification audits all entries, deterministic inactive placeholders,
output format, complete raw-index graph and guards.

LUTs and polynomials share worker deadlines, concurrency and attempt limits.
Default candidate order is LUT followed by the polynomial Cartesian product for
each contract; a limited sweep selects only among examined candidates and reports
its incomplete status. LUT proofs currently bypass the polynomial numerical cache.
General sweeps use report version 5, with an implementation tag on every row and
per-contract LUT availability. Polynomial-only reports remain versions 3/4.
