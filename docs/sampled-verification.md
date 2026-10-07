# Portable sampled verification

Julia prepares references and exact interpreter outputs. One standalone C++20
checker compares captured outputs and produces TOML reports. Julia calls that
checker for local analysis and sweeps. The checker requires GMP and MPFR; it has
no Julia, Sollya or vendor-header dependency.

## Local use

Build the checker through Julia:

```julia
using PRESAGe
checker = build_verification_checker("build/presage_check")
plan = read_plan("plan.toml")
report = verify_samples(plan; checker)
report["status"]                  # passed, failed or unresolved
report["maximum_upper_witness"]  # exact input/output, reference and IR branch
```

Pass a `CertificationResult` to check its global bound as well as the contract's
absolute-error target. Pass `evaluator="path/to/presage_cpu"` to check generated
C++ outputs. Without an evaluator, the checker measures the exact interpreter's
outputs against the mathematical references. The latter supplies useful sweep
observations; its bit comparisons do not independently test generated code.

`directory="build/samples"` retains the bundle and report. Existing bundle
directories are refused. Without a directory, storage is temporary. Explicit
`inputs=[...]` override automatic sampling. The generated CPU harness accepts
little-endian streams; saved outputs can use either supported byte order.

```sh
julia --startup-file=no --project=. scripts/verify.jl plan.toml build/samples \
  --checker=build/presage_check --evaluator=build/presage_cpu
```

Use `-` as the output directory for a temporary run. Optional CLI arguments are
`--backend=sollya|mpfr` and `--exhaustive-bits=N`. Sollya handles compositions and
exact rational polynomials; direct MPFR handles supported primitives.

## Checks and witnesses

Each input has independent checks:

- **Bit agreement:** compare every output bit with the exact IR result, including
  signed zeros and canonical NaNs. This check also covers nonfinite inputs and
  finite inputs outside the contract where the evaluator defines an output.
- **Accuracy:** compare a finite-contract output with a mathematical reference
  enclosure. Finite poles and primitive special identities retain their explicit
  reference policy. Fixed saturation/wrap does not replace the mathematical value.
- **Certificate:** compare the same error enclosure with a supplied global
  certificate bound on finite inputs in the declared domain.

For output `y` and a reference `[a,b]`, the absolute error lies in
`[max(0,a-y,y-b), max(abs(y-a),abs(y-b))]`. MPFR computes outward endpoints with
per-number precision; GMP preserves raw wide words and rational bounds. Exact
rational comparisons resolve equality with a budget even when the error has no
finite binary expansion. Formats do not pass through binary64.

An upper error bound at most the allowance passes. A lower bound greater than
the allowance fails. A straddling interval is unresolved. Julia refines only the
references flagged as unresolved and increases checker precision, for at most
`max_refinements` rounds within `OracleConfig.max_precision`. Exhausting these
limits preserves the unresolved result. There is no fallback to a point estimate.

The maximum sampled error has separate lower and upper witnesses because these
can come from different inputs. Witnesses record exact input, actual and expected
output words, reference endpoints/precision, predicted IR selections and integer
reductions, and the applicable global certificate bound. Branch labels describe
the interpreter's path; hardware need only supply output words. Issue records
identify mismatches, confirmed failures and unresolved cases. Counts distinguish
numeric, special, outside-domain and certificate coverage.
Missing mathematical references keep an infinite maximum-error upper bound;
an empty suite is unresolved.

These observations never replace a uniform certificate or establish correct
rounding. The report's binary error enclosure can remain slightly conservative
when an exact rational comparison has already decided a boundary case.

## Sampling

`VerificationSampling()` exhausts formats up to 12 input bits; the threshold is
configurable through 16 bits. Larger formats use domain endpoints, segment and
comparison boundaries with adjacent words, zeros/subnormal/normal transitions,
stratified exponent/significand patterns, a rational domain grid and deterministic
random words/domain points. Exp and periodic kernels also sample half-integer
selection transitions of their stored reduction multipliers. Fixed-output suites
filter to representable finite inputs inside the contract. The manifest records
the sampling options and seed; explicit inputs retain their supplied order.

## Standalone C++ and later hardware execution

The checker can be built without finding or running Julia:

```sh
cmake -S . -B build/checker -DPRESAGE_CHECKER_ONLY=ON
cmake --build build/checker --target presage_check
```

Generate a bundle locally, feed `inputs.bin` to a CPU evaluator, HLS simulation
or a future device adapter, and save raw outputs in record order:

```sh
build/presage_cpu < build/samples/inputs.bin > outputs.bin
build/checker/presage_check build/samples outputs.bin > report.toml
```

The checker and bundle remain the same when the runner changes. A device adapter
handles packing, transfers and restoring record order. GMP/MPFR and file handling
stay on the host. Intermediate traces remain available in the separate CPU
conformance harness; they are not required by this output protocol.

A bundle contains:

| File | Contents |
| --- | --- |
| `manifest.toml` | Contract, formats, word sizes, byte order, sampling options and count. |
| `cases.tsv` | Versioned checker protocol, exact references/bounds and IR branch labels. |
| `inputs.bin` | Raw input words in case order. |
| `expected.bin` | Exact interpreter output words in case order. |
| `plan.toml` | Stored evaluator for replay. |
| `certificate.toml` | Supplied certificate, when available. |

Protocol v1 starts with `PRESAGE_VERIFICATION\t1`, input/output descriptors,
byte order, rational absolute-error target, count and the column names. Each row
has a consecutive one-based index, input/expected bits, reference status/bits,
lower/upper reference endpoints, precision, certificate bound and branch label.
Float descriptors specify exponent/fraction widths; fixed descriptors specify
total/integer widths and signedness. Numbers use exact `numerator/denominator`
or `significand@exponent` (`significand * 2^exponent`); `-` means unavailable.
All binary words occupy `ceil(width/8)` bytes with zero high padding, and fixed
words use two's complement when signed. `cases.tsv` and both binary bundle files
are cross-checked. Missing/extra words, truncated records, invalid formats and
nonzero padding fail validation. No C++ TOML parser is required to run the checker.

Exit codes are `0` passed, `1` failed, `2` unresolved and `3` invalid input or an
execution error. `check_outputs(bundle, outputs; checker)` consumes the same
protocol from Julia, with optional `report_path` for an atomically saved report.

## Sweeps

```julia
observations = verify_sweep(result; checker)
write_sweep_report("build/sweep.toml", result; observations)
```

This is separate postprocessing after the bounded search, with its own sampling
and reference limits. It checks available interpreter graphs, including candidates
that exceed the proof budget, and preserves expected arithmetic/domain failures
as observations. Search deadlines, cache payloads and certified Pareto metrics
retain their existing meanings. Reports with observations use sweep schema v2;
ordinary reports remain v1. The sweep CLI accepts `--checker=EXEC` and returns a
nonzero status if a certified candidate's sampled verification does not pass.
