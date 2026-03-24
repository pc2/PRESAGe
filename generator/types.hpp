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

#include <array>
#include <cstdint>
#include <iostream>
#include <vector>

bool verbose = false;

enum Symmetry
{
    even,
    odd,
    neither,
};

enum Format
{
    SG = 0, // single precision (32-bit)
    D = 1,  // double precision (64-bit)
};

enum Exponential
{
    is_none,
    is_exp,
    is_cosh,
    is_sinh,
};

enum Boundary
{
    is_all,   // extend polynomial beyond range (used when reductions handle boundaries)
    is_poly,  // evaluate polynomial at boundary segments
    is_nan,   // return NaN outside range
    is_const, // return constant limit value at boundaries
};

enum Toolchain
{
    is_vitis = 0,
    is_oneapi = 1,
};

enum Memory
{
    use_lut,
    use_ram,
    use_auto,
};

std::ostream& operator<<(std::ostream& os, Memory mem)
{
    switch (mem) {
        case use_lut:
            return os << "lut";
        case use_ram:
            return os << "ram";
        case use_auto:
            return os << "auto";
    }
    return os;
}

constexpr std::array<Memory, 2> memory_values = {Memory::use_lut, Memory::use_ram};

enum Minimize
{
    lut,
    ram,
    balanced,
};

struct Strategy
{
    uint32_t degree;
    uint32_t split;
    auto operator<=>(const Strategy&) const = default;
    Strategy(uint32_t degree, uint32_t split) : degree(degree), split(split) {}
    Strategy() {}
};

// Tracks which IEEE 754 fields are needed for segment selection in the multiplexer
struct Segmenting
{
    bool needs_sign;
    bool needs_exponent;
    bool needs_mantissa;
    Segmenting(bool needs_sign, bool needs_exponent, bool needs_mantissa) : needs_sign(needs_sign), needs_exponent(needs_exponent), needs_mantissa(needs_mantissa) {}
};

std::ostream& operator<<(std::ostream &os, const Strategy &s)
{
    return os << "degree = " << s.degree << ", split = " << s.split;
}

std::ostream& operator<<(std::ostream &os, const std::pair<int, int> &p)
{
    return os << "<" << p.first << ", " << p.second << ">";
}
