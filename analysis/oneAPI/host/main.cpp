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
#include "unitary.hpp"
#include <vector>
#include <iostream>
#include <sycl/sycl.hpp>
#include <sycl/ext/intel/fpga_extensions.hpp>
#include "../../common.hpp"

template <typename T>
void run(sycl::queue &q)
{
    Dataset<T> data = Dataset<T>();
    Unitary<T> pipeline;

    std::vector<T*> input_chunks = data.get_input_chunks();
    std::vector<T*> output_chunks = data.get_output_chunks();

    for (uint64_t i = 0; i < input_chunks.size(); i++) {
        std::cout << "running chunk " << i;
        double chunk_start = get_wtime();
        sycl::buffer<T, 1> input_buffer(input_chunks[i], sycl::range<1>(data.chunk_size));
        sycl::buffer<T, 1> output_buffer(output_chunks[i], sycl::range<1>(data.chunk_size));

        pipeline.run(q, data.chunk_size, input_buffer, output_buffer);

        std::cout << ": " << get_wtime() - chunk_start << " seconds" << std::endl;
    }

    std::cout << "writing output" << std::endl;

    data.write_output(pipeline.get_name());
}

int main(int argc, char **argv) {
    try {
#ifdef EMULATION
        sycl::queue q(sycl::ext::intel::fpga_emulator_selector_v);
#else
        sycl::queue q(sycl::ext::intel::fpga_selector_v);

#ifndef DISABLE_HALF
        std::cout << "calculating halfs" << std::endl;
        double half_start = get_wtime();
        run<uint16_t>(q);
        std::cout << "took: " << get_wtime() - half_start << " seconds" << std::endl;
#endif
#endif
        std::cout << "calculating floats" << std::endl;
        double single_start = get_wtime();
        run<uint32_t>(q);
        std::cout << "took: " << get_wtime() - single_start << " seconds" << std::endl;

        if (argc == 1) {
            std::cout << "calculating doubles" << std::endl;
            double double_start = get_wtime();
            run<uint64_t>(q);
            std::cout << "took: " << get_wtime() - double_start << " seconds" << std::endl;
        }

    } catch (std::exception &e) {
        std::cerr << "Caught SYCL exception: " << e.what() << std::endl;
        return 1;
    }

    return 0;
}
