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
using SpecialFunctions

config_str = read("config.json", String)
config = JSON.parse(config_str)

asinpi(x::T) where {T<:AbstractFloat} = asin(x) / T(pi)
acospi(x::T) where {T<:AbstractFloat} = acos(x) / T(pi)
atanpi(x::T) where {T<:AbstractFloat} = atan(x) / T(pi)

rsqrt(x::T) where {T<:AbstractFloat} = T(1.0) / sqrt(x) 
recip(x::T) where {T<:AbstractFloat} = T(1.0) / x

function write_deviations(operation, operation_name, precision_name, precision_bits, ::Type{F}) where {F <: AbstractFloat}
    chunk_size = sizeof(F) == 2 ? 131072 : 536870912
    chunk_elements = div(chunk_size, sizeof(F))
 
    in_path = "./build_input/in_" * precision_name * ".bin"
    in_file = open(in_path, "r")

    golden_path = "./build_golden/" * join([operation_name, precision_name], "_") * ".bin"
    golden_file = open(golden_path, "w")

    in_buffer = Vector{F}(undef, chunk_elements)
    golden_buffer = Vector{F}(undef, chunk_elements)

    setprecision(precision_bits)

    count = 0
    while !eof(in_file)
        read!(in_file, in_buffer)

        print("Calculating golden result on ", Threads.nthreads(), " threads with chunk ", count)
        flush(stdout)

        count += 1
        Threads.@threads for i in eachindex(in_buffer, golden_buffer)
            try
                golden_buffer[i] = F(operation(BigFloat(in_buffer[i])))
            catch e
                golden_buffer[i] = F(NaN)
            end
        end

        println(": done")

        write(golden_file, golden_buffer)
    end

    close(in_file)
    close(golden_file)
end

if length(ARGS) != 1
    println("Pass operation as argument")
    exit(1)
end

operation_name = ARGS[1]

precisions = [("half", 11, Float16), ("single", 24, Float32), ("double", 53, Float64)]

operation = getfield(@__MODULE__, Symbol(operation_name))

for precision in precisions
    println("calculating for ", precision[1])
    write_deviations(operation, operation_name, precision[1], precision[2], precision[3])
    println("Done")
end
