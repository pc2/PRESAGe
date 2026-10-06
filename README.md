# PRESAGe

Julia planning and verification core for systematic function approximation on
FPGAs. Generated evaluators use C++ with `ac_fixed` or `ap_fixed` arithmetic,
with a portable integer backend for reference checks.
Development and numerical verification currently run locally without an FPGA.

The package provides exact IEEE formats and rounding, `FunctionSpec`, versioned
contract/candidate artifacts, adaptive references, a typed arithmetic IR,
an exact interpreter and a C++ CPU emitter. Inputs, outputs, coefficients and
intermediates can use fixed formats; mixed fixed/floating interfaces are supported.
The fixed binary16/IEEE32 `erf` evaluators have uniform absolute-error certificates
covering every finite input. Fixed polynomial kernels can also be certified on
bounded domains. Binary16 also supports a complete lookup table with resolved
nearest-even outputs. Floating candidates run locally.
The development plan is maintained at
[`../plan/DEVELOPMENT_PLAN.md`](../plan/DEVELOPMENT_PLAN.md).

## Local setup

Requires Julia 1.13 or newer, a local [Sollya.jl](../Sollya.jl/README.md) checkout
and installed Sollya/MPFR/GMP libraries. CPU tests also require a C++20 compiler
(Clang or GCC with native 128-bit integers), plus GMP C++ headers/libraries;
set `CXX` and optionally `GMP_PREFIX` for the package tests. The expected workspace is:

```text
workspace/
├── PRESAGe/          # Project.toml, src/, test/, scripts/, docs/
├── Sollya.jl/        # Local numerical dependency
├── ac_types/        # Public Algorithmic C headers
└── HLS_arbitrary_Precision_Types/ # Public Xilinx simulation headers
```

From the **PRESAGe repository root**:

```sh
julia --startup-file=no scripts/dev.jl
julia --startup-file=no --threads=4 scripts/check.jl
```

`dev.jl` develops the sibling Sollya package and creates an ignored local
manifest. Set `PRESAGE_SOLLYA_PATH` for another local checkout. Both scripts use
offline package operations, including with an empty depot. They do not download
dependencies or change your registries. Rerun `dev.jl` when switching Julia
versions. For an isolated cache, prefix commands with
`JULIA_DEPOT_PATH=/tmp/presage-depot:`.

Sollya.jl discovers the installed library. Set `SOLLYA_LIBRARY` to an explicit
shared-library path before the first native call when necessary. Direct MPFR
references use Julia's own MPFR runtime.

Both fixed libraries are public under Apache 2.0:
[Algorithmic C types](https://github.com/hlslibs/ac_types) and
[Xilinx arbitrary precision simulation types](https://github.com/Xilinx/HLS_arbitrary_Precision_Types).
Place local checkouts beside PRESAGe, or set `PRESAGE_AC_INCLUDE_DIR` and
`PRESAGE_AP_INCLUDE_DIR` to their `include` directories. Tests run each vendor
backend when its headers are present; `PRESAGE_REQUIRE_VENDOR_TESTS=true` makes
missing headers an error. Builds and tests do not download them.

To obtain the official checkouts from the PRESAGe repository root:

```sh
git clone --depth 1 https://github.com/hlslibs/ac_types.git ../ac_types
git clone --depth 1 https://github.com/Xilinx/HLS_arbitrary_Precision_Types.git ../HLS_arbitrary_Precision_Types
```

## Formatting

JuliaFormatter uses the repository's [configuration](.JuliaFormatter.toml),
with four-space indentation and a 92-column margin. Its version is pinned in a
separate development environment. From the repository root:

```sh
julia --startup-file=no --project=tools/format -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=tools/format scripts/format.jl
julia --startup-file=no --project=tools/format scripts/format.jl --check
```

The check command exits with status 1 when formatting is required and does not
write files. The command formats Julia files in `src`, `scripts`, `test` and
`examples`. For offline setup, reuse a resolved formatter manifest and cached
dependencies, and call `Pkg.offline(true)` before `Pkg.instantiate()`.

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
separate multiply/add operations, `ac_fixed` arithmetic and IEEE32 input/output. Generation searches
within explicit width limits and requires a successful certificate.

The header exposes `presage_evaluator::evaluate(float)` and `evaluate_bits`.
The harness reads and writes little-endian words. `verify_cpu.jl` checks output
bits, the first table index and every visited fixed node's exact payload against
the interpreter, including boundary
neighbours and special values. CMake uses strict floating semantics. Manual
compilation needs C++20, `-ffp-contract=off -fno-fast-math -frounding-math`,
GMP include/library paths and `-lgmpxx -lgmp` for fixed evaluators.
Vendor builds also need the selected library's include directory.

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
[backend semantics and CPU limits](docs/arithmetic.md#fixed-backends).

Standalone generation and recertification are also available:

```sh
julia --startup-file=no --project=. scripts/generate.jl erf build/erf
julia --startup-file=no --project=. scripts/certify.jl \
  build/erf/plan.toml build/erf/certificate.toml
```

Use `cpu-linux` on Linux. `-DPRESAGE_PLAN=/path/to/plan.toml` selects an existing
evaluator; `-DPRESAGE_EVALUATION=fma` selects FMA for fresh `erf` generation.
Floating candidates use `-DPRESAGE_INTERNAL=double -DPRESAGE_CERTIFY=OFF`.

The generation CLI accepts `--backend=portable|ap_fixed|ac_fixed` (default
`ac_fixed`), `--internal=fixed|single|double`, `--evaluation=fma`,
`--degree=N`, `--segments=N` (a power of two), `--fraction-bits=N`,
`--coefficient-fraction-bits=N` and `--max-fraction-bits=N`. Generation precision,
proof precision and norm tightness have separate controls. Fixed generation
certifies by default; `--certify=false` emits an unchecked candidate. Pass an
existing `plan.toml` instead of `erf` to emit its stored program again and rerun
the supported certificate.

## Binary16 implementations

Binary16 `erf` supports a lookup table or fixed polynomial, both with half input
and output. The default absolute target is `2^-10`. Automatic selection uses
`ImplementationModel(lut_max_bits=1048576)`: choose the full LUT when its storage
fits this arbitrary threshold, otherwise choose the polynomial. The table has
65,536 sixteen-bit entries, or **128 KiB**. This policy can be calibrated later.

```sh
# Automatic selection: LUT at the default threshold.
julia --startup-file=no --project=. scripts/generate.jl erf build/half-lut \
  --input-format=half

# Automatic selection: polynomial when the table exceeds the threshold.
julia --startup-file=no --project=. scripts/generate.jl erf build/half-poly \
  --input-format=half --lut-max-bits=0
```

Use `--implementation=lut|polynomial|auto` to select explicitly, and
`--absolute-error=1/1024` to set the exact budget. `--output-format` defaults to
the input format; the certified erf kernels require matching half or single
interfaces. `--backend=portable|ac_fixed|ap_fixed` independently selects the C++
arithmetic library. LUT generation requires certification and rejects polynomial
tuning options. Stored plans retain their selected implementation when re-emitted.

```julia
spec = erf_spec(; format=IEEE16)
lut = certified_erf(; spec, implementation=:lut)
polynomial = certified_erf(; spec, implementation=:polynomial)
implementation_cost(lut.plan) # Table bits, reads and static arithmetic counts.
```

The LUT resolves every entry using adaptive reference enclosures and reproduces
nearest-even rounding for every finite input. Signed zeros and nonfinite inputs
follow the shared primitive policy. `certify_lut(plan)` rechecks every stored
entry and the complete lookup graph. `certified_lut(spec)` is also available for
other matching binary16 contracts with established references and finite results
at every finite input. Failed or unresolved references stop generation.

The polynomial has a uniform total-error certificate; it does not promise
correct rounding. Both implementations are checked on all 65,536 input patterns
through the interpreter and all three C++ backends. Structural costs describe
stored tables and IR operations; they are not FPGA latency, II or resource
predictions. Binary16 CPU arithmetic currently uses fixed, float or double
internals with portable half storage and exact conversions.

## Fixed input and output

```julia
using PRESAGe

spec = FunctionSpec("x/2+1/4";
    input_format=FixedFormat(9,4), output_format=FixedFormat(13,5))
plan = polynomial_plan(spec, [1//4,1//2]; internal_format=FixedFormat(24,8))
evaluate_bits(plan, round_fixed(1//2, spec.input_format)) # Encoded fixed output
result = certify_polynomial(plan)
@assert result.status == :certified
@assert result.total_bound == 0 # This affine kernel is exact on the input grid.
write_plan("fixed-plan.toml", plan)
write_certificate("fixed-certificate.toml", result)
emit_cpp("evaluator.hpp", plan; backend=:ac_fixed)
```

Fixed words use two's complement when signed and occupy `ceil(W/8)` bytes.
Unused high bits must be zero, including for negative values. Words beyond 64
bits are supported. Output rounding and reject/saturate/wrap behavior come from
the output format. Outside a bounded domain, a fixed evaluator raises an error.

Run the [complete example](examples/fixed_polynomial.jl):

```sh
julia --startup-file=no --project=. examples/fixed_polynomial.jl
julia --startup-file=no --project=. scripts/generate.jl \
  build/fixed-plan.toml build/fixed --backend=ac_fixed
```

Numerical reports are separate from candidate plans. Stored fixed polynomial
plans and the canonical IEEE32 `erf` graph automatically rerun certification
during generation; `--certify=false` emits an unchecked candidate.
`--certify=true` requires a successful proof and rejects unsupported graphs.
Polynomial certification initially supports degree 0–32, fixed input/output
and internals, nearest-even rounding and rejected overflow. Fixed I/O is also
supported by the reference oracle and binary reference CLI.

The [bounded polynomial example](examples/bounded_polynomial.jl) generates and
certifies `erf` and `exp` on `[-1,1]`, using fixed input/output:

```sh
julia --startup-file=no --project=. examples/bounded_polynomial.jl
julia --startup-file=no --project=. scripts/generate.jl \
  build/bounded/exp-plan.toml build/bounded/exp --backend=ac_fixed
```

In Julia, `result = certified_erf()` returns the plan, status and uniform bounds.
`certify_erf(plan)` checks a stored fixed evaluator. Julia also supports
`erf_fixed_candidate()`, `erf_candidate()` and
`polynomial_plan(spec, ascending_coefficients; evaluation=:separate)`.
`certify_polynomial(plan)` proves a supported fixed polynomial;
`certify_plan(plan)` selects the supported proof for a stored evaluator.
`evaluate_bits(plan, input_bits)` executes either program with exact rounding.

## Reference CLI

```sh
julia --startup-file=no --project=. scripts/reference.jl \
  'erf(x)' inputs.bin references.bin \
  --format=single --byteorder=little --chunk-elements=4096

julia --startup-file=no --project=. scripts/reference.jl \
  exp inputs.bin exp.bin --backend=mpfr --max-precision=4096

julia --startup-file=no --project=. scripts/reference.jl \
  'erf(x)' fixed-inputs.bin fixed-references.bin \
  '--input-format=fixed(9,3)' '--output-format=fixed(10,2)'
```

Formats are `half`, `single`, `double`, `fixed(W,I)` and `ufixed(W,I)`.
`--output-format` defaults to the input format; `--format` remains an input-format
alias. Fixed output also accepts `--rounding=nearest_even|toward_zero|up|down`
and `--overflow=reject|saturate|wrap`. Expressions use Sollya syntax;
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
