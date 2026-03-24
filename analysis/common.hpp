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
#include <string>
#include <sstream>
#include <fstream>
#include <bitset>
#include <omp.h>

inline double get_wtime()
{
    struct timespec time;
    clock_gettime(CLOCK_REALTIME, &time);                                                                            
    return time.tv_sec + (double)time.tv_nsec / 1e9;
}

template <typename T>
class Dataset
{
public:
    Dataset()
    {
        if constexpr (std::is_same<T, uint16_t>::value) {
            type_name = "half";
        } else if constexpr (std::is_same<T, uint32_t>::value) {
            type_name = "single";
        } else if constexpr (std::is_same<T, uint64_t>::value) {
            type_name = "double";
        } else {
            type_name = "unsupported";
            return;
        }
        uint64_t SIGN_EXP_SIZE;
        if constexpr (std::is_same<T, uint16_t>::value) {
            count = (1ULL << (sizeof(T) * 8));
            input = std::vector<T>(count); 
            for (uint64_t i = 0; i < count; i++) {
                input[i] = (T)i;
            }
            SIGN_EXP_SIZE = (1ULL << 6);
        } else {
            const uint64_t MSB_MANTISSA_SHIFT = 13;
            const uint64_t MSB_MANTISSA_SIZE = (1ULL << 10);
            const uint64_t MID_MANTISSA_SHIFT = 3;
            const uint64_t MID_MANTISSA_SIZE = (1ULL << 10);
            const uint64_t LSB_MANTISSA_SIZE = (1ULL << 3);
            std::vector<uint64_t> single_mantissas;
            for (uint64_t msb_mantissa = 0; msb_mantissa < MSB_MANTISSA_SIZE; msb_mantissa++) {
                for (uint64_t mid_mantissa = 0; mid_mantissa < MID_MANTISSA_SIZE; mid_mantissa += (1 + (1ULL << 5))) {
                    for (uint64_t lsb_mantissa = 0; lsb_mantissa < LSB_MANTISSA_SIZE; lsb_mantissa++) {
                        uint64_t bits = (msb_mantissa << MSB_MANTISSA_SHIFT)
                            | (mid_mantissa << MID_MANTISSA_SHIFT)
                            | (lsb_mantissa);
                        single_mantissas.push_back((T)bits);
                    }
                }
            }
            if constexpr (std::is_same<T, uint32_t>::value) {
                count = (1ULL << 27);
                input = std::vector<T>(count);
                const uint64_t SIGN_EXP_SHIFT = 23;
                SIGN_EXP_SIZE = (1ULL << 9);
                uint32_t i = 0;
                for (uint64_t sign_exp = 0; sign_exp < SIGN_EXP_SIZE; sign_exp++) {
                    for (uint64_t mantissa: single_mantissas) {
                        uint64_t bits = (sign_exp << SIGN_EXP_SHIFT) | mantissa;
                        input[i++] = (T)bits;
                    }
                }
            } else if constexpr (std::is_same<T, uint64_t>::value) {
                count = (1ULL << 33);
                input = std::vector<T>(count);
                const uint64_t SIGN_EXP_SHIFT = 52;
                SIGN_EXP_SIZE = (1ULL << 12);
                const uint64_t SINGLE_MANTISSA_SHIFT = 29;
                std::vector<uint64_t> fills = {0, 0x1ffffffc};
                const uint64_t LAST_BITS_SIZE = 0b100;
                const uint64_t SINGLE_MANTISSA_OFFSET = LAST_BITS_SIZE * fills.size();
                const uint64_t SIGN_EXP_OFFSET = LAST_BITS_SIZE * fills.size() * single_mantissas.size();
#pragma omp parallel for
                for (uint64_t sign_exp = 0; sign_exp < SIGN_EXP_SIZE; sign_exp++)
                {
                    for (uint64_t single_mantissa_i = 0; single_mantissa_i < single_mantissas.size(); single_mantissa_i++)
                    {
                        const uint64_t single_mantissa = single_mantissas[single_mantissa_i];
                        for (uint64_t fill_i = 0; fill_i < fills.size(); fill_i++)
                        {
                            const uint64_t fill = fills[fill_i];
                            for (uint64_t last_bits = 0; last_bits < LAST_BITS_SIZE; last_bits++)
                            {
                                uint64_t bits = (sign_exp << SIGN_EXP_SHIFT)
                                    | (single_mantissa << SINGLE_MANTISSA_SHIFT)
                                    | fill | last_bits;

                                uint64_t bits_i = last_bits
                                    + fill_i * LAST_BITS_SIZE
                                    + single_mantissa_i * SINGLE_MANTISSA_OFFSET
                                    + sign_exp * SIGN_EXP_OFFSET;

                                input[bits_i] = bits;
                            }
                        }
                    }
                }
            }
        }
        output = std::vector<T>(count);
        chunk_size = count / SIGN_EXP_SIZE;
    } 

    std::vector<T*> get_output_chunks()
    {
        output = std::vector<T>(count);
        std::vector<T*> chunks;
        for (uint64_t i = 0; i < count; i += chunk_size) {
            chunks.push_back(output.data() + i);
        }
        return chunks;
    }

    std::vector<T*> get_input_chunks()
    {
        std::vector<T*> chunks;
        for (uint64_t i = 0; i < count; i += chunk_size) {
            chunks.push_back(input.data() + i);
        }
        return chunks;
    }

    void write(std::string name, uint64_t num, T *data)
    {
        std::stringstream out_name;  
        out_name << name << "_" << type_name << ".bin";
        std::ofstream out(out_name.str(), std::ios::binary);
        for (uint64_t i = 0; i < num; i++) {
            out.write(reinterpret_cast<const char*>(&data[i]), sizeof(data[i])); 
        }
    }

    void write_input()
    {
        write("in", input.size(), input.data());
    }

    void write_output(std::string name)
    {
        write(name, output.size(), output.data());
    }
 
    std::string type_name;
    uint64_t chunk_size;
    uint64_t count;
    std::vector<T> input;
    std::vector<T> output;
};
