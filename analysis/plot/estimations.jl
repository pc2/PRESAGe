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
# erf_plots.jl
# --- setup ---
using Pkg
# Pkg.add(["CSV","DataFrames","CairoMakie","Statistics"])

# Load plotting/data deps and define resource totals early
using CSV, DataFrames, CairoMakie, Statistics
CairoMakie.activate!()  # crisp SVG/PDF/PNG

totals = Dict(
    "oneAPI" => Dict(
        "LUTs" => 933120,
        "FFs" => 3732480,
        "RAMs" => 11721,
        "DSPs" => 5011,
    ),
    "Vitis" => Dict(
        "LUTs" => 1303680,
        "FFs" => 2607360,
        "RAMs" => 4032,
        "DSPs" => 9024,
    )
)

function argmin_with_tiebreak(primary::AbstractVector, secondary::AbstractVector)
    pmin = minimum(primary)
    candidates = findall(==(pmin), primary)       # all indices with minimum primary
    if length(candidates) == 1
        return candidates[1]
    else
        # among candidates, choose one with minimum secondary
        secvals = secondary[candidates]
        j = argmin(secvals)
        return candidates[j]
    end
end

#=
Additionally create a multi-figure comparing Vitis vs oneAPI
for the specific case of double-precision `erf_approximation_0`, with:
- Row 1: Vitis (title: "Vitis")
- Row 2: oneAPI (title: "oneAPI")
- Row 3: Shared compact legend
=#
function make_erf_approximation_multifigure()
    # --- target approximations (naming differs between toolchains) ---
    vitis_approx  = "erf_approximation_double_0"
    oneapi_approx = "erf_approximation_0_double"

    # Helper to load and augment a dataframe with Usage
    function load_df(toolchain::String, approximation::String)
        path = "$(toolchain)/build_estimations/$(approximation).csv"
        df = CSV.read(path, DataFrame)
        df.Usage .= 0.0
        for resource in keys(totals[toolchain])
            df.Usage += df[!, resource] ./ totals[toolchain][resource]
        end
        return df
    end

    df_vitis  = load_df("Vitis", vitis_approx)
    df_oneapi = load_df("oneAPI", oneapi_approx)

    # unified mappings across both toolchains
    splits_all = sort(unique(vcat(df_vitis.Split, df_oneapi.Split)))
    palette    = Makie.wong_colors()[1:4]
    split_color = Dict(s => palette[mod1(i, length(palette))] for (i, s) in enumerate(splits_all))
    memvals_all = sort(unique(vcat(string.(df_vitis.memory), string.(df_oneapi.memory))))
    marker_map = Dict("lut" => :circle, "ram" => :utriangle)

    # scale function; use shared bounds so legend matches exactly
    function scale_markers(v; lo=6.0, hi=20.0)
        v = Float64.(v)
        vmin, vmax = minimum(v), maximum(v)
        rng = vmax - vmin
        rng ≈ 0 ? fill((lo + hi)/2, length(v)) : lo .+ (v .- vmin) .* (hi - lo) ./ rng
    end
    deg_all = vcat(df_vitis.Degree, df_oneapi.Degree)
    global_vmin, global_vmax = minimum(deg_all), maximum(deg_all)
    scale_markers_with_bounds(v; lo=6.0, hi=20.0) = begin
        v = Float64.(v)
        rng = global_vmax - global_vmin
        rng ≈ 0 ? fill((lo + hi)/2, length(v)) : lo .+ (v .- global_vmin) .* (hi - lo) ./ rng
    end

    # degree scaling per dataset, using shared bounds
    ms_degree_vitis  = scale_markers_with_bounds(df_vitis.Degree)
    ms_degree_oneapi = scale_markers_with_bounds(df_oneapi.Degree)

    # Build a single figure: 2 rows of plots + 1 legend row
    fig = Figure(size = (1200, 400))

    # ---------- Row 1: Vitis ----------
    Label(fig[1, 0], "Vitis"; rotation=π/2, font=:bold, tellheight=false)
    ax1 = Axis(fig[1, 1]; ylabel = "LUTs", xscale = log10)
    for mem in memvals_all, s in reverse(splits_all)
        idx = (string.(df_vitis.memory) .== mem) .& (df_vitis.Split .== s)
        any(idx) || continue
        scatter!(ax1, df_vitis.Segments[idx], df_vitis.LUTs[idx];
            color = split_color[s], markersize = ms_degree_vitis[idx], marker = marker_map[mem],
        )
    end
    iminLUT_vitis = argmin_with_tiebreak(df_vitis.LUTs, df_vitis.RAMs)
    scatter!(ax1, [df_vitis.Segments[iminLUT_vitis]], [df_vitis.LUTs[iminLUT_vitis]];
        marker = :circle, markersize = ms_degree_vitis[iminLUT_vitis] + 5,
        color = :transparent, strokecolor = :red, strokewidth = 1,
    )

    ax2 = Axis(fig[1, 2]; ylabel = "RAMs", xscale = log10)
    for mem in memvals_all, s in reverse(splits_all)
        idx = (string.(df_vitis.memory) .== mem) .& (df_vitis.Split .== s)
        any(idx) || continue
        scatter!(ax2, df_vitis.Segments[idx], df_vitis.RAMs[idx];
            color = split_color[s], markersize = ms_degree_vitis[idx], marker = marker_map[mem],
        )
    end
    iminRAM_vitis = argmin_with_tiebreak(df_vitis.RAMs, df_vitis.LUTs)
    scatter!(ax2, [df_vitis.Segments[iminRAM_vitis]], [df_vitis.RAMs[iminRAM_vitis]];
        marker = :circle, markersize = ms_degree_vitis[iminRAM_vitis] + 5,
        color = :transparent, strokecolor = :red, strokewidth = 1,
    )

    ax3 = Axis(fig[1, 3]; ylabel = "Usage", xscale = log10)
    for mem in memvals_all, s in reverse(splits_all)
        idx = (string.(df_vitis.memory) .== mem) .& (df_vitis.Split .== s)
        any(idx) || continue
        scatter!(ax3, df_vitis.Segments[idx], df_vitis.Usage[idx];
            color = split_color[s], markersize = ms_degree_vitis[idx], marker = marker_map[mem],
        )
    end
    iminUsage_vitis = argmin(df_vitis.Usage)
    scatter!(ax3, [df_vitis.Segments[iminUsage_vitis]], [df_vitis.Usage[iminUsage_vitis]];
        marker = :circle, markersize = ms_degree_vitis[iminUsage_vitis] + 5,
        color = :transparent, strokecolor = :red, strokewidth = 1,
    )

    # ---------- Row 2: oneAPI ----------
    Label(fig[2, 0], "oneAPI"; rotation=π/2, font=:bold, tellheight=false)
    ax4 = Axis(fig[2, 1]; xlabel = "Segments", ylabel = "LUTs", xscale = log10)
    for mem in memvals_all, s in reverse(splits_all)
        idx = (string.(df_oneapi.memory) .== mem) .& (df_oneapi.Split .== s)
        any(idx) || continue
        scatter!(ax4, df_oneapi.Segments[idx], df_oneapi.LUTs[idx];
            color = split_color[s], markersize = ms_degree_oneapi[idx], marker = marker_map[mem],
        )
    end
    iminLUT_oneapi = argmin_with_tiebreak(df_oneapi.LUTs, df_oneapi.RAMs)
    scatter!(ax4, [df_oneapi.Segments[iminLUT_oneapi]], [df_oneapi.LUTs[iminLUT_oneapi]];
        marker = :circle, markersize = ms_degree_oneapi[iminLUT_oneapi] + 5,
        color = :transparent, strokecolor = :red, strokewidth = 1,
    )

    ax5 = Axis(fig[2, 2]; xlabel = "Segments", ylabel = "RAMs", xscale = log10)
    for mem in memvals_all, s in reverse(splits_all)
        idx = (string.(df_oneapi.memory) .== mem) .& (df_oneapi.Split .== s)
        any(idx) || continue
        scatter!(ax5, df_oneapi.Segments[idx], df_oneapi.RAMs[idx];
            color = split_color[s], markersize = ms_degree_oneapi[idx], marker = marker_map[mem],
        )
    end
    iminRAM_oneapi = argmin_with_tiebreak(df_oneapi.RAMs, df_oneapi.LUTs)
    scatter!(ax5, [df_oneapi.Segments[iminRAM_oneapi]], [df_oneapi.RAMs[iminRAM_oneapi]];
        marker = :circle, markersize = ms_degree_oneapi[iminRAM_oneapi] + 5,
        color = :transparent, strokecolor = :red, strokewidth = 1,
    )

    ax6 = Axis(fig[2, 3]; xlabel = "Segments", ylabel = "Usage", xscale = log10)
    for mem in memvals_all, s in reverse(splits_all)
        idx = (string.(df_oneapi.memory) .== mem) .& (df_oneapi.Split .== s)
        any(idx) || continue
        scatter!(ax6, df_oneapi.Segments[idx], df_oneapi.Usage[idx];
            color = split_color[s], markersize = ms_degree_oneapi[idx], marker = marker_map[mem],
        )
    end
    iminUsage_oneapi = argmin(df_oneapi.Usage)

    scatter!(ax6, [df_oneapi.Segments[iminUsage_oneapi]], [df_oneapi.Usage[iminUsage_oneapi]];
        marker = :circle, markersize = ms_degree_oneapi[iminUsage_oneapi] + 7,
        color = :transparent, strokecolor = :red, strokewidth = 1,
    )

    linkxaxes!(ax1, ax4); linkxaxes!(ax2, ax5); linkxaxes!(ax3, ax6)
    hidexdecorations!(ax1; grid=false)
    hidexdecorations!(ax2; grid=false)
    hidexdecorations!(ax3; grid=false)

    # ---------- Row 3: Legend (3 grouped vectors in a single row) ----------
    deg_samples   = sort(unique(vcat(df_vitis.Degree, df_oneapi.Degree)))
    deg_sizes_leg = scale_markers_with_bounds(deg_samples; lo=6.0, hi=20.0)
    mem_order     = filter(m -> m in memvals_all, ["lut","ram"])

    split_elems  = [MarkerElement(color=split_color[s], marker=:circle, markersize=9) for s in splits_all]
    split_labels = [string(s) for s in splits_all]
    mem_elems    = [MarkerElement(color=:black, marker=marker_map[m], markersize=9) for m in mem_order]
    mem_labels   = [uppercase(m) for m in mem_order]
    deg_elems    = [MarkerElement(color=:black, marker=:circle, markersize=sz) for sz in deg_sizes_leg]
    deg_labels   = [string(d) for d in deg_samples]

    Legend(fig[3, 1:3],
        [split_elems, mem_elems, deg_elems],
        [split_labels, mem_labels, deg_labels],
        ["Split", "Memory", "Degree"];
        orientation=:horizontal, nbanks=1, framevisible=false)

    rowgap!(fig.layout, 15)
    colgap!(fig.layout, 10)

    # save combined figure
    save("build_plots/estimations/erf_approximation_double_0_multifigure.pdf", fig)
end

approximations = Dict()

function generate_all_estimation_plots()
    approximations = Dict()
    for toolchain in ["Vitis", "oneAPI"]
        approximations[toolchain] = []
        for precision in ["single", "double"]
            for approximation in ["cos", "sin", "atan", "exp", "cosh", "sinh"]
                push!(approximations[toolchain], "$(approximation)_approximation_$(precision)")
            end
            for approximation in ["erf", "erfc"]
                for i in 0:5
                    if toolchain == "oneAPI"
                        push!(approximations[toolchain], "$(approximation)_approximation_$(i)_$(precision)")
                    else
                        push!(approximations[toolchain], "$(approximation)_approximation_$(precision)_$(i)")
                    end
                end
            end
        end
    end

    for toolchain in ["Vitis", "oneAPI"]
      for approximation in approximations[toolchain]
        # --- load data ---
        path = "$(toolchain)/build_estimations/$(approximation).csv"
        df = CSV.read(path, DataFrame)

        df.Usage .= 0.0

        for resource in keys(totals[toolchain])
            df.Usage += df[!, resource] ./ totals[toolchain][resource]
        end

        # expected columns: :Degree, :Split, :Segments, :LUTs, :FFs, :DSPs, :RAMs, :memory
        memvals = sort(unique(string.(df.memory)))
        marker_map = Dict("lut" => :circle, "ram" => :utriangle)  # shape encodes memory

        # --- helpers ---
        "Scale a vector to a nice marker-size range."
        function scale_markers(v; lo=6.0, hi=20.0)
            v = Float64.(v)
            vmin, vmax = minimum(v), maximum(v)
            rng = vmax - vmin
            rng ≈ 0 ? fill((lo + hi)/2, length(v)) : lo .+ (v .- vmin) .* (hi - lo) ./ rng
        end

        ms_degree   = scale_markers(df.Degree)     # plot 1: size ~ Degree

        # --- color map for Split (exactly 4 legend entries) ---
        splits_str = string.(df.Split)
        splits = sort(unique(df.Split))
        palette = Makie.wong_colors()[1:4]  # good, colorblind-friendly
        split_color = Dict(s => palette[mod1(i, length(palette))] for (i, s) in enumerate(splits))

        # --- Figure layout ---
        fig = Figure(size = (1300, 325))
        fig_lg = Figure(size = (1300, 200))
        # =========================
        # 1) LUTs vs Segments (log x)
        # =========================
        ax1 = Axis(fig[1, 1];
            xlabel = "Segments", ylabel = "LUTs", xscale = log10,
        )

        # draw: color -> Split, marker -> memory, size -> Degree
        for mem in memvals, s in reverse(splits)
            idx = (string.(df.memory) .== mem) .& (df.Split .== s)
            any(idx) || continue
            scatter!(ax1, df.Segments[idx], df.LUTs[idx];
                color      = split_color[s],
                markersize = ms_degree[idx],
                marker     = marker_map[mem],
                # no labels here; we'll build one shared legend for Split
            )
        end

        iminLUT = argmin_with_tiebreak(df.LUTs, df.RAMs)
        scatter!(ax1, [df.Segments[iminLUT]], [df.LUTs[iminLUT]];
                 marker = :circle,
                 markersize = ms_degree[iminLUT] + 5,
                 color = :transparent,
                 strokecolor = :red,
                 strokewidth = 1,
        )

        ax2 = Axis(fig[1, 2];
            #title = "Resource trade-off (size ~ Segments, color ~ Split, marker ~ memory)",
            xlabel = "Segments", ylabel = "RAMs", xscale = log10,
        )

        # draw: color -> Split, marker -> memory, size -> Segments
        for mem in memvals, s in reverse(splits)
            idx = (string.(df.memory) .== mem) .& (df.Split .== s)
            any(idx) || continue
            scatter!(ax2, df.Segments[idx], df.RAMs[idx];
                color      = split_color[s],
                markersize = ms_degree[idx],
                marker     = marker_map[mem],
            )
        end

        iminRAM = argmin_with_tiebreak(df.RAMs, df.LUTs)
        scatter!(ax2, [df.Segments[iminRAM]], [df.RAMs[iminRAM]];
                 marker = :circle,
                 markersize = ms_degree[iminRAM] + 5,
                 color = :transparent,
                 strokecolor = :red,
                 strokewidth = 1,
        )

        ax3 = Axis(fig[1, 3];
            #title = "Resource trade-off (size ~ Segments, color ~ Split, marker ~ memory)",
            xlabel = "Segments", ylabel = "Usage", xscale = log10,
        )

        # draw: color -> Split, marker -> memory, size -> Segments
        for mem in memvals, s in reverse(splits)
            idx = (string.(df.memory) .== mem) .& (df.Split .== s)
            any(idx) || continue
            scatter!(ax3, df.Segments[idx], df.Usage[idx];
                color      = split_color[s],
                markersize = ms_degree[idx],
                marker     = marker_map[mem],
            )
        end

        iminUsage = argmin(df.Usage)
        scatter!(ax3, [df.Segments[iminUsage]], [df.Usage[iminUsage]];
                 marker = :circle,
                 markersize = ms_degree[iminUsage] + 5,
                 color = :transparent,
                 strokecolor = :red,
                 strokewidth = 1,
        )

        # Collect legend keys for highlighted points (same encoding: mem, split, degree)
        legend_highlights = Set{Tuple{String, eltype(splits), eltype(df.Degree)}}()
        push!(legend_highlights, (String(df.memory[iminLUT]),  df.Split[iminLUT],  df.Degree[iminLUT]))
        push!(legend_highlights, (String(df.memory[iminRAM]),  df.Split[iminRAM],  df.Degree[iminRAM]))
        push!(legend_highlights, (String(df.memory[iminUsage]), df.Split[iminUsage], df.Degree[iminUsage]))

        # ----------------------------------
        # Shared legend (only for Split colors)
        # ----------------------------------
        # Four legend entries matching the Split values/colors
        # Split color legend, grouped by memory type
        split_labels = ["Split=$(s)" for s in splits]

        # Memory strategies (lut, ram)
        mem_strats = collect(memvals)

        # Legend entries for each memory type separately
        split_entries = Dict{String, Tuple{Vector{MarkerElement}, Vector{String}}}()

        for mem in mem_strats
            elems = MarkerElement[]
            labels = String[]
            for s in splits
                push!(elems, MarkerElement(color = split_color[s],
                                           marker = marker_map[mem],
                                           markersize = 14))
                push!(labels, "Split=$(s)")
            end
            split_entries[mem] = (elems, labels)
        end

        # Degree legend: pick representative degrees (min, mid, max)
        #deg_samples = [minimum(df.Degree), median(df.Degree), maximum(df.Degree)]

        # ----------------------------------
        # Build the legend grid manually
        # ----------------------------------
        # --- COMPACT LEGEND ROW -------------------------------------------------
        # ======= TABLE LEGEND (compact) =========================================
        # ================= TABLE LEGEND: columns = Degree, sub-columns = {LUT, RAM} =================
        deg_samples   = sort(unique(df.Degree))
        # use identical size mapping as in the plot
        vminD, vmaxD = minimum(df.Degree), maximum(df.Degree)
        function scale_markers_with_bounds_local(v; lo=6.0, hi=20.0)
            v = Float64.(v)
            rng = vmaxD - vminD
            rng ≈ 0 ? fill((lo + hi)/2, length(v)) : lo .+ (v .- vminD) .* (hi - lo) ./ rng
        end
        deg_sizes_leg = scale_markers_with_bounds_local(deg_samples; lo = 6.0, hi = 20.0)
        splits        = sort(unique(df.Split))

        # ensure memory order (only those that exist in data)
        memvals   = sort(unique(string.(df.memory)))              # e.g. ["lut","ram"]
        mem_order = filter(m -> m in memvals, ["lut","ram"])
        mem_name  = Dict("lut" => "LUT", "ram" => "RAM")
        n_deg     = length(deg_samples)
        n_mem     = length(mem_order)

        # Legend grid across the second row of the figure
        t = GridLayout(fig_lg[1, 1:3]; tellheight=false, padding=(0,0,0,0))
        rowgap!(t, 0); colgap!(t, 10)

        Label(t[1, 1], "Degree";
              font=:bold, halign=:center, valign=:bottom,
              tellheight=false, padding=(0,0,0,0))
        # ----- Column headers: Degree numbers (bold), each spanning its two mem sub-columns
        for (j, d) in enumerate(deg_samples)
            startcol = 2 + (j-1)*n_mem
            endcol   = startcol + n_mem - 1
            Label(t[1, startcol:endcol], string(d);
                  halign=:center, valign=:bottom,
                  tellheight=false, padding=(0,0,0,0))
        end

        Label(t[2, 1], "Memory";
              halign=:center, valign=:bottom,
              font=:bold,
              tellheight=false, padding=(0,0,0,0))

        # ----- Second header row: memory sub-columns under each degree
        for (j, _) in enumerate(deg_samples)
            startcol = 2 + (j-1)*n_mem
            for (k, mem) in enumerate(mem_order)
                Label(t[2, startcol + (k-1)], mem_name[mem];
                      halign=:center, valign=:bottom,
                      tellheight=false, padding=(0,0,0,0))
            end
        end

        # ----- Body: one row per Split; cells = one marker (memory shape, split color, degree size)
        for (i, s) in enumerate(reverse(splits))
            row = 2 + i  # rows start after the 2 header rows
            # split label
            Label(t[row, 1], "Split=$(s)";
                  halign=:right, valign=:center, tellheight=false, padding=(0,6,0,0))

            for (j, sz) in enumerate(deg_sizes_leg)
                startcol = 2 + (j-1)*n_mem
                for (k, mem) in enumerate(mem_order)
                    degval = deg_samples[j]
                    is_marked = ((mem, s, degval) in legend_highlights)
                    axsym = Axis(t[row, startcol + (k-1)];
                                 backgroundcolor=:transparent,
                                 xticksvisible=false, yticksvisible=false,
                                 xgridvisible=false, ygridvisible=false,
                                 xminorgridvisible=false, yminorgridvisible=false,
                                 xminorticksvisible=false, yminorticksvisible=false,
                                 leftspinevisible=false, rightspinevisible=false,
                                 topspinevisible=false, bottomspinevisible=false,
                                 alignmode=Makie.Outside())
                    hidexdecorations!(axsym; grid=false)
                    hideydecorations!(axsym; grid=false)
                    xlims!(axsym, 0, 1); ylims!(axsym, 0, 1)
                    scatter!(axsym, [0.5], [0.5]; marker = marker_map[mem], color = split_color[s], markersize = sz)
                    if is_marked
                        scatter!(axsym, [0.5], [0.5]; marker = :circle, color = :transparent,
                                 markersize = sz + 5.0, strokecolor = :red, strokewidth = 1)
                    end
                end
            end
        end

        # Let the legend row collapse to content height
        rowsize!(fig_lg.layout, 1, Auto())

        save("build_plots/estimations/$(toolchain)/$(approximation).pdf", fig)
        save("build_plots/estimations/$(toolchain)/$(approximation)_legend.pdf", fig_lg)
      end
    end
end

ensure_estimation_dirs() = (mkpath("build_plots/estimations"); mkpath("build_plots/estimations/Vitis"); mkpath("build_plots/estimations/oneAPI"))

function main()
    ensure_estimation_dirs()
    make_erf_approximation_multifigure()
    generate_all_estimation_plots()
end

main()
