/*
 * Copyright (C) 2025-2026 Gerrit Pape (gerrit.pape@uni-paderborn.de)
 *
 * This file is part of PRESAGe.
 *
 * PRESAGe is free software: you can redistribute it and/or modify it
 * under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * any later version.
 *
 * PRESAGe is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with PRESAGe. If not, see <https://www.gnu.org/licenses/>.
 */
#pragma once

#include <cstdint>
#include <vector>
#include <sstream>
#include <iomanip>
#include <bit>

#include "types.hpp"
#include "Approximation.hpp"

// Per-FMA resource costs, indexed as [toolchain][format]
// Measured from synthesis of a single FMA operation
// Vitis values are split into multiplier + adder components
const uint32_t luts_per_fma[2][2] = {
    {(78 + 198), (127 + 635)},    // Vitis: single, double
    {64, 2850},                   // oneAPI: single, double
};
const uint32_t ffs_per_fma[2][2] = {
    {(143 + 318), (388 + 685)},
    {128, 389},
};
const uint32_t dsps_per_fma[2][2] = {
    {(3 + 2), (8 + 3)},
    {1, 4},
};

// Per-comparison resource costs for the segment selection multiplexer
const uint32_t luts_per_sign_compare[2][2] = {
    {1, 1},
    {2, 2},
};
const uint32_t luts_per_exponent_compare[2][2] = {
    {1, 4},
    {15, 19},
};
const uint32_t luts_per_mantissa_compare[2][2] = {
    {26, 38},
    {30, 59},
};

// Available resources on target FPGAs
// Vitis: AMD Alveo U280 (XCU280)
// oneAPI: Bittware 520N (Stratix 10 GX 2800)
const uint32_t available_luts[2] = {
    1303680,       // Vitis: LUTs
    933120,        // oneAPI: ALUTs (~245,760 available in MLABs)
};
const uint32_t available_rams[2] = {
    4032,          // Vitis: BRAM18K
    11721,         // oneAPI: M20K
};
const uint32_t available_ffs[2] = {
    2607360,       // Vitis
    3732480,       // oneAPI
};
const uint32_t available_dsps[2] = {
    9024,          // Vitis
    5011,          // oneAPI
};

std::string format_percent(double percent)
{
    std::stringstream out;
    out << std::setprecision(4) << (percent * 100);

    std::string percentage_str =  out.str();
    percentage_str.push_back('%');

    return percentage_str;
}

uint32_t ceil_division(uint32_t a, uint32_t b)
{
    return (a / b) + ((a % b) != 0);
}

class ResourceEstimation
{
public:
    ResourceEstimation() {}
    // binades is indexed as [sign][exponent][mantissa_segment] — mirrors the segment mux hierarchy
    ResourceEstimation(Toolchain toolchain, Format format, Memory memory, Strategy strategy, uint32_t segments, std::vector<std::vector<std::vector<Approximation>>> binades) : toolchain(toolchain), format(format), memory(memory), strategy(strategy), segments(segments), binades(binades)
    {
        // Horner evaluation: one FMA per polynomial degree
        LUTs = luts_per_fma[toolchain][format] * strategy.degree;
        FFs = ffs_per_fma[toolchain][format] * strategy.degree;
        DSPs = dsps_per_fma[toolchain][format] * strategy.degree;

        // Segment selection multiplexer: compare sign, exponent, and mantissa bits
        if (binades[0].size() != 0 && binades[1].size() != 0) {
            LUTs += luts_per_sign_compare[toolchain][format];
        }
        for (const auto &s: binades) {
            if (s.size() > 0) {
                LUTs += luts_per_exponent_compare[toolchain][format] * (s.size() - 1);
                for (const auto &e: s) {
                    if (e.size() > 0) {
                        LUTs += luts_per_mantissa_compare[toolchain][format] * (e.size() - 1);
                        FFs += (e.size() - 1);
                    }
                }
            }
        }
        // Coefficient storage: RAM (M20K/BRAM) or LUT (MLAB/distributed ROM)
        if (toolchain == is_oneapi) {
            if (memory == use_ram || memory == use_auto) {
                RAMs = (strategy.degree + 1);
                if (format == D) {
                    RAMs *= 2;
                }
                RAMs *= ceil_division(segments, 512);
            } else {
                RAMs = 0;
                uint32_t mlabs = (strategy.degree + 1) * 2;
                if (format == D) {
                    mlabs *= 2;
                }
                // depth must be power of two
                mlabs *= std::bit_ceil(ceil_division(segments, 32));
                // 1 MLAB = 10 ALMs = 20 ALUTs
                LUTs += 20 * mlabs;
            }
        } else if (toolchain == is_vitis) {
            bool threshold_reached = ((format == SG) && segments > 128) || ((format == D) && segments > 64);
            if (memory == use_ram || ((memory == use_auto) && threshold_reached)) {
                RAMs = (strategy.degree + 1);
                if (format == D) {
                    RAMs *= 2;
                }
                RAMs *= ceil_division(segments, 512);
            } else {
                RAMs = 0;
                uint32_t bit_width = (format + 1) * 32;
                uint32_t rom_luts = (strategy.degree + 1) * bit_width;
                // depth must be power of two
                rom_luts *= std::bit_ceil(ceil_division(segments, 64));
                LUTs += rom_luts;
            }
        }
        LUT_usage = (double)LUTs / (double)available_luts[toolchain];
        FF_usage = (double)FFs / (double)available_ffs[toolchain];
        RAM_usage = (double)RAMs / (double)available_rams[toolchain];
        DSP_usage = (double)DSPs / (double)available_dsps[toolchain];
    }

    friend std::ostream& operator<<(std::ostream &os, const ResourceEstimation &estimation)
    {
        os << "degree: " << estimation.strategy.degree << ", split: " << estimation.strategy.split
            << ", LUTs: " << estimation.LUTs << " (" << format_percent(estimation.LUT_usage)
            << "), FFs: " << estimation.FFs << " (" << format_percent(estimation.FF_usage) << ")"
            << "), RAMs: " << estimation.RAMs << " (" << format_percent(estimation.RAM_usage) << ")"
            << "), DSPs: " << estimation.DSPs << " (" << format_percent(estimation.DSP_usage) << ")";

        return os;
    }

    std::string to_csv()
    {
        std::stringstream out;
        out << strategy.degree << "," << strategy.split << "," << segments << "," << LUTs << "," << FFs << "," << DSPs << "," << RAMs;
        return out.str();
    }

    uint32_t LUTs;
    uint32_t FFs;
    uint32_t RAMs;
    uint32_t DSPs;

    double LUT_usage;
    double FF_usage;
    double RAM_usage;
    double DSP_usage;

    Toolchain toolchain;
    Format format;
    Memory memory;
    Strategy strategy;
    uint32_t segments;
    std::vector<std::vector<std::vector<Approximation>>> binades;
};
