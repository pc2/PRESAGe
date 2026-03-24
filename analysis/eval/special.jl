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

function check_special_values(df, toolchain, group, operation, precision, ::Type{F}, ::Type{B}) where {F <: AbstractFloat, B <: Unsigned}
    if sizeof(B) != sizeof(F)
        throw(AssertionError("B and F do no match in size"))
    end

    GoldenType, num_elements = if sizeof(B) == 2
        (Float32, 65536)
    elseif sizeof(B) == 4
        (Float64, 134217728)
    elseif sizeof(B) == 8
        (Float128, 8589934592)
    else
        throw(AssertionError("unsupported type size"))
    end

    operation_precision = join([operation, precision], "_")
    golden_path = "./build_golden/" * operation_precision * ".bin"

    println("checking ", golden_path)

    golden_filesize = filesize(golden_path)

    if golden_filesize != (num_elements * sizeof(GoldenType))
        println("golden filesize does not match, skipping")
        return
    end

    input_path = "./build_input/in_" * precision * ".bin"

    input_filesize = filesize(input_path)

    if input_filesize != (num_elements * sizeof(F))
        println("input filesize does not match, skipping")
        return
    end

    output_path = if toolchain == "Vitis"
        "./Vitis/build_" * group * "/" * operation_precision * ".bin"
    elseif toolchain == "oneAPI"
        "./oneAPI/build_" * operation * "/" * operation_precision * ".bin"
    else
        throw(AssertionError("unsupported toolchain"))
    end

    output_filesize = filesize(output_path)

    if output_filesize != (num_elements * sizeof(F))
        println("output filesize does not match, skipping")
        return
    end
    
    num_chunks = 2^(w(F) + 1)

    chunk_size = div(num_elements, num_chunks)

    golden_file = open(golden_path, "r")
    golden_buffer = Vector{GoldenType}(undef, chunk_size)

    input_file = open(input_path, "r")
    input_buffer = Vector{F}(undef, chunk_size)

    output_file = open(output_path, "r")
    output_buffer = Vector{F}(undef, chunk_size)

    nan_deviations_total = 0
    nan_errors_total = 0

    first_zero_pos_total = F(Inf)
    first_zero_neg_total = F(-Inf)

    first_inf_pos_total = F(Inf)
    first_inf_neg_total = F(-Inf)

    for chunk in 1:num_chunks
        read!(golden_file, golden_buffer)
        read!(input_file, input_buffer)
        read!(output_file, output_buffer)

        nan_deviations = fill(0::Int64, Threads.nthreads())
        nan_errors = fill(0::Int64, Threads.nthreads())

        first_zero_pos = fill(F(Inf), Threads.nthreads())
        first_zero_neg = fill(F(-Inf), Threads.nthreads())

        first_inf_pos = fill(F(Inf), Threads.nthreads())
        first_inf_neg = fill(F(-Inf), Threads.nthreads())

        Threads.@threads for i in 1:chunk_size
            tid = Threads.threadid()
            if (isnan(output_buffer[i]) && !isnan(golden_buffer[i])) ||
                (!isnan(output_buffer[i]) && isnan(golden_buffer[i]))
                nan_deviations[tid] += 1
            end

            if isnan(input_buffer[i]) && !isnan(output_buffer[i])
                nan_errors[tid] += 1
            end

            if output_buffer[i] == 0.0 && input_buffer[i] < 0
                if abs(input_buffer[i]) < abs(first_zero_neg[tid])
                    first_zero_neg[tid] = input_buffer[i]
                end
            end

            if output_buffer[i] == 0.0 && input_buffer[i] > 0
                if abs(input_buffer[i]) < abs(first_zero_pos[tid])
                    first_zero_pos[tid] = input_buffer[i]
                end
            end

            if ((output_buffer[i] == Inf) || output_buffer[i] == -Inf) && (input_buffer[i] < 0)
                if abs(input_buffer[i]) < abs(first_inf_neg[tid])
                    first_inf_neg[tid] = input_buffer[i]
                end
            end

            if ((output_buffer[i] == Inf) || output_buffer[i] == -Inf) && (input_buffer[i] > 0)
                if abs(input_buffer[i]) < abs(first_inf_pos[tid])
                    first_inf_pos[tid] = input_buffer[i]
                end
            end
                
        end

        nan_deviations_total += sum(nan_deviations)
        nan_errors_total += sum(nan_errors)

        first_zero_pos_total = min(first_zero_pos_total, minimum(first_zero_pos))
        first_zero_neg_total = max(first_zero_neg_total, maximum(first_zero_neg))

        first_inf_pos_total = min(first_inf_pos_total, minimum(first_inf_pos))
        first_inf_neg_total = max(first_inf_neg_total, maximum(first_inf_neg))

    end

    push!(df, (
        Toolchain = toolchain,
        Operation = operation,
        Precision = precision,
        NaNErrors = nan_errors_total,
        NaNDeviations = nan_deviations_total,
        FirstZeroPos = first_zero_pos_total,
        FirstZeroNeg = first_zero_neg_total,
        FirstInfPos = first_inf_pos_total,
        FirstInfNeg = first_inf_neg_total,
    ))

    close(golden_file)
    close(input_file)
    close(output_file)
end

dir_path = "./build_special_values/"

if !ispath(dir_path)
    mkpath(dir_path)
end

config_str = read("config.json", String)
config = JSON.parse(config_str)

precisions = [("half", Float16, UInt16), ("single", Float32, UInt32), ("double", Float64, UInt64)]

df = DataFrame(
    Toolchain = String[],
    Operation = String[],
    Precision = String[],
    NaNErrors = UInt64[],
    NaNDeviations = UInt64[],
    FirstZeroPos = Float64[],
    FirstZeroNeg = Float64[],
    FirstInfPos = Float64[],
    FirstInfNeg = Float64[],
)

for toolchain in ["Vitis", "oneAPI"]
    for group in config["groups"]
        if group["type"] == "binary"
            continue
        end
        for operation in group["operations"]
            used_precisions = precisions[1:end]
            if operation in config["unsupported_by_ap_float"]
                println("skpping half calculation for ", operation)
                used_precisions = precisions[2:end]
            end
            for precision in used_precisions
                println("checking special values for ", join([toolchain, operation, precision[1]], "_"))
                flush(stdout)

                check_special_values(df, toolchain, group["name"], operation, precision[1], precision[2], precision[3])
                display(df)
            end
        end
    end
end

CSV.write(dir_path * "/all.csv", df)
