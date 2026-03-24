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

const DeviationType = (:bit, :absolute, :relative)

struct Maximum{F, D}
    input::F
    output::F
    golden::F
    value::D
    type::Symbol
end

Maximum{F, D}(type::Symbol) where {F <: AbstractFloat, D <: AbstractFloat} = Maximum{F, D}(0.0, 0.0, 0.0, 0.0, type)
Maximum{F, D}(type::Symbol) where {F <: AbstractFloat, D <: Signed} = Maximum{F, D}(0.0, 0.0, 0.0, 0, type)

UIntOf(T) = "UInt$(8 * sizeof(T))" |> Symbol |> eval

function hex_string(x)
    bitT = UIntOf(typeof(x))
    bits = reinterpret(bitT, x)
    string(bits, base=16, pad=sizeof(bitT)*2)
end

function format_and_push(df, toolchain, operation, precision, chunk, num_chunks, max, ::Type{F}) where {F <: AbstractFloat}
    bitmask = (1 << t(F)) - 1
    push!(df, (
        Toolchain = toolchain,
        Operation = operation,
        Precision = precision,
        Sign = chunk > div(num_chunks, 2),
        Exponent = (chunk > div(num_chunks, 2) ? chunk - div(num_chunks, 2) : chunk) - 1 - bias(F),
        Input = string(max.input),
        Output = string(max.output),
        Golden = string(max.golden),
        Value = string(max.value),
        DType = string(max.type),
        InputHex = hex_string(max.input),
        OutputHex = hex_string(max.output),
        GoldenHex = hex_string(max.golden),
        ValueHex = hex_string(max.value),
    ))
end

function calculate_maximum(df, toolchain, group, operation, approximation, precision, ::Type{F}, ::Type{B}) where {F <: AbstractFloat, B <: Unsigned}
    if sizeof(B) != sizeof(F)
        throw(AssertionError("B and F do no match in size"))
    end

    BitDeviationType, FloatDeviationType, num_elements = if sizeof(B) == 2
        (Int32, Float32, 65536)
    elseif sizeof(B) == 4
        (Int64, Float64, 134217728)
    elseif sizeof(B) == 8
        (Int128, Float128, 8589934592)
    else
        throw(AssertionError("unsupported type size"))
    end

    operation_precision = join([operation, precision], "_")
    approximation_precision = join([approximation, precision], "_")
    golden_path = "./build_golden/" * operation_precision * ".bin"

    println("checking ", golden_path)

    golden_filesize = filesize(golden_path)

    if golden_filesize != (num_elements * sizeof(F))
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
        "./Vitis/build_" * group * "/" * approximation_precision * ".bin"
    elseif toolchain == "oneAPI"
        "./oneAPI/build_" * group * "/" * operation_precision * ".bin"
    else
        throw(AssertionError("unsupported toolchain"))
    end

    println("against ", output_path)

    output_filesize = filesize(output_path)

    if output_filesize != (num_elements * sizeof(F))
        println("output filesize does not match, skipping")
        println(output_path)
        return
    end

    bit_deviations_path = "./build_bit_deviations/" * toolchain * "/" * approximation_precision * ".bin"

    bit_deviations_filesize = filesize(bit_deviations_path)
    if bit_deviations_filesize != (num_elements * sizeof(BitDeviationType))
        println("bit_deviations filesize does not match, skipping")
        return
    end
    
    float_deviations_path = "./build_float_deviations/" * toolchain * "/" * approximation_precision * ".bin"

    float_deviations_filesize = filesize(float_deviations_path)
    if float_deviations_filesize != (num_elements * sizeof(FloatDeviationType))
        println("float_deviations filesize does not match, skipping")
        return
    end
    
    num_chunks = 2^(w(F) + 1)

    chunk_size = div(num_elements, num_chunks)

    golden_file = open(golden_path, "r")
    golden_buffer = Vector{F}(undef, chunk_size)

    input_file = open(input_path, "r")
    input_buffer = Vector{F}(undef, chunk_size)

    output_file = open(output_path, "r")
    output_buffer = Vector{F}(undef, chunk_size)

    bit_deviations_file = open(bit_deviations_path, "r")
    bit_deviations_buffer = Vector{BitDeviationType}(undef, chunk_size)

    float_deviations_file = open(float_deviations_path, "r")
    float_deviations_buffer = Vector{FloatDeviationType}(undef, chunk_size)

    for chunk in 1:num_chunks
        read!(golden_file, golden_buffer)
        read!(input_file, input_buffer)
        read!(output_file, output_buffer)
        read!(bit_deviations_file, bit_deviations_buffer)
        read!(float_deviations_file, float_deviations_buffer)

        partial_max_bit = fill(Maximum{F, BitDeviationType}(:bit), Threads.maxthreadid())
        partial_max_absolute = fill(Maximum{F, FloatDeviationType}(:absolute), Threads.maxthreadid())
        partial_max_relative = fill(Maximum{F, FloatDeviationType}(:relative), Threads.maxthreadid())
        Threads.@threads :static for i in 1:chunk_size
            if !isnan(golden_buffer[i]) && !isnan(output_buffer[i])
                tid = Threads.threadid()

                bit_deviation_absolute = abs(bit_deviations_buffer[i])
                float_deviation_absolute = abs(float_deviations_buffer[i])
                float_deviation_relative = float_deviation_absolute / abs(golden_buffer[i])

                if bit_deviation_absolute > partial_max_bit[tid].value
                    partial_max_bit[tid] = Maximum{F, BitDeviationType}(input_buffer[i], output_buffer[i], golden_buffer[i], bit_deviation_absolute, :bit)
                end

                if float_deviation_absolute > partial_max_absolute[tid].value
                    partial_max_absolute[tid] = Maximum{F, FloatDeviationType}(input_buffer[i], output_buffer[i], golden_buffer[i], float_deviation_absolute, :absolute)
                end

                if float_deviation_relative > partial_max_relative[tid].value
                    partial_max_relative[tid] = Maximum{F, FloatDeviationType}(input_buffer[i], output_buffer[i], golden_buffer[i], float_deviation_relative, :relative)
                end
            end
        end

        chunk_max_bit = argmax(m -> m.value, partial_max_bit)
        chunk_max_absolute = argmax(m -> m.value, partial_max_absolute)
        chunk_max_relative = argmax(m -> m.value, partial_max_relative)

        format_and_push(df, toolchain, operation, precision, chunk, num_chunks, chunk_max_bit, F)
        format_and_push(df, toolchain, operation, precision, chunk, num_chunks, chunk_max_absolute, F)
        format_and_push(df, toolchain, operation, precision, chunk, num_chunks, chunk_max_relative, F)
    end

    close(golden_file)
    close(input_file)
    close(output_file)
    close(bit_deviations_file)
    close(float_deviations_file)
end

if length(ARGS) != 2 && length(ARGS) != 3
    println("Pass toolchain operation [approximation] as argument")
    exit(1)
end

toolchain = ARGS[1]
operation = ARGS[2]
approximation = length(ARGS) == 3 ? ARGS[3] : operation

dir_path = "./build_max_deviations/" * toolchain

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
    Sign = UInt8[],
    Exponent = Int64[],
    Input = String[],
    Output = String[],
    Golden = String[],
    Value = String[],
    DType = String[],
    InputHex = String[],
    OutputHex = String[],
    GoldenHex = String[],
    ValueHex = String[],
)

used_precisions = precisions[1:end]
if toolchain == "oneAPI" && ((operation in config["unsupported_by_ap_float"]) || length(ARGS) == 3)
    println("skpping half calculation for ", operation)
    used_precisions = precisions[2:end]
end

group = ""

if toolchain == "Vitis"
    if length(ARGS) == 2
        group = config["groups"][findfirst(g -> haskey(g, "operations") && operation in g["operations"],config["groups"])]["name"]
    else
        group = config["groups"][findfirst(g -> haskey(g, "approximations") && any(a -> a["name"] == approximation, g["approximations"]), config["groups"])]
        prec = group["approximations"][findfirst(a -> a["name"] == approximation, group["approximations"])]["precision"]
        if prec == "float"
            used_precisions = precisions[2:2]
        else
            used_precisions = precisions[3:3]
        end
        group = group["name"]
    end
else
    if length(ARGS) == 2
        group = operation    
    else
        group = approximation
    end
end


for precision in used_precisions
    println("calculating maxima for ", join([toolchain, operation, precision[1]], "_"))
    flush(stdout)
    
    if length(ARGS) == 2
        calculate_maximum(df, toolchain, group, operation, approximation, precision[1], precision[2], precision[3])
    else
        for i in 0:0
            calculate_maximum(df, toolchain, "$(group)_$(i)", operation, approximation, precision[1], precision[2], precision[3])
        end
    end
end

if length(ARGS) == 2
    CSV.write(dir_path * "/" * operation * ".csv", df)
else
    CSV.write(dir_path * "/$(approximation).csv", df)
end
display(df)
