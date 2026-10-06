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
Both contain only numerical ranges for accepted inputs and have no erf tail
claims. Node formats can be floating or fixed. `read_plan` loads evaluator semantics; `certify_plan`
reruns the supported proof.
Regenerate the report whenever coefficients or arithmetic change. See
[certificate semantics](certification.md).
