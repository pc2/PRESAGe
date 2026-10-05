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
`float(E,M)`, where M is the number of fraction bits.

Nearest-even rounding, IEEE overflow/subnormals, canonical quiet NaNs and
established primitive zero/infinity behavior are shared defaults. They are not
repeated in each contract.

Version 1 contracts remain compact. Candidate artifacts can additionally contain exact segment endpoints and
ascending coefficients, a magnitude-tail dispatch with threshold bits and tail
values, and numerical generation `settings`. Empty fields are omitted.
Rationals use `numerator/positive-denominator` strings; IEEE thresholds use
hexadecimal bits. Decimal/scientific expression constants are parsed as exact
rationals, so `0.1*x` means `x/10`.

Use `write_plan(path, PlanArtifact(spec))` and `read_plan(path)` for serialization.
Unknown versions and formats are rejected. Status is `contract` or `candidate`;
neither supported version can claim certification.

## Version 2 evaluator programs

Artifacts containing an evaluator use `schema_version = 2` and
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
