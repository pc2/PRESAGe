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
#include <stdint.h>
#include <hls_math.h>
#include "Erf.hpp"

template <typename T>
static inline void read(uint32_t num, T *in, hls::stream<T> &in_stream)
{
read:
    for (uint32_t i = 0; i < num; i++) {
#pragma HLS pipeline II=1
        in_stream.write(in[i]);
    }
}

template <typename T>
static inline void write(uint32_t num, T *out, hls::stream<T> &out_stream)
{
write:
    for (uint32_t i = 0; i < num; i++) {
#pragma HLS pipeline II=1
        out[i] = out_stream.read();
    }
}

namespace hls {
static inline half half_identity(half in)
{
    return in;
}

static inline float identityf(float in)
{
    return in;
}

static inline double identity(double in)
{
    return in;
}

static inline half half_sun_erf(half in)
{
    return hls::sun_erf(in);
}

static inline float sun_erff(float in)
{
    return hls::sun_erf(in);
}
}

template <typename T>
static inline void operation(uint32_t num, hls::stream<T> &in, hls::stream<T> &out, T (*func)(T))
{
operation:
    for (uint32_t i = 0; i < num; i++) {
#pragma HLS pipeline II=1
        out.write(func(in.read()));
    }
}

template <typename T>
static inline void stream_operation(uint32_t num, T *in, T *out, T (*func)(T))
{
#pragma HLS dataflow
    hls::stream<T, 16384 / sizeof(T)> in_stream, out_stream;
    read<T>(num, in, in_stream);
    operation<T>(num, in_stream, out_stream, func);
    write<T>(num, out, out_stream);
}
