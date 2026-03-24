# Systematic Function Approximation for FPGAs

This project is the source code used in the following paper and provides a systematic approach for generating polynomial approximations of mathematical functions targeting FPGA implementations via oneAPI and Vitis HLS.

It addresses accuracy and throughput limitations in the math libraries of AMD Vitis HLS and Intel oneAPI, and provides the evaluation codes which were used to find the limitations and evaluate the generated approximations.

> Gerrit Pape, Christian Plessl, and Tobias Kenter. 2026. Systematic Function
Approximation on FPGAs to Address Accuracy and Throughput Issues in
oneAPI and Vitis HLS Math Libraries. In Proceedings of the 16th International
Symposium on Highly Efficient Accelerators and Reconfigurable Technologies
(HEART 2026), June 17–19, 2026, Heidelberg, Germany. ACM, New York, NY,
USA, 10 pages. https://doi.org/10.1145/3814576.3814578

```
.
├── generator/      # Approximation generator (C++, Sollya)
└── analysis/       # Accuracy and resource analysis of HLS math libraries
    ├── Vitis/      # AMD Vitis HLS designs and data collection
    ├── oneAPI/     # Intel oneAPI designs and data collection
    ├── eval/       # Evaluation scripts (Julia)
    ├── plot/       # Visualization scripts (Julia + CairoMakie)
    └── scripts/    # Orchestration scripts
```

See [generator/README.md](generator/README.md) and [analysis/README.md](analysis/README.md) for details.

This repository is licensed under the GNU General Public License v3.0 or later.
