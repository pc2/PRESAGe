# Uniform numerical certification

## Fixed polynomial kernels

`certify_polynomial(plan)` proves a fixed-input/fixed-output `polynomial_plan`
with degree 0–32, fixed internals, nearest-even rounding and rejected overflow.
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
the input grid. An omitted domain covers the complete fixed input format.
Inputs outside the domain are rejected before arithmetic executes. Singleton
domains are supported with certified point enclosures.

Sollya checks a finite function image and bounds the stored polynomial's
absolute approximation error on the input interval. Exact symbolic constant
differences, including a zero error, are proved by error-free canonicalization,
simplification and exact rational extraction; other nondegenerate errors use
`supnorm`. Failed proofs do not fall back to sampling. Sollya's expression
semantics and native proof assumptions apply; intervals containing poles or
invalid values are refused when their image cannot be bounded finitely.

Exact rational interval propagation bounds every reachable fixed node. Its
endpoints are rounded under the declared policy and checked for overflow.
The analysis tracks a guaranteed dyadic grid for each value: stored constants
can use fewer fractional bits than their format, addition aligns operand grids,
and multiplication combines them. Operations preserving that grid are exact;
otherwise nearest-even rounding contributes at most half a target quantum.
Singleton ranges give an exact rounding error. This proves zero total error for
the affine example, including its output conversion.
Unused nodes are excluded from range checks; a constant polynomial does not
execute its unused input conversion.

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

`certify_plan(plan)` selects this proof or the canonical erf proof below.
The generation and recertification CLIs support both. Newly generated fixed
polynomial plans certify by default; use `--certify=false` for an unchecked
candidate. Reports use schema version 2, `PathCertificate.domain` and
method-specific coverage. Numerical certification applies to the exact IR;
CPU conformance checks validate the emitted implementations locally.

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

`certify_erf` supports the canonical fixed IEEE32 `erf` graph with nearest-even
rounding and rejected overflow. Other graphs return an explicit unsupported
result. Floating arithmetic, mixed interfaces and general reductions do not
have uniform evaluator certificates yet.

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
performance require further work.
