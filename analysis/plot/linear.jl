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
using DataFrames
using CairoMakie
using Quadmath

include("../ieee754.jl")

struct Interval
    x_lower
    x_upper
    x_ticks
    y_lower
    y_upper
    y_ticks
end

function read_and_reduce(input_path, output_path, num_chunks, chunk_size, interval, ::Type{InputF}, ::Type{OutputF}) where {InputF <: AbstractFloat, OutputF <: AbstractFloat}
    input_file = open(input_path, "r")
    output_file = open(output_path, "r")

    x = Vector{InputF}(undef, chunk_size)
    y = Vector{OutputF}(undef, chunk_size)

    x_total = Vector{InputF}()
    y_total = Vector{OutputF}()

    for c in 1:num_chunks
        read!(input_file, x)
        read!(output_file, y)

        m = isfinite.(x) .&& isfinite.(y) .&&
            x .>= interval.x_lower .&& y .>= interval.y_lower .&&
            x .<= interval.x_upper .&& y .<= interval.y_upper

        if sizeof(InputF) >= 8 || sizeof(OutputF) >= 8
            m = m .&& [i % 8196 == 1 for i in 1:chunk_size]
        end

        append!(x_total, x[m])
        append!(y_total, y[m])
    end

    p = sortperm(x_total)
    x_total[p], y_total[p]
end

function pi_formatter_single(x; tol=1e-8)
    kπ  = round(x/π)
    if isapprox(x, kπ*π; atol=tol)
        if kπ == 0
            return "0"
        elseif abs(kπ) == 1
            return kπ == 1 ? "π" : "-π"
        else
            return "$(Int(kπ))π"
        end
    end

    return string(round(x; digits=3))
end

pi_formatter(xs) = [pi_formatter_single(x) for x in xs]

function create_figure(x, y, output_path, interval)
    println("plotting ", length(x), " values")
    fig = Figure()
    xticks = interval.x_lower:interval.x_ticks:interval.x_upper
    #yticks = interval.y_lower:interval.y_ticks:interval.y_upper
    axis = Axis(fig[1, 1], xticks=xticks, xtickformat=pi_formatter)
    lines!(axis, x, y)
    if interval.y_ticks != 0.0
        hlines!(axis, interval.y_ticks, color = :red)
        hlines!(axis, -interval.y_ticks, color = :red)
    end
    fig
end

if length(ARGS) != 8
    println("pass input, output, x_lower, x_upper, x_ticks, y_lower, y_upper, y_ticks as arguments")
    exit(1)
end

input_path = ARGS[1]

input_num_bytes = filesize(input_path)

if input_num_bytes == 0
    println(input_path, " not found")
end

output_path = ARGS[2]

output_num_bytes = filesize(output_path)

if input_num_bytes == 0
    println(output_path, " not found")
end

println("plotting " * input_path * " against " * output_path)

input_float_type, input_byte_type, input_log_num_chunks = floatfilemeta(input_num_bytes)

output_float_type, output_byte_type, output_log_num_chunks = floatfilemeta(output_num_bytes)

num_elements = div(input_num_bytes, sizeof(input_float_type))

if num_elements != div(output_num_bytes, sizeof(output_float_type)) && (input_log_num_chunks != output_log_num_chunks)
    println("input and output do not match")
    exit(1)
end

interval = Interval(
    eval(Meta.parse(ARGS[3]))::Float64,
    eval(Meta.parse(ARGS[4]))::Float64,
    eval(Meta.parse(ARGS[5]))::Float64,
    eval(Meta.parse(ARGS[6]))::Float64,
    eval(Meta.parse(ARGS[7]))::Float64,
    eval(Meta.parse(ARGS[8]))::Float64,
)

num_chunks = 2^input_log_num_chunks

chunk_size = div(num_elements, num_chunks)

x, y = read_and_reduce(input_path, output_path, num_chunks, chunk_size, interval, input_float_type, output_float_type)

fig = create_figure(x, y, output_path, interval)

interval_str = join([interval.x_lower, interval.x_upper, interval.y_lower, interval.y_upper], "_")

save(output_path * "." * interval_str * ".png", fig)
