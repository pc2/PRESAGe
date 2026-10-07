# Local design sweeps and numerical caching

`sweep_polynomial` evaluates every configured candidate, including choices after
the first success. It accepts one contract, a nonempty list of contracts or one
stored plan. Contracts share a `PolynomialSearchConfig`; visit contracts, then
segments, degrees and formats in the supplied order. Invalid requests are
validated before launching workers or reading cache entries.

```julia
using PRESAGe
spec = FunctionSpec("exp(x)"; input_format=IEEE16, output_format=IEEE32,
    domain=(-1,1), absolute_error=1//2^20)
config = PolynomialSearchConfig(degrees=[5,9],
    internal_formats=[FixedFormat(24+g,6) for g in (0,3,6,8,10)],
    evaluation=:fma, max_attempts=10, job_timeout=60, total_timeout=300)
result = sweep_polynomial(spec, config;
    max_parallel=2, cache=NumericalCache("build/numerical-cache"))
mkpath("build")
write_sweep_report("build/sweep.toml", result)
```

At most `max_parallel` (1:64) owned Julia processes run concurrently. Native
objects remain in the workers. The job deadline includes startup and cache work;
the total deadline applies to the entire sweep. `max_attempts` is a global row
limit, including cache hits. Results preserve request order regardless of
completion order. Timeouts and crashes retain available checkpoints and allow
other choices to continue. Parent exceptions cancel and reap sibling workers.

`status=:complete` means every choice was visited, even if none passed.
`status=:sweep_limit` reports `:attempt_limit` or `:total_deadline`. A proof that
completed after a deadline remains a timeout and cannot enter the passing set
or cache. Exhaustion does not establish mathematical infeasibility.

## Compare arithmetic precision

The [guard example](../examples/design_sweep.jl) runs guards `{0,3,6,8,10}`
over two degrees, then holds a passing polynomial's degree, segmentation,
coordinates and coefficient storage/payloads fixed while varying only stage
fraction bits. The existing bounded precision optimizer supplies an adaptive
comparison with a separate precision report.

For the stored experiment, pass a candidate plan and explicit `precisions`
aligned with `internal_formats`. All layouts must retain the plan's coordinate
and coefficient formats. Degree, segments, transformation and evaluation must
match. Each candidate rebuilds explicit stage casts and recertifies the complete
evaluator without regenerating coefficients.

Rows contain the complete certificate: approximation, coordinate, arithmetic
and output-rounding contributions for every path, with transformation-specific
reconstruction details. Reports contain operation counts, coefficient/table
bits, individual coefficient/stage widths and operand/result widths. The Pareto
set compares certified total error and coefficient, stage, arithmetic-result and
table bits **within each contract**. A row is dominated only when another row is
no worse in all five metrics and strictly better in at least one. Equal rows
remain in the set. These are declared structural costs, without calibrated FPGA
resources, latency or initiation interval. Samples are not used as proof.

`elapsed_seconds` measures the current job including cache work. On a hit,
`compute_seconds`, `generation_seconds` and `proof_seconds` retain the original
computation's measurements. Generation/proof phases exclude Julia startup and
artifact transfer; stored replay has zero coefficient-generation time. Timing
is diagnostic and is not a Pareto metric.

## Cache identity and integrity

Only on-time, passing complete certificates are cached. Failures, crashes,
interrupted jobs and timeouts are retried on a later sweep. Keys cover exact
expressions, domains, input/output/error contracts, degree, segments,
transformation, arithmetic mode, all coordinate/coefficient/stage formats,
generation/proof precision, norm accuracy and refinement limits. Stored replay
also includes the complete original plan and raw coefficient payloads.

Compatibility identity includes Julia/platform, the active project/manifest,
PRESAGe and Sollya.jl sources, and loaded Sollya/MPFR/GMP libraries. Workers use
the parent's resolved Sollya library. Execution order, concurrency and time
limits are excluded from the key; current limits still apply on a hit. If sources
changed after the package was loaded, restart Julia before using the cache.

Each entry is one versioned TOML bundle with exact plan/certificate data,
request/compatibility identity, payload checksum and original timings. Writes
are staged on the same filesystem and published by rename. Concurrent writers
can publish different passing coefficient choices for the same request; readers
receive one complete bundle. Hits check identity, checksum, contract, graph audit,
node/range records and certificate budget. Damaged/incompatible entries are regenerated;
native norm proofs are not rerun on a valid hit. These are trusted local artifacts,
not authenticated external proofs.

Cache use is opt-in. Clear its directory to reclaim storage. Eviction and caches
for isolated coefficient/norm subproblems are separate work.

## CLI and replay

```sh
julia --startup-file=no --project=. scripts/sweep.jl \
  contract.toml search-config.toml build/sweep \
  --max-parallel=2 --cache=build/numerical-cache
```

The command accepts a stored `plan.toml` with a compatible explicit stage
configuration too. It atomically replaces `build/sweep/sweep.toml`. Exit code zero
means a complete sweep; a limit returns one. The report retains every available
plan/certificate, including failures, and identifies passing Pareto rows. Extract
a passing plan for ordinary generation/replay:

```julia
using PRESAGe, TOML
data = TOML.parsefile("build/sweep/sweep.toml")
i = first(data["pareto_indices"])
open("build/selected-plan.toml", "w") do io
    TOML.print(io, data["rows"][i]["plan"]; sorted=true)
end
```

```sh
julia --startup-file=no --project=. scripts/generate.jl \
  build/selected-plan.toml build/replayed --backend=ac_fixed
```

Generation freshly recertifies the stored plan before emitting C++.
