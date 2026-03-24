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
#include "version.h"
#include <fstream>
#include <unistd.h>
#include <vector>
#include <thread>
#include <iostream>
#include <filesystem>
#include <fstream>
#include <type_traits>

#include "Kernel.hpp"
#include "../../common.hpp"
#include "nlohmann/json.hpp"

using json = nlohmann::json;

template <typename T>
class Evaluator
{
public:
    Evaluator(Bitstream &bitstream, Dataset<T> &data, std::string &operation, std::string &precision) : bitstream(bitstream), data(data), operation(operation)
    {
        kernel = UnitaryKernel<T>(bitstream, operation, precision);
        kernel.prepare(data.chunk_size);
    }

    Evaluator(Bitstream &bitstream, Dataset<T> &data, std::string &operation) : bitstream(bitstream), data(data), operation(operation)
    {
        kernel = UnitaryKernel<T>(bitstream, operation);
        kernel.prepare(data.chunk_size);
    }

    void print_reinterpret(std::string message, T value)
    {
        std::cout << message;
        if constexpr (std::is_same<T, uint16_t>::value) {
            std::cout << reinterpret_cast<_Float16&>(value);
        } else if constexpr (std::is_same<T, uint32_t>::value) {
            std::cout << reinterpret_cast<float&>(value);
        } else if constexpr (std::is_same<T, uint64_t>::value) {
            std::cout << reinterpret_cast<double&>(value);
        }
        std::cout << std::endl;
    }

    void bisect_chunk(UnitaryKernel<T> &kernel, T* data, uint64_t chunk_size, double *timing)
    {
        if (chunk_size == 1) {
            return;
        }
        uint64_t new_chunk_size = chunk_size / 2; 
        std::cout << "new_chunk_size: " << new_chunk_size << std::endl;
        kernel.prepare(new_chunk_size);
        double start = get_wtime();
        kernel.run(data);
        if (kernel.timeout()) {
            std::cout << "timeout: bisecting" << std::endl;
            reset();
            bisect_chunk(kernel, data, new_chunk_size, timing);
        } else {
            *timing += get_wtime() - start;
            std::cout << "worked" << std::endl;
        }
        kernel.prepare(new_chunk_size);
        start = get_wtime();
        kernel.run(data + new_chunk_size);
        if (kernel.timeout()) {
            std::cout << "timeout: bisecting" << std::endl;
            reset();
            bisect_chunk(kernel, data, new_chunk_size, timing);
        } else {
            *timing += get_wtime() - start;
            std::cout << "worked" << std::endl;
        }
    }

    void write_timings(std::vector<double> timings)
    {
        std::stringstream out_name;  
        out_name << kernel.operation << "_timings.csv";
        std::ofstream out(out_name.str(), std::ios::out);
        out << "chunk,time" << std::endl;
        for (uint64_t i = 0; i < timings.size(); i++) {
            out << i << "," << timings[i] << std::endl;
        }
    }

    void reset()
    {
        bitstream.reset();
        kernel = UnitaryKernel<T>(bitstream, operation, data.type_name);
    }

    void run()
    {
        double start = get_wtime();

        std::vector<T*> input_chunks = data.get_input_chunks();
        std::vector<T*> output_chunks = data.get_output_chunks();

        std::vector<double> timings(input_chunks.size(), 0.0);

        for (uint64_t i = 0; i < input_chunks.size(); i++) {
            std::cout << "running chunk " << i;
            double chunk_start = get_wtime();
            try {
                kernel.run(input_chunks[i]);
                if (!kernel.timeout()) {
                    kernel.write_back(output_chunks[i]);
                    timings[i] = get_wtime() - chunk_start;
                    std::cout << ": " << timings[i] << " seconds" << std::endl;
                    double element_time = timings[i] / data.chunk_size;
                    double element_cycles = 300000000 * element_time;
                    std::cout << ": average cycles per element : " << (uint64_t) element_cycles << std::endl;
                } else {
                    std::cout << ": timeout: starting to bisect" << std::endl;
                    reset();
                    bisect_chunk(kernel, input_chunks[i], data.chunk_size, &timings[i]);
                    reset();
                    kernel.prepare(data.chunk_size);
                }
            } catch (const std::exception &e) {
                std::cout << ": caught " << e.what() << std::endl;
                kernel.prepare(data.chunk_size);
            }
        }

        std::cout << "total: " << get_wtime() - start << " seconds" << std::endl;
        write_timings(timings);
        data.write_output(operation);
    }


    Bitstream bitstream;
    Dataset<T> data;
    std::string operation;
    UnitaryKernel<T> kernel;
};

int main(int argc, char *argv[])
{
    if (argc != 2 && argc != 3) {
        std::cout << "pass group [approximation] as argument" << std::endl;
        exit(EXIT_FAILURE);
    }
    if (std::string(argv[1]) == "additive" || std::string(argv[1]) == "multiplicative") {
        std::cout << "skipping binary operations, not implemented" << std::endl;
        exit(EXIT_SUCCESS);
    }
    bool emulation = (std::getenv("XCL_EMULATION_MODE") != nullptr);

    std::ifstream config_file("../../config.json");
    json config = json::parse(config_file);

    std::cout << "generating input data" << std::endl;
    Dataset<uint16_t> half_data = Dataset<uint16_t>();
    Dataset<uint32_t> single_data = Dataset<uint32_t>();
    Dataset<uint64_t> double_data = Dataset<uint64_t>();

    if (std::string(argv[1]) == "input") {
        std::cout << "writing input data" << std::endl;
        half_data.write_input();
        single_data.write_input();
        double_data.write_input();
        exit(EXIT_SUCCESS);
    }

    for (auto &group: config["groups"]) {
        if (group["type"] == "binary") {
            continue;
        }
        std::string name = group["name"];
        if (name != argv[1]) {
            continue;
        }
        std::cout << "programming fpga" << std::endl;
        Bitstream bitstream(0, name, emulation);

        if (group.contains("operations")) {
            std::vector<std::string> operations = group["operations"];
            for (std::string &operation: operations) {
                std::cout <<  operation << std::endl;

                //iterating through the types would require template metaprogramming
                std::cout << half_data.type_name << std::endl;
                Evaluator<uint16_t> half_evaluator(bitstream, half_data, operation);
                half_evaluator.run();
                std::cout << single_data.type_name << std::endl;
                Evaluator<uint32_t> single_evaluator(bitstream, single_data, operation);
                single_evaluator.run();
                std::cout << double_data.type_name << std::endl;
                Evaluator<uint64_t> double_evaluator(bitstream, double_data, operation);
                double_evaluator.run();
            }
        } else if (group.contains("approximations")) {
            std::vector<json> approximations = group["approximations"];
            for (json &approximation: approximations) {
                std::string name = std::string(argv[2]);
                if (name == std::string(approximation["name"])) {
                    if (approximation["precision"] == "float") {
                        Evaluator<uint32_t> single_evaluator(bitstream, single_data, name);
                        single_evaluator.run();
                    } else if (approximation["precision"] == "double") {
                        Evaluator<uint64_t> double_evaluator(bitstream, double_data, name);
                        double_evaluator.run();
                    } else {
                        std::cout << "unsupported precision" << std::endl;
                    }
                }
            }
        }
    }
}

