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

#include <vector>
#include <sycl/sycl.hpp>
#include <sycl/ext/intel/fpga_extensions.hpp>
#ifndef DISABLE_HALF
#include <sycl/ext/intel/ac_types/ap_float.hpp>
#include <sycl/ext/intel/ac_types/ap_float_math.hpp>

namespace ihc
{
    static inline ihc::ap_float<5, 10> ihc_identity(ihc::ap_float<5, 10> in)
    {
        return in;
    }

    static inline ihc::ap_float<5, 10> ihc_recip(ihc::ap_float<5, 10> in)
    {
        return sycl::native::recip(in);
    }
}
#endif

#include "Erf.hpp"

namespace sycl
{
    static inline float identity(float in)
    {
        return in;
    }

    static inline double identity(double in)
    {
        return in;
    }
    
    static inline float recip(float in)
    {
        return sycl::native::recip(in);
    }

    static inline double recip(double in)
    {
        return sycl::native::recip(in);
    }
}

template <typename T>
class ReadKernel {};

template <typename T>
class OperationKernel {};

template <typename T>
class WriteKernel {};

template <typename T>
class Unitary {
public:
    Unitary() = default;
    
    void run(sycl::queue &q, uint64_t num, sycl::buffer<T, 1> &input, sycl::buffer<T, 1> &output);

    std::string get_name();

private:
    using ReadPipe = sycl::ext::intel::pipe<class ReadPipeClass, T, 16384 / sizeof(T)>;
    using WritePipe = sycl::ext::intel::pipe<class WritePipeClass, T, 16384 / sizeof(T)>;
};
