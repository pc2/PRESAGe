# Generation from a contract

`scripts/generate.jl CONTRACT.toml OUTPUT_DIR --search-config=SEARCH.toml`
generates coefficients, certifies the complete evaluator and emits C++.
The contract uses the existing plan schema with status `contract`, an explicit
finite domain and no candidate program, segments, dispatch or settings.
Input/output formats and the error target belong to this contract.

The generic planner approximates the complete Sollya expression. See
[function expression coverage](expression-coverage.md) for supported scope,
failure conditions and the distinction from specialized transformations.

The separate search configuration declares ordered segment counts, degrees and internal
formats, numerical settings and execution limits. Use the Julia writers:

```julia
using PRESAGe
spec = FunctionSpec("exp(x)+0.1*x";
    input_format=IEEE32, domain=(-1,1), absolute_error=1//(1<<21))
config = PolynomialSearchConfig(degrees=[1,9,13],
    internal_formats=[FloatFormat(8,23),FloatFormat(8,27)],
    evaluation=:fma, max_attempts=6, job_timeout=60, total_timeout=300)
write_plan("contract.toml", PlanArtifact(spec))
write_search_config("search-config.toml", config)
```

```sh
julia --startup-file=no --project=. scripts/generate.jl \
  contract.toml build/function --search-config=search-config.toml
```

The checked-in [exp contract](../examples/exp-contract.toml) and
[search configuration](../examples/polynomial-search.toml) provide a fixed
input/output example. They need degree nine with `Fixed(32,6)` after three
budget failures. [Search ordering and limits](certification.md#ordered-search-and-worker-limits)
also apply to the CLI.

Use `segments=[1,4]` with `degrees=[5]` to try a single degree-five polynomial
followed by four normalized segments. The fixed exp contract passes with the
second choice. The [segmented configuration](../examples/segmented-search.toml)
can be used with the same CLI command and exp contract. Generation and proof of
all rows share one attempt deadline; stored segmented plans replay without
another coefficient search.

For individual coefficient/stage formats, set `precisions=[layout,…]` in
`PolynomialSearchConfig`, aligned with `internal_formats`. Each layout must
cover the largest requested degree and use that choice's coordinate format.
`write_search_config` writes schema v3, which the same CLI reads. Explicit
precision plans use schema v5 and retain all target formats during replay.
See the [precision example](../examples/precision_search.jl), which also writes
a configuration for CLI use. Precision optimization has its own Julia API and
report; emit its selected stored plan through the existing replay command.

For bounded `sin(x)`, `sinh(x)`, `atan(x)` and `erf(x)`, set
`transformation=:odd` to use `x*q(x²)`. Degrees are the odd original polynomial
degrees in `1:31`; precision lists describe q and need `(maximum(degrees)+1)÷2`
entries. Only `segments=[1]` is supported. The writer uses configuration v4,
with `transformation="odd"`; stored plans retain the transformation and exact
arithmetic graph in schema v5. Replay audits and recertifies that graph.
The [odd example](../examples/odd_search.jl) writes a contract and configuration
for the same CLI workflow.

For `1/x`, use `transformation=:reciprocal` and `segments=[1]`. Floating
input/output and a bounded domain strictly on one side of zero are required.
Degrees and individual precision lists describe the mantissa polynomial on
`[1,2]`. Fixed and floating internals, separate/FMA evaluation and certified
precision optimization are supported. Configuration/report v5 and plan v6
retain the reduction during the same CLI workflow and stored-plan replay.
See the [reciprocal example](../examples/reciprocal_search.jl) and
[reconstruction proof](certification.md#reciprocal-mantissa-kernels).

## Options

With `--search-config`, the CLI accepts `--name`,
`--backend=portable|ac_fixed|ap_fixed`, `--float-backend=auto|native|ac_std_float`
and optional `--certify=true`. It rejects `--certify=false` and numerical
overrides such as `--degree`, `--internal` or `--proof-precision`: put these
choices in the search configuration. Fixed and floating internal formats
have independent input/output formats as defined by the contract. A backend
must support the selected program; see [CPU limits](arithmetic.md).

The existing `erf OUTPUT_DIR` command and `PLAN.toml OUTPUT_DIR` recertification
remain available. A contract without `--search-config` has no evaluator to emit.
Supplying a candidate plan with `--search-config` is rejected.

## Artifacts and failures

| File | Contents |
| --- | --- |
| `plan.toml` | Selected candidate, exact coefficients and executed arithmetic IR. |
| `certificate.toml` | Separate complete evaluator proof and error contributions. |
| `search.toml` | Ordered choices, numerical/time limits, history and selected attempt. |
| `evaluator.hpp`, `evaluate.cpp` | C++ evaluator and binary CPU harness. |

The evaluator is one self-contained header with only required helpers. Tracing
is disabled by default. Use `--trace=true` to generate CPU instrumentation, then
`scripts/verify_cpu.jl PLAN.toml EXECUTABLE --trace` to check table selections and
fixed intermediates as well as final outputs. CMake exposes the same option as
`PRESAGE_TRACE=ON`.

Only a passing complete certificate authorizes publication of bounded search
output. The selected plan is sufficient for later recertification and emission;
replaying it does not regenerate coefficients or rerun the search:

```sh
julia --startup-file=no --project=. scripts/certify.jl \
  build/function/plan.toml build/function/recertified.toml
julia --startup-file=no --project=. scripts/generate.jl \
  build/function/plan.toml build/replayed --backend=ac_fixed
```

Replay saves a new certificate, with no new search report. Ordinary C++
compilation and the exact interpreter can verify the saved program using the
[local CPU workflow](#generate-and-run-a-cpu-evaluator).

Exhausted searches exit unsuccessfully and save `search-failure.toml`, including
`search_limit`, its stop reason and the available candidate/certificate data.
An existing successful plan, evaluator, certificate and search report are
preserved. A fresh failed output directory contains only the failure report.
Invalid contracts/configurations or incompatible options are reported directly
before search; they do not change valid output or create a search history.

A search can certify a numerical candidate whose C++ emission subsequently
fails. Its failure report retains numerical status `certified` and adds
`generation_failure.stage = "emission"` with the error reason. Publication
errors use stage `publication`. Neither case publishes a replacement evaluator.

Generation stages all new artifacts before replacing the managed files.
Ordinary file-operation errors restore the previous files; unrelated files in
the directory remain in place. Successful generation removes stale failure
reports. Successful stored-plan/erf generation removes an old search report,
and unchecked stored-plan/erf generation also removes an old certificate.

## Generate and run a CPU evaluator

```sh
cmake --preset cpu-macos
cmake --build --preset cpu-macos
ctest --preset cpu-macos
build/cpu-macos/presage_cpu < inputs.bin > outputs.bin
```

CMake 3.24 or newer generates `plan.toml`, `certificate.toml`, `evaluator.hpp`
and a binary harness in `build/cpu-macos/generated`. Defaults are four segments
on `[0,4]`, degree nine, 31 fractional bits, automatic stage integer widths and
separate multiply/add operations, `ac_fixed` arithmetic and IEEE32 input/output. Generation searches
within explicit width limits and requires a successful certificate.

### Interfaces and tracing

The header exposes `presage_evaluator::evaluate(float)` and `evaluate_bits`.
The harness reads and writes little-endian words. `verify_cpu.jl` checks output
bits against the interpreter, including boundary neighbours and special values.
Tracing is disabled by default. `PRESAGE_TRACE=ON` adds checks of the first table
index and every visited fixed node's exact payload. The standalone generator uses
`--trace=true`, and its verifier uses `--trace`.

Each evaluator is one self-contained header containing only required helpers.
CMake uses strict floating semantics. Manual compilation needs C++20, `-ffp-contract=off -fno-fast-math -frounding-math`,
GMP include/library paths and `-lgmpxx -lgmp` for fixed evaluators.
Vendor builds also need the selected library's include directory.

### Arithmetic backends

Build and validate both libraries with ordinary LLVM C++ compilation:

```sh
cmake --preset cpu-macos-ac
cmake --build --preset cpu-macos-ac
ctest --preset cpu-macos-ac

cmake --preset cpu-macos-ap
cmake --build --preset cpu-macos-ap
ctest --preset cpu-macos-ap
```

Use `-DPRESAGE_BACKEND=portable|ap_fixed|ac_fixed` with any preset to select
arithmetic. Existing CMake caches retain their earlier selection. See
[backend semantics and CPU limits](arithmetic.md#fixed-backends).

### Standalone generation

Standalone generation and recertification are also available:

```sh
julia --startup-file=no --project=. scripts/generate.jl erf build/erf
julia --startup-file=no --project=. scripts/certify.jl \
  build/erf/plan.toml build/erf/certificate.toml
```

Use `cpu-linux` on Linux. `-DPRESAGE_PLAN=/path/to/plan.toml` selects an existing
evaluator; `-DPRESAGE_EVALUATION=fma` selects FMA for fresh `erf` generation.
Floating candidates use `-DPRESAGE_INTERNAL=double -DPRESAGE_CERTIFY=OFF`.

### Fresh erf generation options

The generation CLI accepts `--backend=portable|ap_fixed|ac_fixed` (default
`ac_fixed`), `--internal=fixed|single|double`, `--evaluation=fma`,
`--degree=N`, `--segments=N` (a power of two), `--fraction-bits=N`,
`--coefficient-fraction-bits=N` and `--max-fraction-bits=N`. Generation precision,
proof precision and norm tightness have separate controls. Fixed generation
certifies by default; `--certify=false` emits an unchecked candidate. Pass an
existing `plan.toml` instead of `erf` to emit its stored program again and rerun
the supported certificate.
