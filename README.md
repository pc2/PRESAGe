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
Bounded sin, sinh, atan and erf also support certified `x*q(x²)` kernels.
Bounded reciprocal kernels normalize floating inputs exactly, including
subnormals, approximate `1/m` on `[1,2]` and certify exponent reconstruction.
Sqrt and rsqrt use exact `e=2q+r` splitting and kernels on `[1,4]`, with
complete reconstruction bounds and lazy zero/infinity/invalid-input branches.
See the [root example](examples/root_search.jl) and [proof](docs/certification.md#sqrt-and-rsqrt-exponent-splitting).
Cbrt extends this pipeline to bounded signed domains with `e=3q+r`, a positive
kernel on `[1,8]`, exact sign restoration and signed zero/infinity branches.
See the [cbrt example](examples/cbrt_search.jl).
Atan combines a certified odd central kernel with reciprocal tails at `|x|>1`,
including reciprocal rounding, the stored `π/2` constant and signed limits.
See the [atan example](examples/atan_search.jl).
Log supports positive finite inputs over bounded nonnegative domains using
`log(m)+e*log(2)`, with the stored constant and all reconstruction rounding
included in the certificate. See the [log example](examples/log_search.jl).
Exp reduces bounded inputs to a residual near zero, evaluates one polynomial
and scales directly into the floating output. Its certificate includes integer
selection, stored constants and underflow. See the [exp example](examples/exp_search.jl).
Sinh/cosh combine central odd/even kernels with two exponential tails. Each tail
is scaled by one half before reconstruction, preserving finite hyperbolic results
past exp's output overflow point. See the [hyperbolic example](examples/hyperbolic_search.jl).
Erfc combines a central polynomial with a normalized scaled positive tail and
certified exp reconstruction, including square rounding, underflow and the
negative-input identity. See the [erfc example](examples/erfc_search.jl).
Sin/cos support bounded periodic reduction with proved integer quadrants,
two reduced parity kernels and exact quadrant/sign restoration.
See the [periodic example](examples/periodic_search.jl).
Asin/acos support bounded intervals inside `[-1,1]`, with exact endpoint
coordinates, composed sqrt/asin kernels and complete reconstruction bounds.
See the [inverse trig example](examples/inverse_trig_search.jl).
Local design sweeps evaluate all configured candidates with bounded concurrent
workers, exact numerical caching and structural Pareto reports. A configurable
memory model and block budget select a certified design per contract, with
memory or arithmetic priority and exported plan/certificate pairs. Editable
LUT/ALUT, FF, DSP and RAM estimates support individual limits and resource
priorities. Small synthesis examples and a normalized report checker support
later CI calibration; see [resource models](docs/resources.md).
Sweeps can also hold coefficients fixed while varying stage precision. See the
[sweep workflow](docs/sweeps.md) and [guard example](examples/design_sweep.jl).
Portable sampled verification uses Julia-generated reference bundles and one
standalone C++ checker, shared by local runs and saved runner outputs. It reports
error enclosures and witnesses separately from certificates; see
[sampled verification](docs/sampled-verification.md).
Fixed arithmetic graphs also have a C++17 kernel emitter with official AP/AC
types, encoded floating interfaces and explicit rejection status. It preserves
the stored IR's rounding, overflow and lazy branches and uses a separate host
byte-stream adapter. IEEE conversions, special-value branches, floating LUTs,
exact normalization and exponent reconstruction are supported, including
fixed-internal reciprocal, sqrt/rsqrt, cbrt and log kernels.
See [kernels](docs/kernels.md); vendor synthesis remains pending.
Binary16 supports a complete lookup table with resolved nearest-even outputs.
Custom floating formats support wide significands, with automatic `BigInt`
payloads above 64 bits and official AC headers for C++ arithmetic.
The development plan is maintained at
[`../plan/DEVELOPMENT_PLAN.md`](../plan/DEVELOPMENT_PLAN.md).

## Bounded function generation

The generic planner approximates complete Sollya expressions, including
compositions. See [function expression coverage](docs/expression-coverage.md)
for current limits, difficult domains and further planner development.

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
formats. Counts are powers of two up to 512; coefficient tables feed one shared
Horner evaluator. Indices use the minimum required width (nine bits at 512),
and aligned fixed inputs select the row from input bits and an exact modular
lower-row offset. Aligned
floating intervals use exact scaling, integer floor and an integer offset;
on `[-1,1]` at 512 rows this is `min(floor((x+1)*256),511)`.
Other layouts use a balanced comparison tree with at most nine dispatch comparisons.
Binary16/binary32 `erf` kernels also use direct row selection from the exact
floating magnitude; at 512 rows it is `min(floor(abs(x) * 128), 511)`.
`certified_polynomial(...; segments=4)`
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

### Odd function kernels

Set `transformation=:odd` in `certified_polynomial` or `PolynomialSearchConfig`
to generate `x*q(x²)` for bounded `sin(x)`, `sinh(x)`, `atan(x)` or `erf(x)`.
The original polynomial degree must be odd and in `1:31`. Degree nine uses five
stored coefficients and four Horner stages, plus the square and reconstruction
products. Their rounding errors and all precision conversions enter the proof.
An exact lazy zero branch preserves both floating zero signs.

This option uses one central kernel and supports individual coefficient/stage
formats and precision optimization. It must be requested explicitly. See
[transformation proofs](docs/certification.md#odd-function-kernels) and the
[odd search example](examples/odd_search.jl).

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

Requires Julia 1.13 or newer and installed Sollya/MPFR/GMP libraries.
[Sollya.jl](https://github.com/pc2/Sollya.jl) is an unregistered Git dependency
pinned to a tested commit in `Project.toml`. CPU tests also require a C++20 compiler
(Clang or GCC with native 128-bit integers), plus GMP C++ headers/libraries;
set `CXX` and optionally `GMP_PREFIX` for the package tests. The expected workspace is:

```text
workspace/
├── PRESAGe/          # Project.toml, src/, test/, scripts/, docs/
├── Sollya.jl/        # Optional local numerical dependency for development
├── ac_types/        # Public Algorithmic C headers
└── HLS_arbitrary_Precision_Types/ # Public Xilinx simulation headers
```

From the **PRESAGe repository root**:

```sh
julia --startup-file=no scripts/dev.jl
julia --startup-file=no --threads=4 scripts/check.jl
```

`dev.jl` instantiates the pinned Git dependency and creates an ignored local
manifest. Initial setup needs access to the repository through GitHub SSH;
package registration is not required. `JULIA_PKG_USE_CLI_GIT=true` makes Julia
use the system Git and its existing SSH configuration. For cached setup,
set `JULIA_PKG_OFFLINE=true`. The check script runs package tests offline after
setup. Rerun `dev.jl` when switching Julia versions. For an isolated cache,
prefix commands with `JULIA_DEPOT_PATH=/tmp/presage-depot:`.

To develop Sollya locally, explicitly set `PRESAGE_SOLLYA_PATH`:

```sh
PRESAGE_SOLLYA_PATH=../Sollya.jl julia --startup-file=no scripts/dev.jl
```

This mode uses offline package operations. Julia's `Pkg.develop` changes the
Sollya source in `Project.toml` and the local Manifest to that checkout; keep the
committed Git URL and revision when publishing PRESAGe. Changing `Project.toml`
back to its Git source and rerunning `dev.jl` restores the pinned dependency.

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
bits against the interpreter, including boundary neighbours and special values.
Tracing is disabled by default. `PRESAGE_TRACE=ON` adds checks of the first table
index and every visited fixed node's exact payload. The standalone generator uses
`--trace=true`, and its verifier uses `--trace`. Each evaluator is one
self-contained header containing only required helpers. CMake uses strict floating semantics. Manual
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

## Backend selection

[General LUT and polynomial selection](docs/implementations.md) supports small
fixed/custom floating inputs, arbitrary output formats and bounded expressions.
Compare certified candidates using the same configurable resource profiles,
budgets and priorities; generate the selected C++ evaluator and its decision
report. Wide inputs retain polynomial planning.

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
implementation_cost(lut.plan) # Table bits, assumed block allocation and IR counts.
```

The LUT resolves every entry using adaptive reference enclosures and reproduces
nearest-even rounding for every finite input. Signed zeros and nonfinite inputs
follow the shared primitive policy. `certify_lut(plan)` rechecks every stored
entry and the complete lookup graph. `certified_lut(spec)` is also available for
small fixed/custom floating contracts, mixed output formats and bounded
expressions with established references and finite results in the contract. Failed or unresolved references stop generation.

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

## Log exponent reconstruction

```julia
spec = FunctionSpec("log(x)"; input_format=IEEE16,
    domain=(0,65504), absolute_error=1//64)
config = PolynomialSearchConfig(degrees=[9],
    internal_formats=[FixedFormat(80,24)], transformation=:log,
    evaluation=:fma, job_timeout=60, total_timeout=90)
search = search_polynomial(spec, config)
@assert search.status == :certified
```

The degree describes `log(m)` on `[1,2]`. Exact normalization includes
subnormals. Reconstruction uses the coordinate format, allowing individual
Horner widths to change independently. Its certificate includes coordinate
and stage errors, stored `log(2)` error multiplied by the largest accepted
exponent, reconstruction arithmetic and output conversion. `log(1)` is exact
positive zero; included signed zeros return negative infinity. Positive
infinity returns infinity; invalid or excluded finite inputs return NaN.
This is a uniform absolute bound, without a correct-rounding or ulp guarantee.

```sh
julia --startup-file=no --project=. examples/log_search.jl
```

## Atan reciprocal tails

```julia
spec = FunctionSpec("atan(x)"; input_format=IEEE16,
    domain=(-65504,65504), absolute_error=1//1024)
config = PolynomialSearchConfig(degrees=[15],
    internal_formats=[FixedFormat(72,24)], transformation=:atan,
    evaluation=:fma, job_timeout=60, total_timeout=90)
search = search_polynomial(spec, config)
@assert search.status == :certified
```

The degree is the odd original degree of `r*q(r²)`. An exact input-format
comparison selects `r=|x|` for `|x|≤1`, or a rounded reciprocal for `|x|>1`.
The tail subtracts the kernel from stored `π/2`; sign restoration and signed
zeros are explicit. Infinity limits include constant and output-conversion
error in the global bound. NaNs and excluded finite inputs return NaN.

Reciprocal arithmetic uses native division or official AC division, widening
automatically for the input, output and coordinate precision, with at least
binary64 precision. Individual Horner widths, bounded precision search and
exact replay are supported. Contracts currently require floating interfaces
and a bounded signed interval. The certificate is a uniform absolute bound.

```sh
julia --startup-file=no --project=. examples/atan_search.jl
```

## Exp range reduction

```julia
spec = FunctionSpec("exp(x)"; input_format=IEEE16,
    domain=(-65504,5), absolute_error=1//8)
config = PolynomialSearchConfig(degrees=[9],
    internal_formats=[FixedFormat(72,24)], transformation=:exp,
    evaluation=:fma, job_timeout=60, total_timeout=90)
search = search_polynomial(spec, config)
@assert search.status == :certified
```

The evaluator rounds the stored-reciprocal product to an integer `k`, forms
`r=x-k*stored_log2`, and evaluates `p(r)`. It scales the final Horner value
directly by `2^k` into the output, with one destination quantizer. The proof
establishes the ideal residual lies in `[-1/2,1/2]` and includes the implemented
residual error, every Horner operation and exponent-scaled approximation error.
Possible overflow or an unproved reduced domain refuses certification.

Signed zeros return exact one; positive/negative infinity return infinity/zero.
NaNs and excluded finite inputs return NaN before reduction. Fixed/floating
internals, custom formats, individual widths, certified precision search and
replay are supported. Contracts require floating interfaces and a bounded
interval; the bound is absolute. The example certifies about `0.06250000050`,
below `1/8`.

```sh
julia --startup-file=no --project=. examples/exp_search.jl
```

## Sinh/cosh reconstruction

```julia
spec = FunctionSpec("sinh(x)"; input_format=IEEE16,
    domain=(-23//2,23//2), absolute_error=32)
config = PolynomialSearchConfig(degrees=[9],
    internal_formats=[FixedFormat(72,24)], transformation=:sinh,
    evaluation=:fma, job_timeout=60, total_timeout=90)
search = search_polynomial(spec, config)
@assert search.status == :certified
```

Use `cosh(x)` with `transformation=:cosh` for cosh. Kernel degree d (0:15)
describes central q and reduced exp p; central sinh/cosh degrees are 2d+1 and
2d. Per-coefficient/stage formats apply to both coefficient banks and all three
Horner evaluations. Near zero the evaluator uses an odd/even central polynomial.
At `abs(x)>1`, it combines `2^(k-1)*p(r)` and `2^(-k-1)*p(-r)` before output
rounding. The widened reconstruction supports finite hyperbolic outputs even
when exp(abs(x)) would overflow the output format.

The certificate includes both tail terms, constants, reduction, reconstruction,
branch coverage and output rounding. Sinh preserves zero signs and signed
infinities; cosh returns one for either zero and positive infinity for either
infinity. Excluded finite inputs and NaNs return NaN. Bounded floating interfaces,
fixed/floating internals, individual widths, precision search and replay are
supported. The binary16 example certifies a total absolute bound about 16 against
32 on `[-11.5,11.5]`; output rounding dominates this bound.

```sh
julia --startup-file=no --project=. examples/hyperbolic_search.jl
```

## Scaled erfc tails

```julia
spec = FunctionSpec("erfc(x)"; input_format=IEEE16,
    domain=(-8,8), absolute_error=1//512)
config = PolynomialSearchConfig(degrees=[13],
    internal_formats=[FixedFormat(72,24)], transformation=:erfc,
    evaluation=:fma, job_timeout=60, total_timeout=90)
search = search_polynomial(spec, config)
@assert search.status == :certified
```

The central branch approximates erfc on `[0,1]`. For `a=abs(x)>1`, the tail
approximates `exp(a*a)*erfc(a)` in a normalized coordinate, evaluates reduced
exp and reconstructs with `2^k`. The evaluator uses the two stored polynomials;
the scaled mathematical expression is used during generation and proof.
Negative inputs reconstruct `2-erfc(a)` before output conversion. Both signed
zeros return one; positive/negative infinities return zero/two. NaNs and excluded
finite inputs return NaN before numerical evaluation.

The certificate includes normalization, the rounded square, integer selection,
both stored-polynomial norms, multiplication, exponent scaling, reflection and
output rounding. Coefficient/stage lists apply to all three kernels. Fixed and
floating internals, custom formats, individual widths, precision search and
stored replay are supported. Contracts require bounded floating interfaces and
an absolute target. The binary16 example certifies about `0.0009767814` against
`1/512` on `[-8,8]`; degree thirteen also meets `2^-20` for binary32 interfaces.
Tail coefficients belong to the stored normalization; changing its domain or
coordinate precision can require regenerating them.

```sh
julia --startup-file=no --project=. examples/erfc_search.jl
```

## Bounded sin/cos periodic reduction

```julia
spec = FunctionSpec("sin(x)"; input_format=IEEE16,
    domain=(-32,32), absolute_error=1//512)
config = PolynomialSearchConfig(degrees=[5],
    internal_formats=[FixedFormat(56,8)], transformation=:sin,
    evaluation=:fma, job_timeout=60, total_timeout=90)
search = search_polynomial(spec, config)
@assert search.status == :certified
```

Use `cos(x)` with `transformation=:cos` for cos. The evaluator selects an
integer k, forms `r=x-k*stored(pi/2)` and evaluates `r*q(r²)` or `p(r²)` according
to k modulo four. Stored constants, reduction rounding, both kernels and output
conversion enter the complete absolute-error certificate. The proof establishes
the ideal residual in `[-1,1]`; a failed domain or overflow proof refuses the
candidate. The quadrant and sign operations are exact, including negative k.

Degree d (0:15) describes the parity kernels, whose original degrees are 2d+1
and 2d. Individual coefficient/stage lists apply to both banks and both Horner
graphs. Sin preserves signed zeros; cos returns one. NaNs, infinities and excluded
finite inputs return NaN before reduction. Bounded floating interfaces, fixed or
floating internals, custom formats, precision search and replay are supported.
Large-argument reduction remains a separate multiword design and proof.

```sh
julia --startup-file=no --project=. examples/periodic_search.jl
```

## Asin/acos endpoint transformations

```julia
spec = FunctionSpec("acos(x)"; input_format=IEEE16,
    domain=(-1,1), absolute_error=1//512)
config = PolynomialSearchConfig(degrees=[9],
    internal_formats=[FixedFormat(72,24)], transformation=:acos,
    evaluation=:fma, job_timeout=60, total_timeout=90)
search = search_polynomial(spec, config)
@assert search.status == :certified
```

Use `asin(x)` with `transformation=:asin` for asin. At `|x|≤1/2`, a shared
odd polynomial approximates asin. Elsewhere, exact widened arithmetic forms
`t=(1-|x|)/2`; an exponent-split polynomial evaluates sqrt(t), and the same
asin kernel evaluates the reduced argument. Acos uses `2*asin(sqrt(t))` near
+1 and `pi-2*asin(sqrt(t))` near -1. Asin reconstructs from stored pi/2 and
restores the sign. Both kernel errors, every cast and reconstruction rounding
enter the complete absolute bound.

Degree d (0:32) describes the sqrt polynomial and the asin parity polynomial
q, whose original degree is 2d+1. Individual coefficient/stage lists apply to
both banks and both Horner graphs. Floating interfaces, fixed/floating internals,
custom formats, bounded precision search and replay are supported. Contracts
must specify an interval inside `[-1,1]`. NaNs, infinities and excluded finite
inputs return NaN before kernel evaluation. Endpoints and zeros are lazy;
asin preserves zero signs and acos(+1) is exact zero. Stored pi limits and
acos(0) include constant and output-conversion error.

```sh
julia --startup-file=no --project=. examples/inverse_trig_search.jl
```

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
