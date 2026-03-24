# Analysis

Accuracy and resource analysis of the math libraries shipped with AMD Vitis HLS and Intel oneAPI for FPGA, plus evaluation of the generated approximations.

## Structure

```
.
├── Vitis/          # AMD Vitis HLS (Alveo U280, XCU280)
│   ├── hls/        # HLS kernel templates (unary and binary)
│   ├── host/       # Host-side XRT driver
│   ├── configs/    # Build configurations per function group
│   ├── eval/       # Data collection from synthesis reports (Julia)
│   └── scripts/    # SLURM scripts for synthesis and execution
├── oneAPI/         # Intel oneAPI (Bittware 520N, Stratix 10 GX 2800)
│   ├── device/     # SYCL device kernels
│   ├── host/       # Host driver
│   ├── eval/       # Data collection from synthesis reports (Julia)
│   └── scripts/    # SLURM scripts for synthesis and execution
├── eval/           # Accuracy evaluation scripts (Julia)
├── plot/           # Visualization scripts (Julia)
├── scripts/        # Batch orchestration (SLURM)
├── common.hpp      # Shared C++ utilities (Dataset, test input generation)
├── ieee754.jl      # IEEE 754 and file format helpers (Julia)
└── config.json     # Operation and approximation definitions
```

## Analyzed Functions

All math functions listed in `config.json` (37 function entries across binary and unary groups) are evaluated where supported by both toolchains, in half, single, and double precision:

| Group (config.json) | Type | Functions |
|---------------------|------|-----------|
| `additive` | binary | select, addition, subtraction |
| `multiplicative` | binary | multiplication, division |
| `trigonometric` | unary | sin, cos, tan |
| `arcus_trigonometric` | unary | asin, acos, atan |
| `trigonometric_pi` | unary | sinpi, cospi, tanpi |
| `arcus_trigonometric_pi` | unary | asinpi, acospi, atanpi |
| `hyperbolic` | unary | cosh, sinh, tanh |
| `arcus_hyperbolic` | unary | acosh, asinh, atanh |
| `exponential` | unary | exp, exp10, exp2, expm1 |
| `logarithmic` | unary | log, log10, log1p |
| `power` | unary | cbrt, rsqrt, sqrt, recip |
| `special` | unary | identity, erf, erfc |

The oneAPI toolchain does not natively support half precision. Half precision is implemented using `ap_float<5, 10>` type from the HLS AC types library (`sycl/ext/intel/ac_types/ap_float.hpp`). This type does not provide math functions for tan, tanpi, sinh, cosh, tanh, asinh, acosh, atanh, erf, and erfc.

## Configuration

`config.json` defines all operations and approximations organized into groups and can be extended easily to create more designs.

## Dependencies

- **AMD Vitis HLS** (2023.2) — loaded via `Vitis/env.sh`
- **Intel oneAPI** (25.0.0) — loaded via `oneAPI/env.sh`
- **Julia** (v1.11.6+) — installed separately via [juliaup](https://github.com/JuliaLang/juliaup), not included in the `env.sh` scripts

Julia packages:

```julia
using Pkg
Pkg.add(["CSV", "DataFrames", "JSON", "CairoMakie", "SpecialFunctions", "Quadmath"])
```

## FPGA Designs

In the Vitis designs, operations are grouped into bitstreams according to `./Vitis/configs/` utilizing all HBM banks. For the oneAPI designs, one bitstream is created for each operation.

### Building and running for Vitis

```bash
cd Vitis
source env.sh
mkdir build && cd build
cmake -DBUILD_TARGET=hw ..
make main                       # build the host application
make trigonometric_xclbin       # synthesize one group (e.g. trigonometric)
./main trigonometric            # run on FPGA
```

### Building and running for oneAPI

```bash
cd oneAPI
source env.sh
mkdir build && cd build
cmake ..
make sin_link                   # synthesize one operation (e.g. sin)
./sin.fpga                      # run on FPGA
```

### Toolchain-specific scripts

Both `Vitis/scripts/` and `oneAPI/scripts/` contain SLURM scripts for batch submission:

| Script | Purpose |
|--------|---------|
| `run.sh` | SLURM wrapper for running a single design on FPGA hardware |
| `synth.sh` | SLURM wrapper for synthesizing a single design |
| `for_all.sh <synth/run>` | Submits `synth.sh` or `run.sh` for all operations |
| `synth_approximations.sh` | Synthesizes all approximations |
| `run_approximations.sh` | Runs all approximation variants on FPGA |
| `approximations_emu.sh` | Builds reports and software emulation binaries for approximations |
| `run_approximations_emu.sh` | Runs software emulation of approximation binaries |
| `local_mem_reports.sh` | Generates synthesis reports for all degree/segment/memory type combinations |

### Toolchain-specific data collection

Both `Vitis/eval/` and `oneAPI/eval/` contain Julia scripts for extracting data from synthesis reports. Run from within the respective toolchain directory:

| Script | Purpose |
|--------|---------|
| `eval/collect_resources.jl` | Parses synthesis reports for FPGA resource utilization (LUT/FF/BRAM/DSP) |
| `eval/collect_overview.jl` | Normalizes resources against identity baseline, produces `unitary_lib_overview.csv` and `unitary_approx_overview.csv` |
| `eval/collect_estimations.jl` | Collects resource estimations for approximations |
| `eval/collect_local_mem.jl` | Extracts memory implementation details from local memory experiments |

These run after synthesis and produce the CSV files consumed by the plot scripts.

### Evaluation (`eval/`)

| Usage | Purpose |
|-------|---------|
| `julia -t <threads> eval/golden.jl <operation>` | Generates reference outputs using BigFloat arbitrary-precision arithmetic |
| `julia -t <threads> eval/deviations.jl <toolchain> <operation> [approximation] [instance]` | Computes bit, absolute, and relative deviations against golden references |
| `julia -t <threads> eval/max_deviations.jl <toolchain> <operation>` | Finds maximum error per input binade |
| `julia eval/max_deviations_summary.jl` | Aggregates all per-operation results into a summary LaTeX table and worst-case CSV files |
| `julia -t <threads> eval/special.jl` | Checks NaN handling, flush-to-zero, and overflow boundaries for all operations |
| `julia eval/stats.jl <binary_file>` | Prints per-chunk statistics (sign, exponent, mantissa, value ranges) of any binary data file |
| `julia eval/freq.jl` | Extracts kernel clock frequencies from oneAPI Quartus synthesis reports |

### Visualization (`plot/`)

All plot scripts are run manually with `julia plot/<script>`. They read CSV data produced by the evaluation pipeline and generate PDF figures.

| Script | Purpose |
|--------|---------|
| `plot/linear.jl` | Generic linear plot of binary data files (used by the batch plot scripts) |
| `plot/approximation_resources_model.jl` | Resource usage and accuracy of generated approximations with model estimations (paper Figures 8, 9) |
| `plot/approximation_resources.jl` | Resource usage and accuracy of generated approximations without model |
| `plot/approximation_resources_usage.jl` | Comparison of approximation vs. library resource usage |
| `plot/estimations.jl` | Resource estimation accuracy across strategies (paper Figure 7) |
| `plot/local_mem.jl` | Memory resource usage heatmaps for different degree/segment/memory type combinations |
| `plot/oneapi_erf_deviation.jl` | erf/erfc function values and absolute error on oneAPI (paper Figure 4) |
| `plot/vitis_timings.jl` | Average execution time per binade for non-pipelined Vitis functions (paper Figure 5) |
| `plot/vitis_cbrt_half.jl` | cbrt output plot for Vitis half precision (paper Figure 3) |

## Batch Workflow (using SLURM)

All batch scripts in `scripts/` target the Noctua 2 supercomputer. The `scripts/run.sh` wrapper submits Julia jobs with 128 threads on an exclusive node.

### 1. Generate golden references

```bash
./scripts/golden_all.sh
```

### 2. Synthesize FPGA designs

Library functions:

```bash
cd Vitis && ./scripts/for_all.sh synth
cd oneAPI && ./scripts/for_all.sh synth
```

Approximations:

```bash
cd Vitis && ./scripts/synth_approximations.sh
cd oneAPI && ./scripts/synth_approximations.sh
```

### 3. Run on FPGA hardware

Library functions:

```bash
cd Vitis && ./scripts/for_all.sh run
cd oneAPI && ./scripts/for_all.sh run
```

Approximations:

```bash
cd Vitis && ./scripts/run_approximations.sh
cd oneAPI && ./scripts/run_approximations.sh
```

### 4. Collect resource data from synthesis reports

From within each toolchain directory:

```bash
julia eval/collect_resources.jl
julia eval/collect_overview.jl
julia eval/collect_estimations.jl
```

### 5. Evaluate accuracy

Library functions (for both toolchains from analysis directory):

```bash
./scripts/eval_all_deviations.sh
./scripts/eval_all_max_deviations.sh
```

Approximations (for both toolchains from analysis directory):

```bash
./scripts/eval_approximation_deviations.sh
./scripts/eval_approximation_max_deviations.sh
```

### 6. Generate plots

Generate plots of all outputs and deviations for a general overview:

```bash
./scripts/plot_all_deviations_linear.sh
./scripts/plot_all_approximation_deviations.sh
./scripts/plot_all_outputs_linear.sh
```

### Validation of memory resource model (optional)

Generate synthesis reports for all degree/segment/memory type combinations:

```bash
cd Vitis && ./scripts/local_mem_reports.sh
cd oneAPI && ./scripts/local_mem_reports.sh
```

Collect results and plot heatmaps:

```bash
julia eval/collect_local_mem.jl
julia plot/local_mem.jl
```
