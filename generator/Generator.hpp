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

#include <sollya.h>
#include <mpfr.h>

#include <cstdint>
#include <iostream>
#include <sstream>
#include <fstream>
#include <iomanip>
#include <limits>
#include <cmath>
#include <ranges>
#include <algorithm>
#include <cinttypes>
#include <random>
#include <bit>
#include <tuple>
#include <map>
#include <optional>
#include <functional>

#include "types.hpp"
#include "float_utils.hpp"
#include "Approximation.hpp"
#include "ResourceEstimation.hpp"

class Generator
{
public:
    Generator(Approximation &approximation) : prec(approximation.prec), format(approximation.format), degreeMin(approximation.degreeMin), degreeMax(approximation.degreeMax), split_ratios(approximation.split_ratios), fS(sollya_lib_copy_obj(approximation.fS)), precS(sollya_lib_copy_obj(approximation.precS)), rangeS(sollya_lib_copy_obj(approximation.rangeS)), toolchain(approximation.toolchain), boundary(approximation.boundary), minimize(approximation.minimize), symmetry(approximation.symmetry), exponential(approximation.exponential), is_periodic(approximation.is_periodic), fix_segments(approximation.fix_segments), random_coefficients(approximation.random_coefficients), weights(approximation.weights), inline_functions(approximation.inline_functions), no_range_reductions(approximation.no_range_reductions), output_name(approximation.output_name)
    {
        if (format == SG) {
            float_type = "float";
            byte_type = "uint32_t";
            int_type = "int32_t";
            sign_type = ap_uint(1);
            exponent_type = ap_uint(SINGLE_EXPONENT_BITS);
            mantissa_type = ap_uint(SINGLE_MANTISSA_BITS);
        } else if (format == D) {
            float_type = "double";
            byte_type = "uint64_t";
            int_type = "int64_t";
            sign_type = ap_uint(1);
            exponent_type = ap_uint(DOUBLE_EXPONENT_BITS);
            mantissa_type = ap_uint(DOUBLE_MANTISSA_BITS);
        }

        // Enumerate all (degree, split_ratio) combinations to try
        std::vector<Strategy> strategies;
        if (fix_segments > 0) {
            strategies.push_back(Strategy(degreeMin, 2));
        } else {
            for (uint32_t d = degreeMin; d <= degreeMax; d++) {
                for (const auto &s: split_ratios) {
                    strategies.push_back(Strategy(d, s));
                }
            }
        }

        // Try each strategy: recursively split the domain until the target error is reached
        for (const auto &strategy: strategies) {
            approximations[strategy] = std::vector<Approximation>();
            std::cout << "Strategy: " << strategy;
            try {
                split_to_reach_error(approximation, strategy);
                std::cout << std::endl;
            } catch (const std::logic_error &e) {
                std::cout << " failed: " << e.what() << std::endl;
                approximations[strategy] = std::nullopt;
                for (const auto &mem: memory_values) {
                    estimations[{strategy, mem}] = std::nullopt;
                }
            }
        }

        if (std::ranges::all_of(approximations | std::views::values, [](const auto &opt) {return !opt.has_value(); })) {
            throw std::logic_error("no strategy was successful");
        }

        check_merges();

        // Organize segments into a 3D structure indexed as [sign][exponent][mantissa_segment]
        // This mirrors the hierarchical multiplexer in the generated code:
        // first compare sign, then exponent, then mantissa bits within a binade
        for (const auto &strategy: strategies) {
            int pos_min = INT_MAX;
            int pos_max = INT_MIN;
            int neg_min = INT_MAX;
            int neg_max = INT_MIN;

            if (!approximations[strategy].has_value()) {
                continue;
            }

            for (const auto &a: *approximations[strategy]) {
                if (mpfr_sgn(a.domMin) < 0) {
                    int e;
                    if (mpfr_sgn(a.domMax) == 0) {
                        e = static_cast<int>(mpfr_get_exp(a.domMin)) - 2;
                    } else {
                        e = static_cast<int>(mpfr_get_exp(a.domMax)) - 1;
                    }

                    neg_min = std::min(neg_min, e);
                    neg_max = std::max(neg_max, e);
                } else {
                    int e;
                    if (mpfr_sgn(a.domMin) == 0) {
                        e = static_cast<int>(mpfr_get_exp(a.domMax)) - 2;
                    } else {
                        e = static_cast<int>(mpfr_get_exp(a.domMin)) - 1;
                    }
                    pos_min = std::min(pos_min, e);
                    pos_max = std::max(pos_max, e);
                }
            }

            binades[strategy].resize(2);
            if (neg_min <= neg_max) {
                binades[strategy][0].resize(static_cast<std::size_t>(neg_max - neg_min + 1));
            }
            if (pos_min <= pos_max) {
                binades[strategy][1].resize(static_cast<std::size_t>(pos_max - pos_min + 1));
            }

            for (const auto &a: *approximations[strategy]) {
                if (mpfr_sgn(a.domMin) < 0) {
                    int e;
                    if (mpfr_sgn(a.domMax) == 0) {
                        e = static_cast<int>(mpfr_get_exp(a.domMin)) - 2;
                    } else {
                        e = static_cast<int>(mpfr_get_exp(a.domMax)) - 1;
                    }
                    binades[strategy][0][neg_max - e].push_back(a);
                } else {
                    int e;
                    if (mpfr_sgn(a.domMin) == 0) {
                        e = static_cast<int>(mpfr_get_exp(a.domMax)) - 2;
                    } else {
                        e = static_cast<int>(mpfr_get_exp(a.domMin)) - 1;
                    }
                    binades[strategy][1][e - pos_min].push_back(a);
                }
            }
            bool needs_sign = (binades[strategy][0].size() != 0 && binades[strategy][1].size() != 0);

            bool needs_exponent = false;
            bool needs_mantissa = false;
            for (const auto &s: binades[strategy]) {
                if (s.size() > 1) {
                    needs_exponent = true;
                }
                for (const auto &e: s) {
                    if (e.size() > 1) {
                        needs_mantissa = true;
                    }
                }
            }
            segmenting[strategy] = Segmenting(needs_sign, needs_exponent, needs_mantissa);
        }

        // Estimate resources for each strategy × memory type and find the best
        double min_usage = std::numeric_limits<double>::max();
        uint64_t min_luts = std::numeric_limits<uint64_t>::max();
        uint64_t min_rams = std::numeric_limits<uint64_t>::max();
        for (const auto &strategy: strategies) {
            if (approximations[strategy].has_value()) {
                for (const auto &mem: memory_values) {
                    ResourceEstimation estimation = ResourceEstimation(toolchain, format, mem, strategy, approximations[strategy]->size(), binades[strategy]);
                    double usage = (weights[0] * estimation.LUT_usage) + (weights[1] * estimation.FF_usage) + (weights[2] * estimation.RAM_usage) + (weights[3] * estimation.DSP_usage);
                    if (usage < min_usage) {
                        min_usage = usage;
                        min_balanced_strategy = {strategy, mem};
                    }
                    if (estimation.LUTs < min_luts) {
                        min_luts = estimation.LUTs;
                    }
                    if (estimation.RAMs < min_rams) {
                        min_rams = estimation.RAMs;
                    }
                    std::cout << "mem: " << mem << ", " << estimation << ", weighted usage: " << usage << std::endl;
                    estimations[{strategy, mem}] = estimation;
                }
            }
        }

        // Select minimum-LUT strategy, tie-break by minimum RAM
        uint64_t min_rams_of_lut = std::numeric_limits<uint64_t>::max();
        for (const auto &strategy: strategies) {
            for (const auto &mem: memory_values) {
                if (estimations[{strategy, mem}].has_value()) {
                    if (estimations[{strategy, mem}]->LUTs == min_luts) {
                        if (estimations[{strategy, mem}]->RAMs < min_rams_of_lut) {
                            min_luts_strategy = {strategy, mem};
                            min_rams_of_lut = estimations[{strategy, mem}]->RAMs;
                        }
                    }
                }
            }
        }

        // Select minimum-RAM strategy, tie-break by minimum LUT
        uint64_t min_luts_of_ram = std::numeric_limits<uint64_t>::max();
        for (const auto &strategy: strategies) {
            for (const auto &mem: memory_values) {
                if (estimations[{strategy, mem}].has_value()) {
                    if (estimations[{strategy, mem}]->RAMs == min_rams) {
                        if (estimations[{strategy, mem}]->LUTs < min_luts_of_ram) {
                            min_rams_strategy = {strategy, mem};
                            min_luts_of_ram = estimations[{strategy, mem}]->LUTs;
                        }
                    }
                }
            }
        }

        if (minimize == lut) {
            std::cout << "choosing ";
            std::tie(best, memory) = min_luts_strategy;
        }
        std::cout << "strategy with minimum LUTs: mem = " << std::get<1>(min_luts_strategy) << ", " << std::get<0>(min_luts_strategy) << std::endl;
        if (minimize == ram) {
            std::cout << "choosing ";
            std::tie(best, memory) = min_rams_strategy;
        }
        std::cout << "strategy with minimum RAMs: mem = " << std::get<1>(min_rams_strategy) << ", " << std::get<0>(min_rams_strategy) << std::endl;
        if (minimize == balanced) {
            std::cout << "choosing ";
            std::tie(best, memory) = min_balanced_strategy;
        }
        std::cout << "strategy with minimum balanced usage: " << std::get<1>(min_balanced_strategy) << ", " << std::get<0>(min_balanced_strategy) << std::endl;
        std::cout << "Segments:\n";
        for (const auto &s: binades[best]) {
            for (const auto &e: s) {
                for (const auto &m: e) {
                    mpfr_printf("[%.8Rf ; %.8Rf] ", m.domMin, m.domMax);
                }
                std::cout << std::endl;
            }
        }
    }

    // Recursively split the input domain until the minimax polynomial reaches the target error.
    // Splitting is done at binade boundaries using the strategy's split ratio.
    void split_to_reach_error(Approximation &approximation, Strategy strategy)
    {
        if (fix_segments == 0) {
            approximation.fpminimax(strategy.degree);
            if (approximation.reaches_error(strategy.degree)) {
                approximations[strategy]->push_back(approximation);
            } else {
                if (verbose) std::cout << "target error not reached, splitting up" << std::endl;
                for (auto &a: approximation.split(strategy.split)) {
                    split_to_reach_error(a, strategy);
                }
            }
        } else {
            if (!random_coefficients) {
                approximation.fpminimax(strategy.degree);
            }
            if (fix_segments > 1) {
                fix_segments--;
                for (auto &a: approximation.split(2)) {
                    split_to_reach_error(a, strategy);
                }
            } else {
                approximations[strategy]->push_back(approximation);
            }
        }
    }

    // After segmentation, try to merge adjacent segments within the same binade
    // if their combined range still meets the error target — reduces segment count
    void check_merges()
    {
        if (fix_segments != 0) {
            return;
        }
        for (auto& [strategy, approximation]: approximations) {
            if (approximation.has_value()) {
                for (uint32_t i = 0; i < approximation->size() - 1; i++) {
                    if (!in_one_binade((*approximation)[i].domMin, (*approximation)[i + 1].domMax)) {
                        continue;
                    }
                    Approximation merger = Approximation((*approximation)[i], (*approximation)[i].domMin, (*approximation)[i + 1].domMax);
                    merger.fpminimax(strategy.degree);
                    if (merger.reaches_error(strategy.degree)) {
                        if (verbose) std::cout << "merging" << std::endl;
                        (*approximation)[i] = merger;
                        approximation->erase(approximation->begin() + i + 1);
                        i--;
                    }
                }
            }
        }
    }

    std::string binary(mpfr_t value)
    {
        std::stringstream out;
        if (format == SG) {
            float valueF = mpfr_get_flt(value, MPFR_RNDN);
            const uint32_t *valueB = reinterpret_cast<const uint32_t*>(&valueF);
            out << "0x" << std::setfill('0') << std::setw(sizeof(float) * 2) << std::hex << *valueB;
        } else if (format == D) {
            double valueF = mpfr_get_d(value, MPFR_RNDN);
            const uint64_t *valueB = reinterpret_cast<const uint64_t*>(&valueF);
            out << "0x" << std::setfill('0') << std::setw(sizeof(double) * 2) << std::hex << *valueB;
        }
        return out.str();
    }

    std::string random_binary(uint32_t seed)
    {
        std::stringstream out;
        if (format == SG) {
            std::mt19937 engine(seed);
            std::uniform_int_distribution<uint32_t> distribution(0, std::numeric_limits<uint32_t>::max());
            uint32_t value = distribution(engine);

            out << "0x" << std::setfill('0') << std::setw(sizeof(uint32_t) * 2) << std::hex << value;
        } else if (format == D) {
            std::mt19937_64 engine(seed);
            std::uniform_int_distribution<uint64_t> distribution(0, std::numeric_limits<uint64_t>::max());
            uint64_t value = distribution(engine);
            out << "0x" << std::setfill('0') << std::setw(sizeof(uint64_t) * 2) << std::hex << value;
        }
        return out.str();
    }

    std::string decimal(mpfr_t value)
    {
        std::stringstream out;
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt(value, MPFR_RNDN);
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d(value, MPFR_RNDN);
        }
        return out.str();
    }

    std::string ap_uint(uint64_t w)
    {
        std::stringstream out;
        if (toolchain == is_vitis) {
            out << "ap_uint<" << w << ">";
        } else if (toolchain == is_oneapi) {
            out << "ac_int<" << w << ", false>";
        }
        return out.str();
    }

    std::string construct_reinterpret_helper()
    {
        std::stringstream out;
        if (format == SG) {
            out << "const " << byte_type << " EXPONENT_BITS = " << SINGLE_EXPONENT_BITS << ";\n"
                << "const " << byte_type << " MANTISSA_BITS = " << SINGLE_MANTISSA_BITS << ";\n";
        } else if (format == D) {
            out << "const " << byte_type << " EXPONENT_BITS = " << DOUBLE_EXPONENT_BITS << ";\n"
                << "const " << byte_type << " MANTISSA_BITS = " << DOUBLE_MANTISSA_BITS << ";\n";
        }
        out << "const " << byte_type << " SHIFTED_EXPONENT_MASK = ((" << byte_type << ")1 << EXPONENT_BITS) - 1;\n"
            << "const " << byte_type << " MANTISSA_MASK = ((" << byte_type << ")1 << MANTISSA_BITS) - 1;\n\n"
            << "const " << byte_type << " SIGN_MASK = (" << byte_type << ")1 << (MANTISSA_BITS + EXPONENT_BITS);\n\n";

        if (segmenting[best]->needs_sign || symmetry != neither) {
            out << "static inline " << sign_type << " get_sign(" << float_type << " x)\n{\n"
                << "\tconst " << byte_type << " *bits = reinterpret_cast<const " << byte_type << "*>(&x);\n"
                << "\treturn (*bits >> (EXPONENT_BITS + MANTISSA_BITS));\n}\n\n";
        }

        if (segmenting[best]->needs_exponent) {
            out << "static inline " << exponent_type << " get_exponent(" << float_type << " x)\n{\n"
                << "\tconst " << byte_type << " *bits = reinterpret_cast<const " << byte_type << "*>(&x);\n"
                << "\treturn (*bits >> MANTISSA_BITS) & SHIFTED_EXPONENT_MASK;\n}\n\n";

            if (segmenting[best]->needs_mantissa) {
                out << "static inline " << mantissa_type << " get_mantissa(" << float_type << " x)\n{\n"
                    << "\tconst " << byte_type << " *bits = reinterpret_cast<const " << byte_type << "*>(&x);\n"
                    << "\treturn (*bits & MANTISSA_MASK);\n}\n\n";
            }
        }

        if (!(symmetry == neither) || ((exponential == is_cosh) || (exponential == is_sinh)))
        {
            out << "static inline void flip_sign(" << float_type << " &x)\n{\n"
                << "\t" << byte_type << " *bits = reinterpret_cast<" << byte_type << "*>(&x);\n"
                << "\t*bits ^= SIGN_MASK;\n}\n\n";
        }
        return out.str();
    }

    std::string construct_coefficient_table()
    {
        std::stringstream out;

        uint32_t segments = approximations[best]->size();
        out << "const uint32_t segments = " << segments << ";\n"
            << "const uint32_t degree = " << best.degree << ";\n";
        uint32_t numbanks = std::bit_ceil(best.degree + 1);
        if (toolchain == is_oneapi) {
            out << "[[intel::numbanks(" << numbanks << "), intel::max_replicates(1), intel::fpga_memory";
            if (memory == use_lut) {
                out << "(\"MLAB\")";
            } else if (memory == use_ram) {
                out << "(\"BLOCK_RAM\")";
            }
            out << "]]\n";
        }
        out << "static const " << byte_type << " coeff_table[segments][" << numbanks << "] = {\n";
        uint32_t seed = 42;
        for (auto &a: *approximations[best]) {
            if (random_coefficients) {
                out << "\t{";
                for (uint32_t i = 0; i < numbanks; i++) {
                    out << random_binary(seed) << ", ";
                    seed++;
                }
                out << "},\n";

            } else {
                out << "\t/* " << range_str(a.domMin, a.domMax) << "\n\t";
                for (uint32_t i = 0; i < numbanks; i++) {
                    mpfr_t coeff;
                    mpfr_init2(coeff, a.prec);
                    if (i <= best.degree) {
                        sollya_obj_t coeffS = sollya_lib_coeff(a.pS, SOLLYA_CONST_UI64(best.degree - i));
                        sollya_lib_get_constant(coeff, coeffS);
                    } else {
                        mpfr_set_zero(coeff, 1);
                    }

                    out << decimal(coeff) << ", ";
                }
                out << "*/\n\t{";
                for (uint32_t i = 0; i < numbanks; i++) {
                    mpfr_t coeff;
                    mpfr_init2(coeff, a.prec);
                    if (i <= best.degree) {
                        sollya_obj_t coeffS = sollya_lib_coeff(a.pS, SOLLYA_CONST_UI64(best.degree - i));
                        sollya_lib_get_constant(coeff, coeffS);
                    } else {
                        mpfr_set_zero(coeff, 1);
                    }
                    out << binary(coeff) << ", ";
                }
                out << "},\n";
            }
        }
        out << "\n};\n\n";
        out << "static inline " << float_type << " coeff(uint32_t s, uint32_t d)\n{\n"
            << "\t" << int_type << " c = coeff_table[s][d];\n"
            << "\treturn *reinterpret_cast<const " << float_type << "*>(&c);\n}\n\n";
        return out.str();
    }

    std::string domMin(uint32_t i)
    {
        std::stringstream out;
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt((*approximations[best])[i].domMin, MPFR_RNDN) << "f";
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d((*approximations[best])[i].domMin, MPFR_RNDN);
        }
        return out.str();
    }

    std::string domMax(uint32_t i)
    {
        std::stringstream out;
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt((*approximations[best])[i].domMax, MPFR_RNDN) << "f";
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d((*approximations[best])[i].domMax, MPFR_RNDN);
        }
        return out.str();
    }

    std::string domMinValue(uint32_t i)
    {
        std::stringstream out;
        mpfr_t result;
        mpfr_init2(result, prec);
        sollya_lib_evaluate_function_at_point(result, fS, (*approximations[best])[i].domMin, NULL);
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt(result, MPFR_RNDN) << "f";
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d(result, MPFR_RNDN);
        }
        return out.str();
    }

    std::string domMaxValue(uint32_t i)
    {
        std::stringstream out;
        mpfr_t result;
        mpfr_init2(result, prec);
        sollya_lib_evaluate_function_at_point(result, fS, (*approximations[best])[i].domMax, NULL);
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt(result, MPFR_RNDN) << "f";
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d(result, MPFR_RNDN);
        }
        return out.str();
    }

    std::string period()
    {
        std::stringstream out;
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt((*approximations[best])[0].period, MPFR_RNDN) << "f";
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d((*approximations[best])[0].period, MPFR_RNDN);
        }
        return out.str();
    }

    std::string periodMin()
    {
        std::stringstream out;
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt((*approximations[best])[0].periodMin, MPFR_RNDN) << "f";
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d((*approximations[best])[0].periodMin, MPFR_RNDN);
        }
        return out.str();
    }

    std::string periodMax()
    {
        std::stringstream out;
        if (format == SG) {
            out << std::fixed << std::setprecision(9) << mpfr_get_flt((*approximations[best])[0].periodMax, MPFR_RNDN) << "f";
        } else if (format == D) {
            out << std::fixed << std::setprecision(17) << mpfr_get_d((*approximations[best])[0].periodMax, MPFR_RNDN);
        }
        return out.str();
    }

    std::string pow()
    {
        if (toolchain == is_vitis) {
            if (format == SG) {
                return "hls::powf";
            } else if (format == D) {
                return "hls::pow";
            }
        } else if (toolchain == is_oneapi) {
            return "sycl::pow";
        }
        return "";
    }

    std::string round()
    {
        if (toolchain == is_vitis) {
            if (format == SG) {
                return "hls::roundf";
            } else if (format == D) {
                return "hls::round";
            }
        } else if (toolchain == is_oneapi) {
            return "sycl::round";
        }
        return "";
    }

    std::string ldexp()
    {
        std::stringstream out;
        if (toolchain == is_vitis) {
            if (format == SG) {
                out << "hls::ldexpf";
            } else if (format == D) {
                out << "hls::ldexp";
            }
        } else if (toolchain == is_oneapi) {
            out << "sycl::ldexp";
        }
        return out.str();
    }

    std::string ldexp_1(std::string arg)
    {
        std::stringstream out;
        out << ldexp() << "(1.0";
        if (format == SG) {
            out << "f";
        }
        out << ", " << arg << ")";
        return out.str();
    }

    std::string literal(std::string arg)
    {
        std::stringstream out;
        out << arg;
        if (format == SG) {
            out << "f";
        }
        return out.str();
    }

    std::string construct_exponential_reduction()
    {
        std::stringstream out;
        out << "constexpr " << float_type << " log_of_2 = " << std::fixed << std::setprecision(17) << log(2.0) << ";\n"
            << "constexpr " << float_type << " inv_log_of_2 = " << std::fixed << std::setprecision(17) << 1.0/log(2.0) << ";\n\n"
            << "static " << (inline_functions ? "inline " : "") << "void exponential_reduction(" << float_type << " &x, " << int_type << " &e)\n{\n";
        if (toolchain == is_vitis && !inline_functions) {
            out << "#pragma HLS inline off\n";
        }
        out << "\t" << float_type << " x_over_log2 = x * inv_log_of_2;\n"
            << "\te = (" << int_type << ")" << round() << "(x_over_log2);\n"
            << "\tx = x - e * log_of_2;\n"
            << "}\n\n";

        out << "static " << (inline_functions ? "inline" : "") << "void exponential_evaluation(" << float_type << " &y, " << int_type << "&e)\n{\n";
        if (toolchain == is_vitis && !inline_functions) {
            out << "#pragma HLS inline off\n";
        }
        out << "\ty *= " << ldexp_1("e") << ";\n}\n\n";

        if ((exponential == is_cosh) || (exponential == is_sinh)) {
            out << "static " << (inline_functions ? "inline" : "") << float_type << " hyperbolic_evaluation(" << float_type << " &x, " << float_type << " &e_y, " << float_type << "&e_y_neg)\n{\n";
            if (toolchain == is_vitis && !inline_functions) {
                out << "#pragma HLS inline off\n";
            }
                out << "\t" << ap_uint(1) << " sign = get_sign(x);\n"
                    << "\t" << float_type << " r = sign == " << ap_uint(1) << "(1) ? e_y / e_y_neg : e_y_neg / e_y;\n";
            if (exponential == is_cosh) {
                out << "\t" << float_type << " h = sign == " << ap_uint(1) << "(1) ? " << literal("0.5") << " * e_y_neg : " << literal("0.5") << " * e_y;\n"
                    << "\treturn h * (" << literal("1.0") << " + r);\n";
            } else {
                out << "\t" << float_type << " h = sign == " << ap_uint(1) << " (1) ? -" << literal("0.5") << " * e_y_neg : " << literal("0.5") << " * e_y;\n"
                    << "\treturn h * (" << literal("1.0") << " - r);\n";
            }
            out << "}\n\n";
        }
        return out.str();
    }

    std::string floor()
    {
        std::stringstream out;
        if (toolchain == is_vitis) {
            if (format == SG) {
                out << "hls::floorf";
            } else if (format == D) {
                out << "hls::floor";
            }
        } else if (toolchain == is_oneapi) {
            out << "sycl::floor";
        }
        return out.str();
    }

    std::string construct_periodic_reduction()
    {
        std::stringstream out;
        out << "const " << float_type << " period = " << period() << ";\n"
            << "const " << float_type << " period_start = " << periodMin() << ";\n"
            << "constexpr " << float_type << " period_inv = 1.0/" << period() << ";\n\n"
            << "static " << (inline_functions ? "inline " : "") << "void periodic_reduction(" << float_type << " &x)\n{\n";
        if (toolchain == is_vitis) {
            out << "#pragma HLS inline off\n";
        }
        out << "\tif (!(x < " << periodMin() << " || x > " << periodMax() << ")) {\n"
            << "\t\treturn;\n\t}\n"
            << "\t" << float_type << " q = (x - period_start) * period_inv;\n"
            << "\t" << int_type << " n = (" << int_type << ")"<< floor() << "(q);\n"
            << "\tx = (x - period_start) - (n * period);\n"
            << "\tx += period_start;\n}\n\n";
        return out.str();
    }

    std::string construct_symmetric_reduction()
    {
        std::stringstream out;
        out << "static " << (inline_functions ? "inline " : "") << "void symmetric_reduction(" << float_type << " &x";
        if (symmetry == odd) {
            out << ", bool &invert";
        }
        out << ")\n{\n";
        if (!inline_functions && (toolchain == is_vitis)) {
            out << "#pragma HLS inline off\n";
        }
        out << "\tif (get_sign(x) == " << sign_type << "(1)) {\n"
            << "\t\tflip_sign(x);\n";
        if (symmetry == odd) {
            out << "\t\tinvert = true;\n";
        }
        out << "\t}\n}\n\n";

        if (symmetry == odd) {
            out << "static " << (inline_functions ? "inline " : "") << "void symmetric_evaluation(bool invert, " << float_type << " &x)\n{\n";
            if (!inline_functions && (toolchain == is_vitis)) {
                out << "#pragma HLS inline off\n";
            }
            out << "\tif (invert) {\n\t\tflip_sign(x);\n\t}\n}\n\n";
        }
        return out.str();
    }

    std::string construct_boundary_check()
    {
        uint32_t last_i = approximations[best]->size() - 1;
        std::stringstream out;
        out << "static " << (inline_functions ? "inline ": "") << "bool boundary_check(" << ((symmetry == odd) ? "bool invert, " : "") << float_type << " &x)\n{\n";
        if (!inline_functions && (toolchain == is_vitis)) {
            out << "#pragma HLS inline off\n";
        }
        if (!(symmetry == neither)) {
            out << "\tif (x > " << domMax(last_i) << ") {\n";
            if (boundary == is_nan) {
                out << "\t\tx = NAN;\n";
            } else if (boundary == is_const) {
                std::string val = domMaxValue(last_i);
                if (symmetry == odd) {
                    out << "\t\tx = invert ? -" << val << " : " << val << ";\n";
                } else {
                    out << "\t\tx =  " << val << ";\n";
                }
            }
            out << "\t\treturn true;\n\t}\n";
        } else {
            out << "\tif (x < " << domMin(0) << ") {\n";
            if (boundary == is_nan) {
                out << "\t\tx = NAN;\n";
            } else if (boundary == is_const) {
                out << "\t\tx = " << domMinValue(0) << ";\n";
            }
            out << "\t\treturn true;\n\t} else if (x > " << domMax(last_i) << ") {\n";
            if (boundary == is_nan) {
                out << "\t\tx= NAN;\n";
            } else if (boundary == is_const) {
                out << "\t\tx = " << domMaxValue(last_i) << ";\n";
            }
            out << "\t\treturn true;\n\t}\n";
        }
        out << "\treturn false;\n}\n\n";
        return out.str();
    }

    std::string construct_reduction_steps()
    {
        uint32_t last_i = approximations[best]->size() - 1;
        std::stringstream out;

        if (exponential == is_none) {
            if (is_periodic) {
                out << "\tperiodic_reduction(x);\n";
            }
            if (symmetry == odd) {
                out << "\tbool invert = false;\n";
            }
            if (symmetry == even || symmetry == odd) {
                out << "\tsymmetric_reduction(x";
                if (symmetry == odd) {
                    out << ", invert";
                }
                out << ");\n";
                if (!is_periodic && (boundary == is_nan || boundary == is_const)) {
                    out << "\tif (boundary_check(" << ((symmetry == odd) ? "invert, " : "") << "x))\n\t\treturn x;\n";
                }
            }
        } else {
            if (exponential == is_exp) {
                out << "\t" << int_type << " e;\n"
                    << "\texponential_reduction(x, e);\n";
            } else {
                out << "\t" << int_type << " e_neg;\n"
                    << "\t" << int_type << " e_pos;\n"
                    << "\t" << float_type << " x_neg = x;\n"
                    << "\tflip_sign(x_neg);\n"
                    << "\texponential_reduction(x, e_pos);\n"
                    << "\texponential_reduction(x_neg, e_neg);\n";
            }
        }
        out << "\tuint32_t segment = 0;\n";
        if (last_i != 0) {
            out << "\tsegment_mux(x, segment);\n";
        }
        if (exponential == is_cosh || exponential == is_sinh) {
            out << "\tuint32_t segment_neg = 0;\n";
            if (last_i != 0) {
                out << "\tsegment_mux(x_neg, segment_neg);\n";
            }
        }
        return out.str();
    }

    std::string range_str(mpfr_t a, mpfr_t b)
    {
        char buf[4096];
        mpfr_snprintf(buf, 4096, "[%.8Rf ; %.8Rf]", a, b);
        return std::string(buf);
    }

    // Generate the segment selection multiplexer.
    // Determines which polynomial segment to use based on the input value.
    // Compares IEEE 754 fields hierarchically: sign → exponent → mantissa.
    std::string construct_segment_mux() {

        uint32_t last_i = approximations[best]->size() - 1;
        std::stringstream out;
        out << "static " << (inline_functions ? "inline " : "") << "void segment_mux(" << float_type << " &x, uint32_t &segment)\n{\n";
        if (toolchain == is_vitis) {
            out << "#pragma HLS inline off\n";
        }
        uint32_t bias;
        if (format == SG) {
            bias = 127;
        } else if (format == D) {
            bias = 1023;
        }
        uint32_t segment = 0;
        if (segmenting[best]->needs_sign) {
            out << "\tconst " << sign_type << " sign = get_sign(x);\n";
        }
        if (segmenting[best]->needs_exponent) {
            out << "\tconst " << exponent_type << " exponent = get_exponent(x);\n";
        }
        if (segmenting[best]->needs_mantissa) {
            out << "\tconst " << mantissa_type << " mantissa = get_mantissa(x);\n";
        }
        std::string tab = "\t";
        if ((binades[best][0].size() != 0) && (binades[best][1].size() != 0)) {
            tab = "\t\t";
        }
        for (uint32_t s = 0; s < 2; s++) {
            if ((binades[best][0].size() != 0) && (binades[best][1].size() != 0)) {
                if (s == 0) {
                    out << "\tif (sign == " << sign_type << "(1)) {\n";
                } else {
                    out << "\t} else {\n";
                }
            }

            if (binades[best][s].size() == 1) {
                out << tab << "segment = " << segment++ << ";\n";
            } else {
                for (uint32_t b = 0; b < binades[best][s].size(); b++) {
                    std::string compare = s ? "<" : ">=";
                    uint32_t last_m = binades[best][s][b].size() - 1;
                    int e = static_cast<int>(mpfr_get_exp(binades[best][s][b][last_m].domMax)) - 1 + bias;
                    if (b == 0) {
                        out << tab << "if (exponent " << compare << " " << exponent_type << "(" << e << ")) {\n";
                    } else if (b == (binades[best][s].size() - 1)) {
                        out << tab << "} else {\n";
                    } else {
                        if (s) {
                            e -= 1;
                        }
                        out << tab << "} else if (exponent == " << exponent_type << "(" << e << ")) {\n";
                    }
                    if (binades[best][s][b].size() == 1) {
                        out << tab << "\t/* " << range_str(binades[best][s][b][0].domMin, binades[best][s][b][0].domMax) << " */\n";
                        out << tab << "\tsegment = " << segment++ << ";\n";
                    } else {
                        for (uint32_t m = 0; m < binades[best][s][b].size(); m++) {
                            std::string compare = s ? "<" : ">";
                            uint64_t mantissa;
                            if (format == SG) {
                                mantissa = get_single_mantissa(mpfr_get_flt(binades[best][s][b][m].domMax, MPFR_RNDN));
                            } else if (format == D) {
                                mantissa = get_double_mantissa(mpfr_get_d(binades[best][s][b][m].domMax, MPFR_RNDN));
                            }
                            char mantissa_buf[128];
                            snprintf(mantissa_buf, sizeof(mantissa_buf), "0x%" PRIx64, mantissa);
                            if (m == 0) {
                                out << tab << "\tif (mantissa " << compare << " " << mantissa_type << "(" << std::string(mantissa_buf) << ")) {\n";
                            } else if (m == (binades[best][s][b].size() - 1)) {
                                out << tab << "\t} else {\n";
                            } else {
                                out << tab << "\t} else if (mantissa " << compare << " " << mantissa_type << "(" << std::string(mantissa_buf) << ")) {\n";
                            }
                            out << tab << "\t\t/* " << range_str(binades[best][s][b][m].domMin, binades[best][s][b][m].domMax) << " */\n";
                            out << tab << "\t\tsegment = " << segment++ << ";\n";
                        }
                        out << tab << "\t}\n";
                    }
                }
                if (binades[best][s].size() != 0) {
                    out << tab << "}\n";
                }
            }
        }
        if ((binades[best][0].size() != 0) && (binades[best][1].size() != 0)) {
            out << "\t}\n";
        }

        out << "}\n\n";
        return out.str();
    }

    std::string construct_horner_evaluator()
    {
        std::stringstream out;
        out << "static "  << (inline_functions ? "inline " : "") << float_type << " horner_evaluator(" << float_type << " &x, uint32_t segment)\n{\n";
        if (toolchain == is_vitis) {
            out << "#pragma HLS inline off\n"
                << "#pragma HLS array_partition variable=coeff_table type=complete dim=2\n"
                << "#pragma HLS bind_storage variable=coeff_table type=rom_1p impl=";
            if (memory == use_lut) {
                out << "lutram";
            } else if (memory == use_ram) {
                out << "bram";
            } else {
                out << "auto";
            }
            out << "\n";
        }
        out << "\t" << float_type << " y = coeff(segment, 0);\n";
        if (toolchain == is_oneapi) {
            out << "#pragma unroll\n";
        }
        out << "\tfor (uint32_t i = 1; i <= degree; i++) {\n";
        if (toolchain == is_vitis) {
            out << "#pragma HLS unroll\n";
        }
        out << "\t\ty = y * x + coeff(segment, i);\n\t}\n"
            << "\treturn y;\n}\n\n";
        return out.str();
    }

    std::string construct_evaluation_and_return() {
        std::stringstream out;
        out << "\t" << float_type << " y = horner_evaluator(x, segment);\n";
        if (exponential == is_none) {
            if (symmetry == odd) {
                out << "\tsymmetric_evaluation(invert, y);\n";
            }
        } else {
            if (exponential == is_exp) {
                out << "\texponential_evaluation(y, e);\n";
            } else {
                out << "\t" << float_type << " y_neg = horner_evaluator(x_neg, segment_neg);\n"
                    << "\texponential_evaluation(y, e_pos);\n"
                    << "\texponential_evaluation(y_neg, e_neg);\n"
                    << "\ty = hyperbolic_evaluation(x, y, y_neg);\n";
            }
        }
        out << "\treturn y;\n";
        return out.str();
    }

    std::string name()
    {
        // If output_name was provided via command line, use it directly
        if (!output_name.empty()) {
            return output_name;
        }

        // Otherwise, generate a unique name based on function properties
        char name[4096];
        if (exponential == is_exp) {
            sollya_lib_snprintf(name, 4096, "exp_%b", fS);
        } else if (exponential == is_cosh) {
            sollya_lib_snprintf(name, 4096, "cosh_%b", fS);
        } else if (exponential == is_sinh) {
            sollya_lib_snprintf(name, 4096, "sinh_%b", fS);
        } else {
            sollya_lib_snprintf(name, 4096, "f_%b", fS);
        }
        uint64_t num_segments = approximations[best]->size();
        char buf[4096];
        sollya_lib_snprintf(buf, 4096, "%s_%b_%b_%lu_%lu", name, precS, rangeS, num_segments, best.degree);

        // Sanitize: replace non-alphanumeric with underscores
        char *ptr = buf;
        while (*ptr != '\0') {
            if (std::isalnum(*ptr)) {
                ptr++;
            } else {
                *ptr++ = '_';
            }
        }

        // Add hash suffix for uniqueness
        std::string base_name(buf);
        size_t hash = std::hash<std::string>{}(base_name);
        std::stringstream result;
        result << base_name << "_" << std::hex << (hash & 0xFFFFFFFF);
        return result.str();
    }

    void write(std::string path)
    {
        std::ofstream out(path, std::ios::out);
        out << "#include <stdint.h>\n#include <cmath>\n";
        if (toolchain == is_vitis) {
            out << "#include <ap_int.h>\n";
        } else if (toolchain == is_oneapi) {
            out << "#include <sycl/ext/intel/ac_types/ac_int.hpp>\n";
        }
        if (exponential != is_none || is_periodic) {
            if (toolchain == is_vitis) {
                out << "#include <hls_math.h>\n";
            } else if (toolchain == is_oneapi) {
                out << "#include <sycl/sycl.hpp>\n";
            }
        }
        out << "\nnamespace " << name() << " {\n"
            << construct_coefficient_table()
            << construct_reinterpret_helper();
        if (exponential == is_none) {
            if (is_periodic) {
                out << construct_periodic_reduction();
            }
            if (symmetry == even || symmetry == odd) {
                out << construct_symmetric_reduction();
            }
        } else {
            out << construct_exponential_reduction();
        }
        if (!is_periodic && (exponential == is_none) && (boundary == is_nan || boundary == is_const)) {
            out << construct_boundary_check();
        }
        if (approximations[best]->size() != 1) {
            out << construct_segment_mux();
        }
        out << construct_horner_evaluator()
            << "static " << (inline_functions ? "inline " : "") << float_type << " approximation(" << float_type << " x)\n{\n"
            << construct_reduction_steps()
            << construct_evaluation_and_return()
            << "}\n}";
    }

    void write_resource_estimation(std::string path)
    {
        std::ofstream out(path, std::ios::out);
        out << "Degree,Split,Segments,LUTs,FFs,DSPs,RAMs,MinLUTs,MinRAMs,MinUsage\n";
        for (auto &[strategy, estimation]: estimations) {
            if (estimation.has_value()) {
                out << estimation->to_csv()
                    << "," << ((strategy == min_luts_strategy) ? "true" : "false")
                    << "," << ((strategy == min_rams_strategy) ? "true" : "false")
                    << "," << ((strategy == min_balanced_strategy) ? "true" : "false")
                    << "\n";
            }
        }
    }

    uint64_t degreeMin, degreeMax;
    std::vector<uint64_t> split_ratios;
    Toolchain toolchain;
    Boundary boundary;
    Memory memory;
    Exponential exponential;
    bool is_periodic;
    mp_prec_t prec;
    Format format;
    uint64_t fix_segments;
    bool random_coefficients;
    Minimize minimize;
    std::tuple<Strategy, Memory> min_luts_strategy, min_rams_strategy, min_balanced_strategy;
    std::vector<double> weights;
    bool inline_functions;
    bool no_range_reductions;
    std::string output_name;
    sollya_obj_t fS, precS, rangeS;
    std::string float_type, byte_type, int_type, sign_type, exponent_type, mantissa_type;
    Symmetry symmetry;
    Strategy best;
    std::map<Strategy, std::optional<std::vector<Approximation>>> approximations;
    std::map<std::tuple<Strategy, Memory>, std::optional<ResourceEstimation>> estimations;
    std::map<Strategy, std::vector<std::vector<std::vector<Approximation>>>> binades;
    std::map<Strategy, std::optional<Segmenting>> segmenting;
};
