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
    y_lower
    y_upper
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

function check_data_and_read_and_reduce(input_path, output_path, interval)
    input_num_bytes = filesize(input_path)

    if input_num_bytes == 0
        println(input_path, " not found")
        exit(1)
    end

    output_num_bytes = filesize(output_path)

    if output_num_bytes == 0
        println(output_path, " not found")
        exit(1)
    end

    input_float_type, input_byte_type, input_log_num_chunks = floatfilemeta(input_num_bytes)

    output_float_type, output_byte_type, output_log_num_chunks = floatfilemeta(output_num_bytes)

    num_elements = div(input_num_bytes, sizeof(input_float_type))

    if num_elements != div(output_num_bytes, sizeof(output_float_type)) && (input_log_num_chunks != output_log_num_chunks)
        println("input and output do not match")
        exit(1)
    end

    num_chunks = 2^input_log_num_chunks

    chunk_size = div(num_elements, num_chunks)

    x, y = read_and_reduce(input_path, output_path, num_chunks, chunk_size, interval, input_float_type, output_float_type)
end

interval = Interval(
    -3.0,
    3.0,
    -10.0,
    10.0
)

fig = Figure(size=(1600, 500), fontsize=30)
blue = Makie.wong_colors()[1]
red = Makie.wong_colors()[6]

dyticks = -0.0002:0.0001:0.0002
dlimits = ((-3.0, 3.0), (-0.00022, 0.00022))

for (i_f, f) in enumerate(["erf", "erfc"])
    fyticks, flimits = if f == "erf"
        -1.0:0.5:1.0, ((-3.0, 3.0), (-1.1, 1.1))
    else
        0:0.5:2.0, ((-3.0, 3.0), (-0.1, 2.1))
    end
    for (i_p, p) in enumerate(["single", "double"])
        input_path = "./build_input/in_$(p).bin"
        deviations_path = "./build_float_deviations/oneAPI/$(f)_$(p).bin"
        x_d,y_d = check_data_and_read_and_reduce(input_path, deviations_path, interval)
        golden_path = "./build_golden/$(f)_$(p).bin"
        x_g,y_g = check_data_and_read_and_reduce(input_path, golden_path, interval)
        ax1 = if i_p == 1
            Axis(fig[i_f, i_p], yticklabelcolor=blue, ylabel="$(f)(x)", ylabelcolor=blue, title=(i_f==1) ? "$(p) precision" : "", yticks = fyticks, limits = flimits)
        else
            Axis(fig[i_f, i_p], title=(i_f==1) ? "$(p) precision" : "", yticks = fyticks, limits = flimits)
        end
        ax2 = if i_p == 1
            Axis(fig[i_f, i_p], yaxisposition=:right, yticks=dyticks, limits = dlimits)
        else
            Axis(fig[i_f, i_p], yticklabelcolor=red, ylabel="absolute error", yaxisposition=:right, ylabelcolor=red, yticks=dyticks, limits = dlimits)
        end
        hidespines!(ax2, :l)
        hidexdecorations!(ax2; grid = false)
        if i_p == 1
            hideydecorations!(ax2; grid = false)
        else
            hideydecorations!(ax1; grid = false)
        end
        if i_f == 1
            hidexdecorations!(ax1; grid = false)
        end
        linkxaxes!(ax1, ax2)

        println("plotting ", length(x_g), " values")
        lines!(ax1, x_g, y_g, color=blue)
        println("plotting ", length(x_d), " values")
        lines!(ax2, x_d, y_d, color=red)
    end
end

colgap!(fig.layout, 20)
rowgap!(fig.layout, 20)

save("build_plots/oneAPI/erf_deviation.pdf", fig)
