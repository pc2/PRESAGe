# Uniform erf certification

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

Certification currently supports the canonical fixed IEEE32 `erf` graph with
nearest-even rounding and rejected overflow. Other graphs return an explicit
unsupported result. Floating candidates and other functions do not have uniform
evaluator certificates yet.

## What is proved

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

## Results and limits

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
rounding, near-zero ulp accuracy, vendor arithmetic and hardware performance
require further work.
