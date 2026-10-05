# PRESAGe

Julia planning and verification core for systematic function approximation on
FPGAs. Generated evaluators use portable C++; vendor backends will follow.
Development and numerical verification currently run locally without an FPGA.

The package provides exact IEEE formats and rounding, `FunctionSpec`, versioned
contract/candidate artifacts, adaptive references, a typed arithmetic IR,
an exact interpreter and a C++ CPU emitter. The fixed IEEE32 `erf` evaluator has
a uniform absolute-error certificate covering every finite input. Floating
candidates and polynomial kernels also run locally.
The development plan is maintained at
[`../plan/DEVELOPMENT_PLAN.md`](../plan/DEVELOPMENT_PLAN.md).

## Local setup

Requires Julia 1.10 or newer, a local [Sollya.jl](../Sollya.jl/README.md) checkout
and installed Sollya/MPFR/GMP libraries. CPU tests also require a C++20 compiler
(Clang or GCC with native 128-bit integers), plus GMP C++ headers/libraries;
set `CXX` and optionally `GMP_PREFIX` for the package tests. The expected workspace is:

```text
workspace/
├── PRESAGe/          # Project.toml, src/, test/, scripts/, docs/
└── Sollya.jl/        # Local numerical dependency
```

From the **PRESAGe repository root**:

```sh
julia --startup-file=no scripts/dev.jl
julia --startup-file=no --threads=4 scripts/check.jl
```

`dev.jl` develops the sibling Sollya package and creates an ignored local
manifest. Set `PRESAGE_SOLLYA_PATH` for another local checkout. Both scripts use
offline package operations and a temporary local registry, including on Julia
1.10 with an empty depot. They do not download dependencies or change your
registries. Rerun `dev.jl` when switching Julia versions. For an isolated cache,
prefix commands with `JULIA_DEPOT_PATH=/tmp/presage-depot:`.

Sollya.jl discovers the installed library. Set `SOLLYA_LIBRARY` to an explicit
shared-library path before the first native call when necessary. Direct MPFR
references use Julia's own MPFR runtime.

## API

```julia
using PRESAGe

spec = erf_spec() # IEEE32, all finite inputs, absolute target 2^-23
with_oracle(spec) do oracle
    reference(oracle, 0x3f800000) # erf(1), resolved bits and exact bounds
    reference(oracle, 0x80000000) # exact negative zero
end

reference(FunctionSpec("exp(x)"), 0xc2af0001; backend=:mpfr)
# Correct subnormal output bits: 0x006cb285

write_plan("erf-contract.toml", PlanArtifact(spec))
```

The default fixed evaluator's uniform bound is about **`6.321e-8`**, below the
`2^-23` target. Certification reports contain exact rational bounds; sampled
checks provide additional regression evidence. See [certification](docs/certification.md),
[schema](docs/schema.md), [arithmetic](docs/arithmetic.md),
[oracle semantics](docs/oracle.md) and [local verification](docs/verification.md).

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
separate multiply/add operations, with IEEE32 input/output. Generation searches
within explicit width limits and requires a successful certificate.

The header exposes `presage_evaluator::evaluate(float)` and `evaluate_bits`.
The harness reads and writes little-endian words. `verify_cpu.jl` checks output
bits and the first table index against the exact interpreter, including boundary
neighbours and special values. CMake uses strict floating semantics. Manual
compilation needs C++20, `-ffp-contract=off -fno-fast-math -frounding-math`,
GMP include/library paths and `-lgmpxx -lgmp` for fixed evaluators.

Standalone generation and recertification are also available:

```sh
julia --startup-file=no --project=. scripts/generate.jl erf build/erf
julia --startup-file=no --project=. scripts/certify.jl \
  build/erf/plan.toml build/erf/certificate.toml
```

Use `cpu-linux` on Linux. `-DPRESAGE_PLAN=/path/to/plan.toml` selects an existing
evaluator; `-DPRESAGE_EVALUATION=fma` selects FMA for fresh `erf` generation.
Floating candidates use `-DPRESAGE_INTERNAL=double -DPRESAGE_CERTIFY=OFF`.

The generation CLI accepts `--internal=fixed|single|double`, `--evaluation=fma`,
`--degree=N`, `--segments=N` (a power of two), `--fraction-bits=N`,
`--coefficient-fraction-bits=N` and `--max-fraction-bits=N`. Generation precision,
proof precision and norm tightness have separate controls. Fixed generation
certifies by default; `--certify=false` emits an unchecked candidate. Pass an
existing `plan.toml` instead of `erf` to emit its stored program again and rerun
the supported fixed certificate.

In Julia, `result = certified_erf()` returns the plan, status and uniform bounds.
`certify_erf(plan)` checks a stored fixed evaluator. Julia also supports
`erf_fixed_candidate()`, `erf_candidate()` and
`polynomial_plan(spec, ascending_coefficients; evaluation=:separate)`.
`evaluate_bits(plan, input_bits)` executes either program with exact rounding.

## Reference CLI

```sh
julia --startup-file=no --project=. scripts/reference.jl \
  'erf(x)' inputs.bin references.bin \
  --format=single --byteorder=little --chunk-elements=4096

julia --startup-file=no --project=. scripts/reference.jl \
  exp inputs.bin exp.bin --backend=mpfr --max-precision=4096
```

Formats are `half`, `single` and `double`. Expressions use Sollya syntax;
primitive names and `recip`, `rsqrt`, `asinpi`, `acospi`, `atanpi` aliases are
also accepted. Compositions need `--backend=sollya` (the default).
Outputs have completion metadata and per-input statuses. Unresolved references
abort generation and preserve diagnostics without publishing partial binary
results. See [binary stream semantics](docs/oracle.md#binary-streams).
The former `analysis/eval/golden.jl` entry point forwards to this command and
requires the same explicit input/output arguments.

## Paper and archived source

This project is the source code used in the following paper and provides a systematic approach for generating polynomial approximations of mathematical functions targeting FPGA implementations via oneAPI and Vitis HLS.

It addresses accuracy and throughput limitations in the math libraries of AMD Vitis HLS and Intel oneAPI, and provides the evaluation codes which were used to find the limitations and evaluate the generated approximations.

> Gerrit Pape, Christian Plessl, and Tobias Kenter. 2026. Systematic Function
Approximation on FPGAs to Address Accuracy and Throughput Issues in
oneAPI and Vitis HLS Math Libraries. In Proceedings of the 16th International
Symposium on Highly Efficient Accelerators and Reconfigurable Technologies
(HEART 2026), June 17–19, 2026, Heidelberg, Germany. ACM, New York, NY,
USA, 10 pages. https://doi.org/10.1145/3814576.3814578

The original `generator/` and `analysis/` directories are paper-era source,
outside the new package's build, tests and development requirements. Historical
implementations and comparisons can be recovered from Git when needed.

This repository, including the Julia package, is licensed under the
[GNU General Public License v3.0 or later](COPYING).
