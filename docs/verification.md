# Local verification

Verified on 5 October 2026 on macOS, Apple Silicon, using the sibling Sollya.jl
0.1.0 checkout and installed Sollya 8.0 (Homebrew `8.0_3`). CPU evaluators use
LLVM/Clang 23.1.2; the CMake workflow uses CMake 4.4.3. Direct primitive checks
use each Julia installation's own MPFR/GMP runtime.

## Results

The standard `Pkg.test` suite, through the offline `scripts/check.jl` runner,
passes **135,707 checks on both Julia 1.10.12 and Julia 1.13.1**, with four
threads. The count is dominated by exhaustive encoding checks, not by function
coverage or numerical certificates.

| Group | Checks | Coverage |
| --- | ---: | --- |
| Exact IEEE encodings and rounding | 129,326 | Every binary16 encoding against host decoding; exact round trips; signed zero; normal/subnormal ties; binade and overflow transitions; directed rounding; small custom-format midpoints; extreme native exponents. |
| Contract and exact artifacts | 27 | Compact IEEE32 erf contract; default and distinct output formats; custom formats; candidate threshold bits; 2000-bit rational coefficients; round trips; invalid formats/domains; unsupported schema versions and certification claims. |
| Adaptive references | 138 | Sollya/MPFR primitive agreement on selected inputs; subnormal exp; primitive domain/special values; composed functions; irrational constants/coefficients; exact rational ties; bounded refinement; unresolved and evaluation-failure outcomes; concurrent MPFR calls. |
| Bounded streams | 40 | Both byte orders; partial final chunks; truncated words; empty files; output refusal; format metadata; failure records; no final binary on unresolved results. |
| Reference command | 8 | Primitive names and constant expressions; both backends; option validation. |
| Typed IR and exact execution | 60 | Graph/type validation; binary16/32/64 and custom floating arithmetic; separate/FMA cancellation; signed zeros; directed conversion; underflow; extreme scaling; lazy branches; schema v2 round trips. |
| Portable CPU conformance | 18 | Compiled binary32/64 Mul/Add/FMA; bounded nonsymmetric kernels; mixed formats; bit operations; tables; inward domain thresholds; skipped invalid lookups. Each conformance assertion checks multiple input words. |
| Fresh erf candidate | 2,125 | Exact stored coefficients; bit/table conformance; boundary rows and neighbours; special branches; enclosed sampled accuracy; IEEE32 internal FMA variant conformance. |
| Exact fixed arithmetic | 1,568 | Exhaustive small-format encoding round trips and widened arithmetic; signed/unsigned quantization; ties; all rounding/overflow policies; huge scaling; arbitrary-width schema v3 words. |
| Fixed CPU conformance | 37 | Exact IEEE32/64 conversions; native/GMP products, sums and FMA; directed rounding; actual wrap/saturate/reject cases; classification evaluation; scale extremes; binary64 subnormal/midpoint conversions. |
| Uniform fixed erf certificates | 2,346 | Every fixed node's range; complete graph audit; uniform error contributions/tails; CPU bits/rows; sampled MPFR checks against the certified bound; rejected graph/metadata changes; width-search failure; wide separate/FMA certificates. |
| Certified generation commands | 14 | Default certified generation, stored-plan recertification, identical emission, explicit search-limit reports, preserved valid outputs after failure, stale-report removal, option validation. |

In particular, `exp` at IEEE32 input `0xc2af0001` resolves to output
**`0x006cb285`** through both backends at 256 bits. Exact rational midpoint
cases round to even; `erf` preserves both IEEE zero signs and maps infinities
to ±1. A deliberately insufficient precision limit returns `unresolved` with
no output bits and no published partial binary file.

The standalone CLI and the `analysis/eval/golden.jl` forwarding entry point
were also executed on a three-word input with chunk size two. Their outputs
agreed exactly, with valid completion manifests and a correctly handled final
one-word chunk. No legacy evaluator or historical comparison data were used.

## Uniform fixed evaluator result

The default generated evaluator uses IEEE32 input/output, degree nine, four
segments on `[0,4]`, 31 fractional bits and exact range-based stage widths.
Sollya certifies the stored polynomials; exact rational propagation covers
coordinate and evaluator quantization, every fixed intermediate and final IEEE
rounding. The uniform total absolute bound is approximately **`6.321e-8`**,
below **`2^-23`**. The constant-tail bound is approximately **`1.542e-8`**.
These bounds cover every finite input, including negative inputs and zeros.
See [the proof method and contributions](certification.md).

Compiled bits and table selections match the interpreter on **2,107 inputs**
for the default fixed graph. Directed/special cases and wide fixed designs have
additional conformance checks. Both separate Mul/Add and FMA graphs with 80
fractional bits pass uniform certification and CPU conformance. Supnorm failure
has no sampled fallback; changes to branch thresholds or stored coefficients
are rejected by the graph audit. A deliberately inadequate degree/width choice
returns `bound_exceeds_budget`, and an exhausted search returns `search_limit`.

The root `cpu-macos` preset generates the fixed plan and numerical report,
compiles with GMP and strict floating semantics, and passes CTest. Re-emission
from a stored plan reruns its certificate and produces identical C++ files.

## Floating candidate checks

The floating `erf_candidate()` uses degree nine, four segments on
`[0,4]`, IEEE64 internal arithmetic and separate multiply/add operations. Its
compiled output bits and table selections agree with the exact interpreter on
**2,107 inputs**, including raw-bit samples, zeros, infinities, NaNs, segment
boundaries and their neighbours. The largest enclosed absolute-error bound
over the finite sample is approximately **`3.135e-8`**, below the contract
`2^-23` (approximately `1.192e-7`). This is sampled evidence; it is not a uniform
certificate or a near-zero ulp guarantee.

The additional IEEE32-internal FMA candidate is checked for CPU conformance;
its accuracy target is not asserted.

## Reproduce

From the PRESAGe repository root, with native libraries installed:

```sh
JULIA_DEPOT_PATH=/tmp/presage-depot: JULIA_PKG_SERVER='' \
  julia --startup-file=no scripts/dev.jl

JULIA_DEPOT_PATH=/tmp/presage-depot: JULIA_PKG_SERVER='' \
  julia --startup-file=no --threads=4 scripts/check.jl
```

Select the desired installed Julia executable and rerun `dev.jl` before testing
a different version. The ignored local manifest is version-specific. The
bootstrap and check runner use a temporary empty local registry to avoid Julia
1.10's default-registry fetch in an empty depot. Successful verification runs
resolve only standard libraries and the local development dependency.

After bootstrap, with LLVM/Clang and CMake installed:

```sh
JULIA_DEPOT_PATH=/tmp/presage-depot: cmake --preset cpu-macos
JULIA_DEPOT_PATH=/tmp/presage-depot: cmake --build --preset cpu-macos
JULIA_DEPOT_PATH=/tmp/presage-depot: ctest --preset cpu-macos
```

The package CPU tests compile with `-ffp-contract=off -fno-fast-math
-frounding-math` and C++20. Fixed verification also uses GMP C++ development
headers/libraries. Set `CXX` and optionally `GMP_PREFIX` for another installation.

## Limits

Uniform certification currently covers the canonical fixed IEEE32 erf graph.
Floating candidates and other functions do not have complete evaluator
certificates. The [compact contract](../examples/erf-contract.toml) remains
unchanged; schema v3 stores fixed programs, and a separate report records the
numerical proof. Floating CPU arithmetic supports binary32/binary64 with
nearest-even rounding; fixed helpers also support directed conversions.
Binary16 **encoding and rounding** were exhausted; binary16 transcendental
functions were not. Near-zero ulp and correct-rounding claims are not established.
Sollya and direct MPFR checks share MPFR algorithms, so their agreement is not
fully independent evidence. Linux, vendor arithmetic, synthesis and FPGA
performance were not tested. These are separate later gates in the plan.
