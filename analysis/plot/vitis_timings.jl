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
using ColorSchemes

include("../ieee754.jl")

linestyles = [:solid, :dot, :dash]

theoretical = Dict(
    "cosh" => 384, "sinh" => 383,
    "acos" => 273, "asin" => 265, "atan" => 142,
    "acospi" => 304, "asinpi" => 296, "atanpi" => 174,
)

function read_timings(path, sign)
    df = CSV.read(path, DataFrame; header = ["chunk", "time"])
    transform!(df,
        :chunk => ByRow(c -> (c >= div(nrow(df), 2)) ? 1 : 0) => :sign,
        :chunk => ByRow(c -> (c >= div(nrow(df), 2)) ? c - div(nrow(df), 2) - 1 - bias(Float64) : c - 1 - bias(Float64)) => :exp,
        :time => ByRow(c -> (Float64(c) / 2097152.0) * 300000000) => :avg_cycle,
    )
    filter!(row -> row.sign == sign, df)
    filter!(row -> row.exp > -33 && row.exp < 33, df)
    transform!(df,
       :exp => ByRow(e -> 2.0^e) => :value
    )
    return df
end

group_name = ["hyperbolic", "arcus_trigonometric", "arcus_trigonometric_pi"]
operations = [["cosh", "sinh"], ["acos", "asin", "atan"], ["acospi", "asinpi", "atanpi"]]
legendorder = ["sinh", "cosh", "asinpi", "acospi", "asin", "acos", "atanpi", "atan"]

all_ops = vcat(operations...)
op_color = Dict(op => ColorSchemes.tab10[i] for (i, op) in enumerate(all_ops))

for sign in [0, 1]
    fig = Figure(size=(1100, 450), fontsize=30)
    axis = Axis(fig[1, 1], xlabel="Binade Start", ylabel="Average Cycles per\nOperation per Binade", xscale=log2,
        yticks=([144, 176, 268, 275, 299, 307, 373, 374],
                [rich("144", color=op_color["atan"]),
                 rich("176", color=op_color["atanpi"]),
                 rich("268", color=op_color["asin"]),
                 rich("275        ", color=op_color["acos"]),
                 rich("299", color=op_color["asinpi"]),
                 rich("307        ", color=op_color["acospi"]),
                 rich("373", color=op_color["sinh"]),
                 rich("374        ", color=op_color["cosh"])]))
    xlims!(axis, 2.0^-32, 2.0^32)

    for (ig, group) in enumerate(operations)
        for (io, op) in enumerate(group)
            timings = read_timings("./Vitis/build_$(group_name[ig])/$(op)_double_timings.bin", sign)
            CSV.write("./Vitis/build_timings/$(op)_double.csv", timings)
            lines!(axis, timings.value, timings.avg_cycle, label=op, color=op_color[op])
        end
    end

    # Right axis with theoretical values as colored ticks
    sorted_theo = sort(collect(theoretical), by=x -> x[2])
    tick_vals = Float64[]
    tick_labels = Makie.RichText[]
    pad = "        "
    for (i, (op, val)) in enumerate(sorted_theo)
        push!(tick_vals, Float64(val))
        nudge = ""
        if i > 1 && abs(Float64(val) - Float64(sorted_theo[i-1][2])) < 20
            nudge = pad
        end
        push!(tick_labels, rich("$(nudge)$(val)", color=op_color[op]))
    end

    ax_right = Axis(fig[1, 1],
        ylabel="Reported Maximum\nLatency in Cycles",
        yaxisposition=:right,
        yticks=(tick_vals, tick_labels),
        yticksize=10,
        ytickcolor=:black,
        backgroundcolor=:transparent)
    hidespines!(ax_right, :l, :b, :t)
    hidexdecorations!(ax_right)
    linkyaxes!(axis, ax_right)

    entries = [[LineElement(color=op_color[op], linewidth=3)] for op in legendorder]
    labels = legendorder
    Legend(fig[1, 2], entries, labels, nbanks=1)

    save("build_plots/Vitis/timings_s$(sign).pdf", fig)
end
