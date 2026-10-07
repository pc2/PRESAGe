# Plan schema

A function specification contains the expression, formats, domain and absolute
error target. The [erf contract](../examples/erf-contract.toml) is:

```toml
schema = "presage-plan"
schema_version = 1
status = "contract"

[spec]
expression = "erf(x)"
input_format = "binary32"
absolute_error = "1/8388608"
```

The output format defaults to the input format, and an omitted `domain` means
all finite inputs. A bounded domain uses two exact rational strings, such as
`domain = ["-1/3", "2/3"]`. Formats are `binary16`, `binary32`, `binary64` or
`float(E,M)`, where M is the number of fraction bits. `binary128` and `binary256`
are also predefined. Hexadecimal words and dispatch thresholds retain arbitrary
widths; their text encoding is unchanged.

Nearest-even rounding, IEEE overflow/subnormals, canonical quiet NaNs and
established primitive zero/infinity behavior are shared defaults. They are not
repeated in each contract.

Version 1 contracts remain compact. Candidate artifacts can additionally contain
exact segment endpoints and
ascending coefficients, a magnitude-tail dispatch with threshold bits and tail
values, and numerical generation `settings`. Empty fields are omitted.
Rationals use `numerator/positive-denominator` strings; IEEE thresholds use
hexadecimal bits. Decimal/scientific expression constants are parsed as exact
rationals, so `0.1*x` means `x/10`.

Use `write_plan(path, PlanArtifact(spec))` and `read_plan(path)` for serialization.
Unknown versions and formats are rejected. Plan status is `contract` or
`candidate`; numerical certification is stored in a separate report.

## Version 2 evaluator programs

Programs using floating/unsigned formats use `schema_version = 2` and
`status = "candidate"`. They add a `program` table with an output node index,
ordered `nodes` and optional `tables`. Node references are one-based and point
backward. Each node stores its operation, operands and relevant format/rounding
fields. The single input and output formats must match the function specification.

Constants and table entries use hexadecimal bit strings. IR formats include
the floating formats above, `uint(W)` and `bool`. Table rows are zero-based;
optional `banks` and `unroll` describe implementation choices. All conversions,
segment selection, coordinates, special branches and arithmetic order live in
the program. See [arithmetic semantics](arithmetic.md).

Segments and dispatch fields are numerical descriptions; the program is the
executable definition. In the fresh `erf` candidate, segment coefficients are
polynomials in the local coordinate encoded by the program. Reading version 1
artifacts remains supported; a version 1 artifact cannot contain a program.

## Version 3 internal fixed arithmetic

Programs containing fixed formats use `schema_version = 3`. A fixed format is
a table containing `kind = "fixed"`, `width`, `integer_bits`, `signed`,
`rounding` and `overflow`. Its fractional width is `width - integer_bits`.
Signed words use two's complement. Constants and tables retain exact hexadecimal
words, including widths beyond 64 bits. Widened products/sums and narrowing
quantizers are explicit nodes. Versions 1 and 2 remain readable.

## Version 4 fixed interfaces

Fixed input/output contracts and programs use `schema_version = 4`. Their
`spec.input_format` and optional `spec.output_format` use the same fixed-format
table as the IR, carrying width, integer bits, signedness, rounding and overflow.
An omitted output format still means the complete input format. `domain` omitted
means every representable fixed input. Versions 1–3 retain their meanings.

The input node and selected output may be fixed independently, including mixed
float/fixed interfaces and arbitrary-width fixed words. Version 4 also adds
`Guard`, which rejects a false domain condition before evaluating its source;
fixed output cannot encode an outside-domain NaN. Fixed binary words use
`ceil(width/8)` bytes with zero high padding, never sign extension beyond the
declared width. References with fixed interfaces use stream schema version 2
and record word sizes and padding alongside the format tables.

`certificate.toml` uses `schema = "presage-certificate"`, version 2. It records
the numerical status, target, uniform bound, per-path contributions, exact node
ranges, tail bound and proof settings. It is written from the same plan used by
generation. Each path uses `domain`: an input interval for float/fixed polynomials,
or a magnitude interval for the canonical erf evaluator. Coverage describes
the selected proof method. Floating/mixed polynomial reports use method
`floating_polynomial_horner`; all-fixed reports use `fixed_polynomial_horner`.
Normalized segmented reports use `normalized_segmented_horner` and one closed
reachable-input interval per row. These polynomial reports contain only
numerical ranges for accepted inputs and have no erf tail
claims. Node formats can be floating or fixed. `read_plan` loads evaluator semantics; `certify_plan`
reruns the supported proof.
Regenerate the report whenever coefficients or arithmetic change. See
[certificate semantics](certification.md).

`certified_polynomial` uses these existing artifact versions. Its plan settings
record the requested maximum `degree`, `generation_precision` and `evaluation`,
plus `segments` when greater than one;
the IR stores the actual coefficients and degree. Certificate settings record
proof `precision` and `norm_accuracy`. A numerical `generation_failed` result has
a contract-only plan and no uniform bound or coverage claim. Successfully
generated candidates remain replayable even when certification fails or exceeds
the target.

## Search reports

`write_search_report` writes `schema = "presage-search"`, version 1. It records
the function spec, ordered degree/format choices, traversal order, numerical
settings, attempt/time limits, elapsed seconds, result status and stop reason.
`selected_attempt` is present only for a successful search and identifies the
last attempt. Input/output formats remain in the function spec; each attempt
records its explicit internal format and degree.

Reports with segment-count choices use version 2, add the ordered `segments`
array and each attempt's `segments` count, and use
`order = "segment_then_degree_then_format"`. Default single-polynomial searches
retain version 1.

The `attempts` array contains status, elapsed seconds and failure details for
every attempted configuration. An available `plan` is a complete existing plan
artifact with exact stored IR payloads. An available `certificate` is a complete
existing certificate report, including separate error contributions and node
ranges. A plan checkpoint may survive a timeout or worker failure without a
certificate. The report is self-contained for inspection and extracting a plan;
transient worker files and Julia serialization are not public artifact formats.

When CLI emission or publication fails after a certified search,
`search-failure.toml` retains that numerical report and adds a
`generation_failure` table with `stage` and `reason`. Its numerical `certified`
status does not claim successful evaluator publication.

## Search configurations

`write_search_config` writes `schema = "presage-search-config"`, version 1.
`read_search_config` accepts a path or IO and validates the complete request.
Unknown fields, versions and traversal orders are rejected. Choices are
mandatory; omitted numerical settings and limits use `PolynomialSearchConfig`
defaults. An omitted `order` means `degree_then_format`.

Configurations with segment-count choices use version 2:

```toml
schema = "presage-search-config"
schema_version = 2
order = "segment_then_degree_then_format"
segments = [1, 4, 8]
degrees = [5, 9]
internal_formats = [{ format = "float(8,27)" }]
```

Version 2 requires `segments`, an ordered list of distinct powers of two in
1–64. An omitted `order` uses the version's default. Version 1 implies `[1]`
and does not accept a `segments` field. Numerical settings and limits have
the same encoding in both versions. A whole segmented candidate counts as one
attempt and shares the same worker deadline across generation and proof of all
rows. Exact segmented plans use the existing plan schema: `segments` contains
nominal boundaries and normalized polynomial coefficients; the IR stores the
actual thresholds, centre/coefficient tables, scale and complete evaluator.
Certificate paths additionally report `coordinate.center`, `scale_exponent`,
`ideal_domain`, `node` and, when evaluated, `rounded_domain`.

```toml
schema = "presage-search-config"
schema_version = 1
degrees = [1, 9, 13]
internal_formats = [{ format = "binary32" }, { format = "float(8,27)" }]

[settings]
evaluation = "fma"
generation_precision = 256
proof_precision = 256
norm_accuracy = "1/1024"
max_refinements = 2

[limits]
max_attempts = 6
job_timeout_seconds = 60.0
total_timeout_seconds = 300.0
```

Each internal choice wraps its format in a `format` field. Floating formats use
the existing names; fixed formats use the existing complete format table with
`kind`, `width`, `integer_bits`, `signed`, `rounding` and `overflow`. The
[fixed search example](../examples/polynomial-search.toml) shows this encoding.
Choices retain their order, and integer/exponent ranges remain explicit.

## Odd transformation artifacts

Odd searches use configuration/report v4, adding `transformation = "odd"` and
requiring `segments = [1]`. Degrees are odd original-function degrees in `1:31`;
optional precision layouts describe q in `x*q(x²)`. Traversal remains
`degree_then_format`. Versions 1–3 do not accept a transformation field.

Stored odd plans use v5 with their precision layout and complete IR, including
the square, reconstruction, original-input zero test and domain guard. Settings
retain `transformation = "odd"` and the requested degree. Coefficient payloads
are those of q in ascending power order. No additional plan schema is needed.

Certificates use method `odd_polynomial_horner`. A `transformation` table records
the established function identity, positive norm domain, ideal square domain,
square/reconstruction node IDs and zero policy. Path domains and ranges still
refer to actual accepted inputs and executed numeric nodes. Exact signed zeros
are an audited lazy branch. Recertification reconstructs the graph and proves
the norm and full arithmetic bound again.

## Exponent reduction artifacts

Reciprocal searches use configuration/report v5, with
`transformation="reciprocal"`, `segments=[1]` and `degree_then_format` ordering.
Degrees and optional precision lists describe the mantissa polynomial directly.
Other configuration versions retain their existing transformation rules.

Plans containing `FloatMantissa`, `ScaleByInputExponent` or `CopySign` use v6.
The reconstruction node stores its arithmetic source, original floating input,
exponent multiplier `±1`, output format and rounding mode. Coefficient payloads
and individual formats retain their existing exact encoding. Earlier versions
reject these operations. Settings retain `transformation="reciprocal"` for
generation, precision optimization and replay.

Certificates use method `reciprocal_polynomial_horner`. Their transformation
table records the identity, norm domain, accepted input exponent interval,
maximum error scaling, reconstruction node and excluded-input policy. Path
domains describe original inputs; numerical ranges include the certified
mantissa-kernel enclosure and reconstructed output. The existing certificate
schema v2 carries these fields. Replay audits and proves the entire graph again.

## Root exponent splitting

Root searches use configuration/report v6, with `transformation="sqrt"` or
`"rsqrt"`, `segments=[1]` and `degree_then_format` ordering. Degrees and precision
lists describe the polynomial on `[1,4]` in ascending powers.

Plans using `RootArgument` or `ScaleByInputExponent` with `divisor=2` use v7.
The divisor is omitted for the existing v6 reciprocal operation, where it
means one. Earlier versions reject root operations. All coefficients, stages,
exponent reconstruction and lazy exceptional branches are stored in the IR.

Root certificates retain report v2 and use method `root_polynomial_horner`.
The transformation table records the identity, reduced domain, input exponent
range and maximum error scale. Positive finite paths carry numerical bounds;
coverage separately records exact zeros/infinities and invalid/outside inputs.
A zero-only contract has an exact bound of zero and no numerical paths.

## Cube root reduction

Cbrt searches use configuration/report v7, with `transformation="cbrt"`,
`segments=[1]` and `degree_then_format` ordering. Degree and precision lists
describe the ascending positive kernel on `[1,8]`; the original expression must
be `cbrt(x)`, with whitespace allowed.

Plans using `RootArgument(...,3)` or `ScaleByInputExponent(...; divisor=3)`
use v8. `RootArgument` omits its default divisor of two in existing v7 plans;
its output retains input fraction bits and widens the exponent field when
necessary. Older plan versions reject division by three.

Certificate v2 retains method `root_polynomial_horner`, records transformation
`cbrt`, its exponent divisor, reduced argument format and maximum error scale.
Numerical paths describe the original signed input interval; zero branches
are exact. Coverage explicitly includes both signed infinities and NaN handling.
Exact replay audits every normalization, coefficient, stage, sign and branch.

## Log reconstruction artifacts

Log searches use configuration/report v8, `transformation="log"`,
`segments=[1]` and `degree_then_format` ordering. Degree and precision lists
describe the mantissa polynomial on `[1,2]`.

Plans containing `FloatExponent(source)` use v9. Its signed integer fixed
format is inferred from the floating source, including subnormal exponent
limits. Earlier plan versions reject this operation. The stored log(2)
constant, conversions, reconstruction and exceptional branches are ordinary
IR nodes; constant storage and reconstruction use the coordinate format.

Certificate v2 uses method `log_polynomial_horner`. Transformation fields
record the identity, mantissa domain, input exponents, constant/reconstruction
nodes and the exponent-scaled constant error bound. Paths describe positive
finite inputs; coverage records exact zero/one, infinity and invalid-input
behavior. Recertification audits and proves every stored operation again.

## Atan tail artifacts

Atan searches use configuration/report v9, `transformation="atan"`,
`segments=[1]` and `degree_then_format` ordering. Requested degrees are odd in
`1:31`; coefficient and stage lists describe the `(degree+1)/2` entries of q.

Plans containing `FloatReciprocal(source)` use v10. The format is inferred from
its floating source, and rounding is nearest-even. Earlier versions reject this
operation. Atan branch decisions, widened input, reciprocal, shared odd kernel,
stored pi/2, reconstruction, sign and exceptional paths are ordinary IR nodes.
The reduction format is derived from the interfaces and coordinate precision.

Certificate v2 uses method `atan_polynomial_horner`. Numerical paths cover the
original signed input intervals, with the unused branch excluded from range
analysis. Transformation fields record the identity, `[0,1]` norm domain,
reciprocal format, argument intervals, pi/2 node/error and infinity error.
The global bound includes the infinity limits; exact zeros and excluded inputs
are audited separately. Stored replay repeats the complete proof.

## Exp reduction artifacts

Exp searches use configuration/report v10, `transformation="exp"`,
`segments=[1]` and `degree_then_format` ordering. Degree and precision lists
describe the polynomial on `[-1/2,1/2]`.

Plans containing `ScaleByExponent(source, exponent, format)` use v11. Its
signed integer exponent is an ordinary fixed IR operand; source scaling rounds
directly into the floating result with nearest-even rounding. Earlier versions
reject this operation. Selection, reciprocal/log(2) constants, rounded residual,
Horner graph and exceptional guards are ordinary audited nodes.

Certificate v2 uses method `exp_polynomial_horner`. Transformation fields record
the exact identity, norm/reduction formats, selection and exponent format,
constant nodes, direct scaling and zero-only coverage. Settings retain the
proved ideal residual radius, coordinate/constant errors, input-dependent
integer exponent range and conservative maximum error scale. Numerical path
contributions include exponent scaling; output rounding is recorded separately.
Failure reports retain the reason without claiming proved coverage.

## Hyperbolic artifacts

Sinh/cosh searches use configuration/report v11, `transformation="sinh"` or
`"cosh"`, `segments=[1]` and `degree_then_format` ordering. Kernel degree d is
in 0:15. The d+1 coefficient/stage formats apply to separate central and exp
coefficient banks; central degrees are 2d+1 for sinh and 2d for cosh.

Plan v11 already expresses both kernels, input-format dispatch, residual
formation, integer exponent offsets and both half-scalings in ordinary IR.
No new arithmetic node or plan version is required. Coefficient and constant
payloads remain exact, and stored replay preserves them.

Certificate v2 uses method `hyperbolic_polynomial_horner`. Coverage records
signed input partitioning, exact zero/infinity branches and invalid-input
handling. Transformation fields record the identity, central kernel, exp norm
domain, widened format, constant nodes and reconstruction order. Each original
input path reports its scaled approximation, coordinate, arithmetic and final
rounding bounds. Failed proofs do not claim coverage.

## Scaled erfc artifacts

Erfc searches use configuration/report v12, `transformation="erfc"`,
`segments=[1]` and `degree_then_format` ordering. Degree d (0:32) and the d+1
coefficient/stage formats apply to central erfc, normalized scaled erfc and
reduced exp. Three separate coefficient banks retain exact payloads.

Plan v11 already represents input-format dispatch, affine normalization,
squaring, integer selection, both tail Horner graphs, multiplication, dynamic
scaling and reflection. No new arithmetic node or plan version is needed.
Replay preserves the stored normalization and constants; reinterpreting
normalized coefficients on a different domain requires a new norm proof and
can require regeneration.

Certificate v2 uses method `erfc_polynomial_horner`. Transformation fields
record the identity, scaled function and image method, stored center/scale,
scaled and exp norm domains, wide format, square and reduction constant nodes.
Coverage records four signed central/tail intervals and exact exceptional
branches. Path contributions include both polynomial norms, square/reduction
and normalized-coordinate errors, all reconstruction arithmetic and output
rounding, including subnormals. Failed proofs do not claim coverage.

## Version 12 fixed payload bitcasts and periodic artifacts

Plan v12 adds a same-width `BitCast` from a fixed arithmetic value to `uint(W)`.
The result is the stored raw two's-complement payload, including its fractional
bits; it is not a numerical conversion. Existing float/unsigned bitcasts retain
their semantics. Readers reject this fixed-source operation in earlier versions.

Bounded sin/cos plans use this operation to extract an integral quadrant modulo
four. Search configuration/report v13 uses `transformation="sin"` or `"cos"`,
`segments=[1]` and `degree_then_format` ordering. Degree d (0:15) and the d+1
coefficient/stage lists describe both parity kernels. All stored constants,
casts, selection, residual, kernel dispatch, signs and lazy guards are executable
IR; replay retains their payloads exactly.

Certificate v2 uses method `periodic_polynomial_horner`. Transformation fields
record the identity, norm domain, reduction and integer formats, constant nodes,
proved ideal residual radius and implemented residual error. Each path explicitly
records its quadrant 0:3. The four conditional path domains overlap numerically;
their exact quadrant conditions partition runtime execution. Coverage records
all bounded representable finite inputs and lazy exceptional branches. Failed
proofs do not claim coverage. Neither schema nor integer field size implies a
large-argument reduction guarantee.

## Asin/acos endpoint artifacts

Search configuration/report v14 uses `transformation="asin"` or `"acos"`,
`segments=[1]` and `degree_then_format` ordering. Degree d (0:32) and d+1
coefficient/stage formats apply to both the asin parity bank and the sqrt bank.
The original asin polynomial degree is 2d+1; the root polynomial degree is d.

Existing plan v7 represents the complete evaluator with `RootArgument`,
`ScaleByInputExponent`, ordinary arithmetic, explicit casts and lazy input-format
dispatch. No new IR operation is required. Plan replay retains both coefficient
banks and the stored pi/2 payload, with pi formed by exact binary scaling.

Certificate v2 uses method `inverse_trig_polynomial_horner`. Transformation fields
record the identities, kernel norm domains, exact endpoint coordinate, widened
format, pi/2 storage and error. Each path is labelled as a signed central/tail,
zero or endpoint branch, with its representable interval and complete approximation,
coordinate, arithmetic and output contributions. Coverage includes all bounded
representable inputs and lazy invalid-input behavior; failed proofs claim no coverage.
