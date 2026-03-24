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

#include <type_traits>
#include <vector>
#include <sycl/sycl.hpp>
#include <sycl/ext/intel/fpga_extensions.hpp>
#include <sycl/ext/intel/ac_types/ap_float.hpp>
#include <sycl/ext/intel/ac_types/ap_float_math.hpp>

template <int W>
static inline ac_int<W, false> select(ac_int<W, false> a, ac_int<W, false> b)
{
    return a;
}

static inline ihc::ap_float<5, 10> select(ihc::ap_float<5, 10> a, ihc::ap_float<5, 10> b)
{
    return a;
}

static inline float select(float a, float b)
{
    return a;
}

static inline double select(double a, double b)
{
    return a;
}

template <int W>
static inline ac_int<W, false> addition(ac_int<W, false> a, ac_int<W, false> b)
{
    return a + b;
}

static inline ihc::ap_float<5, 10> addition(ihc::ap_float<5, 10> a, ihc::ap_float<5, 10> b)
{
    return a + b;
}

static inline float addition(float a, float b)
{
    return a + b;
}

static inline double addition(double a, double b)
{
    return a + b;
}

template <int W>
static inline ac_int<W, false> subtraction(ac_int<W, false> a, ac_int<W, false> b)
{
    return a - b;
}

static inline ihc::ap_float<5, 10> subtraction(ihc::ap_float<5, 10> a, ihc::ap_float<5, 10> b)
{
    return a - b;
}

static inline float subtraction(float a, float b)
{
    return a - b;
}

static inline double subtraction(double a, double b)
{
    return a - b;
}

template <int W>
static inline ac_int<W, false> multiplication(ac_int<W, false> a, ac_int<W, false> b)
{
    return a * b;
}

static inline ihc::ap_float<5, 10> multiplication(ihc::ap_float<5, 10> a, ihc::ap_float<5, 10> b)
{
    return a * b;
}

static inline float multiplication(float a, float b)
{
    return a * b;
}

static inline double multiplication(double a, double b)
{
    return a * b;
}

template <int W>
static inline ac_int<W, false> division(ac_int<W, false> a, ac_int<W, false> b)
{
    if constexpr (W <= 32) {
        return a.to_uint() / b.to_uint();
    } else {
        return a.to_uint64() / b.to_uint64();
    }
}

static inline ihc::ap_float<5, 10> division(ihc::ap_float<5, 10> a, ihc::ap_float<5, 10> b)
{
    return a / b;
}

static inline float division(float a, float b)
{
    return a / b;
}

static inline double division(double a, double b)
{
    return a / b;
}

template <int Bits, bool Float>
class ReadKernel {};

template <bool Float>
class ReadAPipeClass {};

template <bool Float>
class ReadBPipeClass {};

template <int Bits, bool Float, int Id>
class OperationKernel {};

template <int Bits, bool Float>
class WriteKernel {};

template <bool Float>
class WritePipeClass {};

template <int Bits, bool Float, int Id>
class Binary {
public:
    Binary() = default;

    using PipeType = ac_int<Bits, false>;
    
    void run(sycl::queue &q, uint64_t num, sycl::buffer<PipeType, 1> &a, sycl::buffer<PipeType, 1> &b, sycl::buffer<PipeType, 1> &c);

    std::string get_name();

    using ReadAPipe = sycl::ext::intel::pipe<class ReadAPipeClass<Float>, PipeType, 16384 / sizeof(PipeType)>;
    using ReadBPipe = sycl::ext::intel::pipe<class ReadBPipeClass<Float>, PipeType, 16384 / sizeof(PipeType)>;
    using WritePipe = sycl::ext::intel::pipe<class WritePipeClass<Float>, PipeType, 16384 / sizeof(PipeType)>;
};
