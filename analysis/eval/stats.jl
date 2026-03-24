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
using DataFrames
using CSV
using Quadmath

include("../ieee754.jl")

function stats(df, path, num_elements, num_chunks, chunk_size, ::Type{F}, ::Type{B}) where {F <: AbstractFloat, B <: Unsigned}
    total_bits = k(F)
    num_mantissa_bits = t(F)
    mantissa_mask = B((B(1) << num_mantissa_bits) - 1)
    sign_exp_mask = ~mantissa_mask
    sign_mask = B(1) << (total_bits - 1)
    exp_mask = xor(sign_exp_mask, sign_mask)

    float_buffer = Vector{F}(undef, chunk_size)
    input_file = open(path, "r")
    for c in 1:num_chunks
        read!(input_file, float_buffer)
        byte_buffer = reinterpret(B, float_buffer)
        signs = [(elem & sign_mask) >> (total_bits - 1) for elem in byte_buffer]
        exponents = [((elem & exp_mask) >> num_mantissa_bits) for elem in byte_buffer]
        mantissas = [(elem & mantissa_mask) for elem in byte_buffer]
        push!(df, (
            Chunk = c,
            SignAvg = sum(signs) / length(signs),
            ExpMin = Int(minimum(exponents)) - bias(F),
            ExpAvg = Int(div(sum(exponents), length(exponents))) - bias(F),
            ExpMax = Int(maximum(exponents)) - bias(F),
            ManMin = string(minimum(mantissas), base = 16),
            ManAvg = string(div(sum(mantissas), length(mantissas)), base = 16),
            ManMax = string(maximum(mantissas), base = 16),
            ValMin = minimum(float_buffer),
            ValAvg = sum([val / length(float_buffer) for val in float_buffer]),
            ValMax = maximum(float_buffer),
       ))
    end
    close(input_file)
end

if (length(ARGS) != 1)
    println("pass file name to analyze for stats")
    exit(1)
end

path = ARGS[1]

num_bytes = filesize(path)

if num_bytes == 0
    println(path, " not found")
end

float_type, byte_type, log_num_chunks = floatfilemeta(num_bytes)

num_elements = div(num_bytes, sizeof(byte_type))

num_chunks = 2^log_num_chunks

chunk_size = div(num_elements, num_chunks)

df = DataFrame(
    Chunk = Int[],
    SignAvg = Float32[],
    ExpMin = Int[],
    ExpAvg = Int[],
    ExpMax = Int[],
    ManMin = String[],
    ManAvg = String[],
    ManMax = String[],
    ValMin = float_type[],
    ValAvg = float_type[],
    ValMax = float_type[],
)

stats(df, path, num_elements, num_chunks, chunk_size, float_type, byte_type)

CSV.write(path * ".stats", df)
display(df)
