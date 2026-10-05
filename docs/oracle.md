# Reference oracle

The oracle answers a different question from an approximation certificate:
**which output bits correctly round the mathematical function at this exact
input?** `FunctionSpec.absolute_error` describes the future evaluator contract;
it does not loosen the oracle's rounding decision.

## Computation

1. Decode the input bits to an exact dyadic rational, retaining signed zero and
   exceptional classifications separately.
2. Apply established primitive domain/special-value identities. A NaN input
   becomes the canonical quiet NaN; a validated domain error is separately
   classified. Generic infinite-input identities are not inferred.
3. Evaluate rational polynomials exactly, covering zeros and rounding ties.
4. Otherwise obtain guaranteed image bounds from a singleton input interval
   with `Sollya.enclosure`. Direct MPFR primitives provide a separate check:
   each is evaluated with downward and upward rounding on explicit-precision
   Julia MPFR objects. Compositions use Sollya, not a sequence of naively rounded
   MPFR calls.
5. Round each exact binary endpoint directly into the output format with integer
   arithmetic. Equal endpoint bits determine the reference. Otherwise double
   the working precision, initially 256 bits, up to the configured limit.

The rounder supports subnormal outputs, signed zero, ties to even and IEEE
overflow. Large native exponents are kept as `(significand, exponent)` pairs;
there is no enormous rational allocation merely to discover underflow or
overflow. The default output rounding is nearest with ties to even.

Direct MPFR references use Julia's MPFR/GMP ABI. Sollya objects use the native
library's own runtime. These are never interchanged. No global BigFloat rounding
or precision is modified, including on Julia 1.10. Sollya calls are scoped and
serialized within a process; use separate processes for concurrent Sollya jobs.
The precision limit bounds PRESAGe refinement, not every internal Sollya
algorithm's working precision or wall time. Worker supervision is a later step.

## Results

| Status | Output bits | Meaning |
| --- | --- | --- |
| `resolved` | Yes | Exact rational value or enclosure endpoints agree. |
| `special` | Yes | Established exact value, signed zero, infinity or NaN policy. |
| `domain_error` | Canonical NaN | Known primitive argument is mathematically invalid. |
| `outside_domain` | No | Input violates the declared finite-input domain. |
| `unresolved` | No | Precision exhausted or an exceptional identity is unsupported. |
| `evaluation_failed` | No | Sollya could not obtain usable mathematical bounds. |

Unexpected programming/system exceptions propagate; they are never converted
to NaN. Invalid compositions can return `evaluation_failed`, since recognizing
the domain of an arbitrary expression needs further analysis. A true zero or
exact midpoint in an unrecognized transcendental identity may remain unresolved.
That is a valid outcome, not a reference value.

## Binary streams

`generate_references` accepts byte-aligned IEEE formats, an explicit `:little`
or `:big` byte order and a configurable chunk size (default 4096 input words).
The last chunk may contain fewer complete words. A trailing incomplete word is
an error. Input buffer storage is bounded by the chunk size, independently of
dataset length; reference computations are sequential and reuse an oracle.

Alongside `OUTPUT.bin`, it writes:

- `OUTPUT.bin.status.tsv`: input/output bits, status, working precision and detail
  for each processed word, including an unresolved failure.
- `OUTPUT.bin.toml`: formats, byte order, expression/domain, reference settings,
  counts, completion and failure information.

The binary is published only after successful completion. Unresolved references
abort the stream; partial binary scratch data are removed while diagnostic
sidecars remain with `complete = false`. Known domain-error NaNs are emitted with
their explicit status. Existing output/sidecars are refused. Readers should
require a complete manifest and inspect status counts before using a dataset.
Datasets must remain unchanged during reference generation.
