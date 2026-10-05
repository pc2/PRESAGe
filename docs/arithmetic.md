# Arithmetic and CPU evaluators

An `IR.Program` is a validated, immutable arithmetic graph with one floating
input and one floating output. Nodes reference earlier nodes by one-based
indices. Tables contain exact bit payloads and use zero-based row indices.

```julia
using PRESAGe

spec = FunctionSpec("1/4+3/2*x-1/2*x^2"; domain=(-2,2))
plan = polynomial_plan(spec, [1//4, 3//2, -1//2]; evaluation=:separate)
evaluate_bits(plan, 0x3f800000) # x=1; result=1.25
write_plan("polynomial.toml", plan)
emit_cpp("evaluator.hpp", plan)
```

The coefficients are supplied explicitly, in ascending order, and stored in the
declared internal format. The expression states the mathematical target; this
constructor does not check that the coefficients approximate it. A bounded
kernel returns canonical NaN outside its finite domain. Nonrepresentable domain
endpoints are rounded inward for input comparisons.

## Operations

| Nodes | Semantics |
| --- | --- |
| `Input`, `Const`, `TableLoad` | Exact input/stored bits; checked table bounds. |
| `Mul`, `Add` | Each operation rounds separately into its declared format. |
| `FMA` | Exact product plus sum, followed by one rounding. |
| `Convert`, `Quantize` | Explicit floating format conversion and rounding. Fixed quantisation is future work. |
| `ScalePow2` | Multiply by an exact power of two, then round once. |
| `Compare`, `Classify`, `Select` | IEEE comparisons and classification; only the selected branch executes. |
| `BitCast`, `ExtractBits`, `BitOp` | Equal-width float/unsigned bit casts, field extraction, masked unsigned operations. Shifts at or above the operand width return zero. |

Arithmetic operands must have the node's format; insert conversions explicitly.
Unsigned values use `IR.UIntFormat(W)` for widths 1–64; conditions use `Bool`.
Table `banks` and `unroll` are implementation metadata and do not alter values.

The interpreter uses exact integer/rational arithmetic with nearest-even,
toward-zero, upward or downward rounding. It supports binary16/32/64 and the
package's custom floating formats, including subnormals and finite exponent
ranges. Arithmetic and conversions canonicalise NaNs; raw loads, selects and bit
casts preserve payloads. Signed zeros follow the operation's rounding semantics.
`interpret_trace(program, bits)` returns output bits and visited node values;
table-index nodes can be inspected to check dispatch.

## C++ backend

The C++20 emitter supports binary32/binary64 and nearest-even rounding. It rejects
other formats or rounding choices. Compile with
`-ffp-contract=off -fno-fast-math -frounding-math`, retain gradual underflow and
use `FE_TONEAREST`. The public evaluator checks the rounding mode. `std::fma`
implements explicit FMA; separate nodes retain separate rounding. Bit conversion
uses `std::bit_cast`. Per-call cached nodes preserve shared computations and lazy
branches without process-global state.

The binary harness processes one input word at a time. `--trace-index` adds an
eight-byte first-table-index field after each output; an unvisited index is
`UINT64_MAX`. This mode is consumed by the CPU conformance checker.

## Fresh erf candidate

`erf_candidate()` approximates `erf(t+center)` with Sollya `fpminimax` in four
dyadic segments covering magnitude `[0,4]`. Tables store the negative centres
and coefficient columns. The program explicitly computes the segment row and
rounded coordinate, evaluates Horner arithmetic, converts to IEEE32 and restores
the input sign. Internal arithmetic is IEEE64 by default. Exact signed zeros,
canonical NaNs and constant tails (including infinities) have lazy branches.

Segment metadata records input-domain endpoints and local-coordinate
coefficients; the arithmetic program defines the coordinate and branch rules.
The default candidate meets the error target on the local sampled checks.
Uniform approximation, arithmetic, output-rounding and tail bounds have not
been established. Fixed arithmetic and complete certificates are the next work.
