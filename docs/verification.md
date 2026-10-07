# Local verification

Verified on 7 October 2026 on macOS, Apple Silicon, using the sibling Sollya.jl
0.1.0 checkout and installed Sollya 8.0 (Homebrew `8.0_3`). CPU evaluators use
LLVM/Clang 23.1.2; the CMake workflow uses CMake 4.4.3. Direct primitive checks
use each Julia installation's own MPFR/GMP runtime.

## Results

All **50 test groups are verified: 1,487,066 checks on Julia 1.13.1**, with four
threads and vendor-header tests required. The offline `scripts/check.jl` runner
passed 28 groups before cold worker jobs exceeded an eight-second fixture budget.
After increasing those fixture budgets to 30 seconds, a fresh process passed the
remaining 22 groups against the same implementation. Deadline, kill/reap and
saved-certificate rejection checks remain enforced. The four odd-kernel groups
contribute 217,761 checks. Formatting is clean. The count is dominated by
exhaustive encoding checks, not by function coverage or numerical certificates.

| Group | Checks | Coverage |
| --- | ---: | --- |
| Exact IEEE encodings and rounding | 129,326 | Every binary16 encoding against host decoding; exact round trips; signed zero; normal/subnormal ties; binade and overflow transitions; directed rounding; small custom-format midpoints; extreme native exponents. |
| Contract and exact artifacts | 27 | Compact IEEE32 erf contract; default and distinct output formats; custom formats; candidate threshold bits; 2000-bit rational coefficients; round trips; invalid formats/domains; unsupported schema versions and certification claims. |
| Search configuration artifacts | 39 | Exact choice/settings/limit round trips for fixed, custom and wide formats; defaults; rejected schemas, versions, orders, unknown fields and invalid types. |
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
| Ordered bounded polynomial search | 53 | Caller degree/format order, first-certified selection, higher degree and internal precision, fixed integer/floating exponent constraints, exact report replay and recertification, retained budget/range failures, attempt/choice exhaustion and wide coefficient payloads. |
| Search request validation | 40 | Finite distinct choices, degree/policy/numerical/time limits, validation before worker launch and immutable choice snapshots. |
| Isolated numerical worker supervision | 102 | Controlled timeout/crash/malformed/missing/exception replies, checkpoint retention, replacement workers, process/file cleanup, total/startup deadlines, empty histories, rejection of late completed results and parent exception cleanup. |
| Certified generation commands | 32 | Default certified generation, stored-plan recertification, identical emission, both native backends with identical numerical plans, explicit search-limit reports, preserved valid outputs after failure, stale-report removal and option validation; automatic fixed polynomial proofs with or without a kernel label, standalone recertification and unsupported graphs. |
| Custom floating generation options | 7 | Automatic certification and AC selection for stored binary128 plans, explicit binary32 AC selection, no floating-only GMP dependency, unsupported native mapping/option diagnostics and preservation of generated output on failure. |
| Binary16 generation and implementation policy | 21 | Automatic and explicit LUT/polynomial selection; exact budgets and half interfaces; stored LUT recertification/identical emission; FMA and unchecked polynomial generation; preserved outputs on failed proofs and invalid options. |
| Bounded generation CLI and artifact replay | 823 | Actual CLI subprocess from contract/config files, four-attempt selection, exact report/plan/certificate agreement, replay without search, fixed mathematical enclosures and compiled portable/AC/AP output files; numeric/emission/publication failures, preserved valid artifacts, invalid options and stale-report cleanup. |
| Bounded generation floating and exact expressions | 165,739 | Matching decimal/scientific and rational binary32 programs/bounds, deterministic boundaries/interior samples and official AC floating C++; all small custom words including output subnormal ties; all binary16 words against MPFR, lazy guards and compiled official AC fixed arithmetic. |
| Generation artifact publication recovery | 10 | Controlled failure during replacement restores every managed file, preserves unrelated files and removes staging data; successful replacement and obstructed destinations. |
| Normalized segmentation and complete certificates | 10,794 | Fixed/floating separate/FMA exp, exhaustive small interfaces, mathematical enclosures and every reachable node range, official AC/AP CPU conformance, exact artifacts and fresh certificates. |
| Rounded coordinates, scaling and empty branches | 2,000 | Coarse conversion and coordinate overshoot, exact scaling down, singleton rows, lazy guards, overflow refusal, segment limits and empty-branch rejection before worker launch. |
| Segmented graph and table audit | 32 | Rejected changes to comparisons, thresholds, indices, every centre/coefficient entry, table layout, scale, arithmetic, metadata and guards; matching changed coefficients require a fresh norm proof. |
| Segment boundaries and exhaustive binary16 | 285,949 | Nonrepresentable binary32 endpoints and boundary neighbours, signed zeros, all 64 rows, every binary16 encoding against MPFR and portable/AC/AP C++ with lazy outside-domain behavior. |
| Segment choices, CLI and replay | 1,304 | Exact version 2 configuration round trips and validation, single-polynomial budget failure followed by segmented success, compiled CLI output and identical stored-plan replay. |
| Individual precision formats and exact artifacts | 30 | Immutable format lists, wide floating storage, exact schema v5 replay, independent interfaces, kernel-label independence, negative-zero payload preservation and invalid layout rejection. |
| Precision conversion error and exhaustive CPU conformance | 1,782 | Every small input encoding, seed/coordinate/accumulator conversions, nonzero error contributions, positive/negative ties, separate/FMA, exact node ranges and portable/AC/AP C++ APIs. |
| Precision overflow refusal and canonical graph audit | 22 | Changed quantizers, arithmetic order, coefficient tables and format metadata; fixed/floating conversion and arithmetic overflow refusal. |
| Generated individual storage and stage formats | 5,200 | Fixed/floating segmented exp in separate/FMA modes, mathematical enclosures, all native CPU backends, width reductions against common-format baselines, schema v3 search history, decimal/rational equality and singleton layout truncation. |
| Bounded certified precision optimization and reports | 695 | Fresh baseline proofs, accepted storage/stage reductions, rejected over-budget changes, exact report replay, unchanged floating exponent headroom, attempt/deadline limits and owned-worker cleanup, including a saved certificate before timeout. |
| Precision configuration CLI and replay | 336 | Actual v3 CLI generation, v5 stored replay through portable/AP C++, retained certified outputs after a failed precision choice, distinct layout choices and malformed-field rejection. |
| Odd central generation and complete uniform certificates | 15,511 | Sin/sinh/erf/atan with fixed/floating internals and separate/FMA evaluation; direct MPFR checks, exact replay and official AC arithmetic; portable/AP sin; generated individual coefficient/stage formats. |
| Odd square, reconstruction, zeros and overflow | 8,779 | Exhaustive small inputs, rounded coordinates/squares and q conversion, zero-only and degree-one lazy arithmetic, outside-domain zero guards, square overflow and portable/AC/AP C++ APIs. |
| Odd graph audit, identity authorization and request validation | 26 | Rejected graph/identity changes and unsupported requests; negative-zero coefficient payloads preserved through replay and stage reformatting. |
| Odd binary16 coverage, precision optimization and CLI replay | 193,445 | All 65,536 encodings through Julia and AC/AP C++; certified precision reduction, configuration/report v4, stored-plan CLI replay and malformed transformation rejection. |

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

## Normalized segmentation

`test/segmentation.jl` checks complete per-row certificates, numerical ranges,
dispatch indices and mathematical errors. Fixed and small custom floating inputs
are exhausted, including all excluded words. Nonrepresentable contract endpoints
and internal thresholds are covered, with binary32 boundary neighbours and both
signed zeros. The 64-row fixture reaches the complete six-bit table index.

The fixed `exp` fixture uses `Fixed(9,3)` input, `Fixed(24,4)` output,
`Fixed(32,6)` internals, four normalized segments and degree five on `[-1,1]`.
Both separate/FMA modes have a uniform bound about `5.4092194e-7`, below `2^-18`.
Floating internals are also certified and compiled. The checked-in
[segmented search example](../examples/segmented_search.jl) first retains a
degree-five single-polynomial budget failure, then selects this segmented
candidate. CLI output and stored-plan replay are checked for identical exact
plans, certificates and C++ files.

Binary16 `exp` exhausts all 65,536 encodings against MPFR enclosures and through
portable, official AC and official AP fixed C++. Each accepted encoding checks
the selected path's bound and every visited numeric node; excluded inputs check
canonical NaN and lazy skipping of tables and coordinate arithmetic.

Coarse input conversions explicitly exercise rounded coordinates outside their
ideal domains. Exact affine scaling-down, singleton branches, overflow refusal,
empty-branch validation before worker launch and mutations of predicates,
thresholds, table indices/payloads/layout, scaling, arithmetic, metadata and
guards are covered. Independent point references use 512-bit initial precision
so their enclosures are narrower than tight singleton norm certificates.
These are software numerical and compiler checks; hardware calibration remains
pending.

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
dependency; primitive checks use directed MPFR. `certified_polynomial` performs
one synchronous attempt; supervised searches use `search_polynomial` below.

## Ordered search and supervised workers

Search tests cover caller ordering, first-certified selection, fixed/floating
precision choices with unchanged integer/exponent ranges, generation failures,
attempt exhaustion and complete choice exhaustion. They retain exact candidate
and proof data, including failed candidates. A report's selected plan is
reconstructed, recertified with the same bound and checked through the exact
interpreter. Wide floating coefficient words and 200-bit rational budgets cross
the worker boundary and survive report replay.

The [search example](../examples/bounded_search.jl) visits degree one with
`Fixed(16,6)` then `Fixed(32,6)`, followed by degree nine with those same formats.
The first three candidates exceed the budget; the last passes with a total
bound of `5.519426e-7` against `2^-18`, using the same exp contract as above.
Its report persists all four attempts and their actual coefficients.

Controlled subprocess fixtures exercise job timeouts, nonzero worker exits,
malformed/missing replies, worker exceptions and recovery through a succeeding
job. Candidate checkpoints survive interrupted proofs. Tests check that every
owned process has exited and temporary directories are gone before the next
job starts, and also after a parent exception. No slow mathematical example is
used to induce a timeout. A total deadline interrupts an active job and prevents
later choices from starting; startup and already-expired budgets are covered.
A completed certificate cannot select a candidate if its worker exceeds the
job time limit. Exact available data remains in the report for inspection.

The worker strategy starts a fresh Julia process for every attempt. It trades
startup time for independent native state and straightforward cancellation.
Persistent pools, parallel sweeps and hardware cost optimization are later work.
The generation CLI consumes these choices through a separate search configuration.

## Generation from contracts and artifact replay

The [generation CLI](generation.md) accepts a bounded contract and versioned
search configuration, generates coefficients and publishes only a certified
selected evaluator. The checked-in exp contract visits four candidates, saves
all attempts and selects degree nine with `Fixed(32,6)`. A real Julia CLI
subprocess produces the artifacts; the saved plan is then read, independently
recertified and emitted without another search. The replayed plan, certificate,
header and harness match the original files. All 512 fixed input words exercise
mathematics or lazy rejection; all 129 accepted words agree with compiled
portable, official AC and official AP fixed evaluators. These checks compile
the CLI's actual header/harness files.

Binary32 `exp(x)+1e-1*x` and `exp(x)+x/10` on `[-1,1]`, with a `2^-21` target,
degree thirteen and `Float(8,27)` FMA internals, generate matching executed
programs and uniform bounds of about `1.330035e-7`. Domain neighbours,
subnormal/special input words, deterministic samples and an interior grid pass
mathematical enclosures and official AC floating C++ conformance. Their composed
references share the Sollya numerical dependency.

A small `Float(3,4)` input/output contract for `x/128` uses `Float(8,18)` FMA
internals; all 256 words check final subnormal ties, zero/special encodings,
lazy guards and exact C++/interpreter agreement. Its total bound is exactly
`1/128`. Binary16 `exp` on `[-1,1]` uses degree nine with `Fixed(32,6)` FMA
internals and a `2^-9` target. Its bound is about `9.766376e-4`. All 65,536
input words pass MPFR mathematical-enclosure/lazy-guard checks and compiled
official AC fixed conformance, including the input subnormals and both zeros.

Failure checks cover attempt exhaustion, an expired total budget, fresh failed
output directories, invalid options and emission/publication failures after a
numerical certificate. Existing valid artifacts remain byte-identical after
failure. A controlled file replacement error restores every previously managed
file and preserves unrelated files; staging directories are removed. Successful
generation clears stale reports. Search configuration round trips cover fixed,
custom and wide floating formats, exact rational settings, defaults and rejected
unknown/invalid fields.

## Individual coefficient and stage precision

The [precision example](../examples/precision_search.jl) generates a four-row
degree-five fixed exp FMA evaluator on `[-1,1]`, with `Fixed(9,3)` input and
`Fixed(24,4)` output. Its coordinate format remains `Fixed(32,6)`. Ascending
coefficient widths are `[25,23,22,21,20,19]`; accumulator widths are
`[29,28,27,26,25,24]`. Its complete uniform bound is about `1.439789e-6`, below
`2^-18`, compared with about `5.409219e-7` for the common-format baseline.

| Declared structural count | Common format | Individual formats |
| --- | ---: | ---: |
| Coefficient storage bits | 768 | 520 |
| Stage-width sum, including initial load | 192 | 159 |
| Static arithmetic result-width sum | 192 | 167 |
| Static arithmetic operand-bit sum | 544 | 469 |
| Centre/coefficient table bits | 896 | 648 |
| Explicit conversions | 2 | 18 |

Both fixed and floating separate/FMA fixtures reduce declared widths while
retaining complete bounds. Every accepted small input is checked against a
mathematical enclosure and every visited node's certified range; ordinary C++
with official AC/AP headers matches the exact interpreter. Exhaustive small
fixed/custom formats additionally exercise seed conversion, narrowing stage
coordinates and accumulators, positive/negative halfway cases and lazy guards.
Overflow and graph/table/format mutations are refused.

The bounded optimizer starts with a fresh baseline certificate and accepts only
certified reductions. Tests confirm separate coefficient regeneration and stage
recertification, preservation of the last passing plan, exact report replay,
attempt/deadline limits and rejection of a completed proof in a worker that
continues running beyond its deadline. The CLI retains all individual formats
and preserves valid generated outputs after a failed precision choice.

These counts describe storage declarations and static IR widths. Extra
conversions are visible in the report; no FPGA area, timing or throughput
improvement is established by local software verification.

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
These fixtures use a common internal format. Individual widths, precision search
and normalized segmented polynomial certification are now supported. The
specialized magnitude/tail segmented floating erf graph remains outside the
uniform proof.

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

## Odd central kernels

The [odd search example](../examples/odd_search.jl) generates bounded sin with
`Fixed(9,3)` input, `Fixed(24,4)` output and `Fixed(32,6)` internal arithmetic
on `[-1,1]`, targeting `2^-18`. Degree three exceeds the budget; degree nine
passes with five stored q coefficients, four Horner FMAs, a square and a
reconstruction product. Its total bound is about `5.158886e-7`:

| Contribution | Uniform bound (rounded up) |
| --- | ---: |
| Stored odd-polynomial approximation | `1.798494e-9` |
| Coordinate formation | `0` (exact input conversion and square on this input grid) |
| Horner and reconstruction arithmetic | `3.725291e-8` |
| Output conversion | `4.768372e-7` |

The example declares 160 coefficient bits and 160 stage bits. These are
structural counts, with no measured FPGA performance claim. Its emitted AC
evaluator and an actual CLI invocation using the example's v4 configuration
were generated locally.

Dedicated tests generate sin/sinh/erf/atan on `[-1,1]` at degrees 9/9/13/17,
with fixed and floating internals and separate/FMA evaluation. Every small fixed
input encoding is checked against directed MPFR enclosures and certified node
ranges; official AC C++ checks cover all sixteen combinations. Fixed sin also
uses AP and portable C++. Independent coefficient/stage formats, rounded squares
and reconstruction conversions, nonsymmetric domains and complete graph mutation
rejection are covered.

The binary16 sin contract exhausts all 65,536 encodings through Julia, AC and AP
C++, including subnormals, signed zeros, nonfinite and outside-domain guards.
Precision reduction retains the odd layout and freshly certifies its selected
plan. Configuration/report v4 and plan v5 replay preserve exact semantics through
CLI generation and AC/AP C++ checks. Tests also cover zero-only contracts with
unreachable overflowing arithmetic, original nonzero inputs that round to zero,
reachable square overflow and degree-one evaluators that do not execute a square.
No tiny-argument shortcut is inferred from these tests.

## Limits

Uniform certification covers complete binary16 LUTs, canonical fixed binary16/IEEE32 erf graphs and supported
degree 0–32 float/fixed polynomial kernels with nearest-even rounding and
rejected fixed overflow, including mixed interfaces and custom formats.
Bounded odd sin/sinh/atan/erf kernels also have complete certificates.
Segmented floating erf and other transformation families remain outside the
certificates. The [compact contract](../examples/erf-contract.toml) remains
unchanged; schema v3 stores internal fixed programs and v4 adds fixed interfaces;
schema v5 adds individual coefficient/stage precision; a separate report records the
numerical proof. Native floating CPU arithmetic supports binary32/binary64 with
nearest-even rounding; official AC arithmetic supports custom and wide formats.
Binary16 interfaces and exact conversions are supported,
and fixed helpers also support directed conversions. Binary16 erf is exhausted
for both implementation choices. Polynomial kernels have no near-zero ulp or
correct-rounding guarantee; binary16 LUTs reproduce resolved nearest-even outputs.
Sollya and direct MPFR checks share MPFR algorithms, so their agreement is not
fully independent evidence. Linux, installed vendor toolchains, synthesis and FPGA
performance were not tested. These are separate later gates in the plan.
