# Local verification

Verified on 6 October 2026 on macOS, Apple Silicon, using the sibling Sollya.jl
0.1.0 checkout and installed Sollya 8.0 (Homebrew `8.0_3`). CPU evaluators use
LLVM/Clang 23.1.2; the CMake workflow uses CMake 4.4.3. Direct primitive checks
use each Julia installation's own MPFR/GMP runtime.

## Results

The standard `Pkg.test` suite, through the offline `scripts/check.jl` runner,
passes **794,355 checks on Julia 1.13.1**, with four
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
| Binary16 CPU interfaces and conversions | 7 | All 65,536 raw words and float/double round trips; raw/typed APIs; subnormal, binade and overflow midpoint neighbours; truncation; explicit refusal of half arithmetic nodes. |
| Binary16 fixed bridges | 6 | Complete signed finite half range through exact fixed internals in all three backends; lazy rejection of nonfinites; nearest-even and directed half output at subnormal/normal/overflow ties. |
| Binary16 implementation selection and exhaustive certificates | 196,653 | LUT threshold boundaries and overrides, stored-entry/graph audits, unresolved references and infeasible budgets; all half encodings checked against MPFR for LUT and separate/FMA polynomials, then compiled through all three C++ backends with exact node/table traces. |
| Fresh erf candidate | 2,125 | Exact stored coefficients; bit/table conformance; boundary rows and neighbours; special branches; enclosed sampled accuracy; IEEE32 internal FMA variant conformance. |
| Exact fixed arithmetic | 1,568 | Exhaustive small-format encoding round trips and widened arithmetic; signed/unsigned quantization; ties; all rounding/overflow policies; huge scaling; arbitrary-width schema v3 words. |
| Fixed CPU conformance | 37 | Exact IEEE32/64 conversions; native/GMP products, sums and FMA; directed rounding; actual wrap/saturate/reject cases; classification evaluation; scale extremes; binary64 subnormal/midpoint conversions. Every visited fixed payload is checked. |
| Fixed I/O contracts, execution and references | 25,143 | Fixed/mixed schema v4 round trips; exhaustive small input words against exact affine mathematics under every output policy; domain guards; exact-input precision limits; 512 fixed erf inputs through Sollya/MPFR; explicit domain/pole/overflow failures; wrap enclosure aliasing and enormous exponents. |
| Fixed I/O binary streams and commands | 46 | Both byte orders; 9/137-bit fixed words; padding/word metadata; CLI mixed widths; rejection of invalid padding, truncated words and nonfinite/overflow references without publishing binary output. |
| Fixed I/O CPU conformance | 78 | All three backends; exhaustive small fixed interfaces; signed/unsigned widths through 137 bits; raw and typed public APIs; pure fixed execution with FE_DOWNWARD; output policies; mixed interfaces; guarded domains; invalid padding even with unused input; empty/truncated streams; fixed tables and index traces. |
| Native vendor fixed arithmetic | 48 | Both `ap_fixed` and `ac_fixed` compiled with ordinary LLVM C++20; 16,384 matrix cases per library; mixed signedness/scales; all rounding modes, wrap/saturation and rejection after rounding; every visited fixed payload; 31/80-bit separate/FMA erf; finite IEEE32/64 range and lazy specials; scaling and width limits. |
| Wide floating core | 148 | Automatic UInt64/BigInt storage; binary128/256 and custom fractions; exact rounding, subnormal/overflow ties, signed zeros, extreme scaling, wide dispatch/schema words, both byte orders and non-byte-aligned streams; adaptive 301-bit MPFR references and explicit backend/precision limits. |
| Official AC floating arithmetic | 98 | Binary32/128/256, bfloat16, 300-bit fractions and exhaustive small formats through native AC Add/Mul/FMA; conversions, scaling, wide bit operations/tables, raw/typed APIs, padding, 5000-bit raw payloads; 448 mixed fixed/float cases per portable/AC/AP backend with directed rounding, wrap/saturation and rejection. |
| Uniform fixed erf certificates | 2,346 | Every fixed node's range; complete graph audit; uniform error contributions/tails; CPU bits/rows; sampled MPFR checks against the certified bound; rejected graph/metadata changes; width-search failure; wide separate/FMA certificates. |
| Uniform fixed polynomial certificates | 11,222 | Exhaustive bounded erf/exp in separate/FMA modes against mathematical enclosures and all three C++ backends; every visited fixed node's certified range; exact affine and constant kernels, coarse coordinates and amplification, inward/clipped/singleton domains, unsigned/wide formats, changed coefficients/graphs, overflow, singularities and schema v2 reports. |
| Exact expression certification regressions | 52 | Decimal/scientific and rational expression equivalence in references and certification; exact affine errors, changed coefficients and budget failures. |
| Uniform floating polynomial certificates | 411,962 | Uniform bounds for float/fixed interfaces and internals; 0/4/8 guard bits; exhaustive binary16 erf/exp and small-format quantization/cancellation; exact node ranges and native AC CPU bits; binary64/128/256 and custom wide formats; subnormal/overflow ties, lazy guards, signed-zero coefficients, graph audits and schema v2 reports. |
| Generated bounded polynomial certificates | 12,752 | Coefficient generation and complete certification through one API for fixed/floating erf, exp and nonsymmetric composition; exhaustive small fixed/custom inputs, exact node ranges, lazy guards, official-header CPU conformance, artifact round trips and fresh proof. |
| Bounded generation contracts and failures | 387 | Exact constants/affine functions, decimal/rational equivalence, singleton/clipped/empty domains, all small floating words through a clipped guard and C++, extreme exponent metadata, precision/policy validation, coefficient range/subnormal failures, native failures, arithmetic/output overflow, retained over-budget candidates and ambient settings. |
| Certified generation commands | 32 | Default certified generation, stored-plan recertification, identical emission, both native backends with identical numerical plans, explicit search-limit reports, preserved valid outputs after failure, stale-report removal and option validation; automatic fixed polynomial proofs with or without a kernel label, standalone recertification and unsupported graphs. |
| Custom floating generation options | 7 | Automatic certification and AC selection for stored binary128 plans, explicit binary32 AC selection, no floating-only GMP dependency, unsupported native mapping/option diagnostics and preservation of generated output on failure. |
| Binary16 generation and implementation policy | 21 | Automatic and explicit LUT/polynomial selection; exact budgets and half interfaces; stored LUT recertification/identical emission; FMA and unchecked polynomial generation; preserved outputs on failed proofs and invalid options. |

The custom floating CMake/CTest build passes with binary128 interfaces, a
custom 160-fraction-bit internal format and fused polynomial arithmetic,
without GMP linkage. A separate build passes with binary32 AC interfaces and
AP fixed arithmetic for the certified erf graph. Header simulation is verified
locally; oneAPI compilation/synthesis remains a separate gate. Floating polynomial
certificates are now supported as described below. The existing fixed and
binary16 certificate bounds are unchanged.

In particular, `exp` at IEEE32 input `0xc2af0001` resolves to output
**`0x006cb285`** through both backends at 256 bits. Exact rational midpoint
cases round to even; `erf` preserves both IEEE zero signs and maps infinities
to ±1. A deliberately insufficient precision limit returns `unresolved` with
no output bits and no published partial binary file.

The standalone CLI and the `analysis/eval/golden.jl` forwarding entry point
were also executed on a three-word input with chunk size two. Their outputs
agreed exactly, with valid completion manifests and a correctly handled final
one-word chunk. No legacy evaluator or historical comparison data were used.

## Binary16 implementation results

Both LUT and fixed-polynomial erf implementations meet the default absolute
target `2^-10`. Every one of the 65,536 input encodings is checked, including
signed zeros, subnormals, infinities and NaNs. Portable, ac_fixed and ap_fixed
C++ match interpreter output bits and table choices; polynomial checks also
compare every visited fixed payload. Separate/FMA polynomials have uniform
Sollya/rational certificates and exhaustive direct MPFR enclosure checks.

| Implementation | Logical table bits | Static reads | Arithmetic | Uniform absolute bound | Exhaustive enclosed maximum |
| --- | ---: | ---: | --- | ---: | ---: |
| Full LUT | 1,048,576 | 1 | None | `2.440093e-4` | `2.440093e-4` |
| Fixed polynomial, separate | 852 | 11 | 9 multiplies, 10 adds | `4.954173e-4` | `2.460683e-4` |
| Fixed polynomial, FMA | 852 | 11 | 9 FMAs, 1 add | `4.954173e-4` | `2.460683e-4` |

Every LUT entry matches a resolved nearest-even reference. Its maximum error
enclosure is uniform over the complete finite format; this is exhaustive
evidence, not a sampled maximum. Changed entries or lookup graphs cannot inherit
the certificate. Unresolved references abort table generation. The LUT's
sixteen-bit C++ storage occupies 128 KiB and works under host `FE_DOWNWARD`.
The static costs above describe the IR, rather than device resources or timing.

`ImplementationModel(lut_max_bits=1048576)` selects the LUT at the default
threshold. A threshold below that table size selects a fixed polynomial;
explicit selection overrides the threshold. This arbitrary policy awaits
synthesis calibration. The existing IEEE32 default remains polynomial.

The standalone generator produced `build/half-lut` and `build/half-poly`.
Stored plans were recertified, compiled through CMake, and checked by CTest in
`build/half-lut-ac` and `build/half-poly-ap`. Both pass on all 65,536 encodings.

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
These are exact/exhaustive conformance checks for selected kernels. The affine
example now also has a zero-error numerical certificate.

## Bounded fixed polynomial certificates

Degree-nine erf and exp kernels use fixed input/output on `[-1,1]`, with
`Fixed(9,3)` input, `Fixed(32,6)` internals and `Fixed(24,4)` output. Separate
multiply/add and FMA are both certified and compiled through all three CPU
backends. Every one of the **129 accepted inputs** is checked against a direct
MPFR mathematical enclosure; every visited fixed node is inside its certified
range. The interpreter rejects all remaining input words.

| Kernel | Uniform absolute bound | Exhaustive enclosed maximum |
| --- | ---: | ---: |
| erf, separate and FMA | `1.082233e-6` | `9.252514e-7` |
| exp, separate and FMA | `5.519426e-7` | `4.834759e-7` |

Both bounds meet `2^-18`. The proof checks the entire graph and actual stored
coefficients, input conversion, each arithmetic quantizer, final rounding and
possible overflow. Additional exhaustive cases cover exact affine arithmetic,
coarse internal input conversion, domains larger than one, unsigned formats,
inward/clipped/singleton domains and constants. A tie regression distinguishes
separate multiplication/addition from FMA. Constant kernels with unused narrow
input conversions remain exact and pass all three CPU backends. Wide 137-bit
inputs are certified without enumeration. Changed operations/guards, rounding
and overflow policies outside the supported scope, output overflow and singular
function domains are explicitly refused.

The [bounded example](../examples/bounded_polynomial.jl) was executed locally.
Its stored exp plan was then regenerated with certification, compiled and
checked through CMake/CTest in `build/bounded-demo-ac` and
`build/bounded-demo-ap`. Both builds pass CTest on all 129 accepted inputs,
including output words, fixed-node visitation and exact payloads. Sollya.jl is
unchanged.

## Bounded candidate generation

`certified_polynomial` generates and certifies erf, exp and the nonsymmetric
composition `exp(x)+0.1*x` on `[-1,1]` without supplied coefficients. The generated
fixtures use `Fixed(9,3)` inputs and a `2^-18` absolute target, with either
degree-nine `Fixed(32,6)` internals and `Fixed(24,4)` outputs, or degree-thirteen
`Float(8,27)` internals and binary32 outputs. Both separate and fused arithmetic
pass mathematical-enclosure checks and certified node ranges on all 129 accepted
inputs. The remaining fixed words exercise the lazy domain guards. Composed
kernels also pass ordinary C++ conformance through portable, AC and AP fixed
backends, and official AC floating arithmetic.

Small `Float(3,4)` input fixtures exhaust all 256 words with fixed or binary16
output, including specials and excluded inputs. Regression cases cover exact
constants/affine functions, decimal/rational equivalence, clipped and empty
domains, singleton point candidates, signed-zero guard thresholds, extreme
exponent metadata on compact domains, coefficient storage failures, arithmetic
and output overflow, insufficient budgets and ambient BigFloat settings.
Selected plans survive serialization and fresh certification with the same bound.

The updated [bounded example](../examples/bounded_polynomial.jl) generates these
separate fixed candidates locally:

| Kernel | Uniform absolute bound |
| --- | ---: |
| erf | `1.082233e-6` |
| exp | `5.519426e-7` |
| exp + x/10 | `5.579087e-7` |

The first two preserve the existing example's bounds. The composed-function
mathematical references use Sollya and share the certificate's numerical
dependency; primitive checks use directed MPFR. Generation is one synchronous
attempt. Ordered search, worker timeout/recovery and a contract-driven generation
CLI remain subsequent work.

## Floating polynomial certificates

Degree-thirteen erf and exp kernels on `[-1,1]` have uniform certificates with
binary32 interfaces and floating internals. The coefficients are generated with
32 significand bits, then rounded to each selected internal format. FMA results:

| Kernel | 0 extra fraction bits | 4 extra fraction bits | 8 extra fraction bits |
| --- | ---: | ---: | ---: |
| erf | `2.450315e-7` | `7.271769e-8` | `6.096999e-8` |
| exp | `2.243066e-7` | `1.332194e-7` | `1.200629e-7` |

All meet the test contract `2^-21`. Separate multiply/add paths are also proved;
their arithmetic error allowances decrease with added precision. For extra
internal precision, final binary32 narrowing contributes at most `2^-24` for
erf and `2^-23` for exp on these ranges. With binary32 internals there is no
separate conversion: final operation rounding is part of the arithmetic bound.

The tests exhaust all 65,536 binary16 encodings for both bounded functions with
four extra internal fraction bits. Accepted inputs are compared against MPFR
mathematical enclosures and every visited numerical range; excluded inputs
return NaN without evaluating the polynomial. Generated AC C++ agrees with the
interpreter on all encodings. Smaller custom formats and mixed fixed/floating
interfaces are exhausted for conversion error, subnormal ties, cancellation and
domains larger than one. Binary64/128/256 and 160-fraction-bit formats have
uniform proofs and boundary/random CPU checks. Exact identities have zero
error certificates. Signed-zero coefficient payloads survive graph auditing.
Overflow, invalid arithmetic/guards, insufficient error budgets and singular
function domains produce explicit failure outcomes.

The [floating example](../examples/floating_polynomial.jl) also compares fixed
and floating internals against identical binary32 contracts using FMA:

| Kernel | Fixed(36,6) internals | Float(8,27) internals |
| --- | ---: | ---: |
| erf | `6.801771e-8` | `7.271769e-8` |
| exp | `1.273349e-7` | `1.332194e-7` |

The stored exp floating plan was regenerated with certification and compiled
through CMake/CTest in `build/floating-certified-cmake`. CTest passes against
the exact interpreter; the floating-only executable has no GMP linkage.
Coefficients and stages still share one internal format. Precision search,
individual widths and segmented floating certification remain later work.

## Segmented floating candidate checks

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
bootstrap and check runner use Julia 1.13's offline package mode, including
with an empty depot. Successful verification runs resolve only standard
libraries and the local development dependency.

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

Uniform certification covers complete binary16 LUTs, canonical fixed binary16/IEEE32 erf graphs and supported
degree 0–32 float/fixed polynomial kernels with nearest-even rounding and
rejected fixed overflow, including mixed interfaces and custom formats.
Segmented floating erf and general transformations remain outside the
certificates. The [compact contract](../examples/erf-contract.toml) remains
unchanged; schema v3 stores internal fixed programs and v4 adds fixed interfaces;
a separate report records the
numerical proof. Native floating CPU arithmetic supports binary32/binary64 with
nearest-even rounding; official AC arithmetic supports custom and wide formats.
Binary16 interfaces and exact conversions are supported,
and fixed helpers also support directed conversions. Binary16 erf is exhausted
for both implementation choices. Polynomial kernels have no near-zero ulp or
correct-rounding guarantee; binary16 LUTs reproduce resolved nearest-even outputs.
Sollya and direct MPFR checks share MPFR algorithms, so their agreement is not
fully independent evidence. Linux, installed vendor toolchains, synthesis and FPGA
performance were not tested. These are separate later gates in the plan.
