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
using CairoMakie, Makie
using ColorSchemes, Colors
using CSV
using DataFrames

function create_local_mem_heatmap(segments, degree, values, name, colormap)
    nd = length(degree)
    ns = length(segments)
    fig = Figure(size=(nd*55, ns*50))
    ax = Axis(fig[1, 1], xlabel = "degree", ylabel="segments")

    maxvalue = maximum(vec(values))

    hm = heatmap!(ax, 1:nd, 0:ns, values; colormap = colormap, colorrange = (1, maxvalue), interpolate=false)
    ax.xticks = (1:nd, string.(degree))
    ax.yticks = (1:ns, string.(segments))

    points = vec([Point2f(x, y - 0.5) for y in 1:ns, x in 1:nd])
    txt = text!(ax, points, text=string.(vec(transpose(values))), align = (:center, :center), fontsize = 11, color = :black)

    tickstep = 2^floor(Int, log2(maxvalue / 7))
    ticks = 0:tickstep:maxvalue
    Colorbar(fig[1,2], hm;
        ticks = (ticks, string.(ticks)),
        label = name,
    )
    fig
end

function create_merged_local_mem_heatmap(segments, degree, lut_values, lut_name, lut_color, ram_values, ram_name, ram_color)
    nd = length(degree)
    ns = length(segments)
    fig = Figure(size=(nd*55, ns*50))
    ax = Axis(fig[1, 1], xlabel = "degree", ylabel="segments")

    ram_values = map(v -> v == 0 ? NaN : float(v), ram_values)
    lut_values = map(v -> v == 0 ? NaN : float(v), lut_values)

    lut_values_filtered = filter(!isnan, vec(lut_values))
    lut_maxvalue = isempty(lut_values_filtered) ? 0 : maximum(lut_values_filtered)

    ram_values_filtered = filter(!isnan, vec(ram_values))
    ram_maxvalue = maximum(ram_values_filtered)

    lut_colorrange = isempty(lut_values_filtered) ? (0.0, 1.0) : (minimum(lut_values_filtered), maximum(lut_values_filtered))
    ram_colorrange = isempty(ram_values_filtered) ? (0.0, 1.0) : (minimum(ram_values_filtered), maximum(ram_values_filtered))

    lut_hm = heatmap!(ax, 1:nd, 0:ns, lut_values; colormap=lut_color, colorrange = lut_colorrange, interpolate=false)
    ram_hm = heatmap!(ax, 1:nd, 0:ns, ram_values; colormap=ram_color, colorrange = ram_colorrange, interpolate=false)

    ax.xticks = (1:nd, string.(degree))
    ax.yticks = (1:ns, string.(segments))

    points = vec([Point2f(x, y-0.5) for y in 1:ns, x in 1:nd])

    lut_txt_values = map(v -> isfinite(v) ? string(Int(v)) : "", vec(transpose(lut_values)))
    lut_txt = text!(ax, points, text=lut_txt_values, align = (:center, :center), fontsize = 11, color = :black)

    ram_txt_values = map(v -> isfinite(v) ? string(Int(v)) : "" , vec(transpose(ram_values)))
    ram_txt = text!(ax, points, text=ram_txt_values, align = (:center, :center), fontsize = 11, color = :black)

    lut_tickstep = lut_maxvalue == 0 ? 1 : 2^floor(Int, log2(lut_maxvalue / 7))
    Colorbar(fig[1,2], lut_hm;
        ticks = 0:lut_tickstep:Int(lut_maxvalue),
        label = lut_name,
    )

    ram_tickstep = 2^floor(Int, log2(ram_maxvalue / 7))
    Colorbar(fig[1,3], ram_hm;
        ticks = 0:ram_tickstep:Int(ram_maxvalue),
        label = ram_name,
    )
    fig
end

function get_value(df, s, d, value)
    mask = (df.Segments .== s) .& (df.Degree .== d)
    rows = df[mask, value]
    if length(rows) == 0
        return 0
    elseif length(rows) > 1
        error("too much values for s=$s, d=$d")
    else
        return only(rows)
    end
end

function fill_matrix(values, segments, degree, df, value)
    for (i, s) in enumerate(segments)
        for (j, d) in enumerate(degree)
            values[j, i] = get_value(df, s, d, value)
        end
    end
end

function read_and_prepare(toolchain, segments, degree, precision, mem)
    ramid, lutid = if toolchain == "oneAPI"
        :RAMs, :MLABs
    elseif toolchain == "Vitis"
        :BRAM18K, :LUT
    else
        error("unsupported toolchain")
    end
    df = CSV.read("$toolchain/local_mem.csv", DataFrame)

    df_filtered = filter(:Precision => ==(precision), df)
    filter!(:Mem => ==(mem), df_filtered)

    ram_values = Matrix{Int64}(undef, length(degree), length(segments))
    fill_matrix(ram_values, segments, degree, df_filtered, ramid)

    lut_values = Matrix{Int64}(undef, length(degree), length(segments))
    fill_matrix(lut_values, segments, degree, df_filtered, lutid)

    if toolchain == "oneAPI" && mem == "lut"
        # 20 ALUTs per MLAB
        lut_values *= 20
    end

    return ram_values, lut_values
end


function display_bytes(segments, degree)
    bytes = Matrix{Int64}(undef, length(segments), length(degree))
    for (i, s) in enumerate(segments)
        for (j, d) in enumerate(degree)
            bytes[s, d] = 32 * s * d
        end
    end
end


degree = 0:15
segments =  [32, 64, 128, 256, 512, 1024]
values = Dict{NTuple{3, String}, NTuple{2, Matrix{Int64}}}()

for toolchain in ["Vitis", "oneAPI"]
    for precision in ["single", "double"]
        for mem in ["ram", "lut", "auto"]
            ram, lut = read_and_prepare(toolchain, segments, degree, precision, mem)
            values[toolchain, precision, mem] = ram, lut
        end
    end
end

lut_name = Dict(
    "Vitis" => "LUTs",
    "oneAPI" => "ALUTs",
)

ram_name = Dict(
    "Vitis" => "BRAM18Ks",
    "oneAPI" => "M20Ks",
)

function remove_end_of_cmap(color)
    full = to_colormap(color)
    partial = full[1:round(Int, 0.75 * length(full))]
    resample_cmap(partial, 256)
end

lut_color = remove_end_of_cmap(:speed)
ram_color = remove_end_of_cmap(:matter)

for toolchain in ["Vitis", "oneAPI"]
    folder = "./build_plots/$(toolchain)/local_mem/"
    if !ispath(folder)
        mkpath(folder)
    end
    for precision in ["single", "double"]
        for mem in ["ram", "lut", "auto"]
            name = join([precision, mem], "_")
            ram, lut = values[toolchain, precision, mem]
            fig = if mem == "ram"
                create_local_mem_heatmap(segments, degree, ram, ram_name[toolchain], ram_color)
            elseif mem == "lut"
                create_local_mem_heatmap(segments, degree, lut, lut_name[toolchain], lut_color)
            else
                create_merged_local_mem_heatmap(segments, degree, lut, lut_name[toolchain], lut_color, ram, ram_name[toolchain], ram_color)
            end
            save("$(folder)$(name).pdf", fig)
        end
    end
end

