# Generator

Generates pipelined polynomial approximations of mathematical functions for FPGAs. The generated C++ code is compatible with AMD Vitis HLS and Intel oneAPI toolchains.

Given a target error, input range, and toolchain, the generator:

1. **Detects function properties** — symmetry (even/odd), periodicity, and exponential structure to apply range reductions automatically
2. **Explores strategies** — tries combinations of polynomial degrees and segmentation split ratios
3. **Generates segments** — partitions the input domain at binade boundaries using the Sollya minimax (Remez) algorithm
4. **Estimates resources** — predicts LUT, FF, RAM, and DSP usage with toolchain-specific cost models
5. **Selects the best strategy** — minimizes a user-chosen resource metric (LUT, RAM, or balanced)
6. **Outputs C++ code** — produces a Horner evaluator with coefficient tables and toolchain-specific HLS pragmas

## Source Files

| File | Purpose |
|------|---------|
| `main.cpp` | Entry point: direct mode (generate approximation) and pragma mode (rewrite source file) |
| `types.hpp` | Enums and structs: `Toolchain`, `Format`, `Symmetry`, `Boundary`, `Strategy`, etc. |
| `Approximation.hpp` | Parses options, detects function properties (symmetry, periodicity, exp), runs Sollya fpminimax |
| `Generator.hpp` | Explores degree/split strategies, selects best by resource cost, generates C++ output |
| `ResourceEstimation.hpp` | FPGA resource cost model (LUT, FF, RAM, DSP) for both toolchains |
| `Rewriter.hpp` | Pragma mode: parses `#pragma approximate` directives and rewrites source files |
| `float_utils.hpp` | IEEE 754 bit manipulation utilities (binade detection, field extraction) |

## Dependencies

System packages (Ubuntu/Debian):

```bash
sudo apt install build-essential cmake
sudo apt install autoconf automake libtool bison flex
sudo apt install libmpfr-dev libgmp-dev
```

The following are automatically downloaded and built by CMake:

- [Sollya](https://www.sollya.org/) — mathematical function approximation library
- [fplll](https://github.com/fplll/fplll) — lattice algorithms library (Sollya dependency)
- [cxxopts](https://github.com/jarro2783/cxxopts) — command-line argument parser

On Noctua 2 use the provided script to load dependencies:

```bash
source env.sh
```

## Building

```bash
mkdir build && cd build
cmake ..
make
```

The first build takes several minutes as it downloads and compiles the dependencies.

## Usage

### Direct Mode

```bash
./generator <toolchain> <precision> <function> <error> [options]
```

Example:
```bash
./generator vitis single "sin(x)" "2^-23" --range "-pi,pi"
```

### Pragma Mode

Process a source file containing `#pragma approximate` directives:

```bash
./generator <input>.cpp
```

The pragma syntax is:

```cpp
#pragma approximate <function_to_replace> <toolchain> <precision> <function> <error> [options]
```

Example:

```cpp
void calculate(uint32_t num, double *in, double *out)
{
#pragma approximate hls::erf vitis double erf(x) 2^-52 \
    --range -5.93,5.93 --boundary const --minimize lut
    for (uint32_t i = 0; i < num; i++) {
        out[i] = hls::erf(in[i]);
    }
}
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `<toolchain>` | Target toolchain (`vitis`/`oneapi`) | positional, required |
| `<precision>` | Output format (`single`/`double`) | positional, required |
| `<function>` | Function to approximate (Sollya expression) | positional, required |
| `<error>` | Target error bound (Sollya expression) | positional, required |
| `-r, --range` | Approximation domain (two values) | `-1.0,1.0` |
| `-d, --degree` | Polynomial degree range (min,max) | `3,14` |
| `-s, --split` | Segmentation split ratios | `2,3,5,7` |
| `-t, --errortype` | Error metric: `absolute` or `relative` | `absolute` |
| `-b, --boundary` | Boundary behavior: `poly`, `const`, or `NaN` | `poly` |
| `-m, --minimize` | Resource to minimize: `lut`, `ram`, or `balanced` | `lut` |
| `-w, --weights` | Weights for balanced minimization (LUTs,FFs,RAMs,DSPs) | `1.0,0.0,1.0,0.0` |
| `-n, --no_range_reductions` | Disable automatic range reduction implementation | `false` |
| `-v, --verbose` | Verbose output | `false` |

## Output

The generator produces:

- `<input>.cpp.approximation.cpp` - Original input file with function call replaced by call to generated approximation
- `<name>.cpp` — Generated HLS-ready C++ with a Horner evaluator, coefficient table, and segmentation multiplexer
- `<name>.csv` — Resource estimations for all evaluated strategies
