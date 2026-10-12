# Local design sweeps and numerical caching

`sweep_polynomial` evaluates every configured candidate, including choices after
the first success. It accepts one contract, a nonempty list of contracts or one
stored plan. Contracts share a `PolynomialSearchConfig`; visit contracts, then
segments, degrees and formats in the supplied order. Invalid requests are
validated before launching workers or reading cache entries.

`PolynomialSearchConfig` defaults to `evaluation=:auto`.
For each degree and precision choice, automatic arithmetic considers separate multiplication and addition, then fused multiply add.
Target profiles exclude unsupported arithmetic before launching workers.
Every retained candidate has its own concrete graph and numerical certificate.
Resource sweeps compare both forms using the selected cost objective.
Bounded search returns the first passing candidate in this order.
Explicit `:separate` and `:fma` settings restrict the search to one form.
Constant kernels are evaluated once unless their reconstruction depends on the arithmetic choice.
Stored plan sweeps preserve the saved arithmetic when configured with `:auto`.
Each arithmetic candidate counts toward the attempt limit and has a distinct numerical cache identity.
Attempt records preserve the chosen arithmetic even when generation fails before producing a plan.

```julia
using PRESAGe
spec = FunctionSpec("exp(x)"; input_format=IEEE16, output_format=IEEE32,
    domain=(-1,1), absolute_error=1//2^20)
config = PolynomialSearchConfig(degrees=[5,9],
    internal_formats=[FixedFormat(24+g,6) for g in (0,3,6,8,10)],
    evaluation=:fma, max_attempts=10, job_timeout=60, total_timeout=300)
result = sweep_polynomial(spec, config;
    max_parallel=2, cache=NumericalCache("build/numerical-cache"),
    memory_model=BlockMemoryModel(depth=512, word_bits=32),
    max_table_blocks=8, objective=:memory)
mkpath("build")
write_sweep_artifacts("build/sweep", result)
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
set compares eligible certified rows **within each contract**, using total error,
modeled table blocks, arithmetic result bits, operand bits, stage bits and static
comparison/conversion/table-read counts. A row is dominated only when another
eligible row is no worse in all eight metrics and strictly better in at least
one. Equal rows remain in the set. Logical coefficient/table bits are retained
as diagnostics and final selection tie breakers. These are structural costs,
without calibrated FPGA resources, latency or initiation interval.
Samples are not used as proof.

`elapsed_seconds` measures the current job including cache work. On a hit,
`compute_seconds`, `generation_seconds` and `proof_seconds` retain the original
computation's measurements. Generation/proof phases exclude Julia startup and
artifact transfer; stored replay has zero coefficient-generation time. Timing
is diagnostic and is not a Pareto metric.

## Memory budgets and design selection

`memory_model=BlockMemoryModel(depth=512, word_bits=32)` describes an assumed
rectangular block. Each reachable ROM column is allocated independently, with
depth/width tiling and cyclic bank padding. Center storage is included.
For a 32-bit column, 128 rows and 512 rows each occupy one modeled block.
More segments may allow fewer coefficient columns and less Horner arithmetic,
even when logical table bits increase. See [memory layout](kernels.md#coefficient-memory-layout).
The [memory sweep example](../examples/memory_sweep.jl) generates 128/512-row
`exp(x)` candidates and reselects them under a different block depth and priority.

`max_table_blocks=nothing` permits any modeled allocation; a nonnegative integer
sets a per-candidate budget. Over-budget candidates retain their certificates
and costs, but are excluded from Pareto membership and selection. A budget of
zero permits untabled designs. Each contract has one `result.selections` entry:
`:selected`, `:no_certified_candidate` or `:memory_budget_exceeded`. A selected
entry identifies a request row and explains the decision. An incomplete sweep
can select the best examined candidate; the result still records the search limit.

Selection minimizes a recorded lexicographic order:

| Objective | Priority order |
| --- | --- |
| `:memory` (default) | Blocks, arithmetic result bits, operand bits, stage bits, comparisons, conversions, table reads. |
| `:arithmetic` | Arithmetic result bits, operand bits, stage bits, comparisons, conversions, table reads, blocks. |

Both orders then compare certified total error, logical table bits and coefficient
bits. Exact ties use the original request index. The policy uses declared widths
and static operation counts; it makes no latency or DSP estimate.

Change the model, budget or objective without rerunning numerical jobs:

```julia
reselected = select_sweep(result;
    memory_model=BlockMemoryModel(depth=512, word_bits=36),
    max_table_blocks=6, objective=:arithmetic)
write_sweep_artifacts("build/reselected", reselected)
```

Rows and certificates remain identical. These selection settings are excluded
from numerical cache keys; new sweeps with the same numerical requests can reuse
their cached proofs and recompute costs. Counts exceeding TOML's signed 64-bit
integer range are stored as exact decimal strings.

## Resource estimates

For editable LUT/ALUT, FF, DSP and RAM estimates, individual limits and resource
priorities, see [resource models](resources.md). Resource objectives require a
profile; unknown required estimates exclude a candidate. Profiles also control
block versus distributed ROM hints and export matching selected resource artifacts.

## Sampled observations

Sampled observations can be added after the bounded sweep:

```julia
checker = build_verification_checker("build/presage_check")
observations = verify_sweep(result; checker)
write_sweep_report("build/sweep.toml", result; observations)
```

One C++ checker evaluates mathematical error enclosures, exact bit agreement and
supplied certificate bounds. Julia generates references and refines unresolved
cases. The default runner is the exact interpreter; generated C++ and later device
outputs use the same bundle/checker. See [sampled verification](sampled-verification.md).
Observations are separate from proof status and Pareto metrics. Their postprocessing
does not consume the sweep's search deadline or enter its numerical cache.
Sweep reports use schema v3 without a resource profile and v4 with one. They
record models, budgets, ranking order, eligibility and selections. Observations
are optional. The CLI's optional `--checker=EXEC` adds these observations and requires sampled passing
results for certified rows before returning success.

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
for isolated coefficient/norm subproblems, and cache integration in ordered
generation/precision optimization, are deferred until repeated numerical work
becomes a bottleneck. A single sweep of unique candidates needs no cache;
existing caching is useful for reruns and completed results from interrupted work.

## CLI and replay

```sh
julia --startup-file=no --project=. scripts/sweep.jl \
  contract.toml search-config.toml build/sweep \
  --max-parallel=2 --cache=build/numerical-cache --checker=build/presage_check \
  --memory-depth=512 --memory-word-bits=32 --max-table-blocks=8 --objective=memory
```

The command accepts a stored `plan.toml` with a compatible explicit stage
configuration too. It publishes `build/sweep/sweep.toml` and exact selected
artifacts under `build/sweep/selected/N/`, where `N` is the contract index starting
at one. `write_sweep_artifacts` provides the same Julia workflow;
`write_sweep_report` writes only the report.

The report and `selected/` tree are managed outputs. Publication stages the
bundle, restores previous outputs on ordinary file-operation failures, preserves
unrelated files in the output directory and removes stale selections. Keep
user files outside `selected/`. Report-only writes contain relative selection
paths but do not create the selected files.

Exit code zero requires a complete sweep, one eligible certified selection per
contract and, when requested, passing sampled checks for certified rows. Limits,
missing selections or sampled failures return one. Numerical certification and
memory eligibility remain separate in the report. Selected plans can be used
directly for ordinary generation/replay:

```julia
using PRESAGe
selected = read_plan("build/sweep/selected/1/plan.toml")
@assert certify_plan(selected).status == :certified
```

```sh
julia --startup-file=no --project=. scripts/generate.jl \
  build/sweep/selected/1/plan.toml build/replayed --backend=ac_fixed
```

Generation freshly recertifies the stored plan before emitting C++.

## LUT and polynomial candidates

Use `sweep_implementations` or `scripts/sweep.jl --implementation=auto` to compare
full LUT and polynomial candidates under the same resource/memory selection.
The shared result, `select_sweep`, artifact export and verification APIs work for
both backends. General sweeps use schema version 5; rows identify their
implementation, and reports explain per-contract LUT availability and entry
limits. See [backend selection](implementations.md) for formats, guards and CLI
examples. Existing polynomial-only sweeps retain versions 3/4.
