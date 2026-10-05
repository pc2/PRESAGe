# Local verification

Verified on 5 October 2026 on macOS, Apple Silicon, using the sibling Sollya.jl
0.1.0 checkout and installed Sollya 8.0 (Homebrew `8.0_3`). CPU evaluators use
LLVM/Clang 23.1.2; the CMake workflow uses CMake 4.4.3. Direct primitive checks
use each Julia installation's own MPFR/GMP runtime.

## Results

The standard `Pkg.test` suite, through the offline `scripts/check.jl` runner,
passes **161,034 checks on both Julia 1.10.12 and Julia 1.13.1**, with four
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
| Fixed CPU conformance | 37 | Exact IEEE32/64 conversions; native/GMP products, sums and FMA; directed rounding; actual wrap/saturate/reject cases; classification evaluation; scale extremes; binary64 subnormal/midpoint conversions. Every visited fixed payload is checked. |
| Fixed I/O contracts, execution and references | 25,143 | Fixed/mixed schema v4 round trips; exhaustive small input words against exact affine mathematics under every output policy; domain guards; exact-input precision limits; 512 fixed erf inputs through Sollya/MPFR; explicit domain/pole/overflow failures; wrap enclosure aliasing and enormous exponents. |
| Fixed I/O binary streams and commands | 46 | Both byte orders; 9/137-bit fixed words; padding/word metadata; CLI mixed widths; rejection of invalid padding, truncated words and nonfinite/overflow references without publishing binary output. |
| Fixed I/O CPU conformance | 78 | All three backends; exhaustive small fixed interfaces; signed/unsigned widths through 137 bits; raw and typed public APIs; pure fixed execution with FE_DOWNWARD; output policies; mixed interfaces; guarded domains; invalid padding even with unused input; empty/truncated streams; fixed tables and index traces. |
| Native vendor fixed arithmetic | 48 | Both `ap_fixed` and `ac_fixed` compiled with ordinary LLVM C++20; 16,384 matrix cases per library; mixed signedness/scales; all rounding modes, wrap/saturation and rejection after rounding; every visited fixed payload; 31/80-bit separate/FMA erf; finite IEEE32/64 range and lazy specials; scaling and width limits. |
| Uniform fixed erf certificates | 2,346 | Every fixed node's range; complete graph audit; uniform error contributions/tails; CPU bits/rows; sampled MPFR checks against the certified bound; rejected graph/metadata changes; width-search failure; wide separate/FMA certificates. |
| Certified generation commands | 26 | Default certified generation, stored-plan recertification, identical emission, both native backends with identical numerical plans, explicit search-limit reports, preserved valid outputs after failure, stale-report removal, option validation; fixed-interface candidates and refusal of unsupported certification. |

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

Compiled output bits, table selections, fixed-node visitation and exact fixed
payloads match the interpreter on **2,107 inputs** for the default fixed graph
with each of `portable`, `ap_fixed` and `ac_fixed`. Directed/special cases and
wide fixed designs have additional checks. Both separate Mul/Add and FMA graphs
with 80 fractional bits pass uniform certification and all three CPU backends.
Supnorm failure
has no sampled fallback; changes to branch thresholds or stored coefficients
are rejected by the graph audit. A deliberately inadequate degree/width choice
returns `bound_exceeds_budget`, and an exhausted search returns `search_limit`.

The `cpu-macos-ac` and `cpu-macos-ap` presets generate the fixed plan and numerical
report, compile with native library headers, GMP and strict floating semantics,
and pass CTest. Fresh root builds default to `ac_fixed`. Re-emission
from a stored plan reruns its certificate and produces identical C++ files.

## Public fixed libraries

The workspace has local checkouts of [Algorithmic C types](https://github.com/hlslibs/ac_types)
(headers report 5.1.1) and [Xilinx arbitrary precision simulation types](https://github.com/Xilinx/HLS_arbitrary_Precision_Types).
Both use Apache 2.0. No vendor toolchain or FPGA is needed for these tests.
Library quantizers implement nearest-even, toward-zero and downward rounding;
upward rounding and reject overflow are explicit native adapters. Native fixed
arithmetic and stored bits are tested against the exact Julia interpreter.
GMP supplies the host IEEE output bridge, rather than native fixed evaluation.

Xilinx's public scalar types compile with LLVM/libc++ after suppressing their
unused, conflicting legacy `std::complex` specializations. Upstream files remain
unchanged. This repository supplies simulation code and excludes synthesis
support. These checks establish local conformance for the tested public headers;
installed HLS headers and generated synthesis code require their own gate.

## Fixed interfaces

Contracts, IR input/output, the exact interpreter, oracle, streams and C++ now
support independent float/fixed input and output formats. Signed and unsigned
words are tested at widths 1, 7, 64, 65 and 137 in the portable, `ap_fixed` and
`ac_fixed` backends. Fixed affine kernels exhaust 9-bit inputs. Public typed and
raw APIs match the interpreter, including arithmetic under host `FE_DOWNWARD`
for pure fixed graphs. Domain rejection is lazy, and width validation executes
even when the graph does not use the input.

The [fixed polynomial example](../examples/fixed_polynomial.jl) was generated,
compiled through CMake and checked through CTest with both vendor backends.
Each build matches output bits and fixed intermediates on all **512 inputs**.
These are exact/exhaustive conformance checks for selected kernels. The uniform
Sollya evaluator certificate still covers the canonical IEEE32 erf graph;
generic fixed-interface polynomial certification remains separate work.

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

JULIA_DEPOT_PATH=/tmp/presage-depot: JULIA_PKG_SERVER='' PRESAGE_REQUIRE_VENDOR_TESTS=true \
  julia --startup-file=no --threads=4 scripts/check.jl
```

Select the desired installed Julia executable and rerun `dev.jl` before testing
a different version. The ignored local manifest is version-specific. The
bootstrap and check runner use a temporary empty local registry to avoid Julia
1.10's default-registry fetch in an empty depot. Successful verification runs
resolve only standard libraries and the local development dependency.

After bootstrap, with LLVM/Clang and CMake installed:

```sh
JULIA_DEPOT_PATH=/tmp/presage-depot: cmake --preset cpu-macos-ac
JULIA_DEPOT_PATH=/tmp/presage-depot: cmake --build --preset cpu-macos-ac
JULIA_DEPOT_PATH=/tmp/presage-depot: ctest --preset cpu-macos-ac

JULIA_DEPOT_PATH=/tmp/presage-depot: cmake --preset cpu-macos-ap
JULIA_DEPOT_PATH=/tmp/presage-depot: cmake --build --preset cpu-macos-ap
JULIA_DEPOT_PATH=/tmp/presage-depot: ctest --preset cpu-macos-ap
```

The package CPU tests compile with `-ffp-contract=off -fno-fast-math
-frounding-math` and C++20. Fixed verification also uses GMP C++ development
headers/libraries. Set `CXX` and optionally `GMP_PREFIX` for another installation.
Supply sibling header checkouts, or `PRESAGE_AP_INCLUDE_DIR` and
`PRESAGE_AC_INCLUDE_DIR`. The required-vendor flag rejects missing dependencies;
without it, unavailable vendor test groups are explicitly skipped.

## Limits

Uniform certification currently covers the canonical fixed IEEE32 erf graph.
Floating candidates and other functions do not have complete evaluator
certificates. The [compact contract](../examples/erf-contract.toml) remains
unchanged; schema v3 stores internal fixed programs and v4 adds fixed interfaces;
a separate report records the
numerical proof. Floating CPU arithmetic supports binary32/binary64 with
nearest-even rounding; fixed helpers also support directed conversions.
Binary16 **encoding and rounding** were exhausted; binary16 transcendental
functions were not. Near-zero ulp and correct-rounding claims are not established.
Sollya and direct MPFR checks share MPFR algorithms, so their agreement is not
fully independent evidence. Linux, installed vendor toolchains, synthesis and FPGA
performance were not tested. These are separate later gates in the plan.
