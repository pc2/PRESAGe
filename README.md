# PRESAGe

Julia planning and verification core for systematic function approximation on
FPGAs. Generated evaluators use C++ with `ac_std_float`, `ac_fixed` or `ap_fixed` arithmetic,
with a portable integer backend for reference checks.
Development and numerical verification currently run locally without an FPGA.

The package provides exact IEEE formats and rounding, `FunctionSpec`, versioned
contract/candidate artifacts, adaptive references, a typed arithmetic IR,
an exact interpreter and a C++ CPU emitter. Inputs, outputs, coefficients and
intermediates can use fixed formats; mixed fixed/floating interfaces are supported.
The fixed binary16/IEEE32 `erf` evaluators have uniform absolute-error certificates
covering every finite input. Fixed polynomial kernels can also be certified on
bounded domains. Floating and mixed fixed/floating polynomial kernels also have
uniform certificates, including custom formats and extra internal fraction bits.
Bounded generation also supports normalized segments with complete dispatch,
coordinate and per-path error proofs. Coefficient storage and Horner stage formats
can be chosen individually and reduced through a bounded certified search.
Binary16 supports a complete lookup table with resolved nearest-even outputs.
Custom floating formats support wide significands, with automatic `BigInt`
payloads above 64 bits and official AC headers for C++ arithmetic.
The development plan is maintained at
[`../plan/DEVELOPMENT_PLAN.md`](../plan/DEVELOPMENT_PLAN.md).

## Bounded function generation

Generate coefficients and certify the complete evaluator in one call:

```julia
using PRESAGe

spec = FunctionSpec("exp(x)+0.1*x";
    input_format=IEEE32, domain=(-1,1), absolute_error=1//(1<<21))
result = certified_polynomial(spec; degree=13,
    internal_format=FloatFormat(8,27), evaluation=:fma,
    generation_precision=256, proof_precision=256)
@assert result.status == :certified
write_plan("composed.toml", result.plan)
write_certificate("certificate.toml", result)
```

This makes one attempt with the selected degree and shared coefficient/stage
format by default. Fixed and floating internals and independent input/output formats are
supported. Generation precision, proof precision and norm tightness are separate
settings. Decimal/scientific literals retain exact rational semantics.
The result retains a generated plan when its bound exceeds the budget or its
proof fails; `generation_failed` includes a reason and a contract-only plan.
See [generation details](docs/certification.md#generating-a-bounded-evaluator)
and the [fixed example](examples/bounded_polynomial.jl).

Search explicitly ordered degrees and internal formats with bounded execution:

```julia
config = PolynomialSearchConfig(degrees=[1,9,13],
    internal_formats=[FloatFormat(8,23), FloatFormat(8,27)],
    evaluation=:fma, max_attempts=6, job_timeout=60, total_timeout=300)
search = search_polynomial(spec, config)
write_search_report("search.toml", search)
if search.status == :certified
    write_plan("composed.toml", search.selected.plan)
    write_certificate("certificate.toml", search.selected)
end
```

Degrees are visited in caller order, with every format in caller order within
each degree. The first certified candidate is selected. Each attempt uses a
fresh process; startup counts toward both time limits, and timed-out workers
are killed and reaped before continuing. Integer and exponent ranges remain
explicit choices. `search_limit` retains the history and identifies exhaustion
of choices, the attempt limit or the total deadline. Reports include exact
available plans, certificate contributions and failure reasons. See
[search limits](docs/certification.md#ordered-search-and-worker-limits) and the
[search example](examples/bounded_search.jl).

Add `segments=[1,4,8]` to search normalized segment counts before degrees and
formats. Counts are powers of two up to 64; coefficient tables feed one shared
Horner evaluator. `certified_polynomial(...; segments=4)`
makes one segmented attempt. Every executed threshold and table payload is
audited, with input conversion/subtraction/scaling and final output rounding
included in the uniform bound. See [coverage proofs](docs/certification.md#normalized-segments-and-coverage)
and the [segmented example](examples/segmented_search.jl).

### Individual coefficient and stage formats

`PolynomialPrecision` separates coordinate arithmetic, coefficient storage and
accumulator formats. Lists are in ascending power order, including the initial
highest coefficient load. Each stage has a common format across segments.

```julia
precision = PolynomialPrecision(FixedFormat(32,6);
    coefficient_formats=[FixedFormat(24,4), FixedFormat(20,3)],
    stage_formats=[FixedFormat(28,4), FixedFormat(24,3)])
affine = FunctionSpec("x/2+1/4"; input_format=FixedFormat(8,3),
    output_format=FixedFormat(16,4), domain=(-1,1))
result = certified_polynomial(affine; degree=1, precision)
reduced = optimize_precision(result; max_attempts=16,
    bit_step=2, job_timeout=30, total_timeout=120)
write_precision_report("precision-search.toml", reduced)
```

Every conversion, overflow check and rounding contribution enters the complete
certificate. `optimize_precision` regenerates coefficients after storage changes
and recertifies every candidate in an owned worker. It keeps the last passing
plan when limits or failed reductions stop the search. `precision_cost` reports
declared storage, stage and operand widths; FPGA performance remains unmeasured.
Search configurations accept `precisions=[precision,…]` alongside their internal
format choices. See [precision semantics](docs/certification.md#individual-coefficient-and-stage-precision)
and the [segmented precision example](examples/precision_search.jl).

## Generation from a contract

The CLI reads a bounded contract and a separate search configuration:

```sh
julia --startup-file=no --project=. scripts/generate.jl \
  examples/exp-contract.toml build/bounded \
  --search-config=examples/polynomial-search.toml --backend=ac_fixed

# Replay the stored evaluator and recertify it without another search.
julia --startup-file=no --project=. scripts/generate.jl \
  build/bounded/plan.toml build/replayed --backend=ap_fixed
```

A successful search saves `evaluator.hpp`, `evaluate.cpp`, `plan.toml`,
`certificate.toml` and `search.toml`. A failed search saves
`search-failure.toml` and preserves the previous valid output. Bounded search
always requires certification. Create your own inputs with
`write_plan(path, PlanArtifact(spec))` and `write_search_config(path, config)`;
`read_search_config` restores the exact choices and limits. Numerical search
options belong in that file; CLI backend/name options control emission.
See [generation and failure reports](docs/generation.md).

## Custom floating formats

```julia
using PRESAGe

spec = FunctionSpec("1/4+3/2*x-1/2*x^2"; input_format=IEEE128, domain=(-1,1))
plan = polynomial_plan(spec, [1//4, 3//2, -1//2];
                       internal_format=FloatFormat(8,160), evaluation=:fma)
write_plan("custom.toml", plan)
emit_cpp("evaluator.hpp", plan) # automatically selects official AC float types
emit_harness("evaluate.cpp", plan.program)
```

`FloatFormat(E,M)` declares exponent and fraction widths. Encoded words use
`UInt64` up to 64 bits and `BigInt` for larger formats; `IEEE128` and `IEEE256`
are predefined. The interpreter rounds each operation exactly. References
adapt MPFR/Sollya working precision independently of the target format.

Generate a stored custom plan with `scripts/generate.jl custom.toml build/custom`.
`--float-backend=auto|native|ac_std_float` selects floating arithmetic separately
from the fixed `--backend`. Use `ac_std_float` explicitly to validate binary32
through the AC headers. Floating-only AC evaluators compile without GMP linkage.
See [format and backend limits](docs/arithmetic.md#custom-floating-backend).
Custom floating polynomial plans certify by default during generation.
Certificates include the stored polynomial, input conversion, arithmetic,
subnormals, exponent limits and output conversion. See
[certification](docs/certification.md) for supported graphs and policies.

### Internal guard bits

Input/output and internal formats are independent. Four extra fraction bits for
binary32 arithmetic use `FloatFormat(8,27)`:

```julia
spec = FunctionSpec("1/4+x/2-x^2/4"; input_format=IEEE32, domain=(-1,1))
plan = polynomial_plan(spec, [1//4,1//2,-1//4];
                       internal_format=FloatFormat(8,27), evaluation=:fma)
result = certify_polynomial(plan)
@assert result.status == :certified
```

The [floating polynomial example](examples/floating_polynomial.jl) generates
bounded erf and exp approximations and certifies fixed and floating internals
against matching binary32 contracts. `PolynomialPrecision` allows independent
coefficient and stage fraction widths; floating exponent headroom is a separate
choice and remains unchanged by precision optimization.

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

Numerical reports are separate from candidate plans. Stored float/fixed polynomial
plans and the canonical IEEE32 `erf` graph automatically rerun certification
during generation; `--certify=false` emits an unchecked candidate.
`--certify=true` requires a successful proof and rejects unsupported graphs.
Polynomial certification supports degree 0–32, float/fixed input/output
and internals, nearest-even rounding and rejected fixed overflow. Fixed I/O is also
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
`certify_polynomial(plan)` proves a supported float/fixed polynomial;
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

Formats are `half`, `single`, `double`, `quad`, `octuple`, `float(E,M)`,
`fixed(W,I)` and `ufixed(W,I)`, where `M` is the fraction width.
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
