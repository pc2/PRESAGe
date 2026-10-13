# PRESAGe

Generate and verify mathematical function approximations for FPGAs.

A Julia core plans the approximation, certifies its numerical error and generates
C++ evaluators using official AC or AP arithmetic types. Planning and numerical
verification run locally without an FPGA.

The design objective is low resource use with one input per cycle (**II=1**).
Resource estimates are configurable; vendor synthesis must establish actual
resource use and achieved II.

## What can it generate?

- **Bounded Sollya expressions**, including compositions, with polynomial
  approximation and complete evaluator error bounds.
- **Segmented Horner evaluators** with up to 512 uniform segments and individual
  coefficient and stage widths.
- **Fixed and floating interfaces**, including mixed formats, custom floating
  precision and internal guard bits.
- **Specialized reductions** for erf, erfc, reciprocal, roots, logarithms,
  exponentials, trigonometric and hyperbolic functions.
- **Full lookup tables** for small input formats, compared with polynomial
  candidates using resource profiles and budgets.

See [function expression coverage](docs/expression-coverage.md) for supported
domains and current limits. A certificate includes evaluator arithmetic and
output rounding; it does not generally promise correctly rounded results.

## Setup

Requires **Julia 1.13 or later** and installed **Sollya 8.0, MPFR and GMP** libraries.

From the repository root:

```sh
julia --startup-file=no scripts/dev.jl
```

This installs the unregistered [Sollya.jl](https://github.com/pc2/Sollya.jl)
dependency at the Git revision pinned in `Project.toml`. Initial setup needs
GitHub SSH access. Set `JULIA_PKG_USE_CLI_GIT=true` before starting Julia to use
the system Git and its SSH configuration.

C++ verification also needs a C++20 compiler with native 128-bit integers and
GMP/MPFR development headers. Vendor arithmetic uses the public
[AC](https://github.com/hlslibs/ac_types) or
[AP](https://github.com/Xilinx/HLS_arbitrary_Precision_Types) headers.
See [development setup](CONTRIBUTING.md#development-setup) for header locations,
custom library paths and a local Sollya checkout.

## Quick start

Generate a bounded approximation and certify the complete evaluator:

```julia
using PRESAGe

spec = FunctionSpec("exp(x)+0.1*x";
    input_format=IEEE32, domain=(-1,1), absolute_error=1//(1<<21))
result = certified_polynomial(spec; degree=13,
    internal_format=FloatFormat(8,27), evaluation=:fma,
    generation_precision=256, proof_precision=256)

@assert result.status == :certified
write_plan("composed.toml", result.plan)
write_certificate("certificate.toml", result)
```

This makes one attempt with the chosen degree and arithmetic format.
Use `search_polynomial` with its default automatic arithmetic to compare certified candidates.
Supply a resource profile and budget to select by estimated hardware cost, or use a [design sweep](docs/sweeps.md) for multiple contracts and cached comparisons.

To generate C++ from a contract and search configuration:

```sh
julia --startup-file=no --project=. scripts/generate.jl \
  examples/exp-contract.toml build/bounded \
  --search-config=examples/polynomial-search.toml --backend=ac_fixed
```

Successful generation saves the evaluator, host adapter, plan, certificate and
search report. See the [generation guide](docs/generation.md) for replay and
failure handling, or [kernel generation](docs/kernels.md) for synthesis-oriented
C++.

## Generate and run a CPU evaluator

Build and check the default erf evaluator with CMake 3.24 or later:

```sh
cmake --preset cpu-macos
cmake --build --preset cpu-macos
ctest --preset cpu-macos
build/cpu-macos/presage_cpu < inputs.bin > outputs.bin
```

Use `cpu-linux` on Linux. The default build uses AC headers; portable and AP
backends are also available. See [CPU build options](docs/generation.md#generate-and-run-a-cpu-evaluator).

The host adapter reads and writes encoded binary words. The
[standalone C++ checker](docs/sampled-verification.md) can also check saved
simulation or hardware outputs.

## Documentation

| Topic | Guide |
| --- | --- |
| Expressions and supported domains | [Function coverage](docs/expression-coverage.md) |
| Generation, search and replay | [Generation](docs/generation.md) |
| Formats and arithmetic backends | [Arithmetic](docs/arithmetic.md) |
| Uniform error proofs | [Certification](docs/certification.md) |
| Design selection and resource budgets | [Sweeps](docs/sweeps.md), [resource models](docs/resources.md), [LUT or polynomial](docs/implementations.md) |
| Generated kernels and interfaces | [C++ kernels](docs/kernels.md) |
| References and numerical checks | [Oracle](docs/oracle.md), [sampled verification](docs/sampled-verification.md), [local results](docs/verification.md) |
| Stored contracts and plans | [Artifact schema](docs/schema.md) |
| Testing and formatting | [Contributing](CONTRIBUTING.md) |

Runnable examples are in [`examples/`](examples/). The development plan is
maintained in [`../plan/DEVELOPMENT_PLAN.md`](../plan/DEVELOPMENT_PLAN.md).

## Paper and license

PRESAGe originated with the following paper:

> Gerrit Pape, Christian Plessl, and Tobias Kenter. 2026. Systematic Function
> Approximation on FPGAs to Address Accuracy and Throughput Issues in
> oneAPI and Vitis HLS Math Libraries. HEART 2026, Heidelberg, Germany.
> ACM, 10 pages. [DOI: 10.1145/3814576.3814578](https://doi.org/10.1145/3814576.3814578)

The original `generator/` and `analysis/` directories contain paper-era source.
They are outside the Julia package's build and tests.

Licensed under the [GNU General Public License v3.0 or later](COPYING).
