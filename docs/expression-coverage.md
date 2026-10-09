# Function expression coverage

PRESAGe already supports general single-variable mathematical expressions through
Sollya. Smooth expressions on explicit bounded intervals use the generic
polynomial planner; they do not require a dedicated implementation for each
function appearing in the expression. Successful generation remains conditional
on a complete certificate meeting the contract.

## The generic path

Sollya approximates the **whole expression** with stored coefficients. PRESAGe
builds a Horner evaluator, optionally with normalized segments, and certifies
approximation error, coordinate formation, arithmetic and output rounding.
The generated hardware evaluates these polynomials and their coefficient tables.

For example:

```julia
using PRESAGe

spec = FunctionSpec("exp(x)+0.1*x";
    input_format=IEEE32, domain=(-1,1), absolute_error=1//(1<<21))
result = certified_polynomial(spec; degree=13,
    internal_format=FloatFormat(8,27), evaluation=:fma,
    generation_precision=256, proof_precision=256)
```

Inspect `result.status` before using the evaluator. Generation can fail, a proof
can fail, or a conservative certified bound can exceed the requested budget.
Sampling never substitutes for a failed uniform proof. Use
[ordered search](certification.md#ordered-search-and-worker-limits) or
[resource-aware sweeps](implementations.md) to compare configured candidates.

The generic planner requires an explicit bounded domain and a finite Sollya
enclosure of the expression on each proof interval. Input/output formats,
arithmetic policies and internal ranges must satisfy the
[polynomial certification requirements](certification.md#polynomial-kernels).
Decimal and scientific literals retain exact rational semantics.

Current search limits are degree **0–32 per polynomial** and **1, 2, 4, …, 512
uniform normalized segments**. Degree, segment count, formats and execution
limits are supplied by the caller. Smoothness helps approximation but does not
guarantee that generation or certification succeeds within those limits.

## Difficult expressions and domains

| Case | Current support and limitation |
| --- | --- |
| Smooth, finite expression on a moderate bounded interval | Generic approximation is available. Success depends on the error target, formats, search limits and Sollya proof. |
| Strong variation or high oscillation | Uniform segmentation may require excessive degree, storage or arithmetic precision. Adaptive segmentation is not implemented. |
| Kinks, discontinuities or removable singularities | Generation or proof may fail. Automatic breakpoint discovery, branch construction and singularity regularization are not implemented. |
| Very large floating domains | Practical approximation often needs range reduction. Existing certified reductions cover specific recognized primitive expressions. Large-argument periodic reduction remains separate work. |
| Compositions that need internal reductions | The generic path approximates the complete expression directly. It does not automatically combine specialized reduced kernels and their error proofs. |

Existing transformations, such as exponent splitting for roots or quadrant
reduction for sin/cos, must be requested explicitly and require their supported
primitive expression. They are not automatically discovered inside a larger
composition. See [transformation proofs](certification.md) and
[generation options](generation.md).

A valid Sollya mathematical expression alone does not guarantee a feasible
contract. A domain can include a pole or invalid argument; the output format can
be unable to represent a result within the requested error; or the resource
budget can exclude every available design. The interface accepts mathematical
function expressions, rather than arbitrary Sollya programs.

## Small input formats: exhaustive LUTs

The LUT backend gives broader expression coverage without polynomial
approximation. Every covered finite input must have a resolved reference and a
finite output, and the exhaustive absolute error bound must meet the contract.
Unresolved references, poles and mathematical domain errors prevent certification.

The default limit is **65,536 entries**, allowing up to 16 input bits. Tables
contain every raw input encoding, including placeholders outside a bounded
domain. Wider inputs make full enumeration and storage increasingly expensive.
See [LUT limits and semantics](implementations.md#lut-limits-and-semantics).

## Further planner development

The most useful extensions for broader automatic coverage are:

1. **Adaptive segmentation and explicit breakpoints:** concentrate polynomial
   rows where approximation is difficult and handle separate smooth regions.
2. **Expression analysis:** identify invalid regions, removable singularities
   and transformations justified by established identities or proofs.
3. **Composable certified reductions:** reuse reduced kernels inside larger
   expressions and propagate their errors through reconstruction and composition.
4. **Additional proof strategies:** subdivide difficult proof intervals and
   exhaust suitably small input regions when uniform norm proofs fail.

These are planner extensions with their own proof requirements. Ordinary bounded
expression support is already present; robust automatic treatment of difficult
expressions needs this additional work. Any implementation still has to meet its
numerical contract and resource budget. Vendor synthesis separately establishes
backend acceptance and [achieved II=1](resources.md#design-objective-resources-at-ii1).
