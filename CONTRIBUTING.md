# Contributing

## Development setup

Requires Julia 1.13 or newer and installed Sollya/MPFR/GMP libraries.
[Sollya.jl](https://github.com/pc2/Sollya.jl) is an unregistered Git dependency
pinned to a tested commit in `Project.toml`. CPU tests also require a C++20 compiler
(Clang or GCC with native 128-bit integers), plus GMP C++ and MPFR development
headers/libraries. Set `CXX` and optionally `GMP_PREFIX` for the package tests.

The expected workspace is:

```text
workspace/
├── PRESAGe/          # Project.toml, src/, test/, scripts/, docs/
├── Sollya.jl/        # Optional local numerical dependency for development
├── ac_types/        # Public Algorithmic C headers
└── HLS_arbitrary_Precision_Types/ # Public Xilinx simulation headers
```

From the **PRESAGe repository root**:

```sh
julia --startup-file=no scripts/dev.jl
```

`dev.jl` instantiates the pinned Git dependency and creates an ignored local
manifest. Initial setup needs access to the repository through GitHub SSH;
package registration is not required. `JULIA_PKG_USE_CLI_GIT=true` makes Julia
use the system Git and its existing SSH configuration.

For cached setup, set `JULIA_PKG_OFFLINE=true`. Rerun `dev.jl` when switching
Julia versions. For an isolated cache, prefix commands with
`JULIA_DEPOT_PATH=/tmp/presage-depot:`.

### Local Sollya checkout

To develop Sollya locally, explicitly set `PRESAGE_SOLLYA_PATH`:

```sh
PRESAGE_SOLLYA_PATH=../Sollya.jl julia --startup-file=no scripts/dev.jl
```

This mode uses offline package operations. Julia's `Pkg.develop` changes the
Sollya source in `Project.toml` and the local Manifest to that checkout; keep the
committed Git URL and revision when publishing PRESAGe. Changing `Project.toml`
back to its Git source and rerunning `dev.jl` restores the pinned dependency.

### Native libraries and vendor headers

Sollya.jl discovers the installed library. Set `SOLLYA_LIBRARY` to an explicit
shared-library path before the first native call when necessary. Direct MPFR
references use Julia's own MPFR runtime.

Both fixed libraries are public under Apache 2.0:
[Algorithmic C types](https://github.com/hlslibs/ac_types) and
[Xilinx arbitrary precision simulation types](https://github.com/Xilinx/HLS_arbitrary_Precision_Types).
Place local checkouts beside PRESAGe, or set `PRESAGE_AC_INCLUDE_DIR` and
`PRESAGE_AP_INCLUDE_DIR` to their `include` directories. Tests run each vendor
backend when its headers are present; `PRESAGE_REQUIRE_VENDOR_TESTS=true` makes
missing headers an error. Builds and tests do not download them.

To obtain the official checkouts from the PRESAGe repository root:

```sh
git clone --depth 1 https://github.com/hlslibs/ac_types.git ../ac_types
git clone --depth 1 https://github.com/Xilinx/HLS_arbitrary_Precision_Types.git ../HLS_arbitrary_Precision_Types
```

## Tests

After setup, run the package tests from the repository root:

```sh
julia --startup-file=no --threads=4 scripts/check.jl
```

The check script uses offline package operations. To require both official
vendor-header backends rather than skip a missing library:

```sh
PRESAGE_REQUIRE_VENDOR_TESTS=true \
  julia --startup-file=no --threads=4 scripts/check.jl
```

See [local verification](docs/verification.md) for recorded results and numerical
coverage. CPU checks establish arithmetic behavior; vendor synthesis establishes
hardware resource use and achieved II.

## Formatting

JuliaFormatter uses the repository's [configuration](.JuliaFormatter.toml),
with four-space indentation and a 92-column margin. Its version is pinned in a
separate development environment. From the repository root:

```sh
julia --startup-file=no --project=tools/format -e 'using Pkg; Pkg.instantiate()'
julia --startup-file=no --project=tools/format scripts/format.jl
julia --startup-file=no --project=tools/format scripts/format.jl --check
```

The check command exits with status 1 when formatting is required and does not
write files. The command formats Julia files in `src`, `scripts`, `test` and
`examples`. For offline setup, reuse a resolved formatter manifest and cached
dependencies, and call `Pkg.offline(true)` before `Pkg.instantiate()`.
