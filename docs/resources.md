# Configurable resource estimates

`ResourceModel` estimates LUT/ALUT, FF, DSP and block-memory counts from reachable
IR nodes and ROMs. Numerical certificates remain independent of this model.

## Design objective: resources at II=1

PRESAGe targets evaluators that accept one input per cycle. Resource use is the
selection objective; achieved initiation interval **II=1** is a synthesis
acceptance requirement. Latency and peak clock frequency are secondary.

Polynomial evaluation uses spatial Horner: the IR expands every multiply/add or
FMA stage, with distinct stage formats and operations. A pipeline can therefore
have different inputs in different stages concurrently. The resource model
counts the stage instances; it assumes no arithmetic reuse across Horner stages.
Coefficient columns have independent storage so stages can obtain their needed
coefficients. A full LUT is an alternative under the same II=1 requirement.

Calibration must use this architecture at a declared target clock. The vendor
report must establish II=1 for the complete evaluator, including dispatch,
coordinates, conversions, reconstruction and memory accesses. Any II greater
than one fails the throughput requirement. Pipeline register and alignment costs
remain provisional until those synthesis examples calibrate the FF rules.
Local C++ conformance establishes arithmetic behavior; it cannot establish II.

```julia
using PRESAGe
model = read_resource_model("config/resources/vitis.toml")
estimate = estimate_resources(plan; model)
estimate.totals  # luts, ffs, dsps, rams; unknown estimates are nothing
estimate.known   # subtotal of modeled contributions
write_resource_report("resources.toml", estimate)
```

| Editable profile | Contents |
| --- | --- |
| [generic](../config/resources/generic.toml) | Illustrative fixed arithmetic, integer/control logic and memory assumptions. |
| [vitis](../config/resources/vitis.toml) | Illustrative rules plus the existing generator's single/double floating multiplier, adder and combined FMA costs. |
| [oneAPI](../config/resources/oneapi.toml) | Illustrative fixed/control rules, MLAB-shaped distributed storage and existing single/double floating FMA costs. Separate floating multiplication/addition remain unknown. |

Historical floating constants come from
[ResourceEstimation.hpp](../generator/ResourceEstimation.hpp). Vitis FMA values
sum multiplier and adder measurements. Matching requires the declared floating
precision and nearest-even rounding. Fixed/control costs, DSP operand dimensions
and FF coefficients are placeholders for later calibration. Generic has no
floating arithmetic costs.

## Edit costs and matching scope

Rules are visited in file order. The first matching rule controls the entire node;
an omitted resource remains unknown without falling through. Put specific
overrides before broader rules:

```toml
[[rules]]
operation = "mul"
format = "fixed"
max_width = 64
luts = { constant = 2, result_bits = "1/2" }
ffs = { result_bits = 2 }
dsps = { dsp_tiles = 1 }
rams = 0
```

Each resource is a constant integer or a formula in these features:

| Feature | Value |
| --- | --- |
| `constant` | One. |
| `result_bits` | Declared output width; one for Bool. |
| `operand_bits` | Sum of referenced widths, including control/index operands. |
| `max_operand_bits` | Largest referenced width, or zero. |
| `operand_product` | Product of the first two Mul/FMA operand widths; zero otherwise. |
| `dsp_tiles` | Rectangular tiling of those two operands; zero otherwise. |

Sum nonnegative coefficients times features exactly, then round up once per
node/resource. Use integers or rational strings such as `"1/3"`; decimal TOML
floats are rejected. Large integers round-trip as decimal strings. DSP tiling
uses `[dsp].operand_bits`, trying both orientations. It does not model signed
packing, truncation, cascade modes or constant multiplication optimizations.

`format` is `fixed`, `uint`, `bool`, `float`, `mixed` or `any`. Float rules can
restrict both `exponent_bits` and `fraction_bits`; every involved data format
must match. Optional `rounding` and `max_width` further restrict scope.
Operations cover arithmetic, conversions, comparisons, muxes, classification,
bits, normalization, reciprocal and exponent reconstruction; see `ResourceRule`.
Initial profiles leave unsupported transformations and mixed conversions unknown.

The model assumes one spatial instance per reachable IR node. Shared nodes
count once, unreachable nodes are omitted and separate branch nodes are summed.
The intended schedule is a spatial Horner pipeline at II=1. The model does not
predict compiler sharing, actual pipeline registers, placement or constant
folding. Register coefficients are explicit assumptions. Complete
coverage means every count has a rule; it does not establish synthesis accuracy.

## Memory policy and generated hints

`[memory]` sets block depth/width and `policy="block"`, `"distributed"` or
`"auto"`. Auto uses distributed ROM when padded table bits are at most
`distributed_max_bits`. Center/coefficient columns and cyclic banks are independent.

Block allocation follows the [existing model](kernels.md#coefficient-memory-layout).
Distributed allocation is
`banks * bitceil(ceil(rows/distributed_depth)) * ceil(width/distributed_word_bits) * distributed_luts`.
Vitis/generic assume 64 rows of one bit per one-LUT unit. oneAPI assumes
32 rows of 16 bits per 20-ALUT unit. These dimensions and the illustrative auto
threshold are editable.

`emit_kernel(...; resource_model=model)` applies the same table choices to
guarded Vitis `bind_storage` or oneAPI `fpga_memory` hints. An incompatible
explicit model/toolchain pair is rejected before output. Generic emission allows
public-header compilation. Hints request storage; synthesis establishes inference.

```sh
julia --startup-file=no --project=. scripts/generate.jl plan.toml build/kernel \
  --target=kernel --backend=ap_fixed --toolchain=vitis \
  --resource-model=config/resources/vitis.toml
```

Generation adds `resources.toml` and `resource-model.toml`. CMake accepts
`-DPRESAGE_RESOURCE_MODEL=/absolute/path/to/model.toml` and tracks that dependency.

## Sweep limits and ranking

```julia
result = sweep_polynomial(spec, config;
    resource_model=model,
    resource_budget=ResourceBudget(luts=5000, ffs=8000, dsps=40, rams=8),
    objective=:resources)
write_sweep_artifacts("build/sweep", result)
```

Unset limits impose no constraint; zero is a real limit. Estimates required by
limits or ranking must be known. Rejected rows retain numerical certificates
and eligibility reasons. Missing selection reports `resource_budget_exceeded`
or `resource_model_incomplete`, as appropriate.

`:resources` follows the profile's `priority` lexicographically, for example
`["luts", "rams", "dsps", "ffs"]`; a shorter list is allowed. `:luts`, `:ffs`,
`:dsps` and `:rams` minimize that resource before structural/error tie breakers.
Memory/arithmetic priorities remain available. All four resources also enter
Pareto comparison; unknown counts prevent a row from establishing dominance.

`max_table_blocks` counts hypothetical allocation with every table in block
memory. `ResourceBudget(rams=...)` counts tables actually assigned block storage
plus RAM costs in node rules. Use the latter for storage-policy comparisons.
New sweeps default to the profile's block dimensions; explicit options override
them. Reselection retains existing dimensions unless `memory_model` is supplied.

```sh
julia --startup-file=no --project=. scripts/sweep.jl contract.toml search.toml build/sweep \
  --resource-model=config/resources/vitis.toml --objective=resources \
  --max-luts=5000 --max-ffs=8000 --max-dsps=40 --max-rams=8
```

`select_sweep` changes profiles/budgets/priorities without numerical workers or
new proofs. Settings are excluded from numerical cache keys. Resource-aware
reports use sweep schema v4, embedding profile rules, node coverage, allocations,
unknown totals and known subtotals. Selected directories also contain matching
`resources.toml` and `resource-model.toml`.

## Small examples for CI calibration

Generate six certified examples with fixed widths 16/32/64, separate/fused
arithmetic, 128/512-row tables and 17/33/65/9-bit coefficient columns:

```sh
julia --startup-file=no --project=. scripts/resource_examples.jl \
  config/resources/vitis.toml build/resource-examples
```

The table examples approximate `1/(2-x)` and `sin(256*x)` with varying
coefficients. Their columns contain nonzero data and multiple values, so they
exercise ROM storage rather than constant/zero tables.

oneAPI defaults to AC. `--include-float=true` also generates single/double FMA
examples with AC and generic/oneAPI emission. AP kernels currently support fixed
arithmetic. Each example contains a certified plan, profile, estimate, header,
host runner and `kernel.cpp` with callable top `presage_resource_kernel`.
`examples.toml` lists their paths. Vitis tops request II=1; synthesis must confirm
it for acceptance. oneAPI integration must request and check II=1 in the FPGA evaluation loop that calls
the top. All accepted calibration counts must come from configurations meeting
this requirement at their declared target clock.

A later vendor CI job should generate examples, compile/simulate/synthesize each
top with declared target/clock settings, then normalize resource reports:

```toml
schema = "presage-resource-measurements"
schema_version = 1
# Replace illustrative counts with actual synthesis results.
[[examples]]
name = "fixed-16-separate"
luts = 123
ffs = 234
dsps = 3
rams = 0
# Include every generated example.
```

Use profile units, including BRAM18K versus BRAM36K and ALUT versus ALM.
Retain the original synthesis reports with the comparison:

```sh
julia --startup-file=no --project=. scripts/check_resources.jl \
  build/resource-examples/examples.toml measured.toml comparison.toml \
  --tolerances=config/resources/tolerances.toml
```

Allowed difference is `absolute + relative * measured`, independently configured
per resource. Initial tolerances allow 50% plus five LUTs/FFs and exact DSP/RAM
counts; calibrate them for the chosen mapping. Missing measurements and unknown
predictions stay unresolved. Exit codes: zero passed, one failed, two unresolved.
Duplicate/unknown names and mismatched optional model/backend/toolchain labels
are rejected.

Local tests use explicitly synthetic counts to check the protocol, and public
AP/AC headers to check numerical conformance. Actual resource accuracy remains
pending vendor synthesis and CI calibration.

## Select between evaluator backends

[General backend selection](implementations.md) applies this same model to full
LUTs and polynomial candidates. `sweep_implementations` generates both; the
certificate-list overload of `select_implementation` compares existing proof
results. ROM policies, limits, unknown estimates and priorities are shared with
polynomial sweep selection. Ordinary compilation verifies numerical semantics;
actual backend performance remains a synthesis calibration task.
