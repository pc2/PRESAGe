# Copyright (C) 2025-2026 Gerrit Pape (gerrit.pape@uni-paderborn.de)
#
# This file is part of PRESAGe.
#
# PRESAGe is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# any later version.
#
# PRESAGe is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
# See the GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with PRESAGe. If not, see <https://www.gnu.org/licenses/>.
using CSV
using JSON
using DataFrames
using Quadmath
using Printf

include("../ieee754.jl")

function calculate_deviations(toolchain, operation, name, output_folder, precision, ::Type{F}, ::Type{B}) where {F <: AbstractFloat, B <: Unsigned}
    if sizeof(B) != sizeof(F)
        throw(AssertionError("B and F do no match in size"))
    end

    num_elements, BitDeviationType, FloatDeviationType = if sizeof(B) == 2
        65536, Int32, Float32
    elseif sizeof(B) == 4
        134217728, Int64, Float64
    elseif sizeof(B) == 8
        8589934592, Int128, Float128
    else
        throw(AssertionError("unsupported type size"))
    end

    name_precision = join([name, precision], "_")
    operation_precision = join([operation, precision], "_")
    golden_path = "./build_golden/" * operation_precision * ".bin"

    println("checking ", golden_path)

    golden_filesize = filesize(golden_path)

    if golden_filesize != (num_elements * sizeof(F))
        println("golden filesize does not match, skipping")
        return
    end

    output_path = if toolchain == "Vitis"
        output_folder * "/" * name_precision * ".bin"
    else
        output_folder * "/" * operation_precision * ".bin"
    end

    println("against ", output_path)

    output_filesize = filesize(output_path)

    if output_filesize != (num_elements * sizeof(F))
        println("output filesize does not match, skipping")
        return
    end

    bit_deviations_path = "./build_bit_deviations/" * toolchain * "/" * name_precision * ".bin"
    float_deviations_path = "./build_float_deviations/" * toolchain * "/" * name_precision * ".bin"

    num_chunks = 2^(w(F) + 1)

    chunk_size = div(num_elements, num_chunks)

    golden_file = open(golden_path, "r")
    golden_buffer = Vector{F}(undef, chunk_size)

    output_file = open(output_path, "r")
    output_buffer = Vector{F}(undef, chunk_size)

    bit_deviations_file = open(bit_deviations_path, "w")
    bit_deviations_buffer = Vector{BitDeviationType}(undef, chunk_size)

    float_deviations_file = open(float_deviations_path, "w")
    float_deviations_buffer = Vector{FloatDeviationType}(undef, chunk_size)

    for chunk in 1:num_chunks
        read!(golden_file, golden_buffer)
        read!(output_file, output_buffer)

        Threads.@threads for i in 1:chunk_size
            bit_deviations_buffer[i] = Int128(consecutive_map(reinterpret(B, output_buffer[i]))) - Int128(consecutive_map(reinterpret(B, golden_buffer[i])))
            float_deviations_buffer[i] = FloatDeviationType(output_buffer[i]) - FloatDeviationType(golden_buffer[i])
        end

        write(bit_deviations_file, bit_deviations_buffer)
        write(float_deviations_file, float_deviations_buffer)
    end

    close(golden_file)
    close(output_file)
    close(bit_deviations_file)
    close(float_deviations_file)
end

if length(ARGS) != 2 && length(ARGS) != 3 && length(ARGS) != 4
    println("Pass toolchain operation [approximation] [inst] as argument")
    exit(1)
end

toolchain = ARGS[1]
operation = ARGS[2]
if length(ARGS) >= 3
    approximation = ARGS[3]
else
    approximation = operation
end

if length(ARGS) == 4
    inst = ARGS[4]
end

bit_deviations_path = "./build_bit_deviations/" * toolchain

if !ispath(bit_deviations_path)
    mkpath(bit_deviations_path)
end

float_deviations_path = "./build_float_deviations/" * toolchain

if !ispath(float_deviations_path)
    mkpath(float_deviations_path)
end

config_str = read("config.json", String)
config = JSON.parse(config_str)

precisions = [("half", Float16, UInt16), ("single", Float32, UInt32), ("double", Float64, UInt64)]

group_name = ""
used_precisions = precisions[1:end]

if toolchain == "Vitis"
    if length(ARGS) == 2
        group_name = config["groups"][findfirst(g -> haskey(g, "operations") && (operation in g["operations"]), config["groups"])]["name"]
        used_precisions = precisions[1:end]
        output_folder = "./Vitis/build_" * group_name
    else
        println("going here: $(inst)")
        for group in config["groups"]
            if haskey(group, "approximations")
                for approximation_element in group["approximations"]
                    if approximation_element["name"] == approximation && haskey(approximation_element, "precision")
                        global group_name
                        group_name = group["name"]
                        if approximation_element["precision"] == "float"
                            global used_precisions
                            used_precisions = precisions[2:2]
                        elseif approximation_element["precision"] == "double"
                            global used_precisions
                            used_precisions == precisions[3:3]
                        else
                            println("unsupported precision")
                            exit(1)
                        end
                    end
                end
            end
        end
        global group_name
        output_folder = "./Vitis/build_$(group_name)_$(inst)"
    end
elseif toolchain == "oneAPI"
    if length(ARGS) == 2
        output_folder = "./oneAPI/build_" * operation
    else
        output_folder = "./oneAPI/build_" * approximation
        if length(ARGS) == 4
            output_folder *= "_$(inst)"
        end
    end
    if operation in config["unsupported_by_ap_float"]
        println("skpping half calculation for ", operation)
        used_precisions = precisions[2:end]
    end
end

for precision in used_precisions
    println("calculating deviations for ", join([toolchain, operation, precision[1]], "_"))
    flush(stdout)

    calculate_deviations(toolchain, operation, approximation, output_folder, precision[1], precision[2], precision[3])
end
