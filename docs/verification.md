# Local verification

Verified on 7 October 2026 on macOS, Apple Silicon, using the sibling Sollya.jl
0.1.0 checkout and installed Sollya 8.0 (Homebrew `8.0_3`). CPU evaluators use
LLVM/Clang 23.1.2; the CMake workflow uses CMake 4.4.3. Direct primitive checks
use each Julia installation's own MPFR/GMP runtime.

## Results

The exp change passes **six new groups with 756,831 checks** on Julia 1.13.1,
with four threads and official vendor headers required. These cover exact dynamic
scaling, complete reduction/reconstruction proofs, every binary16 encoding in
separate/FMA modes, custom and individual precision, underflow, proof refusals,
supervised precision search and CLI replay. Another **20 regression groups pass
with 1,481,219 checks**, covering formats, schemas, IR, references, root direct
rounding and all atan/log groups. The targeted runs verify **26 groups and
2,238,050 checks**. The standalone example and formatting pass. The complete
package runner was not repeated. See the [exp results](#exp-range-reduction-and-reconstruction).

The preceding atan change passes **seven new groups with 836,815 checks** on Julia
1.13.1, with four threads and official vendor headers required. These cover
rounded reciprocal semantics, complete central/tail certificates, every binary16
encoding in separate/FMA modes, custom and wide precision, supervised precision
search, CLI replay, directed infinity references and writable failure reports.
The binary16 example certifies `0.0004883187620752597` against `1/1024`.
Its standalone generation and formatting checks also pass. Another **24
regression groups pass with 1,383,439 checks**, covering formats, schemas, IR,
references and every odd, sqrt/rsqrt and log group. Together these runs verify
**31 groups and 2,220,254 checks**. See the detailed
[atan results](#atan-central-and-reciprocal-tails) below. The complete package
runner was not repeated.

The preceding cbrt change passes **ten new groups with 451,880 checks** on Julia 1.13.1,
with four threads and official vendor headers required. It covers exact division
by three, argument widening, direct reconstruction, signed certificates, every
binary16 encoding, custom/nonuniform precision, supervised optimization,
CLI replay and Sollya/MPFR reference semantics.
Another **20 regression groups pass with 1,123,640 checks**, covering formats,
schemas, IR, all reciprocal and sqrt/rsqrt groups, adaptive references and exact
expression semantics. Together these runs verify **30 groups and 1,575,520
checks** for this change. The complete package runner was not repeated.
The first wider fixed fixture refused certification because its conservative
Horner range exceeded its integer width; a fresh run with more integer headroom
and the same 88 fractional bits passed. The standalone cbrt example also runs
successfully. Formatting is clean.

The preceding sqrt/rsqrt change verified 24 groups and 1,548,520 checks,
including eight new groups with 521,283 checks. The reciprocal change verified
27 groups and 1,251,386 checks. Those earlier results remain recorded below.

The preceding complete gate verified **50 groups with 1,487,066 checks**, with four
threads and vendor-header tests required. The offline `scripts/check.jl` runner
passed 28 groups before cold worker jobs exceeded an eight-second fixture budget.
After increasing those fixture budgets to 30 seconds, a fresh process passed the
remaining 22 groups against the same implementation. Deadline, kill/reap and
saved-certificate rejection checks remain enforced. The four odd-kernel groups
contribute 217,761 checks. Formatting is clean. The count is dominated by
exhaustive encoding checks, not by function coverage or numerical certificates.

| Reciprocal group | Checks | Coverage |
| --- | ---: | --- |
| Exact floating magnitude normalization | 192,924 | All binary16 and small custom words; both signs; subnormal significand shifts; exact rational reconstruction; 128/256-bit formats, 300/4096-bit fractions and cheap extreme-exponent decomposition. |
| Exponent reconstruction IR and official CPU headers | 39 | Exhaustive finite nonzero binary16/small custom identity reconstruction; wide words; portable/native/AC/AP interfaces; direct fixed-to-float scaling; a subnormal midpoint exposing double rounding; overflow, invalid normalization, host rounding and AC exponent headroom. |
| Certified reciprocal mantissa kernels and complete error bounds | 1,158 | Positive/negative domains and separate/FMA fixed kernels; subnormal custom inputs; wide input/output and 96-bit fixed arithmetic; graph ranges, exact rational reciprocal errors, exponent-scaled budgets and artifact recertification. |
| Exhaustive binary16 reciprocal verification | 278,534 | All 65,536 encodings for each signed domain; exact rational `1/x` bounds and every visited range; native portable and official AC/AP C++; lazy rejection of zeros, nonfinite and out-of-domain values. |
| Reciprocal proof refusal and exact graph authorization | 26 | Wrong identities and graph mutations refused; invalid domains/interfaces/segmentation; output overflow and unmet budgets; unused coordinate conversion; singleton-domain approximation enclosure. |
| Reciprocal precision optimization and configuration replay | 34 | Nonuniform Horner stages and complete recertification; exact negative-zero coefficient preservation; supervised coefficient reduction; v5 configuration/report and v6 plan CLI generation/replay through compiled official-header evaluators. |

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

## Reciprocal exponent reduction

[`examples/reciprocal_search.jl`](../examples/reciprocal_search.jl) generates
`1/x` for binary16 input/output on `[1/16,16]`, with an absolute target of
`1/64`, `Fixed(40,12)` internals and FMA evaluation. Degree three exceeds the
budget; degree seven certifies. The selected graph stores eight coefficients
and uses seven FMAs, one mantissa normalization, one direct exponent scaling
and one sign copy. There is no lookup table. These are static IR counts.

| Contribution | Certified upper bound |
| --- | ---: |
| Approximation after exponent scaling | `1.754034e-5` |
| Coordinate conversion | `0` |
| Arithmetic after exponent scaling | `3.775563e-6` |
| Direct reconstruction/output rounding | `0.0078125` |
| Total | `0.007833815906388823` |
| Contract target | `0.015625` |

Exact normalization covers all finite nonzero binary16/small custom encodings,
with wide-format and extreme-exponent cases. Reciprocal checks exhaust all
binary16 encodings for positive and negative bounded contracts, comparing the
accepted results directly with rational `1/x`; zeros, nonfinite values and
out-of-domain inputs take the lazy NaN branch. Official AC/AP and native CPU
paths match the interpreter. A dedicated subnormal case demonstrates direct
reconstruction: rounding the kernel first would produce encoding 384, while
the correct direct result is 385.

Generated custom-format contracts also cover subnormal input normalization,
112-fraction-bit output, 96-bit fixed arithmetic and coordinate conversion
error. Nonuniform stages, negative-zero coefficient payloads and supervised
precision reduction retain complete certificates. Configuration/report v5,
plan v6, actual CLI generation and stored replay are verified through compiled
evaluators. The standalone example and CLI replay also run successfully.

The reciprocal contract currently accepts one bounded interval strictly on
one side of zero, with floating interfaces. Overflow refuses certification.
Full-domain reciprocal special values and disconnected domains remain pending.
AC reconstruction requires sufficient intermediate
exponent headroom within its 30-bit limit; arbitrary significand widths remain
available within the existing CPU width limits.

## Sqrt and rsqrt exponent reduction

[`examples/root_search.jl`](../examples/root_search.jl) generates both functions
for binary16 input/output on `[0,65504]`, covering every positive finite input.
Degree eleven uses `Fixed(80,24)` internals, twelve coefficients, eleven FMAs,
one exact root-argument formation and one direct exponent reconstruction.
These counts include no lookup table and make no hardware performance claim.

| Contribution | sqrt bound | rsqrt bound |
| --- | ---: | ---: |
| Approximation after exponent scaling | `5.271950e-6` | `0.001955457` |
| Coordinate conversion | `0` | `0` |
| Arithmetic after exponent scaling | `1.235915e-9` | `3.954927e-8` |
| Reconstruction/output rounding | `0.125` | `2` |
| Total | `0.12500527318529048` | `2.0019554959649266` |
| Contract target | `0.25` | `4` |

The finite proof excludes zero from its numerical paths. Both signed zeros use
exact branches when zero belongs to the contract: sqrt preserves the sign,
rsqrt returns the corresponding signed infinity. Positive infinity produces
infinity or zero respectively; negative inputs/infinity, NaNs and finite inputs
outside the contract return canonical NaN before normalization or arithmetic.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Exact root argument and floor exponent splitting | 192,753 | All binary16 and small custom encodings; exact rational identity, negative odd exponents, Int endpoints, BigInt exponents and 4096-bit fractions. |
| Root reconstruction IR and single output quantizer | 9 | Compiled exact arguments and quotient scales; direct fixed-to-half subnormal midpoint in portable/AC/AP and native/AC floating paths; plan v7 and rejection by earlier schemas. |
| Certified sqrt and rsqrt reduced kernels | 266 | Full positive binary16 contracts, separate/FMA arithmetic, every reachable range, both floating backends and all fixed backends, serialized recertification and exponent-scaled proof contributions. |
| Exhaustive binary16 sqrt and rsqrt verification | 325,632 | All 65,536 encodings for each function; exact rational squared inequalities establish the error independently; native/AC/AP C++ and lazy special-value branches agree. |
| Root zero branches and graph proof refusal | 80 | Zero-only contracts, excluded zeros, infinity policy, invalid domains/interfaces, graph/identity mutations, possible overflow and unmet budgets. |
| Root precision search and configuration replay | 42 | Supervised reduction with complete recertification, compiled selected plans and search configuration/report v6. |
| Root floating and wide mixed precision | 2,494 | Exhaustive small custom inputs with floating internals; 100-fraction-bit inputs, 112-bit output fractions, 96-bit fixed kernels and nonzero coordinate error; nonuniform stages and exact negative-zero coefficients. |
| Root CLI generation and stored replay | 7 | Actual contract/config generation with AP C++, stored rsqrt recertification/replay with AC C++, schema/report/certificate payloads and compiled artifacts. |

Numerical contracts currently require floating interfaces, a bounded
nonnegative interval and one kernel. Possible output overflow refuses a finite
certificate. These are absolute-error certificates, without a correct-rounding
or ulp guarantee.

## Signed cbrt exponent reduction

[`examples/cbrt_search.jl`](../examples/cbrt_search.jl) generates `cbrt(x)` for
binary16 input/output on `[-65504,65504]`, covering both signs of every finite
input. Degree thirteen uses `Fixed(96,24)` internals, fourteen coefficients,
thirteen FMAs, one exact argument formation and one direct exponent scaling.
The coefficient/stage declarations each total 1,344 bits; these structural
counts make no FPGA resource or throughput claim.

| Contribution | Certified upper bound |
| --- | ---: |
| Approximation after exponent scaling | `2.686640e-5` |
| Coordinate conversion | `0` |
| Arithmetic after exponent scaling | `2.645557e-10` |
| Reconstruction/output rounding | `0.03125` |
| Total | `0.03127686665682863` |
| Contract target | `0.0625` |

All 65,536 encodings are checked in Julia and compiled native, AC and AP C++.
Exact rational inequalities `(y-B)^3 ≤ x ≤ (y+B)^3` independently establish
the numerical error, and every visited numeric range is checked. Signed zeros
and infinities retain their signs through lazy branches; NaNs and finite inputs
outside a bounded contract return canonical NaN before kernel evaluation.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Exact cube root argument and exponent splitting | 192,676 | All binary16 and smallest custom words; exact rational identities, subnormals, negative remainders, 100/4096-bit fractions and automatic argument exponent widening. |
| Cube root IR reconstruction and official CPU headers | 24 | Exhaustive binary16/small custom argument construction; wide AC words; direct fixed-to-half subnormal midpoint in portable/AC/AP and native/AC floating paths; invalid divisors refused. |
| Certified signed cbrt mantissa kernel | 371 | Both signs, separate/FMA kernels, exponent transitions, special values, all fixed/floating CPU backend combinations and serialized recertification. |
| Exhaustive binary16 cbrt verification | 258,045 | Every encoding, exact cubic error inequalities, all visited ranges, sign restoration and native/AC/AP CPU agreement. |
| Cbrt signed domains, zeros and proof refusal | 181 | Positive/negative/cross-zero intervals, zero-only generation, excluded zeros, identity/graph mutations, invalid interfaces/segmentation, output overflow and unmet budgets. |
| Cbrt custom floating and individual precision | 283 | Smallest exponent input with floating internals; 100-fraction-bit input and 112-fraction-bit output, 136-bit fixed arithmetic with coordinate error; nonuniform stages and exact negative-zero coefficients. |
| Cbrt precision search, CLI generation and replay | 37 | Supervised width reduction with fresh proof, search configuration/report v7, plan v8, actual CLI generation, AP artifact compilation and AC replay. |
| Cbrt inferred coordinate format | 213 | Direct use of the widened argument format as the coordinate, audited coefficient positions, exact serialization, every small input and compiled typed/raw interfaces. |
| Cbrt Sollya and MPFR references | 42 | Directed positive fractional-power bounds and odd extension agree with native MPFR on both signs; independent exact cubes, zeros, infinities and NaNs. |
| Cbrt expression parsing and ordinary polynomial proof | 8 | Canonical primitive mapping; unsupported compositions rejected; ordinary positive-domain proof; signed identity evaluators refused and untransformed signed generation fails explicitly. |

The default Sollya reference previously recovered `cbrt(x)` as `x`, producing
an incorrect result such as `-8` for `cbrt(-8)`. Explicit mapping and signed
endpoint reversal correct that path. The parser now refuses unsupported cbrt
compositions; signed ordinary polynomial requests require the root transformation.

Cbrt currently requires floating interfaces, a bounded signed interval and one
kernel. Internal or output overflow refuses certification. The absolute bound
does not imply correct rounding or an ulp guarantee.

## Log exponent reconstruction

[`examples/log_search.jl`](../examples/log_search.jl) generates binary16
`log(x)` on `[0,65504]`, covering every positive finite encoding and both
zero poles. Degree nine uses `Fixed(80,24)` internals, ten coefficients,
nine Horner FMAs and one reconstruction FMA. Coefficient and stage declarations
each total 800 bits; these are structural counts.

| Contribution | Certified upper bound |
| --- | ---: |
| Mantissa approximation | `4.535559e-9` |
| Coordinate conversion | `0` |
| Arithmetic, including stored constant and reconstruction | `3.643207e-15` |
| Output rounding | `0.0078125` |
| Total | `0.007812504535561773` |
| Contract target | `0.015625` |

The stored log(2) contribution, already included in arithmetic, is at most
`1.095626e-16` after exponent scaling. Directed MPFR enclosures check the
absolute error independently of the Sollya norm. Every visited numeric range
is checked, and compiled portable/AC/AP evaluators agree on output bits and
fixed-node payloads with both native and AC floating backends.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Exact exponent IR and C++ | 129,149 | Every binary16/small custom encoding, exact mantissa/exponent identity, signed integer storage including wide metadata, plan v9 and official headers. |
| Certified log reconstruction | 193 | Separate/FMA bounds, stored constant term, subnormal and binade boundaries, exact one and zero poles, every CPU backend and stored recertification. |
| Exhaustive binary16 log verification | 385,012 | All encodings for FMA, positive finite inputs for separate reconstruction, directed MPFR error enclosures, visited ranges and six compiled FMA backend combinations. |
| Log domains, exact branches and proof refusals | 170 | Zero-/one-only generation, included/excluded poles, bounded positive intervals, mutated graphs/constants, insufficient exponent headroom and unmet budgets. |
| Log custom floating and individual precision | 221 | Small custom input with double internals, 100-fraction-bit input and 112-fraction-bit output, nonuniform fixed stages, raw/typed AC/AP/portable conformance. |
| Log precision search, CLI and replay | 45 | Supervised precision reduction with fresh proof, search/report v8, plan v9, actual generation, recertification and exact C++ replay. |
| Log exponent conversion and stored constant error | 15 | Exponent 25 rounds to 24 in a three-fraction-bit coordinate; constant and reconstruction errors are accounted for separately, with official-header CPU agreement. |

These seven groups pass 514,805 checks. Nineteen regression groups pass
1,123,588 checks, covering formats, schemas, IR, references and every reciprocal,
sqrt and rsqrt group. Together, the targeted runs pass 26 groups and 1,638,393
checks with official vendor headers required. Formatting passes. The complete
runner was not repeated.
Log currently requires floating interfaces, a bounded nonnegative interval and
one kernel. Possible overflow refuses certification. The absolute bound does
not imply an ulp or correct-rounding guarantee.

## Atan central and reciprocal tails

[`examples/atan_search.jl`](../examples/atan_search.jl) generates binary16
`atan(x)` on `[-65504,65504]`. Degree fifteen uses eight coefficients and
`Fixed(72,24)` internals. The central branch evaluates `r*q(r²)` with `r=abs(x)`;
the tails use a rounded binary64 reciprocal and subtract the same kernel from
stored π/2. Dispatch at `abs(x)>1` compares the original input exactly.
The shared graph contains one floating division, two multiplications and eight
FMAs. Coefficient and stage declarations each total 576 bits. These counts
describe the IR; they do not predict FPGA resource use or throughput.

| Contribution | Largest certified upper bound |
| --- | ---: |
| Stored odd polynomial approximation | `3.751206e-8` |
| Reciprocal and coordinate formation | `6.437069e-15` |
| Arithmetic, stored π/2 and tail reconstruction | `1.584141e-14` |
| Output rounding | `0.00048828125` |
| Signed infinity limits, separate branch | `0.0004838267948966193` |
| Total across all branches | `0.0004883187620752597` |
| Contract target | `0.0009765625` |

The stored π/2 contribution, included in tail arithmetic, is at most
`1.715125e-15`. The infinity branch has its own complete constant/conversion
bound, included in the global maximum even for zero-only finite contracts.
Signed zeros are exact. NaNs and excluded finite inputs return canonical NaN
before numerical evaluation.

Both separate and fused evaluators are checked over all 65,536 encodings
against directed MPFR enclosures and every visited numeric range. The compiled
fused evaluator agrees with Julia for native and AC floating arithmetic,
combined with each portable, AC and AP fixed backend. Standalone reciprocal
tests also compile the official AC floating division, including custom wide
formats. Sollya and MPFR atan infinity references resolve adaptively to directed
π/2 bounds; insufficient precision retains an unresolved enclosure.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Rounded floating reciprocal IR and official headers | 65,624 | All binary16 and small custom words; signed zeros, infinities and NaNs; native/AC division, wide raw/typed AC APIs, host rounding rejection and plan v10. |
| Certified atan central and reciprocal tails | 183 | Fresh generation, separate/FMA proofs, exact boundary neighbours, stored constants, all six C++ backend combinations and artifact recertification. |
| Exhaustive binary16 atan verification | 770,042 | Both evaluators over every encoding; independent directed MPFR errors, visited ranges and six compiled fused backend combinations. |
| Atan domains, exceptional limits and proof refusals | 392 | Central/tail/signed/singleton and zero-only contracts; infinity error, lazy guards, graph mutations, invalid requests and unmet budgets. |
| Atan custom floating, guard bits and individual precision | 461 | Small custom inputs, 100-bit input and 112-bit output fractions, widened reciprocals, full finite binary64 domains, nonuniform stages and official-header conformance. |
| Atan precision search, generation and replay | 59 | Supervised width reduction with fresh proofs, search/report v9, actual CLI generation, plan v10, byte-identical replay and compiled AP/AC artifacts. |
| Atan directed infinity reference limits | 54 | Both reference backends and signs, half through 112-bit fractions, fixed output, insufficient precision and output overflow. |

These seven groups pass 836,815 checks with official vendor headers required.
Twenty-four regression groups pass another 1,383,439 checks, covering formats,
schemas, IR, references and every odd, sqrt/rsqrt and log group. The targeted
runs total 31 groups and 2,220,254 checks. The standalone example and formatting
also pass. The complete runner was not repeated for this change.
Atan currently requires floating interfaces, a bounded signed interval and one
shared kernel. Possible internal/output overflow refuses certification. The
certificate establishes a uniform absolute bound; it does not establish an ulp
or correct-rounding guarantee.

## Exp range reduction and reconstruction

[`examples/exp_search.jl`](../examples/exp_search.jl) generates binary16 `exp(x)`
on `[-65504,5]`. Degree nine uses ten coefficients, `Fixed(72,24)` Horner
internals and a binary64 reduction format. The evaluator selects an integer
from the rounded reciprocal product, forms the residual and scales the final
Horner value directly into binary16. The selected exponents span `[-94502,7]`;
the proved ideal residual radius is about `0.346573590286`, within `[-1/2,1/2]`.
The shared graph has one selection multiplication, ten FMAs and one exponent
scaling. Coefficient and stage declarations each total 720 bits. These are
structural counts, without an FPGA resource or throughput claim.

| Contribution | Certified upper bound |
| --- | ---: |
| Approximation after exponent scaling | `6.789113e-11` |
| Residual/coordinate error after exponent scaling | `4.291108e-10` |
| Horner arithmetic after exponent scaling | `3.479463e-13` |
| Direct reconstruction/output rounding | `0.0625` |
| Total | `0.06250000049734979` |
| Contract target | `0.125` |

Stored log(2) error contributes at most `2.191546e-12` before the coordinate
propagation and exponent scaling. Complete residual formation error is at most
`2.193322e-12`. The maximum error scale is 128. Every binary16 encoding is
checked against directed MPFR enclosures for both separate and fused evaluation;
every visited numeric range and integer selection is checked. Compiled fused
evaluators agree with Julia across native/AC floating and portable/AC/AP fixed
backend combinations, including deeply underflowed outputs.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Dynamic exponent scaling and direct output quantization | 196,638 | Three scalings over all binary16 words; signed zeros, infinities and NaNs; subnormal double-rounding case; 320-bit fixed and 100/112-bit floating bridges; huge Julia exponents; CPU headroom/rounding refusals and plan v11. |
| Certified exp reduction and reconstruction | 1,051 | Fresh generation, separate/FMA complete bounds, rounded integer transition neighbours, stored replay, structural counts and six compiled backend combinations. |
| Exhaustive binary16 exp verification | 558,588 | Both evaluators over all encodings; directed MPFR errors, integer decisions, visited ranges and six compiled fused backend combinations. |
| Exp underflow, exceptional branches and proof refusals | 209 | Signed, singleton, clipped and zero-only domains; exact zeros/infinities; deep underflow; mutated graphs/policies, unsupported interfaces, invalid reduction, overflow and unmet budgets. |
| Exp guard bits, custom formats and individual precision | 296 | Small custom inputs, floating internals, 100-bit input and 112-bit output fractions, nonuniform coefficient/stage formats and official-header conformance. |
| Exp precision search, CLI generation and replay | 49 | Supervised certified width reduction, search/report v10, actual CLI generation, plan v11, exact header replay and compiled AP/AC artifacts. |

These six groups pass 756,831 checks. Twenty regression groups pass another
1,481,219 checks, covering formats, schemas, IR, references, direct root rounding
and all atan/log groups. The targeted runs total 26 groups and 2,238,050 checks
with official vendor headers required. The standalone example and formatting
pass. The complete runner was not repeated.
The first binary32-output fixture correctly refused a budget below its final
rounding contribution; a feasible absolute target passes. Exp currently requires
floating interfaces, a bounded interval and one shared kernel. Unproved residual
coverage and possible overflow refuse certification. The uniform absolute bound
does not establish correct rounding or an ulp guarantee. Stable bounded
sinh/cosh reconstruction is described below.

## Sinh/cosh reconstruction

[`examples/hyperbolic_search.jl`](../examples/hyperbolic_search.jl) generates
binary16 sinh and cosh on `[-11.5,11.5]`, with absolute target 32. Kernel degree
nine uses ten central Taylor coefficients and ten reduced exp coefficients in
`FixedFormat(72,24)`. Three Horner evaluations share the declared stage formats.
The tail scales by `2^(k-1)` and `2^(-k-1)` in binary64 before reconstruction
and conversion to binary16. Both functions certify `16.00000003516688`.

| Tail contribution | Certified upper bound |
| --- | ---: |
| Approximation after both exponent scalings | `3.476039e-8` |
| Residual/coordinate errors after scaling | `2.174290e-10` |
| Horner, scaling and reconstruction arithmetic | `1.890632e-10` |
| Final output rounding | `16` |
| Total | `16.00000003516688` |

Central bounds are about `0.0004882812500190` for sinh and
`0.0004882812500150` for cosh. The coefficient banks total 1,440 declared bits;
three stage sets total 2,160 bits. Static IR contains 28 FMAs and two exponent
scalings, plus dispatch and reconstruction. These counts are not device results.

Every binary16 encoding is checked in both separate and fused evaluators against
directed MPFR enclosures, with all visited numeric ranges and central/tail
choices checked. Exhaustive compiled conformance covers portable/native sinh
and AC/AC cosh. Directed tests cover all six portable/AC/AP fixed and native/AC
floating combinations, raw and typed public interfaces, exponent transitions
and branch neighbours. Both binary16 and binary64 tests include finite
hyperbolic outputs beyond exp's output overflow point.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Certified sinh/cosh central and exponential tails | 3,134 | Fresh supervised generation, separate/FMA certificates, central and exponent boundaries, six backend combinations, stored recertification and finite results past exp overflow. |
| Exhaustive binary16 sinh/cosh verification | 1,279,494 | Both functions and arithmetic modes over all encodings, directed MPFR bounds, lazy exceptional branches, visited ranges and two exhaustive compiled evaluators. |
| Hyperbolic bounded branches and proof refusals | 602 | Central/tail/singleton/clipped/zero-only contracts, degree-zero generation, invalid identities/interfaces, mutated graphs, reduction failures, overflow and unmet budgets. |
| Hyperbolic guard bits and custom precision | 624 | Floating/fixed internals, small custom formats, 100-bit inputs and 112-bit outputs, binary64 finite reconstruction beyond exp overflow, individual widths and official-header conformance. |
| Hyperbolic search schema, precision search and CLI | 39 | Complete certified width reduction including both residual signs, configuration/report v11, actual CLI generation/replay and compiled AP/AC artifacts. |

The five new groups pass 1,283,893 checks. Seven regression groups pass another
327,350 checks, covering formats, plan/search schemas, IR and dynamic exp scaling,
reduction and proof refusals. The targeted runs total twelve groups and 1,611,243
checks with official vendor headers required. The standalone example and
formatting pass. The complete runner was not repeated. The CLI fixtures were
rerun after fixing their vendor include flags; the custom-precision group was
rerun with the added binary64 overflow-transition cases.

Hyperbolic contracts currently require floating interfaces, an explicit bounded
interval and kernel degree 0:15. Central coefficients use a stored Taylor basis;
tail coefficients use Sollya fpminimax. Both have direct stored-polynomial norm
proofs. This is a uniform absolute bound, without an ulp or correct-rounding
guarantee. Scaled erfc tails are described below.

## Scaled erfc tails

[`examples/erfc_search.jl`](../examples/erfc_search.jl) generates binary16 erfc on
`[-8,8]` with target `1/512`. Degree thirteen uses three banks of fourteen
coefficients in `FixedFormat(72,24)`: central erfc, normalized scaled erfc and
reduced exp. The stored tail center is 4.5 and normalization scale is 1/4,
giving the norm interval `[-7/8,7/8]` for physical arguments `[1,8]`.
Reconstruction occurs in binary64 before output conversion. The total bound is
`0.0009767813924863073`.

| Negative-tail contribution | Certified upper bound |
| --- | ---: |
| Both stored-polynomial norms after reconstruction | `2.188925e-7` |
| Normalization, square and exp-coordinate errors | `1.276853e-15` |
| Horner, multiplication, scaling and reflection arithmetic | `1.050864e-14` |
| Final output rounding | `0.0009765625` |
| Total | `0.0009767813924863073` |
| Contract target | `0.001953125` |

The positive-tail bound is `0.00012228920498608516`. Coefficient banks and
Horner stage sets each total 3,024 declared bits. Static IR has 41 FMAs, four
multiplications, one normalization add and one dynamic exponent scaling, plus
dispatch and conversions. These are structural counts, without a device claim.

With binary32 interfaces and target `2^-20`, ordered search first refuses degree
nine with bound `1.932926e-5`, then certifies degree thirteen at
`3.3810177585913347e-7`. Directed references include square/exponent transitions,
central/tail neighbours, subnormal inputs and outputs, zero outputs and negative
reflection. A positive binary64 contract on `[30,32]` certifies below its smallest
subnormal quantum and produces zero through both Julia and official-header C++.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Certified erfc scaled tails and reflection | 4,361 | Fresh generation, separate/FMA complete proofs, exponent and output transitions, all six backend combinations, exact exceptional branches and stored recertification. |
| Exhaustive binary16 erfc scaled-tail verification | 630,788 | Both arithmetic modes over all encodings, directed MPFR error bounds, every visited range and two exhaustive compiled evaluators. |
| Erfc bounded branches, underflow and proof refusals | 447 | Central/tail/singleton/clipped/zero-only contracts, degree-zero generation, deep binary64 underflow, mutated graphs, invalid interfaces/reductions, fixed overflow, insufficient constants for large squares and unmet budgets. |
| Erfc binary32, guard bits and individual precision | 320 | Ordered degree refinement, binary32 and small custom formats, 100-bit input and 112-bit output fractions, floating/fixed internals, explicit coordinate errors, individual widths and official-header C++. |
| Erfc precision search, artifacts and CLI | 46 | Supervised complete width reduction over both tail kernels, all coefficient banks, configuration/report v12, actual CLI generation and exact AP/AC replay. |

The five new groups pass 635,962 checks; the two added overflow/constant refusals
were checked separately after the main run. Eight regression groups pass another
327,389 checks, covering formats, plan/search schemas, IR, dynamic exp scaling,
exp reduction/refusals and sinh/cosh precision search and CLI replay. The targeted
runs total 963,351 checks with official vendor headers required. The example and
formatting pass. The complete runner was not repeated. The initial subnormal
fixture was corrected to check exponent bits, matching the decoder's `finite`
classification for both normal and subnormal values.

Contracts currently require floating interfaces, an explicit bounded interval,
three degree 0:32 kernels and an absolute-error target. The single normalized
scaled-tail polynomial is tied to its stored domain; a wider domain can need
higher degree, different coefficients or another architecture. Unsupported
ranges fail explicitly. This does not establish full-domain erfc, relative/ulp
accuracy or correct rounding. Bounded sin/cos periodic reduction is described below.

## Bounded sin/cos periodic reduction

[`examples/periodic_search.jl`](../examples/periodic_search.jl) generates both
binary16 functions on `[-32,32]` with target `1/512`. Kernel degree five uses
six coefficients per parity bank in `FixedFormat(56,8)`, with binary64 reduction
and reconstruction. Both complete bounds are `0.0004882833282255482`, dominated
by output rounding. The static graph has eleven FMAs and four multiplications;
coefficient and declared stage storage each total 672 bits. Only the chosen
parity kernel executes for an input. These counts are not FPGA resource or
throughput measurements.

The proof covers the stored pi/2 and reciprocal constants, rounded integer
selection, correlated residual formation, squared coordinates, both Horner
kernels, exact quadrant/sign restoration and final output conversion. Transition
checks use predecessor/successor inputs around multiples of pi/2 and halfway
quadrant boundaries. All binary16 encodings are checked against directed MPFR
references and visited-node ranges; both generated AC evaluators are exhausted.
Directed tests also compile portable/AP arithmetic, native/AC floating arithmetic,
public typed APIs and stored artifacts. Infinity, NaN, excluded finite and signed
zero branches execute lazily.

Further checks cover binary32, binary64, custom formats with 80 fraction bits,
individual coefficient/stage widths, supervised precision reduction, exact replay,
malformed graphs/constants, unsupported contracts, singleton/clipped domains and
degree-zero kernels. Fixed payload bitcasts are verified for signed/unsigned
formats, fractional payloads and 130-bit words. Quadrant fields grow automatically
with the domain; sufficient stored-constant and arithmetic precision must still
be proved. A bounded `[-2^70,2^70]` contract exercises an integer field above
64 bits with wider internal fractions and official-header C++.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Periodic kernels and exact quadrant restoration | 5,940 | Fresh search, separate/FMA proofs, pi/2 and halfway-transition neighbours, all quadrants, lazy specials and compiled portable/AP/AC evaluators. |
| Exhaustive binary16 periodic verification | 589,830 | Both functions over all encodings, directed MPFR bounds, visited ranges and two exhaustive compiled AC evaluators. |
| Periodic binary32, custom floats and individual precision | 17,776 | Binary32/binary64, custom/wide fractions, individual coefficient/stage formats, stage replay and public-header conformance. |
| Periodic proof refusals and lazy exceptional inputs | 103 | Invalid constants/reductions, zero-only and positive contracts, unsupported interfaces/degrees/segments, graph mutations and insufficient arithmetic precision. |
| Fixed payload bitcast and periodic artifacts | 3,014 | Signed/unsigned and 130-bit payloads, version rejection, supervised accepted precision reduction, actual CLI generation and exact AP replay. |
| Periodic wide quadrants and small contracts | 6,224 | Singleton/clipped contracts, degree-zero kernels, unsupported fixed interfaces and certified integer quadrants above 64 bits on `[-2^70,2^70]`. |

The six groups pass 622,887 checks with official headers required. Seven
regression groups pass another 327,350 checks, covering formats, plan/search
schemas, IR, dynamic scaling and bounded exp reduction/refusals. Together these
are 950,237 checks. Formatting is clean. The complete runner was not repeated;
the groups were run individually, with failed test setup assertions corrected
and their affected groups rerun.

These are uniform absolute-error certificates for explicitly bounded floating
contracts. An efficient general large-argument reducer, ulp contracts and correct
rounding remain separate work. Asin/acos endpoint transformations now reuse the
certified root machinery, as described below.

## Asin/acos endpoint transformations

The [standalone example](../examples/inverse_trig_search.jl) generates both
functions on `[-1,1]` with binary16 interfaces, degree-nine sqrt and asin parity
kernels, FMA evaluation and signed 72-bit fixed internals with 48 fraction bits.
The uniform bounds are approximately `0.0004885738889478` for asin and
`0.0009768551389478612` for acos, both below `1/512`. Coefficient and declared
stage storage each total 1,440 bits for the two banks. These are structural
counts, without FPGA resource or throughput measurements.

Every binary16 encoding is checked against directed MPFR references and
visited-node ranges for both separate and fused evaluation. Both generated AC
evaluators are exhausted. Directed C++ compilation also covers portable/AP/AC
fixed arithmetic, native/AC floating arithmetic and public typed interfaces.
Transition tests include predecessor/successor inputs at `|x|=1/2`, the
endpoints and varying endpoint distances. All nonzero tails form
`t=(1-abs(x))/2` exactly; zero, endpoint and invalid-input branches remain lazy.

Further checks cover binary32, binary64, custom formats with 80 fraction bits,
individual coefficient/stage widths, accepted supervised precision reduction,
singleton/clipped contracts, degree-zero kernels, actual CLI generation and
exact stored-plan replay through official AP/AC headers. Malformed coordinates,
root exponent/divisor operations, selections, constants and insufficient
arithmetic precision refuse certification. Both banks participate in precision
proposals and are recertified together.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Certified asin/acos endpoint transformations | 1,054 | Fresh search, separate/FMA proofs, both banks, lazy branches and portable/AP/AC public interfaces. |
| Exhaustive binary16 inverse trig verification | 1,024,024 | Both functions and arithmetic modes over all encodings, directed MPFR bounds, visited ranges and two exhaustive compiled AC evaluators. |
| Inverse trig custom formats and individual precision | 3,635 | Binary32/binary64, small/wide custom formats, individual widths, shared stage proposals and exact public-header conformance. |
| Inverse trig specials, small domains and proof refusals | 2,273 | Zero/endpoint/singleton/clipped contracts, degree-zero kernels, insufficient precision, malformed graphs/constants and unsupported interfaces. |
| Inverse trig precision search, artifacts and replay | 539 | Search v14, labelled certificates, accepted supervised precision reduction, actual CLI generation and exact AP replay. |

The five groups pass 1,031,525 checks with official headers required. Seven
regression groups pass another 325,228 checks, covering formats, plan/search
schemas, IR, root normalization/reconstruction, fixed payload bitcasts and periodic
artifacts. Together these are 1,356,753 checks. Formatting is clean. The complete
runner was not repeated; the groups were run individually, and the special-case
group was rerun after correcting its degree-zero execution assertion.

These are uniform absolute-error certificates for explicitly bounded floating
contracts inside `[-1,1]`. Near-endpoint relative/ulp accuracy and correct
rounding are separate work. Configured design sweeps and numerical caching are
now implemented, as described below.

## Local design sweeps and numerical cache

The [guard example](../examples/design_sweep.jl) evaluates exp with binary16
inputs, binary32 outputs and target `2^-20` on `[-1,1]`. It regenerates degrees
five/nine at guards `{0,3,6,8,10}`, then holds the degree-nine coordinates and
coefficients fixed for a separate stage-width experiment. Both experiments have
passing guards 6, 8 and 10 and retain three structural Pareto rows. The adaptive
comparison certifies approximately `1.376738779803136e-7`; its exact saved plan
is freshly recertified and compiled through official AP/AC headers.

| New group | Checks | Coverage |
| --- | ---: | --- |
| Local sweeps, concurrent workers and exact cache replay | 31 | Bounded overlapping workers, request order, cleanup, exact plans/certificates, AP CPU replay, timing reports, corruption repair and proof-precision invalidation. |
| Numerical cache key coverage and artifact rejection | 18 | Contracts, numerical/arithmetic/format settings, source/native/dependency identities, incompatible schemas, malformed plans/certificates and damaged entries. |
| Sweep failures, Pareto sets and stored stage guards | 18 | All candidates after first success, retained budget failures, passing-only cache, unchanged coefficients, AC CPU replay, independent contract Pareto sets and concurrent publication. |
| Sweep validation, limits and worker recovery | 27 | Invalid inputs/settings, row/total/job limits, late results, controlled crash/hang recovery, parent cancellation and owned-process cleanup. |
| Sweep CLI exact artifacts and public replay | 7 | Actual CLI entry point, atomic report replacement, repeat cache reuse, exact report-plan extraction, fresh certificate and AC replay. |
| Floating transformed cache and exact shared banks | 16 | Acos root/asin banks, all seven branches, changed stage widths, custom floating node/range records, non-dyadic coefficients and public AC floating APIs. |
| Loaded-source cache invalidation | 1 | An isolated copied module accepts its loaded identity and refuses cache use after a numerical source changes. |
| Persistent cache reuse across Julia processes | 3 | Cold/warm CLI runs in separate Julia processes and verified passing hits. |

These eight groups pass 121 checks with official headers required for CPU tests.
Five regression groups pass another 929 checks: search schemas, ordered search,
request validation, isolated worker supervision and bounded precision optimization.
Together these are 1,050 targeted checks. The standalone guard example, fresh
certificate, AP/AC CPU compilation and formatting also pass. The complete runner
was not repeated. A TOML tuple-export bug and a test broadcast setup error were
corrected, and their affected groups rerun. After narrowing the SHA dependency
to version 1, cross-process cache reuse was checked again.

Hits validate exact local artifacts and compatibility rather than rerunning
native norm proofs. Failures/timeouts are not cached. Structural Pareto metrics
are not FPGA measurements. Portable sampled witness overlays are now implemented.
Further cache integration, isolated norm/coefficient caches and eviction are
deferred until repeated numerical work becomes a bottleneck.

## Portable sampled verification

Julia writes exact input/interpreter-output streams and mathematical reference
enclosures. One host C++20 checker, using GMP/MPFR, supplies bit agreement,
absolute-error and global-certificate decisions plus maximum-error witnesses.
Julia invokes the same checker for sweeps and selectively refines unresolved
references. The protocol also accepts captured runner outputs without Julia.
See [the workflow and format](sampled-verification.md).

| New group | Checks | Coverage |
| --- | ---: | --- |
| C++ error decisions, rational equality and witnesses | 46 | Pass/fail/unresolved intervals, signed errors, exact rational equality, separate bit/accuracy/certificate failures, nonfinite outputs and missing-reference coverage. |
| Wide words, exact fixed decoding, custom exponents and byte order | 44 | Signed/unsigned and 320-bit fixed values, binary16/128/256 and custom floats, both byte orders, zero error budgets and extreme exponents without rational expansion. |
| Strict stream and bundle validation | 12 | Truncated/extra words, nonzero padding, mismatched inputs/expected streams, schema rejection, exact reversed-reference checks, invalid rationals/precision and protected report destinations. |
| Bundle preparation, sampling, finite scope and special branches | 35 | Exact stored replay, exhaustive fixed inputs, deterministic boundaries, unchanged Julia precision/rounding, failed-generation cleanup, empty-suite status, fixed-reference overflow, signed zeros and nonfinite/outside coverage. |
| Selective reference refinement and reduction transitions | 7 | An uncertain exp witness resolves after precision refinement; exp/quadrant transitions use stored multipliers. |
| CPU runners with official AP/AC headers and wide AC floating outputs | 14 | Exhaustive accepted fixed inputs through both vendors, actual output/certificate checks, mixed wide input/binary128 output and witness bounds. |
| Sweep observations and verification CLI | 12 | Actual bounded sweep, separate sampled report v2, retained proof/Pareto fields, observation-index validation and both verification/sweep CLI execution. |

These seven groups pass 170 checks locally, with official AP/AC headers required.
All eight sweep/cache regression groups pass another 121 checks, for 291 targeted
checks. The standalone checker-only CMake build and both full CPU CTests pass.
A retained AC run passes all 129 bit/accuracy/certificate cases, and its captured
outputs replay through the standalone checker. Julia formatting and whitespace
checks pass. The complete package runner was not repeated.
Accuracy covers finite inputs in the contract; nonfinite and excluded inputs
exercise exact IR bit policies. Witness branch labels describe the interpreter,
and the certificate comparison currently uses the supplied global bound.
Captured device results can use the same checker later; no hardware execution
or synthesis is claimed. Sampling is separate from full-domain certification.

## Fixed C++ kernels

The kernel emitter and separate host adapter pass four groups with 2,113 checks:

| Group | Checks | Coverage |
| --- | ---: | --- |
| AP CPU scaling regression | 4 | Exact sign extension before heavy downscaling, in all four rounding modes. |
| Fixed kernel arithmetic, branches and intermediate values | 4 | 81 graphs and 50,726 input records per backend; complete successful traces, exact typed/raw outputs and rejection statuses agree with the interpreter. |
| Validate before writing | 23 | Unsupported floating graphs, widths/toolchains/banks and protected destinations; no PRESAGe host dependencies in the header. |
| Bundles, standalone replay, streams and generation | 2,082 | Actual AP/AC C++17 executables, certificate/error checks, all 512 input encodings in status mode, strict input padding/truncation, CLI artifacts and preservation on failed emission. |

The graph matrix includes all fixed rounding/overflow combinations, exact FMA
versus separate rounding, mixed operand scales, 65/129/257-bit interfaces,
wide integer operations and shift counts, all comparisons/classifications,
unsigned/fixed tables, cyclic bank padding, lazy guards/selects, rejection order,
normalized segments and individual coefficient/stage formats. Ordinary C++17
compilation uses official headers with exceptions and RTTI disabled and no
GMP/MPFR linkage. Two existing vendor-matrix regression checks also pass,
covering 16,384 inputs per CPU backend.
Both kernel CMake builds and their numerical CTests pass; the existing CPU build
and both of its CTests also pass. Julia formatting and whitespace checks are
clean. The complete package runner was not repeated.

See [kernel interfaces and supported scope](kernels.md). Public-header
compilation does not establish vendor compiler or synthesis acceptance.

## Encoded floating kernel interfaces

Four additional groups pass 118 checks with official AP/AC headers required:

| Group | Checks | Coverage |
| --- | ---: | --- |
| Conversion and branch conformance | 4 | 479 graphs and 1,567,420 input records per backend; successful intermediate traces, typed/raw outputs and rejection statuses match the exact interpreter. |
| Capability validation | 20 | Unsupported floating arithmetic, normalization and widths fail before writing; emitted headers contain no PRESAGe host dependencies. |
| Maximum conversion work widths | 4 | Signed/unsigned 4096-bit fixed inputs and 4095-bit fixed destinations, all rounding modes and both backends. |
| Mixed plans, erf and captured-output replay | 90 | Certified binary16/32 interfaces, separate/FMA fixed internals, complete binary16 input streams and standalone numerical checks of actual AP/AC outputs. |

The matrix exhausts binary16 encodings for conversion, comparison,
classification, payload-preserving bit casts/CopySign and banked floating LUTs.
Small custom formats cover every fixed rounding/overflow policy and both signs.
Boundary checks cover binary32/64/128/256, custom significands/exponents,
subnormal transitions, signed zeros, NaNs/infinities, directed floating overflow
and extreme static scaling. Very wide exponent fields use finite encodings near
one to keep the exact rational interpreter bounded.

Ordinary C++17 compilation disables exceptions/RTTI and links no GMP/MPFR into
the kernels. Fixed-to-float negative magnitudes use width-preserving complement
and increment; the affected fixed-input matrix passes again after this change.
Both CMake kernel builds and numerical CTests also pass for a certified
binary128-input/binary32-output plan. The existing four fixed-kernel groups pass
2,113 checks. Formatting and whitespace checks pass; the full package runner was
not repeated. Floating arithmetic remains outside kernel emission. Normalization
and reconstruction are described below. Actual vendor compilation and synthesis
remain pending.

## Kernel normalization and exponent reconstruction

Three new groups pass 117 checks with official AP/AC headers required:

| Group | Checks | Coverage |
| --- | ---: | --- |
| Normalization and reconstruction | 4 | 318 graphs and 833,522 input records per backend; exact intermediate payloads, lazy branches, typed/raw outputs and rejection order. |
| Root format widening | 4 | A widened cube-root argument that exceeds 4096 bits is rejected before header output. |
| Certified transformed kernels | 109 | Fresh reciprocal, sqrt/rsqrt, cbrt and log plans; binary16/32 inputs, fixed internals, separate/FMA evaluations, exhaustive binary16 traces and independent checks of captured AP/AC outputs. |

The graph matrix covers exact subnormal normalization, signed exponent
extraction, floor division by two/three and direct final reconstruction.
Input-exponent scaling covers both multipliers and all rounding modes.
Dynamic signed fixed exponents include 8/32/64/129/4096-bit words, minimum
negative values and wide output-format boundaries. Full-magnitude checks precede
scalar conversion. Special source values, shared operands, inactive invalid
branches and competing domain/overflow/table failures retain interpreter policy.
4096-bit floating words and extreme 62-bit exponent fields are checked without
expanding rational inputs. Interpreter input validation now checks the encoded
width directly and leaves numerical decoding to operations that require it.

The affected IR, static floating conversion, capability and maximum-width
regressions pass another 86 checks, for 203 targeted checks. Both CMake kernel
builds and numerical CTests pass for a freshly certified binary32-input,
binary16-output sqrt plan. Formatting and whitespace checks pass. The complete
package runner was not repeated. These are ordinary C++17 public-header checks;
actual vendor compilation, C simulation and synthesis remain pending.

## Limits

Uniform certification covers complete binary16 LUTs, canonical fixed binary16/IEEE32 erf graphs and supported
degree 0–32 float/fixed polynomial kernels with nearest-even rounding and
rejected fixed overflow, including mixed interfaces and custom formats.
Bounded odd sin/sinh/atan/erf, reciprocal, sqrt/rsqrt, signed cbrt, log, atan-tail, exp, sinh/cosh, scaled erfc, bounded sin/cos and asin/acos
kernels also have complete certificates.
Segmented floating erf and other transformation families remain outside the
certificates. The [compact contract](../examples/erf-contract.toml) remains
unchanged; schema v3 stores internal fixed programs and v4 adds fixed interfaces;
schema v5 adds individual coefficient/stage precision, v6 adds exponent
reconstruction, v7 adds sqrt/rsqrt exponent splitting, v8 adds cbrt and v9
adds exact exponent extraction for log; v10 adds rounded floating reciprocals
for atan tails; v11 adds dynamic integer-exponent reconstruction for exp and
v12 adds fixed payload bitcasts for periodic quadrants. A
separate report records the
numerical proof. Native floating CPU arithmetic supports binary32/binary64 with
nearest-even rounding; official AC arithmetic supports custom and wide formats.
Binary16 interfaces and exact conversions are supported,
and fixed helpers also support directed conversions. Binary16 erf is exhausted
for both implementation choices. Polynomial kernels have no near-zero ulp or
correct-rounding guarantee; binary16 LUTs reproduce resolved nearest-even outputs.
Sollya and direct MPFR checks share MPFR algorithms, so their agreement is not
fully independent evidence. Linux, installed vendor toolchains, synthesis and FPGA
performance were not tested. These are separate later gates in the plan.

## Exact-width coefficient ROMs and 512-row dispatch

Local verification covers normalized and fixed-erf layouts through 512 rows,
with nine-bit indices, direct fixed-bit indexing and balanced threshold dispatch.
Official AP and AC C++17 runs compare all visited intermediate payloads, typed/raw results and
rejection statuses against the Julia interpreter.

| Check | Assertions | Coverage |
| --- | ---: | --- |
| Memory depth and width | 50 | Independent tiling, cyclic bank padding, configurable dimensions, unreachable tables and invalid models. |
| Direct fixed segment indexing | 7,179 | Exhaustive signed/unsigned inputs, positive/negative intervals, phase-zero/top-bit-offset layouts, inclusive upper endpoints and comparison fallback for incompatible grids. |
| 512-segment coefficients and certificates | 16,435 | Separate/FMA, every 12-bit fixed input, exact zero-error proof, 17/33/65/9-bit storage columns, center allocation, last-row mutation refusal, serialized replay and fresh Sollya generation. |
| 512-row erf floating dispatch | 6,148 | Binary16/binary32, every threshold and its neighbors, both signs, row 511, zero/tail laziness and canonical graph audit. The synthetic zero coefficients exercise layout, without an erf accuracy claim. |
| Exact-width table payloads | 52 | 1/17/32/33/64/129-bit words, fixed/floating/unsigned tables, partial cyclic banks, rejected padding reads and all 65,536 binary16 lookup encodings. |

The new fixtures execute 94,210 records per vendor backend. Existing normalized
segmentation, binary16 coverage, certificate audits, CLI replay, fixed-erf
certificates, kernel conformance and selective helper checks also pass.
CMake generates and certifies the 512-row evaluator with tracing disabled;
AP and AC builds pass the standalone C++ checker through CTest.
Memory counts assume the declared block dimensions; actual BRAM inference and
resource/timing measurements remain for vendor synthesis.

## Direct floating erf row selection

Binary16/binary32 erf layouts now select rows using exact power-of-two scaling
and downward unsigned integer conversion. At 512 rows the mapping is
`min(floor(abs(x) * 128), 511)`. The inclusive endpoint bypasses conversion;
zero, NaN and tail branches bypass dispatch. Only the tail and endpoint
comparisons are evaluated on the central erf path. General floating normalized
segmentation retains comparison dispatch.

| Check | Assertions | Coverage |
| --- | ---: | --- |
| Exact floating row selection | 85,690 | Counts 1/2/4/16/512; all 34,818 binary16 encodings with magnitude at most 4; binary32 threshold neighbors, both signs and exponent coverage; coarse custom floats with upward-rounded thresholds; AP/AC kernel intermediates, portable/AP/AC CPU APIs and explicit AC float conversion. |
| Comparison fallback | 21 | Incompatible domains, widths, endpoints, counts and threshold payloads; general floating segmentation remains on its existing path. |
| 512-row erf layout | 6,148 | Every binary16/binary32 boundary and its neighbors, endpoint row, special-value laziness and canonical graph audit. |
| Fixed erf certificates | 2,354 | Complete error bound, explicit dispatch overflow ranges, serialized CPU replay and refusal of altered scale, rounding or endpoint branches. |
| Floating erf candidates | 2,125 | IEEE64 separate and IEEE32 fused internals, CPU conformance, signed zeros, NaNs, tails, boundary rows and sampled mathematical accuracy. |
| Existing kernel regressions | 2,126 | Readability, scaling, exact arithmetic, branches, intermediate values, validation, standalone verification and CLI generation. |

These 98,464 targeted assertions pass. A fresh binary32, degree-three, 512-row
erf plan with 31 fractional bits has a complete absolute-error bound of
`3.047668456215022e-8`. Its graph has 47 nodes and four floating constants.
AP/Vitis and AC/oneAPI CMake builds with tracing disabled both pass the standalone
C++ checker through CTest. Reviewable headers and the plan are generated under
`build/float-dispatch-512/`. Julia formatting and whitespace checks pass.
The complete package runner was not repeated; these checks use ordinary local
C++ compilation with public vendor headers. Hardware inference and timing
remain unmeasured.
