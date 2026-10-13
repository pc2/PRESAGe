# Configurable resource estimates

`ResourceModel` estimates LUT or ALUT, FF, DSP equivalents, block RAM and MLAB counts from reachable IR nodes and ROMs.
Numerical certificates remain independent of this model.

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

Calibration uses this architecture with clock selection left to the vendor tools.
The vendor report must establish II equal to one for the complete evaluator, including dispatch, coordinates, conversions, reconstruction and memory accesses.
Any II greater than one fails the throughput requirement.
Pipeline register and alignment costs remain provisional until synthesis calibrates the FF rules.
Local C++ conformance establishes arithmetic behavior, it cannot establish II.

```julia
using PRESAGe
model = read_resource_model("config/resources/vitis.toml")
estimate = estimate_resources(plan; model)
estimate.totals  # Unknown estimates are nothing.
estimate.known   # Known contributions remain available.
write_resource_report("resources.toml", estimate)
```

| Editable profile | Contents |
| --- | --- |
| [generic](../config/resources/generic.toml) | Illustrative fixed arithmetic, integer/control logic and memory assumptions. |
| [vitis](../config/resources/vitis.toml) | Illustrative fixed and control rules, floating arithmetic requires calibration. |
| [oneAPI](../config/resources/oneapi.toml) | Illustrative fixed and control rules with native integer ROM storage. Floating arithmetic requires calibration. |

The measured [U280 profile](../config/resources/vitis-u280-2023.2.toml) and [Stratix 10 profile](../config/resources/oneapi-stratix10-2025.0.toml) contain experimental primitive calibration rules.
Their companion evidence files record the synthesis and emulation inputs.
Whole evaluator accuracy remains incomplete, these profiles do not establish reliable resource limits for arbitrary compositions.

The Stratix 10 profile includes 32 distinct measured arithmetic patterns with passing FPGA emulation.
Independent Horner validation uses coefficients equal to `1/3` with highest coefficient `2/7`, plus cubic evaluators with variable coefficients.
Predicted and measured DSP equivalents agree for every floating case below.

| Evaluator | Binary32 separate | Binary32 FMA | Binary64 separate | Binary64 FMA |
| --- | --- | --- | --- | --- |
| Constant coefficient cubic | 3 | 2 | 11 | 8 |
| Constant coefficient quintic | 5 | 4 | 19 | 16 |
| Variable coefficient cubic | 3 | 3 | 12 | 12 |

All twelve evaluators achieve II equal to one and pass FPGA emulation against the interpreter.
The constant coefficient and table designs also have output error certificates on `[-1,1]`.
Datapath ALUT and FF estimates satisfy the configured rough tolerances, pipeline costs remain unknown.
The 128 row, 512 row and mixed column ROM examples match at 3, 3 and 9 M20K blocks.
Their fixed arithmetic DSP predictions remain 5, 5 and 15 against measured counts of 2, 2 and 6.
These discrepancies prevent treating the fixed arithmetic fallback rules as calibrated limits.

The [validation example](../examples/resource_validation.jl) prepares these fifteen designs and certifies the eleven approximation contracts.
The four variable coefficient designs check arithmetic conformance against the interpreter.

```sh
julia --project=. examples/resource_validation.jl config/resources/oneapi-stratix10-2025.0.toml build/oneapi-validation
julia --project=. scripts/synthesize.jl run build/oneapi-validation/synthesis.toml
julia --project=. scripts/synthesize.jl emulate build/oneapi-validation/synthesis.toml
julia --project=. scripts/synthesize.jl collect build/oneapi-validation/synthesis.toml
julia --project=. scripts/check_resources.jl build/oneapi-validation/examples.toml build/oneapi-validation/measured.toml build/oneapi-validation/comparison.toml
```

The complete comparison reports the unresolved pipeline costs and fixed arithmetic discrepancies.

The [FMA validation example](../examples/fma_validation.jl) prepares eleven Intel and four Vitis primitive formats, a polynomial with individual stage widths and a cubic with variable coefficients.
All nineteen designs achieve II equal to one and pass vendor simulation against the interpreter.
Both polynomials with individual stage widths have output error certificates and pass all 1,024 input encodings.
The independent variable coefficient cubics match their DSP predictions at 1.5 Intel DSP equivalents and 3 Vitis DSPs.
Their LUT estimates pass the configured tolerance.
Intel datapath FFs also pass, the Vitis FF prediction is 2,946 against 5,920 measured and falls just outside the configured tolerance.
Conversions in the individual stage designs still have unknown costs.

Generic FMA uses substantial logic, the Vitis binary32 primitive requires 12,055 evaluator LUTs and 2 DSPs.
The native Intel binary32 and binary64 FMA primitives retain their measured costs of 1 and 4 DSP equivalents.
Only measured formats and operand patterns receive calibrated costs.
Run `julia --project=. examples/fma_validation.jl config/resources/oneapi.toml build/fma-oneapi` to prepare the Intel checks, use the Vitis profile for U280.
The generated `probes`, `holdout` and `composition` projects use the usual synthesis, emulation and collection commands.

The [fixed validation example](../examples/fixed_validation.jl) prepares 36 Vitis arithmetic probes and 15 complete evaluator and ROM designs.
The probes cover DSP width boundaries, unequal operand widths, constant coefficients, signedness, rounding and overflow policies.
The complete evaluators cover constant and variable coefficient cubics, individual stage widths and segmented coefficient tables.
All 51 designs achieve II equal to one and pass Vitis C simulation against the interpreter.
The nine approximation contracts also have output error certificates.
These checks use HLS reports with the default tool clock selection.

| Validation design | Predicted and reported DSPs | Predicted and reported BRAM18 blocks |
| --- | --- | --- |
| Variable coefficient cubic at 16, 32 and 64 bits | 3, 12, 48 | 0, 0, 0 |
| Constant coefficient FMA cubic at 16, 32 and 64 bits | 3, 12, 44 | 0, 0, 0 |
| Cubic with individual stage widths | 4 | 0 |
| 128 row, 512 row and mixed column evaluators | 2, 2, 12 | 0, 3, 6 |
| Distributed 17 bit ROM, two bank 33 bit ROM and four bank 65 bit ROM | 0, 0, 0 | 0, 4, 16 |

DSP and ROM agreement covers these tested patterns, it does not establish exact costs for arbitrary widths or compositions.
Pipeline FF estimates still need calibration.
The approximate multiplication LUT formula fits the measured 16, 32 and 64 bit primitives.
The ROM output LUT formula fits the three isolated ROM layouts and applies when the table is the evaluator result.
Complete polynomial evaluators provide independent checks of these costs.
All 51 LUT predictions satisfy the configured rough tolerance.
FF predictions remain outside tolerance for the 32 bit variable cubic, the 16 bit constant FMA cubic, both banked ROMs and the 128 row and 512 row segmented evaluators.
The profile therefore remains unsuitable for enforcing exact FF limits.

```sh
julia --project=. examples/fixed_validation.jl config/resources/vitis-u280-2023.2.toml build/fixed-validation
julia --project=. scripts/synthesize.jl run build/fixed-validation/holdout/synthesis.toml
julia --project=. scripts/synthesize.jl emulate build/fixed-validation/holdout/synthesis.toml
julia --project=. scripts/synthesize.jl collect build/fixed-validation/holdout/synthesis.toml
julia --project=. scripts/check_resources.jl build/fixed-validation/holdout/examples.toml build/fixed-validation/holdout/measured.toml build/fixed-validation/holdout/comparison.toml --model=config/resources/vitis-u280-2023.2.toml
```

The `probes`, `patterns`, `constants`, `extensions`, `composition` and `rom` directories support the same commands.
The optional comparison model recomputes predictions without changing the recorded synthesis inputs.
Its toolchain, device, compiler and generated kernel must match the measurements.
The comparison records the profile hash and retains failures for resources outside tolerance.

Fixed and control costs, DSP operand dimensions and FF coefficients are placeholders for calibration.
Floating costs require measurements of the emitted arithmetic implementation.
Separate multiplication and addition costs do not predict a fused operation.

Target support is checked independently of cost coverage.
Vendor profiles automatically validate the complete lowered evaluator against `TargetProfile(:vitis)` or `TargetProfile(:oneapi)`.
Unsupported evaluators have `status=:unsupported` and unknown totals even when historical cost rules match.
Supported evaluators with missing costs have `status=:partial`.
Complete coverage still requires synthesis calibration before its predictions can be trusted.

Intel oneAPI 25.0 provides `ap_float` arithmetic for these exponent and fraction widths.
The fraction width excludes the implicit leading bit.
The generic AC backend uses the public `ac_std_float` implementation for a broader range of widths.
That backend provides CPU conformance coverage and does not establish Intel hardware support or resource costs.
Intel emission uses the toolchain headers independently of the public AC checkout.

| Exponent bits | Fraction bits |
| --- | --- |
| 5 | 10 |
| 8 | 7, 10, 17, 23, 26 |
| 10 | 35 |
| 11 | 44, 52 |
| 15 | 63 |

PRESAGe emits Intel addition, multiplication and division with nearest even rounding, high accuracy and subnormal support.
These operations use `ihc::ap_float<8,23>` for single precision and `ihc::ap_float<11,52>` for double precision.
Native `float` and `double` arithmetic can map to different hardware and requires separate resource calibration.
The `:separate` Horner form rounds each multiplication and addition independently.
Subnormal support, accuracy settings and special value handling affect both logic area and DSP mapping.
Resource calibration must match these arithmetic settings and the emitted wrappers.
Changing these settings also requires matching interpreter and certificate semantics.
The Intel host emulator ignores the requested accuracy level, so emulation alone cannot validate reduced accuracy hardware arithmetic.
Intel documents the mapping differences in its [ap_float resource guidance](https://www.intel.com/content/www/us/en/docs/oneapi-fpga-add-on/developer-guide/2024-1/quality-of-results-and-the-ap-float-data-type.html).
Intel floating FMA uses native `sycl::fma` for binary32 and binary64 with exact format conversion at the arithmetic boundary.
Other floating FMA formats use vendor integers to preserve the full product and perform one rounding after addition.
Vitis uses the same implementation for floating FMA, addition and multiplication.
The accumulator retains exact cancellation and sticky information for distant operands.
Both paths support subnormals, signed zeros, infinities and canonical NaNs with nearest even rounding.
Floating arithmetic requires at most 30 exponent bits and `2*(fraction_bits+1)+12 <= 4096`.
Intel addition, multiplication and reciprocal still require one of the native formats listed above.
Vitis floating reciprocal is unsupported.
Automatic arithmetic selection can consider FMA at custom stage widths.
Intel synthesis uses `-fp-model=precise -no-fma -no-ftz` to preserve explicit operation boundaries and subnormal behavior.
Explicit `sycl::fma` retains fused semantics under these flags.
External builds of the generated headers require the same arithmetic settings.
Encoded floating interfaces, tables and integer conversions retain general `FloatFormat` support.
Arithmetic constraints apply to intermediate nodes as well as outputs.
Emission rejects unsupported nodes before writing the destination, including unreachable nodes.

`search_polynomial(spec, config; target=TargetProfile(:oneapi))` filters unsupported arithmetic before starting numerical workers.
Sweeps using vendor resource profiles perform the same filtering and exclude unsupported lowered evaluators during selection.
Numerical certificates and cache entries remain independent of target support.
`target_support(plan, target)` returns support status and rejection reasons without requiring a cost model.

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
| `dsp_tiles` | Rectangular tiling of the two operands. |
| `intermediate_bits` | Exact intermediate arithmetic width before quantization. |
| `rounding_bits` | Number of discarded fraction bits. |
| `overflow_bits` | Number of additional integer bits checked by rejection. |

Sum nonnegative coefficients times features exactly, then round up once per
node/resource. Use integers or rational strings such as `"1/3"`.
Decimal TOML floats are rejected. Large integers round-trip as decimal strings. DSP tiling
uses `[dsp].operand_bits`, trying both orientations. It does not model signed
packing, truncation, cascade modes or constant multiplication optimizations.

`format` is `fixed`, `uint`, `bool`, `float`, `mixed` or `any`. Float rules can
restrict both `exponent_bits` and `fraction_bits`; every involved data format
must match. Optional `rounding` and `max_width` further restrict scope.
Operations cover arithmetic, conversions, comparisons, muxes, classification,
bits, normalization, reciprocal and exponent reconstruction; see `ResourceRule`.
Rules can require `result_width`, `operand_widths`, `integer_bits`, `overflow` and `operand_constants`.
The optional `formats` list matches the output and every operand exactly, including signedness and fixed rounding policies.
Operand constants are hexadecimal bit patterns or `variable`, their order follows the IR operands.
Fixed constant conversions retain their rounded bit patterns for rule matching.
Vitis operands loaded directly from ROM use their stored widths after removing redundant sign extension.
Exact fixed extensions and subsequent exact requantization preserve effective operand widths.
Rounding that discards unknown bits keeps the full declared width.
Fixed conversions of ROM outputs use the declared source width because Vitis retains that width at the conversion boundary.
The `output_bits` cost feature counts result bits only at the evaluator output node.
Calibrated rules preserve these restrictions because constant multiplication can use different hardware.
Initial profiles leave unsupported transformations and mixed conversions unknown.
DSP equivalents remain exact rationals, other resource counts are integers.

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
Vitis/generic assume 64 rows of one bit per one-LUT unit. Intel MLAB counts remain separate from ALUT counts.
Intel constant ROM emission requires block storage, distributed requests are rejected before output.
The Intel model counts native integer storage widths, including 128 bits for a 65 bit word.
The Vitis model removes redundant sign extension from constant ROM widths and rounds allocation widths up to a power of two.
Storage bits and allocated word bits are reported separately.
These dimensions and the illustrative automatic storage threshold are editable.

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

Unset limits impose no constraint, zero is a real limit.
Estimates required by limits or ranking must be known.
An otherwise viable candidate with unknown required estimates leaves selection at `resource_model_incomplete` until synthesis or calibration supplies them.
Rejected rows retain numerical certificates and eligibility reasons.
Known budget violations can exclude candidates independently of their missing estimates.

`:resources` follows the profile's `priority` lexicographically, for example
`["luts", "rams", "dsps", "ffs"]`; a shorter list is allowed. `:luts`, `:ffs`,
`:dsps` and `:rams` minimize that resource before structural/error tie breakers.
Memory and arithmetic priorities remain available.
All five resources enter Pareto comparison, unknown counts prevent dominance.

`max_table_blocks` counts hypothetical allocation with every table in block
memory.
`ResourceBudget(rams=...)` counts tables actually assigned block storage plus RAM costs in node rules.
Use this budget for storage policy comparisons.
`ResourceBudget(mlabs=...)` and `--max-mlabs` constrain MLAB usage.
DSP limits accept exact fractions such as `--max-dsps=7/2`.
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

oneAPI defaults to AC.
`--include-float=true` generates separate single and double arithmetic for oneAPI and fused arithmetic for generic AC emission.
AP kernels currently support fixed arithmetic.
Each example contains a certified plan, profile, estimate, header,
host runner and `kernel.cpp` with callable top `presage_resource_kernel`.
`examples.toml` lists their paths.
The synthesis wrappers request II equal to one in the evaluator loop.
Synthesis reports must confirm this interval before calibration counts can pass.
Clock selection remains with the vendor tools and platform defaults.

A vendor CI job should generate examples, compile and synthesize each top for the selected device, then normalize resource reports.

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
mlabs = 0
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
counts, MLAB counts also require exact agreement. Missing measurements and unknown
predictions stay unresolved. Exit codes: zero passed, one failed, two unresolved.
Duplicate/unknown names and mismatched optional model/backend/toolchain labels
are rejected.

Local tests use explicitly synthetic counts to check the protocol, and public AP and AC headers to check numerical conformance.
Resource accuracy requires agreement with vendor synthesis measurements.

## Integrated synthesis and comparison

`prepare_synthesis`, `run_synthesis` and `collect_synthesis` provide the calibration workflow inside PRESAGe.
The scripts under `analysis` remain historical experiments for the old generator.
New calibration work uses the generated evaluator directly.

```sh
julia --project=. scripts/resource_examples.jl config/resources/vitis.toml build/u280
julia --project=. scripts/synthesize.jl prepare build/u280/examples.toml
julia --project=. scripts/resource_examples.jl config/resources/oneapi.toml build/stratix10 --include-float=true
julia --project=. scripts/synthesize.jl prepare build/stratix10/examples.toml
```

Preparation defaults to U280 part `xcu280-fsvh2892-2L-e` and Stratix 10 board `p520_hpc_sg280l`.
Vitis uses `v++` with platform `xilinx_u280_gen3x16_xdma_1_202211_1`.
Both wrappers use separate transfer and evaluator stages with stream depths matching the `analysis` workflows.
The compiler commands preserve their hardware report settings and select C++17 for the generated evaluators.
Preparation emits no explicit clock constraint or frequency threshold.
The Julia API accepts an explicit `device` override.
For direct Vitis HLS synthesis of the scalar top, pass `hls` after the example manifest.
Run the following commands with the corresponding vendor environment loaded.
Report generation uses Vitis compilation or Intel early linking and performs no hardware image linkage or placement and routing.

```sh
julia --project=. scripts/synthesize.jl run build/u280/synthesis.toml
julia --project=. scripts/synthesize.jl collect build/u280/synthesis.toml
julia --project=. scripts/synthesize.jl emulate build/u280/synthesis.toml
julia --project=. scripts/check_resources.jl build/u280/examples.toml build/u280/measured.toml build/u280/comparison.toml
```

Use the Stratix 10 project path for the Intel workflow.
The `run` and `emulate` commands accept an optional example name to select an unfinished case.
`run_emulation` uses the Intel FPGA emulator or Vitis HLS C simulation of the scalar top.
Intel floating emulation selects the vendor host arithmetic library with `__EMULATION_FLOW__`.
Vitis HLS C simulation does not exercise XRT software emulation.
The calibration runner transfers arbitrary width interfaces as 64 bit chunks and compares output bits and rejection status with the exact interpreter.
Intel host buffers contain standard integer arrays to avoid arbitrary precision object layout differences.
Arithmetic probes also exercise combinations of boundary operand encodings.
Inputs up to 12 bits are exhaustive, floating inputs include boundary values and special encodings.
Fixed width helper loops are fully unrolled for synthesis so bit copying does not create iterative datapaths.
The Intel importer uses Python 3 and isolates `OperationKernel` from the memory transfer kernels.
The Vitis importer reads the evaluator function synthesis XML for the default flow and the scalar top XML for direct HLS.
Both preserve raw reports, source hashes, compiler commands, tool versions and device identities.
Vitis timing records retain the period selected by the tool and the estimated period without imposing a pass threshold.
Estimated Fmax comes from the Vitis estimated period or the slowest Intel evaluator block when available.
The Intel scheduling target is recorded separately from estimated Fmax.
Platform defaults can still constrain synthesis when no clock option is supplied.
These are HLS estimates and do not establish timing closure after placement and routing.
Achieved maximum frequency requires a full implementation run.

Measurement schema version 3 requires evaluator scope, II equal to one, matching resource units and matching provenance before a resource comparison can pass.
The importer preserves kernel totals and excluded interface components, their sums must reconcile.
Vitis excludes AXI control instances using the text report breakdown.
Intel excludes startup blocks, loop feedback, cluster control and pipe operations.
Evaluator totals include pipeline state and record it separately.
Inferred ROM storage must match the requested policy.
An invalid or unresolved measurement cannot establish an estimator failure or success.
Missing reports, missing II and unrecognized report layouts cannot establish a passing calibration.
Nested evaluator loops need additional throughput evidence before calibration can pass.
Vitis counts use LUT, FF, DSP equivalents, BRAM18K and MLAB units.
Intel counts use ALUT, FF, DSP equivalents, M20K and MLAB units.
Fractional ALUT and FF estimates are rounded to whole counts after aggregation within each reported component.
Intel DSP equivalents include the fractional count divided by the packing factor from the report.
Intel block memory hints use `BLOCK_RAM`, the device determines the physical block type.
Intel arithmetic constants have local scope because SYCL rejects their dynamic initialization in static storage.
Intel ROMs use constant integer arrays because AC object initialization prevents inference of constant storage.
Wide ROM words use multiple integer chunks and convert to AC words after lookup.
Fractional DSP budgets and calibration costs use exact rational strings in TOML.
The legacy measurement schema version 1 compares counts only and is insufficient for calibration acceptance.
Synthesis runs refuse to overwrite an existing run record.
Create a new output directory for each changed design or synthesis configuration.

## Calibrate isolated arithmetic.

`resource_probe_plans` supplies independent operand bits to one arithmetic operation.
`constants` optionally supplies exact constant operands, with `nothing` for variable operands.
`operand_formats` supplies individual fixed operand formats independently of the result format.
`input_formats` supplies narrower variable inputs through exact fixed extensions.
Vitis calibration records these extensions as wires and matches the effective widths of their arithmetic consumers.
Conversions that require rounding or can overflow need separate calibration.
Fixed formats preserve integer width, rounding and overflow policy.
These probes verify arithmetic behavior against the interpreter and do not claim approximation certificates.

```julia
using PRESAGe
model = read_resource_model("config/resources/oneapi.toml")
write_resource_probes("build/probes"; model, formats = [IEEE32, IEEE64],
    operations = (:add, :mul, :fma))
project = prepare_synthesis("build/probes/examples.toml")
run_synthesis(project)
run_emulation(project)
calibrated = calibrate_resource_model(project, "build/oneapi-calibrated.toml")
```

Calibration accepts only primitive probe projects with verified reports.
It prepends rules for exact formats and operand patterns and writes a companion evidence file containing source hashes, report hashes, device and compiler identities.
A vector of project paths combines compatible probe suites.
Repeated rules must have identical costs.
Existing emulation records must pass and match the project and source hashes.
Calibrated profiles are restricted to their recorded device and compiler.
ROM and datapath comparisons are also reported separately from complete evaluator counts.
Intel calibration subtracts reported pipeline state before assigning arithmetic costs.
Pipeline resources observed in probes remain unknown at evaluator scope until a scheduling model is supplied.
The profile records these unresolved costs in its `pipeline` table, full evaluator comparisons cannot pass with unknown costs.
The default fixed rules remain illustrative until replaced by measured rules.
Probe agreement verifies the recorded calibration points, independent complete evaluators must validate composition and compiler optimizations.
Pipeline state, constant propagation and sharing can make a complete evaluator differ from the sum of isolated probes.
Keep those discrepancies visible and use separate validation designs before trusting a profile for resource limits.

## Select between evaluator backends

[General backend selection](implementations.md) applies this same model to full
LUTs and polynomial candidates. `sweep_implementations` generates both; the
certificate-list overload of `select_implementation` compares existing proof
results. ROM policies, limits, unknown estimates and priorities are shared with
polynomial sweep selection. Ordinary compilation verifies numerical semantics;
actual backend performance remains a synthesis calibration task.
