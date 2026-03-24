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
#include <hls_stream.h>
#include <hls_math.h>
#include <ap_int.h>
#include <stdint.h>

template <typename T>
static inline void read(uint32_t num, T *a, hls::stream<T> &a_stream, T *b, hls::stream<T> &b_stream)
{
    for (uint32_t i = 0; i < num; i++) {
        a_stream.write(a[i]);
        b_stream.write(b[i]);
    }
}

template <typename T>
static inline void write(uint32_t num, T *c, hls::stream<T> &c_stream)
{
    for (uint32_t i = 0; i < num; i++) {
        c[i] = c_stream.read();
    }
}

template <typename T>
static inline void operation(uint32_t num, hls::stream<T> &a, hls::stream<T> &b, hls::stream<T> &c, T (*func)(T, T))
{
    for (uint32_t i = 0; i < num; i++) {
        c.write(func(a.read(), b.read()));
    }
}

namespace hls {

template <int W>
static inline ap_uint<W> select(ap_uint<W> a, ap_uint<W> b)
{
    return a;
}

static inline double select(double a, double b)
{
    return a;
}

static inline float selectf(float a, float b)
{
    return a;
}

static inline half half_select(half a, half b)
{
    return a;
}

template <int W>
static inline ap_uint<W> addition(ap_uint<W> a, ap_uint<W> b)
{
    return a + b;
}

static inline double addition(double a, double b)
{
    return a + b;
}

static inline float additionf(float a, float b)
{
    return a + b;
}

static inline half half_addition(half a, half b)
{
    return a + b;
}

template <int W>
static inline ap_uint<W> subtraction(ap_uint<W> a, ap_uint<W> b)
{
    return a - b;
}

static inline double subtraction(double a, double b)
{
    return a - b;
}

static inline float subtractionf(float a, float b)
{
    return a - b;
}

static inline half half_subtraction(half a, half b)
{
    return a - b;
}

template <int W>
static inline ap_uint<W> multiplication(ap_uint<W> a, ap_uint<W> b)
{
    return a * b;
}

static inline double multiplication(double a, double b)
{
    return a * b;
}

static inline float multiplicationf(float a, float b)
{
    return a * b;
}

static inline half half_multiplication(half a, half b)
{
    return a * b;
}

template <int W>
static inline ap_uint<W> division(ap_uint<W> a, ap_uint<W> b)
{
    return a / b;
}

static inline double division(double a, double b)
{
    return a / b;
}

static inline float divisionf(float a, float b)
{
    return a / b;
}

static inline half half_division(half a, half b)
{
    return a / b;
}
}

template <typename T>
static inline void stream_operation(uint32_t num, T *a, T *b, T *c, T (*func)(T, T))
{
#pragma HLS dataflow
    hls::stream<T, 16384 / sizeof(T)> a_stream, b_stream, c_stream;
    read<T>(num, a, a_stream, b, b_stream);
    operation<T>(num, a_stream, b_stream, c_stream, func);
    write<T>(num, c, c_stream);
}


