# Uniform numerical certification

## Reciprocal mantissa kernels

`certified_polynomial(spec; transformation=:reciprocal, degree=7, …)` and the
same option in `PolynomialSearchConfig` build `1/x` from one polynomial
approximating `1/m` on `[1,2]`. For every finite nonzero floating input,
`normalize_float(bits, format)` gives the exact decomposition
`abs(x)=m*2^e`, `1≤m<2`, including subnormals. The evaluator converts m to the
coordinate format, executes the chosen Horner graph, reconstructs with `2^-e`
and restores the original sign.

Input/output must be floating; internals may be fixed or floating with
individual coefficient and stage formats. The domain must be bounded and
strictly positive or strictly negative. Zeros, infinities, NaNs and inputs
outside that domain return canonical quiet NaN before normalization or kernel
arithmetic. Full-domain reciprocal special values and disconnected domains are
not yet supported. Output overflow refuses a finite absolute-error certificate.

The complete graph audit verifies normalization, coefficient payloads, all
conversions, arithmetic order, reconstruction, sign copying and the domain
guard. Sollya certifies the actual stored polynomial on `[1,2]`. If its norm
upper bound is N, coordinate error is C and arithmetic error is V, the kernel
error is `N+C+V`. The certifier bounds the last Horner value using the exact
function image `[1/2,1]` enlarged by this error, with outward format rounding.
This certified enclosure tightens the interval bound before reconstruction;
no samples determine the range.

For the accepted input exponent interval `[e_min,e_max]`, let `S=2^-e_min`.
The uniform total error is bounded by

```text
S * (N + C + V) + R
```

R bounds the direct reconstruction quantizer, including subnormal output
rounding. The last stage scales directly into the output format without an
intermediate output conversion. Exact normalization, exponent multiplication
and sign copying add no rounding. Since `1/m` is positive, copying its sign to
the magnitude of a computed kernel cannot increase approximation error:
`||p|-1/m|≤|p-1/m|`.

This bound covers all representable inputs in the contract without enumerating
exponents. It is conservative for wide exponent intervals under an absolute
error target. Search and precision reduction retain the same proof and worker
limits. See [generation](generation.md) and the
[worked example](../examples/reciprocal_search.jl).

## Polynomial kernels

`certify_polynomial(plan)` proves a `polynomial_plan` or normalized segmented
evaluator with degree 0–32,
floating or fixed input/output and internals, nearest-even rounding and rejected
fixed overflow. Custom floating exponent/fraction widths are supported.
Separate multiply/add and FMA have distinct proofs. Unsupported graphs and
policies return `unsupported_domain`; possible overflow or native proof failure
returns `proof_failed`. A successful proof above the requested budget returns
`bound_exceeds_budget`.

```julia
using PRESAGe
spec = FunctionSpec("x/2+1/4";
    input_format=FixedFormat(9,4), output_format=FixedFormat(13,5))
plan = polynomial_plan(spec, [1//4,1//2]; internal_format=FixedFormat(24,8))
result = certify_polynomial(plan)
@assert result.status == :certified && result.total_bound == 0
```

The certifier extracts coefficients from the stored IR, rebuilds the canonical
Horner program and compares the entire graph, including constants, conversions,
rounding order and the lazy domain guard. A kernel label cannot authorize a
proof. Changed coefficients are proved afresh against the contract's function.

Coverage is every representable input inside the declared domain. The proof
interval is clipped to the input format and its endpoints rounded inward to
the input grid. An omitted domain covers every finite input in the format.
Inputs outside a bounded domain return canonical NaN for floating output or
are rejected for fixed output before arithmetic executes. Singleton
domains are supported with certified point enclosures.

Sollya checks a finite function image and bounds the stored polynomial's
absolute approximation error on the input interval. Exact symbolic constant
differences, including a zero error, are proved by error-free canonicalization,
simplification and exact rational extraction; other nondegenerate errors use
`supnorm`. Failed proofs do not fall back to sampling. Sollya's expression
semantics and native proof assumptions apply; intervals containing poles or
invalid values are refused when their image cannot be bounded finitely.

Exact rational interval propagation bounds every reachable arithmetic node. Its
endpoints are rounded under the declared policy and checked for overflow.
The analysis tracks a guaranteed dyadic grid for each value: stored constants
can use fewer fractional bits than their format, addition aligns operand grids,
and multiplication combines them. Operations preserving that grid are exact;
fixed nearest-even rounding otherwise contributes at most half a target quantum.
Singleton ranges give an exact rounding error. This proves zero total error for
the affine example, including its output conversion.
Unused nodes are excluded from range checks; a constant polynomial does not
execute its unused input conversion.

### Floating precision and guard bits

Floating endpoints are rounded exactly in the declared format. Monotonicity
bounds each implemented node, and an endpoint rounding to infinity refuses the
proof. A finite result just above the largest finite value can still be proved.
For a nonexact operation, the local nearest-even bound is half the largest
spacing on its exact range. Below the normal range this is half a subnormal
quantum, including underflow to zero. Dyadic grids, exact widening conversions
and zero/unit identities eliminate unnecessary rounding allowances.

Use `internal_format=FloatFormat(E,M+g)` for `g` extra fraction bits. The same
format stores coefficients and rounds each Horner stage by default. Input conversion is
exact when the wider format can represent the inputs. Final narrowing is
bounded separately; if no output conversion exists, the final operation's
rounding belongs to the arithmetic bound. More fraction bits do not enlarge
exponent range; every intermediate is checked against its declared limits.

```julia
spec = FunctionSpec("1/4+x/2-x^2/4"; input_format=IEEE32, domain=(-1,1))
plan = polynomial_plan(spec, [1//4,1//2,-1//4];
                       internal_format=FloatFormat(8,27), evaluation=:fma)
result = certify_polynomial(plan)
@assert result.status == :certified
```

Coefficient quantization is included in the stored-polynomial norm. Proof
precision is independent of evaluator precision; insufficient Sollya precision
to reconstruct the stored polynomial or domain returns `proof_failed` and can
be retried with a higher `precision`. Signed-zero coefficient payloads remain
part of the graph audit. Numerical error treats both zeros as the value zero;
it does not establish correctly rounded output or a signed-zero policy for
general polynomial functions.

For input `x`, rounded coordinate `z`, ideal Horner intermediate `h_k(x)`,
`T >= abs(z)`, coordinate error `eta >= abs(z-x)` and interval magnitude
`H_(k+1) >= abs(h_(k+1)(x))`, propagate:

```text
C_d = 0; V_d = 0
C_k = T*C_(k+1) + eta*H_(k+1)
V_k = T*V_(k+1) + rho_k
total = approximation_upper + C_0 + V_0 + output_rounding
```

`rho_k` includes the actual multiply/add quantizers or the single FMA quantizer.
The input domain can exceed one in magnitude; its amplification is included.
Output conversion is separately bounded and checked for overflow. A conservative
range or error bound can refuse a correct candidate; this is not an infeasibility
proof.

The [bounded example](../examples/bounded_polynomial.jl) uses degree nine,
`Fixed(9,3)` input, `Fixed(32,6)` internals and `Fixed(24,4)` output on `[-1,1]`.
The separate-operation uniform bounds are about `1.083e-6` for erf and
`5.520e-7` for exp, both below `2^-18`. Each domain contains 129 input values.

`certify_plan(plan)` selects this proof, the canonical erf proof or exhaustive
binary16 LUT verification. The generation and recertification CLIs support all three. Newly generated
polynomial plans certify by default; use `--certify=false` for an unchecked
candidate. Reports use schema version 2, `PathCertificate.domain` and
method-specific coverage. Numerical certification applies to the exact IR;
CPU conformance checks validate the emitted implementations locally.

## Generating a bounded evaluator

`certified_polynomial(spec; degree, internal_format, ...)` generates coefficients,
builds the canonical Horner graph and returns its complete `CertificationResult`.
It requires an explicit domain and a maximum degree in `0:32`. Coefficients and
stages share the internal format by default; input and output formats remain independent.
The supported arithmetic policies are the same as `certify_polynomial` above.

```julia
spec = FunctionSpec("exp(x)+0.1*x";
    input_format=FixedFormat(9,3), output_format=FixedFormat(24,4),
    domain=(-1,1), absolute_error=1//(1<<18))
result = certified_polynomial(spec; degree=9,
    internal_format=FixedFormat(32,6), evaluation=:separate,
    generation_precision=256, proof_precision=256, accuracy=1//1024)
@assert result.status == :certified
```

Generation, domain guards and proof share the same clipped, inward-rounded
input interval. Empty representable domains and invalid settings raise
`ArgumentError`. Exact rational polynomials that fit the format are exported
directly. Other ordinary intervals use Sollya `fpminimax` with absolute error:
fixed formats specify fractional bits, floating formats specify significand
bits. Each returned coefficient must fit the storage format exactly, including
its exponent range and subnormal spacing. A singleton interval uses a constant
selected from a certified point enclosure, avoiding a degenerate Remez problem.

`generation_precision` controls the coefficient computation;
`proof_precision` controls the complete evaluator proof. `accuracy` controls
norm tightness, and `max_refinements` bounds tightness refinement. The contract's
absolute target remains separate. Parsing, approximation, references and proof
use matching exact decimal/scientific literal semantics.

Numerical generation failure returns `generation_failed`, a reason and a
contract-only plan. After successful generation, the usual certificate statuses
apply, and the stored evaluator is retained even for `bound_exceeds_budget` or
`proof_failed`. Only `certified` establishes the complete contract; a successful
Sollya approximation alone is insufficient. Existing plan/certificate writers,
stored-plan generation and recertification work with the returned artifacts.

This API performs one synchronous attempt without a wall-time limit. Use
`search_polynomial` for supervised generation and proof.

## Normalized segments and coverage

```julia
spec = FunctionSpec("exp(x)"; input_format=FixedFormat(9,3),
    output_format=FixedFormat(24,4), domain=(-1,1), absolute_error=1//(1<<18))
result = certified_polynomial(spec; degree=5, segments=4,
    internal_format=FixedFormat(32,6), evaluation=:fma)
@assert result.status == :certified && length(result.paths) == 4
```

`segments=1` keeps the original single polynomial. Counts 2, 4, …, 64 use equal
subintervals of the representable contract interval. Nominal boundaries are
exact dyadic rationals. Each emitted threshold rounds upward in the **input**
format, with `input >= threshold` selecting the next row. Every proof path is a
closed interval between its first and last reachable input values; consecutive
endpoints are numerical neighbours in the input format. This proves coverage
without gaps or overlapping inputs. Both signed zeros select the same row.
Empty representable branches are rejected before launching a search worker.

Centres are rounded to the shared internal format, and the mathematical kernel
uses these stored centres exactly. A common power-of-two scale makes every ideal
coordinate `t=(x-center)*2^k` lie within `[-1,1]`. Sollya generates and proves
`f(center+t*2^-k)` separately on each branch's ideal coordinate interval.
Input conversion, subtraction and scaling execute as explicit IR nodes.
Their accumulated coordinate error is propagated through Horner; the actual
rounded coordinate may extend beyond the ideal interval. Range proofs bound
this actual coordinate and all perturbed intermediates before accepting the
complete error certificate. Final output conversion is bounded separately.

The canonical graph audit compares every threshold, row selector, centre and
coefficient payload, scale exponent, arithmetic node, conversion and lazy guard.
Metadata or a kernel label cannot authorize a changed graph. Coefficient rows
share one padded degree and a common evaluator. Their formats default to the
coordinate format; individual formats are also supported as described below.
All paths must prove their error budget; the reported total is their maximum.
Certificate paths include input coverage, ideal and rounded coordinate domains,
error contributions and reachable node ranges. Constant rows that skip coordinate
arithmetic have no rounded coordinate range.

Fixed internals require signed nearest-even arithmetic with rejected overflow.
The selected format must hold the input conversion, stored negative centres and
unscaled subtraction as well as the normalized coordinate and Horner stages.
Segmentation does not automatically widen integer or exponent ranges.
Singleton branches use certified point enclosures; a singleton whole contract
uses the existing `segments=1` path. `segmented_polynomial_plan(spec, rows; ...)`
also accepts supplied ascending coefficients **in the normalized coordinate**.
Use `certified_polynomial` to generate them automatically.

## Ordered search and worker limits

```julia
config = PolynomialSearchConfig(degrees=[1,9],
    internal_formats=[FixedFormat(16,6), FixedFormat(32,6)],
    generation_precision=256, proof_precision=256,
    accuracy=1//1024, max_refinements=2,
    max_attempts=4, job_timeout=60, total_timeout=300)
search = search_polynomial(spec, config)
write_search_report("search.toml", search)
@assert search.status == :certified
certificate = search.selected
```

Choice lists must be nonempty finite vectors or tuples without duplicates.
An optional `segments=[1,4,8]` adds segment-count choices; the default is `[1]`.
Counts are visited first, then degrees, then formats, each in caller order.
Selection stops at the first complete passing certificate.
This policy provides a feasible evaluator without optimizing hardware cost.
Increasing fixed fractional precision or floating significand precision does
not change an integer or exponent range: supply each desired format explicitly.

All contract, format and numerical settings are validated before a worker starts.
Invalid settings and empty representable domains raise `ArgumentError`.
The search clock starts after validation. Each attempt starts a fresh Julia
process in the caller's active project and depot, with one Julia thread.
Generation and certification happen there, and native objects never cross the
process boundary. Startup, generation and proof count toward `job_timeout`
and `total_timeout`, measured with a monotonic clock. A worker exceeding either
limit is killed and reaped, and its temporary files are removed. Cleanup and
reading exact results can add a small amount of time beyond a deadline.
The next attempt starts with a fresh worker. There is no persistent pool,
parallel candidate execution or cache yet.

`PolynomialSearchResult` contains `status`, `selected`, `attempts`,
`elapsed_seconds` and `stop_reason`. A successful search has status and stop
reason `certified`, with its `CertificationResult` in `selected`. Exhaustion
returns `search_limit` with `selected=nothing` and one of these stop reasons:

| Stop reason | Meaning |
| --- | --- |
| `choices_exhausted` | Every supplied segment/degree/format combination was attempted. |
| `attempt_limit` | Further choices remain, but the maximum attempt count was reached. |
| `total_deadline` | The total time limit expired; any active worker was stopped. |

Each `SearchAttempt` records segment count, degree, internal format, status, elapsed seconds,
reason, an optional exact `plan` and an optional `certificate`. Normal numerical
statuses remain `generation_failed`, `bound_exceeds_budget`, `proof_failed` or
`certified`. Supervision adds `timeout`, `worker_crashed` and `worker_failed`.
An individual timeout, crash or numerical failure advances to the next choice
if limits permit. A total timeout stops the search. No further candidate starts
after success or a limit. Exhaustion makes no mathematical infeasibility claim.

Workers checkpoint a generated plan before proof. Interrupted proofs can
therefore retain coefficient payloads and the IR, even without a certificate.
Late completed certificates may be retained for inspection but cannot select
a candidate after a time limit. `write_search_report` saves the choices, limits,
attempt history, exact available plans and proof contributions. Save the actual
coefficients: repeating fpminimax with changed numerical settings can produce
different coefficients. A stored candidate can be read and recertified without
repeating generation.

## Complete IEEE32 erf evaluator

`certified_erf()` generates and certifies a fixed IEEE32 evaluator. The default
has degree nine, four magnitude segments on `[0,4]`, 31 fractional bits and
separate multiply/add operations. Its uniform total absolute bound is about
**`6.321e-8`**, below `2^-23`. The report stores exact rational bounds.

```julia
using PRESAGe
result = certified_erf()
@assert result.status == :certified
write_plan("plan.toml", result.plan)
write_certificate("certificate.toml", result)

# Rerun the proof over a serialized evaluator.
certify_erf(read_plan("plan.toml"))
```

`certify_erf` supports the canonical fixed binary16 or IEEE32 `erf` graph with nearest-even
rounding and rejected overflow. Other graphs return an explicit unsupported
result. The segmented floating `erf_candidate()` and general reductions do not
have uniform evaluator certificates yet; bounded float/fixed polynomial kernels
use the proof above.

### What is proved

The certifier reconstructs the evaluator from its stored coefficients and
numerical choices, then compares every node and table with the executed graph.
This checks thresholds, coefficient bits, coordinate construction, rounding
order, conversions, sign restoration and exceptional branches. Segment metadata
must cover `[0,4]` without gaps. Each segment proof includes both endpoints;
the emitted predicates select the next row at internal boundaries.

For each segment centre `c`, Sollya `supnorm` bounds the stored polynomial's
absolute error against `erf(t+c)` on the exact closed coordinate interval.
Coefficient representability and native polynomial reconstruction are checked
exactly. Norm tightness is independent of the function's error target. A norm
enclosure straddling its allocation triggers bounded tightening; proof failure
does not use sampling as a fallback.

The implemented coordinate is `t_hat = round_fixed(abs(x)) - c`. Dyadic
centres/endpoints lie on the fixed grid. Nearest-even rounding is monotone, so
the computed coordinate stays inside the segment's closed interval. Its error
is at most `eta = 2^(-F-1)`. Coordinate subtraction is exact in a widened format.

For the exact Horner recurrence `h_k = a_k + t*h_(k+1)`, bound its intermediate
by `H_(k+1)` and both coordinate magnitudes by `T`. Propagate separately:

```text
C_d = 0
V_d = abs(quantized(a_d) - a_d)
C_k = T*C_(k+1) + eta*H_(k+1)
V_k = T*V_(k+1) + rho_k
```

`rho_k` sums the actual quantizers' bounds. Narrowing the fractional scale
contributes half a target quantum; conversions preserving the scale are exact.
Aligned fixed addition at the same scale is exact. Separate multiplication
rounding and fused rounding remain distinct, including parity at ties.

Exact rational interval propagation bounds every implemented fixed node,
including widened products/sums before quantization and stored intermediates
afterwards. Common integer widths cover all segments. The proof checks each
range against the declared format and bounds the final IEEE conversion without
overflow. Final output rounding contributes a spacing bound derived from the
implemented output range, including subnormals.

Each central path's total is:

```text
approximation_upper + coordinate_error + arithmetic_error + output_rounding
```

The largest default bound is on magnitude `[0,1]`:

| Contribution | Approximate upper bound |
| --- | ---: |
| Stored polynomial approximation | `2.779e-9` |
| Coordinate quantization, propagated | `3.568e-10` |
| Evaluator quantization, propagated | `4.648e-10` |
| IEEE32 output rounding | `5.960465e-8` |
| Total | `6.321e-8` |

For magnitude greater than four, monotonicity and `erf(x) <= 1` give
`abs(1-erf(x)) <= 1-erf(4)`. An enclosed endpoint evaluation bounds this tail by
about `1.542e-8`. Exact odd sign restoration covers negative inputs. Dedicated
branches preserve both signed zeros, return ±1 at infinities and canonicalize
NaNs. NaNs are outside numerical error comparisons.

### Results and limits

Results are `certified`, `bound_exceeds_budget`, `proof_failed`,
`unsupported_domain` or `search_limit`. A conservative bound above budget or
exhausted width search does not prove mathematical infeasibility.
`certified_erf` starts from the guard heuristic `ceil(log2(16*degree))`, refines
fractional widths in steps of two, and stops at the configured maximum.
Degree, segmentation, coefficient scale, generation precision, proof precision
and norm accuracy are independent controls. Wider coefficient choices regenerate
the polynomial and its certificate.

The numerical certificate applies to the exact IR. Local C++ conformance tests
check emitted bits and table decisions against its interpreter, including
boundaries, exceptional values, ties and arbitrary-width arithmetic. Sampled
reference errors are additional evidence and are reported separately. Correct
rounding, near-zero ulp accuracy, synthesis-toolchain conformance and hardware
performance require further work for polynomial evaluators.

## Individual coefficient and stage precision

`PolynomialPrecision(coordinate_format; coefficient_formats, stage_formats)`
declares separate storage and arithmetic formats for degree 0–32 polynomial
evaluators. Both lists have `d+1` entries in ascending power order:
`a_0,…,a_d` and `h_0,…,h_d`. `h_d` is the initial coefficient load. Formats use
one fixed or floating family, with independent input/output interfaces. Fixed
arithmetic uses nearest-even rounding and rejected overflow. Lists are copied
into tuples; each stage's format is shared across all segments.

Pass `precision=layout` to `polynomial_plan`, `segmented_polynomial_plan` or
`certified_polynomial`. The coordinate format becomes the internal default;
an explicitly supplied internal format must match it. Generation accepts lists
covering the requested maximum degree, truncating to the actual stored degree.
Sollya receives each coefficient's fractional/significand precision separately.
Each exported coefficient must fit its own declared storage range exactly.
Coefficient generation precision and proof precision remain independent of
these target formats.

Before stage `k`, the evaluator explicitly converts the previous accumulator,
coordinate and stored coefficient into `stage_formats[k+1]`. Fixed-to-fixed
changes use `Quantize`; floating changes use `Convert`. Separate multiplication
and addition each round, while FMA rounds once. Initial coefficient loading and
final output conversion also execute explicitly when their formats differ.

The certifier rebuilds the complete graph and tables from the stored layout,
then compares payloads, format metadata, conversions, quantizers and arithmetic
order. Every conversion and intermediate range is checked for overflow. For
each stage, let `T_k` bound its actual rounded coordinate and `H_(k+1)` bound
the ideal stored-polynomial accumulator. Error propagation is:

```text
C_d = 0
V_d = initial coefficient conversion error
C_k = T_k*C_(k+1) + (coordinate formation error + rho_tk)*H_(k+1)
V_k = T_k*V_(k+1) + T_k*rho_hk + rho_ak + arithmetic rounding
```

The `rho` terms cover the coordinate, previous-accumulator and coefficient
conversions. Arithmetic rounding is the separate product/addition sum or the
single FMA bound. The stored-polynomial norm accounts for coefficient storage
error, and final output rounding is added separately. Normalized branches retain
their complete coverage and coordinate-formation proofs.

### Bounded precision reduction

`optimize_precision(baseline; max_attempts=64, job_timeout=60,
total_timeout=300, bit_step=1, min_precision_bits=0)` accepts a certified bounded
polynomial. It audits and freshly recertifies the baseline in an owned worker;
this counts as the first attempt. It proposes fixed integer-range reductions,
then fractional/significand reductions ordered by coordinate bounds and
amplification through later stages. Estimates only order proposals.

Coefficient format changes regenerate coefficients and their norm proof. Stage
changes reuse exact stored coefficients, preserving constant payloads including
negative zero, and recertify the complete evaluator.
Only passing certificates with reduced declared storage/arithmetic widths are
accepted. A failed reduction, worker failure or exhausted limit retains the last
passing plan. The result's `stop_reason` distinguishes attempt/deadline/choice
exhaustion and baseline failure. No globally optimal layout is claimed.

Coordinate formats stay fixed. Floating fraction bits can shrink to one; exponent
headroom stays unchanged. Fixed formats retain at least one integer bit, with
integer widths checked across all rows. Additional rounding policies require
their own proof and conformance coverage.

`precision_cost(plan)` counts coefficient bits, per-coefficient/per-stage widths,
static arithmetic result and operand bits, table bits and conversions.
`write_precision_report` records before/after counts, exact plans, complete
certificates and accepted/rejected history. These structural counts do not
estimate DSP/BRAM use, throughput or timing. Plans with explicit layouts use
schema v5; ordered search configurations use v3 with `precisions` aligned to
internal format choices. Stored plans replay without another coefficient search.

## Odd function kernels

`transformation=:odd` enables one bounded `x*q(x²)` kernel for the exact primitive
expressions `sin(x)`, `sinh(x)`, `atan(x)` and `erf(x)` (whitespace is allowed).
These functions have established odd identities and exact zeros. Composed
expressions and heuristic parity estimates do not authorize this transformation.
The original polynomial degree must be odd and in `1:31`; q has at most
`(degree+1)÷2` coefficients. Explicit precision lists describe q in ascending
power order. Both arithmetic families, separate/FMA evaluation and independent
interfaces are supported. Segmentation is not yet combined with this option.

```julia
spec = FunctionSpec("sin(x)"; input_format=IEEE16, output_format=IEEE16,
    domain=(-1,1), absolute_error=1//2^9)
result = certified_polynomial(spec; degree=9,
    internal_format=FixedFormat(32,6), transformation=:odd, evaluation=:fma)
```

Generation first approximates the function in a regular dense basis on `[-R,R]`,
where R bounds the accepted input magnitudes, then retains its odd coefficients.
Sparse odd Remez calls failed native convergence in local experiments, including
on `[0,1]`. The discarded even coefficients are not assumed to vanish. The proof
certifies the *actual stored* expanded polynomial `x*q(x²)` directly against the
function on `[0,R]`; established oddness extends that norm to negative inputs.
There is no division by x or unproved quotient limit at zero.

The graph audit checks every coefficient, conversion, stage, square,
reconstruction, zero test and domain guard. Range propagation handles the
correlated square as a nonnegative interval. Let x be the exact input, a its
converted coordinate, B bound `abs(a)`, and `ηx` bound `abs(a-x)`. If `ρsquare`
bounds the square's local rounding, its coordinate formation error is
`ηz = ηx*(B+R) + ρsquare`. Horner propagation uses this error and includes
every stage coordinate conversion. With ideal Q = q(x²), let Cq bound coordinate
error, Vq bound arithmetic error, and Lq bound the final q conversion into the
coordinate format. Reconstruction contributes:

| Contribution | Bound |
| --- | --- |
| Coordinate error | `B*Cq + ηx*max(abs(Q))` |
| Arithmetic error | `B*(Vq+Lq) + ρreconstruction` |
| Output conversion | Its own local rounding bound |

The approximation norm and these contributions sum to the complete absolute
error bound. Exact rational grids remove local allowances only when justified.
Endpoint ranges reject possible overflow at every reachable arithmetic node.
A constant q does not execute the square. A zero-only contract executes only
the zero branch, so unused arithmetic cannot invalidate its exact bound.

The original input's zero test precedes evaluation through a lazy select.
Floating input/output pairs preserve both zero signs by conversion; fixed
outputs return exact zero. A nonzero input that rounds to a zero coordinate
still follows the ordinary numerical proof. Outside-domain and nonfinite guards
execute first. No tiny-argument shortcut is implemented, especially no generic
erf return-x rule.

Use the same option in `PolynomialSearchConfig` for supervised attempts.
`optimize_precision` preserves the transformation, includes reconstruction
magnitude in proposal estimates and freshly certifies every candidate.
`odd_polynomial_plan(spec, coefficients; precision, evaluation)` builds a
candidate from supplied ascending coefficients of q. Stored plans replay through
the existing certification and C++ commands. See the [example](../examples/odd_search.jl).

## Exhaustive binary16 lookup tables

`certified_lut(spec)` builds a full 65,536-entry table for matching binary16
interfaces on all finite inputs. The default reference backend is direct MPFR.
Adaptive enclosures must resolve a unique nearest-even output; every finite
input must have a finite result. Exact primitive zero/unit cases use their
established identities. Nonfinite inputs use the shared primitive policy.
Domain errors at finite inputs, nonfinite finite-input results and unresolved
references stop generation with explicit failure status.

For each finite input, the stored output's absolute error is bounded against
both directed enclosure endpoints. The maximum across the complete finite
format is a uniform error bound, rather than a sampled maximum. For erf, this
bound is about `2.4401e-4`, below `2^-10`. Every finite output also matches the
resolved nearest-even reference, including subnormal results and signed zeros.

`certify_lut(plan)` audits the canonical input-bitcast-table-load graph, table
format and complete entry count, then resolves all references afresh. Changed
entries cannot retain a certificate. Reports use method
`binary16_exhaustive_lut` and explicitly record exhaustive coverage.
Generation through `certified_erf` selects a LUT or fixed polynomial by the
configurable table-bit threshold; explicit selection bypasses that threshold.
This selection policy contains no measured FPGA performance assumptions.
