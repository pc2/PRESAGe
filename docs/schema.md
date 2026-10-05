# Plan schema v1

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

Candidate artifacts can additionally contain exact segment endpoints and
ascending coefficients, a magnitude-tail dispatch with threshold bits and tail
values, and numerical generation `settings`. Empty fields are omitted.
Rationals use `numerator/positive-denominator` strings; IEEE thresholds use
hexadecimal bits. Decimal/scientific expression constants are parsed as exact
rationals, so `0.1*x` means `x/10`.

Use `write_plan(path, PlanArtifact(spec))` and `read_plan(path)` for serialization.
Unknown versions and formats are rejected. Status is `contract` or `candidate`;
schema v1 has no arithmetic IR or proof payload and cannot claim certification.
