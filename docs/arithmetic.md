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

Emission writes one self-contained `evaluator.hpp`. It contains shared type aliases, exact constants and tables,
then local arithmetic stages and ordinary `if` blocks. Shared work is evaluated
once while preserving operand order, lazy branches and rejection order. Rounding
and overflow arguments use named policies. Only helpers referenced by emitted
operations and their dependencies are included. Unreachable nodes and unused
tables are validated but omitted from the generated code.

Tracing is disabled by default: normal output has no trace storage, recording
calls or runtime trace checks. Use `emit_cpp(...; trace=true)` and
`emit_harness(...; trace=true)` for local debugging. In that output,
`evaluate_bits(bits, &trace)` records visited nodes and their intermediate values.

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
| `RootArgument` | Exact `t=m*2^r`, where `abs(x)=m*2^e` and `e=d*q+r` uses floor division. `d=2` gives `[1,4)`; `d=3` gives `[1,8)`. |
| `ScalePow2` | Multiply by an exact power of two, then round once. |
| `Compare`, `Classify`, `Select` | Arithmetic comparisons and classification; only the selected branch executes. |
| `Guard` | Reject a false domain condition before evaluating its arithmetic source. |
| `BitCast`, `ExtractBits`, `BitOp` | Equal-width float/unsigned bit casts or fixed payload to unsigned, field extraction, masked unsigned operations. Shifts at or above the operand width return zero. |

Floating arithmetic operands must have the node's format; insert conversions explicitly.
Fixed operands may have different scales; the operation's result format defines
rounding and overflow. `FixedFormat(W,I)` has `W-I` fractional bits, with `I`
including the sign bit. It supports signed/unsigned storage, all four rounding
modes and reject/saturate/wrap overflow. Fixed values have no signed zero or
nonfinite encodings; converting NaN/infinity to fixed raises an error.
Unsigned values use `IR.UIntFormat(W)` with positive widths; conditions use `Bool`.
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
Floating and unsigned payloads use `UInt64` through 64 bits and `BigInt` above
that width. `FloatFormat(E,M)` allows custom exponent/fraction widths whose
metadata and exponents fit Julia `Int`; `IEEE128` and `IEEE256` are predefined.
`interpret_trace(program, bits)` returns output bits and visited node values;
table-index nodes can be inspected to check dispatch.

## C++ backend

The native C++20 floating backend supports binary32/binary64 arithmetic with nearest-even
rounding, binary16 interfaces and exact conversions, plus exact fixed arithmetic
and directed fixed conversions. Binary16 uses the namespace-local `Half` type,
a portable two-byte representation with exact widening to float/double and
explicit nearest-even narrowing. Native binary16 arithmetic nodes require fixed,
binary32 or binary64 internals. Compile with
`-ffp-contract=off -fno-fast-math -frounding-math`, retain gradual underflow and
use `FE_TONEAREST` for floating evaluators with arithmetic/conversion nodes. `std::fma`
implements explicit FMA; separate nodes retain separate rounding. Bit conversion
uses `std::bit_cast`. Per-call cached nodes preserve shared computations and lazy
branches without process-global state.

The raw `evaluate_bits` interface accepts/returns `std::uint64_t` for fixed widths
up to 64, and `mpz_class` for wider fixed words. Fixed high padding bits are zero
and checked on input. The typed `evaluate` interface accepts/returns the selected
library's fixed types. In the portable backend, fixed values are scaled integer
units in native integers or GMP. A typed portable input must fit its declared
format. Binary16 raw interfaces use `std::uint16_t`, and typed interfaces use
`Half`. Pure lookup/bit graphs and pure fixed programs are independent of host
floating rounding. LUTs store sixteen-bit entries for binary16.

Fixed fields use native 64/128-bit integers where their widths fit. Products,
aligned sums and FMA use widened native temporaries when their complete ranges
fit; wider operations use GMP. Exact quantization and float/fixed conversion
helpers also use GMP integers. Fixed headers need `gmpxx.h` and linkage with
`-lgmpxx -lgmp`. The supported CPU compilers are Clang/GCC with native 128-bit
integers. `emit_cpp` defaults to this portable reference backend.

### Custom floating backend

`emit_cpp(...; float_backend=:auto)` retains native binary16/32/64 interfaces
for programs using those formats. A custom format or wide unsigned node selects
the official `ac_std_float<W,E>` / `ac_int<W,false>` headers for the complete
floating path. `float_backend=:ac_std_float` explicitly selects AC types,
including binary32; `:native` rejects custom formats. The floating choice is
independent of `backend=:portable|ac_fixed|ap_fixed` for fixed arithmetic.
The CLI exposes `--float-backend`; CMake exposes `PRESAGE_FLOAT_BACKEND`.

AC Add/Mul/FMA and float conversions use explicit nearest-even library calls
with subnormals enabled. Scaling uses an exact power of two in a wider exponent
format before one final conversion. Classification, signed zeros, comparisons,
raw tables and lazy branches retain the IR semantics. Native fixed-to-float and
float-to-fixed adapters use AC conversion routines, with the declared directed
rounding and overflow policies; AP payloads are transferred exactly by bits.
The portable fixed backend retains its independent GMP conversion path.

Wide floating raw interfaces use byte-padded `ac_int` words; typed interfaces
use `ac_std_float`. Input padding must be zero. Floating-only evaluators require
the AC headers but no GMP linkage. Mixed fixed evaluators still use GMP for host
transport/tracing, and portable fixed arithmetic. CPU width parameters must fit
C `int`; the AC header's exponent calculations restrict exponent widths to 30
bits, with additional headroom needed for scaling. Existing native fixed width
and scale limits still apply. Unsupported mappings fail before header output.

These checks exercise official header simulation using ordinary C++ compilation.
Binary32 (`ac_std_float<32,8>`) is the initial oneAPI candidate. Toolchain support
for other combinations requires separate validation. Floating evaluator
certification remains separate from CPU arithmetic conformance.

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

The binary harness processes one input word at a time. When generated with
`trace=true`, `--trace-index` adds an
eight-byte first-table-index field after each output; an unvisited index is
`UINT64_MAX`. `--trace-fixed` also appends, for each fixed node in graph order,
one visitation byte and `ceil(W/8)` little-endian payload bytes, with zero padding.
Unvisited nodes have zero payload and are not evaluated. Run the CPU checker with
`--trace` to detect intermediate differences hidden by final IEEE rounding.

## Polynomial certification

`polynomial_plan` stores the rounded coefficients and the exact Horner graph.
`certify_polynomial` audits that graph and proves a uniform absolute bound for
float/fixed input/output and internals with nearest-even rounding and rejected
fixed overflow. It covers conversions, each arithmetic quantizer, output rounding,
subnormals, exponent limits and every numerical node's range. Coefficients and internal widths remain explicit
choices; an inadequate width or conservative interval can refuse a proof.
Extra fraction bits use `internal_format=FloatFormat(E,M+g)`. Coefficients and
stages share that format by default. `PolynomialPrecision` supplies individual
storage and stage formats with explicit conversions and quantizers. See
[the numerical proof](certification.md#individual-coefficient-and-stage-precision).

Odd kernels use the same arithmetic IR to evaluate `x*q(x²)`. The coordinate
format governs input conversion, the square, q's final conversion and the
reconstruction product. A lazy original-input zero branch preserves floating
zero signs; the domain guard runs before either branch. See
[odd kernel semantics](certification.md#odd-function-kernels).

## Floating magnitude and exponent reconstruction

`IR.FloatMantissa(source)` extracts the exact positive normalized mantissa of
a finite nonzero floating word. Subnormals are normalized by shifting their
significand. `IR.ScaleByInputExponent(source,input,multiplier,format)` decodes
the original input's normalized exponent, multiplies it by `±1`, and rounds
`source*2^(multiplier*e)` directly into the floating output format. The source
can be a fixed or floating Horner value. `IR.CopySign(source,sign)` copies a
floating sign bit exactly. The interpreter supports arbitrary format widths
and exponents using integer payloads and direct dyadic rounding.

Native CPU reconstruction uses strict floating scaling or the existing exact
fixed-to-float conversion adapter. With official AC types, floating and vendor
fixed sources are widened exactly, multiplied by an exact power of two, then
converted once to the output. The intermediate exponent range must fit AC's
30-bit limit; emission rejects a request without sufficient headroom. Wider
significands remain supported. Portable fixed reconstruction uses the existing
GMP conversion adapter. These local CPU paths have separate conformance checks.

Structural reports count normalizations, exponent scalings and sign copies.
They do not predict FPGA resources or timing. Reciprocal generation places an
audited lazy domain guard before these operations; see
[its complete error proof](certification.md#reciprocal-mantissa-kernels).

## Fresh erf candidate

`erf_candidate()` approximates `erf(t+center)` with Sollya `fpminimax` in four
dyadic segments covering magnitude `[0,4]`. Tables store the negative centres
and coefficient columns. Row selection scales the exact decoded magnitude by
`segments/4` and rounds down into an unsigned integer. A lazy equality check
keeps magnitude 4 in the final row. At 512 segments this is
`min(floor(abs(x) * 128), 511)`, followed by indexed table loads. The program
then computes the rounded coordinate, evaluates Horner arithmetic, converts to
IEEE32 and restores the input sign. Internal arithmetic is IEEE64 by default.
Exact signed zeros, canonical NaNs and constant tails (including infinities)
have lazy branches.

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

For root reconstruction, `ScaleByInputExponent(...; divisor=2)` multiplies by
`2^(multiplier*floor(e/2))`, with one final rounding. Negative odd exponents
use a nonnegative remainder: `split_exponent(-3) == (-2,1)`. `RootArgument`
constructs its result exactly by changing the normalized exponent field.
Normalization rejects zero/NaN/infinity when reached; canonical sqrt/rsqrt
plans guard those cases with lazy branches first. AC and AP fixed sources and
AC floating sources are widened exactly before reconstruction. The portable
fixed path uses its independent integer adapter.


`RootArgument(source,3)` and `ScaleByInputExponent(...; divisor=3)` express
cube-root reduction. Negative exponents use floor division:
`split_exponent(-1,3) == (-1,2)`. Argument formation retains every fraction bit
and automatically widens a two-bit exponent field to three bits, sufficient
for `[1,8)`. The result type is inferred by the IR and stored through its node
semantics. Native/AC C++ uses the same integer quotient/remainder and exact
field construction. Cbrt restores the original input sign after direct scaling;
its lazy branches preserve both signed zeros and infinities.

## Log reconstruction arithmetic

`FloatExponent(source)` returns the exact signed integer `e` from the same
normalization as `FloatMantissa`: `abs(x)=m*2^e`, including subnormal inputs.
Its inferred signed fixed format has no fractional bits and holds every finite
nonzero input exponent. Zero, infinity and NaN are invalid for this operation;
the log evaluator's lazy branches prevent their evaluation.

`log_polynomial_plan(spec, coefficients, log2; precision, evaluation)` stores
`p(m)+e*log2` as explicit IR. Constant storage and reconstruction use the
coordinate format. Cast the final Horner value and exact exponent as needed;
separate evaluation rounds a multiply and an add, while FMA rounds their
combined expression once. A final conversion rounds to the output format.
The complete certificate accounts for every operation. C++ uses the existing
bit-field normalization and official fixed arithmetic types; no C++ `log` call
is used in the evaluator.

## Atan and rounded reciprocals

`FloatReciprocal(source)` rounds exact `1/source` to its floating source format
with nearest-even rounding. Signed zeros produce signed infinities; signed
infinities produce signed zeros; NaNs become canonical NaN. The interpreter
rounds the exact rational reciprocal. Native C++ uses strict floating division;
AC uses `div<AC_RND_CONV,false>`, retaining subnormal arithmetic. Native public
entry points require `FE_TONEAREST` for this operation. Native binary16
arithmetic remains unsupported; AC supports the binary16 reciprocal operation.

The atan evaluator widens the magnitude exactly before reciprocal evaluation.
The reduction exponent field covers the input and coordinate formats; its
fraction width covers input, output and coordinate precision, with at least
52 fraction bits. Fixed coordinates contribute their fractional width.
Conversions to the coordinate format remain separate quantizers.

The original magnitude selects the central or tail argument before one shared
odd Horner kernel. Its reconstructed value is selected directly for the central
branch, or subtracted from stored pi/2 for the tail. Separate evaluation uses
exact negation followed by an add; FMA combines negation/subtraction in one
quantizer. The kernel reconstruction product still rounds separately. All
branches are lazy. Static costs explicitly count the reciprocal as one division.

## Exp and dynamic exponent scaling

`ScaleByExponent(source, exponent, output_format)` rounds the exact dyadic
`source*2^exponent` directly to a floating output. Its exponent operand must be
a signed fixed integer, with no fractional bits. Nearest-even is the supported
rounding policy. Julia accepts arbitrary integer widths and uses exact dyadic
rounding, without constructing a huge power of two for underflow or overflow.
CPU exponents must fit a C int. Official AC scaling additionally needs enough
exponent headroom within its 30-bit limit; unsupported mappings are rejected
before emission. Native floating sources are decoded to their full significand;
fixed sources use the existing exact bridge. Official AC adapters widen exactly,
multiply by an exact power of two and convert once to the output. A rounded
floating power of two is never materialized in the output format first.

The exp graph widens the input exactly to a reduction format covering input,
output and coordinate fraction precision, with at least binary64 precision.
It multiplies by stored `1/log(2)`, rounds to an inferred signed integer `k`,
converts `k` back explicitly, and forms `x-k*stored_log2`. Separate mode rounds
a product and add; FMA mode rounds the combined residual once. A separate
conversion forms the polynomial coordinate. Horner storage/stage conversions
and direct output scaling remain explicit. Zero, infinity and domain branches
are lazy. Static costs count one exponent scaling.

## Sinh/cosh reconstruction arithmetic

`hyperbolic_polynomial_plan` compares `abs(x)>1` in the input format. The central
branch forms `a*a`, evaluates q and returns `a*q(a*a)` for sinh or `q(a*a)` for
cosh. Ascending central coefficients are stored separately from exp coefficients;
both lists use the declared per-coefficient formats. The stage formats apply to
one central and two tail Horner evaluations.

The tail forms the same rounded integer k and residual r as exp, using exact
input widening. It evaluates p(r) and p(-r), then uses two `ScaleByExponent`
nodes with explicit signed integer expressions `k-1` and `-k-1`. Reconstruction
subtracts the second term for sinh and adds it for cosh. The reduction and
reconstruction format has at least binary64 precision, preserves input/coordinate
precision and has extra exponent range beyond the output format. Only the
reconstructed value is converted to the output. No intermediate exp(a) is formed.

Sinh copies the original sign after conversion, preserves both signed zeros
exactly and maps signed infinities to themselves. Cosh returns exact one for
either zero and positive infinity for either infinity. NaNs and excluded finite
inputs return canonical NaN before numerical evaluation. All branches are lazy.
Structural cost reports count two coefficient banks, three Horner stage sets
and two exponent scalings; these are not synthesis estimates.

## Scaled erfc reconstruction arithmetic

The erfc graph compares `abs(x)>1` in the input format. Central erfc uses an
ascending polynomial on `[0,1]`. The positive tail uses a separate polynomial
for `phi(a)=exp(a*a)*erfc(a)` in a normalized coordinate. A stored center and
power-of-two scale map `[1,max(2,R)]` inside `[-1,1]`, where R is the largest
accepted representable magnitude. Center subtraction and normalization occur
in the widened reduction format, then convert to the coordinate format.

The same wide format squares the exactly widened input. Negate the rounded
square, select k and form the exp residual, with separate or fused arithmetic
as declared. Evaluate the reduced exp polynomial, explicitly convert both tail
Horner results, multiply and scale the product by `2^k`. No exp(a²) or erfc(a)
library call is emitted. Negative inputs reconstruct `2-positive_result` in
the wide format; separate mode uses a negation product and add, while fused
mode uses FMA. Convert the selected result into the floating output.

The reduction exponent field covers input squaring and has extra range beyond
the output; fraction precision covers the interfaces and coordinate format,
with at least binary64 precision. All operations and casts are explicit IR.
Zeros return exact one, infinity limits are zero/two, and invalid finite inputs
and NaNs return canonical NaN before numerical evaluation. Branches are lazy.
Structural cost reports count three coefficient banks, three Horner stage sets
and one dynamic exponent scaling. Individual width proposals account for both
tail kernels and their reconstruction factors.

## Bounded periodic reduction arithmetic

Sin/cos exactly widen the input into a reduction format covering input, output
and coordinate precision, with at least binary64 precision. Multiply by stored
2/pi, round to a signed fixed integer k, and convert k into the reduction format.
Form `r=x-k*stored(pi/2)` using the declared separate or fused arithmetic. Convert
r into the coordinate format, square it, and evaluate the two stored parity
kernels `sin(r)=r*q(r²)` and `cos(r)=p(r²)`. All conversions and quantizers are IR
nodes. Alternating Taylor coefficients seed generation; the stored-polynomial
norm proof decides whether they meet the contract.

`BitCast` can expose a fixed value's exact two's-complement payload as a same-width
unsigned word. This operation changes no bits and performs no numerical conversion.
For integral k, the low two bits equal k modulo four, including negative k.
The low bit selects the parity kernel; the high bit selects sin's sign. Cos's
sign is the exclusive-or of the two bits. Negation in the widened floating format
is exact. Only the chosen kernel and sign branch execute.

The integer field is inferred from the bounded input domain, using BigInt payloads
above 64 bits and official vendor integers in C++. Certification also proves that
the rounded selection leaves the ideal residual in `[-1,1]`; field size alone does
not establish reduction accuracy. Wider internal fractions can extend the proved
bounded range. An efficient general large-argument reducer requires a separate
multiword design. Sin preserves signed zeros; cos returns
exact one. NaNs, infinities and excluded finite inputs return canonical quiet NaN
before numerical evaluation. Structural costs count two coefficient banks and
two Horner stage sets; no FPGA performance is inferred.

## Asin/acos endpoint arithmetic

The input-format comparisons split at `abs(x)=1/2` and recognize the exact
endpoints. On nonzero tails, exactly widen a=abs(x), form `1-a` and divide by
two. The coordinate t is exact: a lies strictly between one half and one,
subtraction satisfies Sterbenz's condition, and the widened format retains the
subsequent binary scaling. The certifier also verifies zero local rounding
bounds and exact endpoint-coordinate ranges from the executed graph.

Use the existing `RootArgument(t)` to split t's exponent into `e=2q+r`, evaluate
the stored sqrt polynomial on `[1,4]`, and reconstruct sqrt(t) directly into
the widened format with `ScaleByInputExponent`. Convert the result into the
asin coordinate format. The central branch converts abs(x) directly. Both
branches share a square and one Horner graph for `u*q(u²)` on `[0,1/2]`.
Asin's Taylor coefficients seed this parity kernel, and Sollya generates the
separate sqrt polynomial. The actual
stored polynomials receive direct norm certificates.

Asin tails use `stored(pi/2)-2*kernel`, followed by exact sign restoration.
Central acos uses `stored(pi/2)±kernel`; positive tails use `2*kernel`, while
negative tails use `stored(pi)-2*kernel`. Stored pi is an exact power-of-two
scaling of stored pi/2. Separate/FMA subtraction and all wide/output conversions
are explicit IR. Root and kernel precision lists are shared; structural costs
count two coefficient banks and two Horner stage sets.

Zero and endpoint branches bypass root normalization and both kernels. Asin
preserves signed zeros and returns signed stored pi/2 at ±1. Acos returns zero
at +1, stored pi at -1 and stored pi/2 for either zero. Constant and output
rounding errors are certified for these branches. Contracts are bounded inside
`[-1,1]`; NaNs, infinities and excluded finite inputs return canonical quiet NaN
before numerical evaluation. No vendor sqrt or inverse trig library call is emitted.
