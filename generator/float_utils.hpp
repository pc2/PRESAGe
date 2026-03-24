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

#include <mpfr.h>
#include <cstdint>
#include <cmath>

// Check if x is exactly a power of two (e.g. 0.5, 1.0, 2.0, ...)
bool is_power_of_two(mpfr_t x)
{
    int sign = mpfr_sgn(x);
    if (sign == 0) return false;

    mpfr_exp_t exp = mpfr_get_exp(x);

    return mpfr_cmp_si_2exp(x, sign > 0 ? 1 : -1, exp -1) == 0;
}

// Check if [a, b] spans at most one binade (same sign and exponent).
// Powers of two are boundaries between binades, so [0.5, 1.0] counts as one binade.
bool in_one_binade(mpfr_t a, mpfr_t b)
{
    mpfr_exp_t exp_a = mpfr_get_exp(a);
    mpfr_exp_t exp_b = mpfr_get_exp(b);

    mpfr_exp_t sign_a = mpfr_sgn(a);
    mpfr_exp_t sign_b = mpfr_sgn(b);

    bool a_is_power_of_two = is_power_of_two(a);
    bool b_is_power_of_two = is_power_of_two(b);

    bool is_in_one_binade = false;
    if (sign_a == sign_b) {
        if (exp_a == exp_b) {
            is_in_one_binade = true;
        } else if (a_is_power_of_two || b_is_power_of_two) {
            if (std::abs((exp_a) - (exp_b)) == 1) {
                is_in_one_binade = true;
            }
        }
    }
    return is_in_one_binade;
}

const uint32_t SINGLE_EXPONENT_BITS = 8;
const uint32_t SINGLE_MANTISSA_BITS = 23;
const uint32_t SINGLE_EXPONENT_MASK = ((uint32_t)1 << SINGLE_EXPONENT_BITS) - 1;
const uint32_t SINGLE_MANTISSA_MASK = ((uint32_t)1 << SINGLE_MANTISSA_BITS) - 1;

const uint64_t DOUBLE_EXPONENT_BITS = 11;
const uint64_t DOUBLE_MANTISSA_BITS = 52;
const uint64_t DOUBLE_EXPONENT_MASK = ((uint64_t)1 << DOUBLE_EXPONENT_BITS) - 1;
const uint64_t DOUBLE_MANTISSA_MASK = ((uint64_t)1 << DOUBLE_MANTISSA_BITS) - 1;

static inline uint32_t get_single_mantissa(float x)
{
    const uint32_t *bits = reinterpret_cast<const uint32_t*>(&x);
    return (*bits & SINGLE_MANTISSA_MASK);
}

static inline uint32_t get_single_exponent(float x)
{
    const uint32_t *bits = reinterpret_cast<const uint32_t*>(&x);
    return (*bits >> SINGLE_MANTISSA_BITS) & SINGLE_EXPONENT_MASK;
}

static inline uint32_t get_single_sign(float x)
{
    const uint32_t *bits = reinterpret_cast<const uint32_t*>(&x);
    return (*bits >> (SINGLE_EXPONENT_BITS + SINGLE_MANTISSA_BITS));
}

static inline uint64_t get_double_mantissa(double x)
{
    const uint64_t *bits = reinterpret_cast<const uint64_t*>(&x);
    return (*bits & DOUBLE_MANTISSA_MASK);
}

static inline uint64_t get_double_exponent(double x)
{
    const uint64_t *bits = reinterpret_cast<const uint64_t*>(&x);
    return (*bits >> DOUBLE_MANTISSA_BITS) & DOUBLE_EXPONENT_MASK;
}

static inline uint64_t get_double_sign(double x)
{
    const uint64_t *bits = reinterpret_cast<const uint64_t*>(&x);
    return (*bits >> (DOUBLE_EXPONENT_BITS + DOUBLE_MANTISSA_BITS));
}
