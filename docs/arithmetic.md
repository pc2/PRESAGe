# Arithmetic and CPU evaluators

An `IR.Program` is a validated, immutable arithmetic graph with one float/fixed
input and one float/fixed output. Nodes reference earlier nodes by one-based
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
| `Convert`, `Quantize` | Explicit float/fixed conversions, fractional quantisation and overflow policy. |
| `ScalePow2` | Multiply by an exact power of two, then round once. |
| `Compare`, `Classify`, `Select` | Arithmetic comparisons and classification; only the selected branch executes. |
| `Guard` | Reject a false domain condition before evaluating its arithmetic source. |
| `BitCast`, `ExtractBits`, `BitOp` | Equal-width float/unsigned bit casts, field extraction, masked unsigned operations. Shifts at or above the operand width return zero. |

Floating arithmetic operands must have the node's format; insert conversions explicitly.
Fixed operands may have different scales; the operation's result format defines
rounding and overflow. `FixedFormat(W,I)` has `W-I` fractional bits, with `I`
including the sign bit. It supports signed/unsigned storage, all four rounding
modes and reject/saturate/wrap overflow. Fixed values have no signed zero or
nonfinite encodings; converting NaN/infinity to fixed raises an error.
Unsigned values use `IR.UIntFormat(W)` for widths 1–64; conditions use `Bool`.
Table `banks` and `unroll` are implementation metadata and do not alter values.

`FunctionSpec` supports either format independently for input and output; output
defaults to input. `domain=nothing` covers every fixed encoding. `IR.Input` loads
fixed bits exactly, without quantization. Fixed output bits use the declared
result format. Invalid input widths are rejected even if the graph does not use
the input. `polynomial_plan` supports fixed internal arithmetic as well; users
must select sufficient widths. It derives inward domain thresholds from the
representable grid. Floating output returns NaN outside a bounded domain; fixed
output uses `Guard` to reject those inputs. Fixed outputs never invent a NaN word.

The interpreter uses exact integer/rational arithmetic with nearest-even,
toward-zero, upward or downward rounding. It supports binary16/32/64 and the
package's custom floating formats, including subnormals and finite exponent
ranges. Fixed arithmetic uses arbitrary-width integers. Arithmetic and floating
conversions canonicalise NaNs; raw loads, selects and bit
casts preserve payloads. Signed zeros follow the operation's rounding semantics.
`interpret_trace(program, bits)` returns output bits and visited node values;
table-index nodes can be inspected to check dispatch.

## C++ backend

The C++20 emitter supports binary32/binary64 floating arithmetic with nearest-even
rounding, plus exact fixed arithmetic and directed fixed conversions. Compile with
`-ffp-contract=off -fno-fast-math -frounding-math`, retain gradual underflow and
use `FE_TONEAREST` when floating nodes are present. `std::fma`
implements explicit FMA; separate nodes retain separate rounding. Bit conversion
uses `std::bit_cast`. Per-call cached nodes preserve shared computations and lazy
branches without process-global state.

The raw `evaluate_bits` interface accepts/returns `std::uint64_t` for fixed widths
up to 64, and `mpz_class` for wider fixed words. Fixed high padding bits are zero
and checked on input. The typed `evaluate` interface accepts/returns the selected
library's fixed types. In the portable backend, fixed values are scaled integer
units in native integers or GMP. A typed portable input must fit its declared
format. Programs containing floating nodes require `FE_TONEAREST`; pure fixed
programs are independent of host floating rounding.

Fixed fields use native 64/128-bit integers where their widths fit. Products,
aligned sums and FMA use widened native temporaries when their complete ranges
fit; wider operations use GMP. Exact quantization and float/fixed conversion
helpers also use GMP integers. Fixed headers need `gmpxx.h` and linkage with
`-lgmpxx -lgmp`. The supported CPU compilers are Clang/GCC with native 128-bit
integers. `emit_cpp` defaults to this portable reference backend.

### Fixed backends

```julia
plan = certified_erf().plan
emit_cpp("evaluator.hpp", plan; backend=:ac_fixed) # or :ap_fixed / :portable
```

The generation CLI and fresh CMake builds default to `ac_fixed`. Both native
backends store fixed fields and tables in the library's fixed types, evaluate
exact widened products/aligned sums/FMA with those types, and narrow with the
library's quantizers. Constants are loaded from exact raw bits. IEEE inputs are
decoded into an exact native fixed value before the library applies rounding;
this avoids implicit double rounding or loss of subnormals.

| PRESAGe policy | `ap_fixed` / `ac_fixed` implementation |
| --- | --- |
| Nearest even | `AP_RND_CONV` / `AC_RND_CONV` |
| Toward zero | `AP_TRN_ZERO` / `AC_TRN_ZERO` |
| Down | `AP_TRN` / `AC_TRN` |
| Up | Floor into a widened native value, then add one quantum if a remainder exists. `RND_INF` is a nearest rounding tie policy and cannot implement this. |
| Wrap / saturate | `AP_WRAP` / `AC_WRAP`, or `AP_SAT` / `AC_SAT` after quantization. |
| Reject | Quantize into a safe native width, compare with exact target limits, then cast or throw. Neither library has this overflow policy. |

The final IEEE conversion extracts the native result's bits and uses the exact
GMP bridge. GMP does not evaluate or quantize native fixed operations. These
are CPU verification backends; removing the host bridge, diagnostics and trace
machinery for HLS synthesis is separate work.

Use the public [Xilinx simulation headers](https://github.com/Xilinx/HLS_arbitrary_Precision_Types)
and [Algorithmic C headers](https://github.com/hlslibs/ac_types). Compile with
their include directory and GMP linkage. The Xilinx public repository explicitly
excludes synthesis support. With libc++, the emitter skips its unused legacy
`std::complex` specializations, whose forward declarations conflict with libc++'s
inline namespace. Scalar arithmetic headers remain unmodified.

Native widths and absolute integer-bit counts are capped at 4096, including
widened temporaries and IEEE decoding. Unsupported widths or extreme scales are
rejected during emission before writing a header. The portable backend retains
arbitrary-width arithmetic and huge-exponent handling. The `ap_fixed` header
requires `AP_INT_MAX_W >= 4096`; generated code supplies this default when unset.

The binary harness processes one input word at a time. `--trace-index` adds an
eight-byte first-table-index field after each output; an unvisited index is
`UINT64_MAX`. `--trace-fixed` also appends, for each fixed node in graph order,
one visitation byte and `ceil(W/8)` little-endian payload bytes, with zero padding.
Unvisited nodes have zero payload and are not evaluated. The CPU checker uses
this mode for fixed programs to detect differences hidden by final IEEE rounding.

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
This floating mode has sampled accuracy evidence.

`erf_fixed_candidate()` generates fixed coefficients, derives common integer
widths per stage from exact interval ranges, and inserts widened products/sums
and explicit quantizers. `certified_erf()` searches fractional widths within
configured limits and returns a uniform certificate for the resulting fixed
program. Its default starts at 31 fractional bits; coefficient and arithmetic
scales can be selected separately. Fixed Mul/Add and FMA retain their distinct
rounding order. See [the numerical proof](certification.md).
