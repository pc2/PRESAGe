# Fixed C++ kernels

`emit_kernel` generates a C++17 evaluator using official `ap_fixed`/`ap_uint`
or `ac_fixed`/`ac_int` types throughout. The header contains bounded arrays,
scalar values and a finite DAG of inline functions. PRESAGe's GMP/MPFR helpers,
streams, tracing and exceptions belong to host tools.

## Generate and verify locally

```julia
using PRESAGe

spec = FunctionSpec("1/3+x";
    input_format=FixedFormat(9,3), output_format=FixedFormat(24,4),
    domain=(-1,1), absolute_error=1//2^18)
plan = polynomial_plan(spec, [1//3,1];
    internal_format=FixedFormat(32,6), evaluation=:fma)
certificate = certify_plan(plan)
@assert certificate.status == :certified

write_plan("plan.toml", plan)
emit_kernel("evaluator.hpp", plan; backend=:ac_fixed)
emit_kernel_harness("evaluate.cpp", plan.program)
```

Compile the host adapter against the supplied AC headers:

```sh
clang++ -std=c++17 -O2 -fno-exceptions -fno-rtti \
  -isystem ../ac_types/include evaluate.cpp -o evaluate
```

AP uses `backend=:ap_fixed` and the `HLS_arbitrary_Precision_Types/include`
directory. Neither runner links GMP or MPFR. The independent checker uses
these libraries for directed error comparisons:

```julia
checker = build_verification_checker("presage_check")
report = verify_samples(certificate;
    checker, evaluator="./evaluate", directory="verification")
@assert report["status"] == "passed"
```

Saved `outputs.bin` can be checked again without invoking Julia. The runner
uses the existing little-endian raw-word protocol, so a later simulation or
hardware adapter can supply the same outputs. See
[portable verification](sampled-verification.md).

The generation CLI accepts the same stored plan:

```sh
julia --project=. scripts/generate.jl plan.toml build/kernel \
  --target=kernel --backend=ac_fixed
```

`--toolchain=generic` is the default. `vitis` requires AP types and emits guarded
array partition hints. `oneapi` requires AC types, selects Intel's AC include
paths under the Intel compiler and emits guarded FPGA memory attributes.
Ordinary compilation of that header uses the supplied public AC headers.
Public header fallbacks are compiled locally. Vendor compiler branches and
synthesis are still pending.

For the CMake host workflow, set `PRESAGE_PLAN`, `PRESAGE_TARGET=kernel` and
`PRESAGE_BACKEND=ac_fixed|ap_fixed`. `PRESAGE_TOOLCHAIN` selects the hints.
The `presage_cpu` executable is the host adapter, and `kernel_verification`
is its CTest gate. No FPGA is needed.

## Interfaces and rejection

The generated namespace defaults to `presage_evaluator`:

```cpp
presage_evaluator::Input input = /* exact declared fixed input */;
auto result = presage_evaluator::evaluate(input);
if (result.valid()) {
    presage_evaluator::Output output = result.value;
}

presage_evaluator::InputBits raw = /* unsigned input payload */;
auto bits = presage_evaluator::evaluate_bits(raw);
// Consume bits.bits only when bits.valid() is true.
```

| Status | Byte | Corresponding interpreter result |
| --- | --- | --- |
| `ok` | 0 | Valid output with identical bits. |
| `domain_rejected` | 1 | `Guard` raises `DomainError`. |
| `overflow_rejected` | 2 | Rounded fixed result raises `OverflowError`. |
| `table_index_rejected` | 3 | `TableLoad` raises `BoundsError`. |

Failure stops evaluation immediately. Failed results carry a zero placeholder
and a nonzero status; the placeholder is not a mathematical output.
The adapter exits with code 1 on rejection. Its optional `--status` mode writes
one status byte followed by the output word for every input, including rejected
inputs. This mode is useful for domain tests; it is a different stream from
the checker's ordinary output format. Truncated words and nonzero padding
are rejected with code 3, even when the graph does not use its input.

## Preserved arithmetic and dispatch

The emitted graph is the stored IR. Emission does not generate coefficients,
choose new formats or replace reduction identities.

- Constants and tables retain exact payloads, including widths above 64 bits.
- Each `Mul`/`Add` rounds separately. `FMA` stores the full exact product plus
  sum before a single rounding. Native expression widths are widened explicitly.
- `Convert`, `Quantize` and `ScalePow2` use the declared rounding and overflow
  policies. All four rounding modes and reject/saturate/wrap are supported.
  Scaling reinterprets the binary point before quantization.
- Individual coefficient, coordinate and stage formats remain independent.
- `Select` evaluates only its chosen branch; `Guard` checks its condition
  before its source. Other operands are visited in interpreter order, and shared
  nodes are evaluated once. Rejected operations in untaken branches stay inactive.
- Fixed classification, all six comparison predicates, unsigned bit operations
  and extraction retain their IR semantics. Shifts at or above the operand
  width return zero, including wide shift counts.
- Table indices are checked before conversion to a host index. Storage uses
  cyclic banks: entry `i` is in bank `i % banks`, row `i / banks`. Padding is
  inaccessible. `unroll=true` emits each bank selection explicitly. Horner
  stages are already expanded by the IR. Both metadata fields remain in the
  header; toolchain hints may guide the physical implementation.

The old `generator/` inspired the table organization and compiler hints.
Arithmetic follows the current IR and certificate, including explicit separate
versus fused rounding.

## Supported scope

Fixed input, output and arithmetic graphs are supported, including ordinary,
normalized segmented and individually sized polynomial evaluators. Unsigned
nodes and fixed/unsigned tables are supported. Floating interfaces, floating
arithmetic and exponent-reduction graphs are rejected explicitly. The active
CPU emitter continues to cover those graphs.

All vendor types and exact temporaries must fit the 4096-bit limit. A table must
fit the C `int` index range; bank counts cannot exceed its entry count or 4096.
OneAPI bank counts must be powers of two. Unsupported emission leaves an
existing destination header or generated bundle intact.

Local conformance establishes arithmetic agreement with the interpreter and
reference checker. It does not establish vendor compiler acceptance, resources,
latency or throughput. Those require actual vendor compilation and synthesis.
