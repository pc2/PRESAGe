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
using CSV, DataFrames
using CairoMakie
using GridLayoutBase: Relative, Auto, Fixed, rowsize!, colsize!, rowgap!, colgap!

totals = Dict(
    "oneAPI" => Dict(
        "ALUTs" => 933120,
        "FFs" => 3732480,
        "RAMs" => 11721,
        "DSPs" => 5011,
    ),
    "Vitis" => Dict(
        "LUT" => 1303680,
        "FF" => 2607360,
        "BRAM" => 4032,
        "DSP" => 9024,
    )
)

metrics_order = Dict(
    "oneAPI" => ["ALUTs", "FFs", "RAMs", "DSPs"],
    "Vitis" => ["LUT", "FF", "BRAM", "DSP"],
)

eticks_map = Dict(
    "single" => [-23, -21, -19, -17, -15, -13],
    "double" => [-52, -46, -40, -34, -28, -23],
)

function transform_label(l, precision)
    if l == "sun_erf"
        rich("$(l)")
    elseif occursin("_", l)
        splitted = split(l, '_')
        var = try
            parse(Int, splitted[end])
        catch
            0
        end
        rich(
            " approx. ",
            string(splitted[1]),
            " (2",
            superscript(string(eticks_map["single"][var+1])),
            "|2",
            superscript(string(eticks_map["double"][var+1])),
            ")"
        )
    else
        rich("library $(l)")
    end
end

"""
    plot_resources!(parent, df, df_max_d, toolchain, precision, eticks, dlabel; title="")

Render the resources plot into an existing grid position `parent`.
This is a refactor of the previous `plot_resources` that created and saved
its own figure. Now, the caller is responsible for building the multi-figure
and saving the result; this function only renders into the provided slot.
"""
function plot_resources!(parent, df, df_max_d, toolchain, precision, eticks, dlabel; title="", show_xticks::Bool=true)
    metrics = metrics_order[toolchain]
    groups  = String.(df.Operation)
    is_sun_group = groups .== "sun_erf"

    # matrix of actual values
    vals = [Float64(df[i, Symbol(m)]) for i in 1:nrow(df), m in metrics]

    # normalize per metric column → percentage values
    perc_vals = [vals[i, j] / totals[toolchain][m] * 100 for i in 1:nrow(df), (j, m) in enumerate(metrics)]

    # --- Plot ---
    # create a nested layout inside `parent` so we can manage broken axes cleanly
    gl = GridLayout()
    gl.default_rowgap = Fixed(2)
    parent[1, 1] = gl

    n_groups  = length(groups)
    n_metrics = length(metrics)
    n_total   = n_metrics + 1              # +1 slot per group reserved for the boxplot
    group_width = 0.9                      # a touch wider; adjust to taste
    bar_width   = group_width / n_total
    x_centers   = 1:n_groups
    palette     = Makie.wong_colors()[1:n_metrics]

    # helper for slot-centered x positions
    xslot(xc, j, total) = xc + ((j - (total + 1)/2) * bar_width)

    ymax = maximum(perc_vals)
    has_break = ymax > 10.0
    # compute tight x-limits spanning from first bar to last box slot
    left_edge  = xslot(first(x_centers), 1, n_total) - bar_width/2
    right_edge = xslot(last(x_centers), n_total, n_total) + bar_width/2

    ax, ax2 = if has_break
        ax_top = Axis(gl[1, 1];
                      ylabel = "Usage [%]",
                      xticklabelrotation = π/16,
                      xticks=1:n_groups,
                      xticklabelsize=8,
                      yticklabelsize=8,
                      xlabelsize=9,
                      ylabelsize=9)
        hidespines!(ax_top, :b)
        ax_top.ygridstyle[] = :dash
        ax_bot = Axis(gl[2, 1];
                      xticks=(1:n_groups, transform_label.(groups, precision)), 
                      xticklabelrotation = π/16,
                      xticklabelsize=8,
                      yticklabelsize=8,
                      xlabelsize=9,
                      ylabelsize=9)
        hidespines!(ax_bot, :t)
        ax_bot.ygridstyle[] = :dash
        # defer linking until the spanning right axis is created
        hidexdecorations!(ax_top; grid=false)
        # favor the lower axis height for readability
        rowsize!(gl, 1, Relative(0.45))
        rowsize!(gl, 2, Relative(0.55))
        # increase the visual break between axes to ~one fontsize
        rowgap!(gl, Fixed(10))
        ylims!(ax_bot, 0, 5)
        ylims!(ax_top, 10, ymax * 1.15)
        # we'll enforce final x-limits after creating/linking all axes


        # trackers to avoid overlapping labels within each group for each axis
        last_y_bot = fill(-Inf, n_groups)
        last_y_top = fill(-Inf, n_groups)

        for (j, metric) in enumerate(metrics)
            x     = [xslot(xc, j, n_total) for xc in x_centers]
            yperc = [perc_vals[i, j] for i in 1:n_groups]
            # draw bars first
            barplot!(ax_bot, x, yperc; width=bar_width, color=palette[j], label=nothing)
            barplot!(ax_top, x, yperc; width=bar_width, color=palette[j], label=metric)
        end

        # Place labels per group following a simple neighbor-based staggering rule
        yoff_low   = 0.02 * 5.0
        yoff_high  = 0.02 * max(ymax - 10.0, 1e-6)
        step_bot   = 0.05 * 5.0      # half-step (~half font height)
        step_top   = 0.05 * max(ymax - 10.0, 1e-6)
        for i in 1:n_groups
            prev_axis = nothing
            prev_y_adj = NaN
            prev_move  = :none  # :up | :down | :none
            for j in 1:n_metrics
                av = vals[i, j]
                if is_sun_group[i] && abs(av) <= 1e-9
                    continue
                end
                yv = perc_vals[i, j]
                lbl = string(Int(round(av; digits=0)))
                x = xslot(i, j, n_total)
                # base position and target axis
                on_top = yv >= 10.0 - 1e-9
                if yv <= 5.0 + 1e-9
                    y = min(yv + yoff_low, 5.0 - 0.02)
                    axis_tgt = :bot
                elseif on_top
                    y = yv + yoff_high
                    axis_tgt = :top
                else
                    y = 5.0 - 0.10
                    axis_tgt = :bot
                end

                # special case: very first bar at the far left → nudge right by digits
                dx = 0.0
                if i == 1 && j == 1
                    dx = length(lbl) * 0.08 * bar_width
                end

                # neighbor rule: adjust only if overlapping with the previous label on the same axis
                if j > 1 && prev_axis == axis_tgt && isfinite(prev_y_adj)
                    step = axis_tgt == :bot ? step_bot : step_top
                    base_y = y
                    overlap = abs(base_y - prev_y_adj) < step * 0.8
                    if overlap
                        if base_y < prev_y_adj
                            y = prev_y_adj - step
                            prev_move = :down
                        else
                            y = prev_y_adj + step
                            prev_move = :up
                        end
                    else
                        prev_move = :none
                    end
                else
                    prev_move = :none
                end
                # never go below y=0 when staggering downward
                if axis_tgt == :bot
                    y = max(y, 0.0)
                end

                if axis_tgt == :bot
                    text!(ax_bot, lbl; position=(x + dx, y), align=(:center, :bottom), fontsize=8)
                else
                    text!(ax_top, lbl; position=(x + dx, y), align=(:center, :bottom), fontsize=8)
                end
                prev_axis = axis_tgt
                prev_y_adj = y
            end
        end

        #lines!(ax_bot, [-0.1, 0.1], [4.9, 5.1]; color=:black, linewidth=2)
        #lines!(ax_top, [-0.1, 0.1], [9.9, 10.1]; color=:black, linewidth=2)

        if !show_xticks
            hidexdecorations!(ax_bot; grid=false)
        end
        ax_bot, ax_top
    else
        ax = Axis(gl[1, 1],
            ylabel = "Usage [%]",
            xticks = (1:length(groups), transform_label.(groups, precision)),
            xticklabelrotation = π/16,
            xticklabelsize=8,
            yticklabelsize=8,
            xlabelsize=9,
            ylabelsize=9,
        )
        ax.ygridstyle[] = :dash

        for (j, metric) in enumerate(metrics)
            x     = [xslot(xc, j, n_total) for xc in x_centers]
            yperc = [perc_vals[i, j] for i in 1:n_groups]
            barplot!(ax, x, yperc; width=bar_width, color=palette[j], label=metric)
        end

        # Place labels per group with simple neighbor staggering
        yoff = 0.02 * max(ymax, 1e-6)
        step = 0.06 * max(ymax, 1e-6)
        for i in 1:n_groups
            prev_y_adj = NaN
            prev_move = :none
            for j in 1:n_metrics
                av = vals[i, j]
                if is_sun_group[i] && abs(av) <= 1e-9
                    continue
                end
                base_y = perc_vals[i, j] + yoff
                lbl = isinteger(av) ? string(Int(av)) : string(av)
                x = xslot(i, j, n_total)
                dx = (i == 1 && j == 1) ? (length(lbl) * 0.08 * bar_width) : 0.0
                y = base_y
                if j > 1 && isfinite(prev_y_adj)
                    overlap = abs(base_y - prev_y_adj) < step * 0.8
                    if overlap
                        if base_y < prev_y_adj
                            y = prev_y_adj - step
                            prev_move = :down
                        else
                            y = prev_y_adj + step
                            prev_move = :up
                        end
                    else
                        prev_move = :none
                    end
                end
                # clamp to y >= 0 in the single-axis case as well
                y = max(y, 0.0)
                text!(ax, lbl; position=(x + dx, y), align=(:center, :bottom), fontsize=8)
                prev_y_adj = y
            end
        end

        if !show_xticks
            hidexdecorations!(ax; grid=false)
        end
        ylims!(ax, 0, ymax * 1.15)
        xlims!(ax, left_edge, right_edge)
        ax, nothing
    end

    # right-hand log-scaled axis (unchanged)
    yticks = if eticks == nothing
        Makie.automatic
    else
        ([2.0^e for e in eticks], [rich("2", superscript(string(e))) for e in eticks])
    end
    # overlay the deviation axis; if we have a break, span both rows
    if has_break
        ax_deviation = Axis(gl[1:2, 1];
                             yaxisposition=:right,
                             backgroundcolor=:transparent,
                             rightspinecolor=Makie.wong_colors()[5],
                             yscale=log2,
                             yticks=yticks,
                             ylabel=dlabel,
                             xticklabelsize=8,
                             yticklabelsize=8,
                             xlabelsize=9,
                             ylabelsize=9)
        hidespines!(ax_deviation, :l)
        hidexdecorations!(ax_deviation)
        # Link all three at once to avoid breaking previous links
        linkxaxes!(ax_top, ax_bot, ax_deviation)
    else
        ax_dev = Axis(gl[1, 1];
                      yaxisposition=:right,
                      backgroundcolor=:transparent,
                      rightspinecolor=Makie.wong_colors()[5],
                      yscale=log2,
                      yticks=yticks,
                      ylabel=dlabel,
                      xticklabelsize=8,
                      yticklabelsize=8,
                      xlabelsize=9,
                      ylabelsize=9)
        hidespines!(ax_dev, :l)
        hidexdecorations!(ax_dev)
        linkxaxes!(ax, ax_dev)
        ax_deviation = ax_dev
    end

    # --- place the boxplot as the (n_total)th slot in each group, width = bar_width ---
    for (i, df_group) in enumerate(groupby(df_max_d, :name))
        x_box = xslot(x_centers[i], n_total, n_total)
        boxplot!(ax_deviation,
                 fill(x_box, nrow(df_group)),
                 df_group.Value;
                 color=Makie.wong_colors()[5],
                 width=bar_width,
                 markersize=4,
                 label=nothing)
    end

    for i in 1:2:n_groups
        rect = Rect(i-0.5, 0, 1, ymax*1.15)
        poly!(ax, rect; color=(:gray, 0.30), strokewidth=0)
        if has_break
            poly!(ax2, rect; color=(:gray, 0.30), strokewidth=0)
        end
    end

    # Enforce final shared x-limits after all plots and links.
    if has_break
        xlims!(ax_deviation, left_edge, right_edge)
    else
        xlims!(ax, left_edge, right_edge)
        xlims!(ax_deviation, left_edge, right_edge)
    end

    # overlay a small title inside the same cell (no extra layout space)
    if !isempty(title)
        Label(gl[1, 1, Makie.Top()], title; fontsize=10, tellwidth=false, tellheight=false, padding=(0, 0, 10, 0))
    end

    return isnothing(ax2) ? ax : ax2
end

filter_max_abs(df, precision) = df[(df.Precision .== precision) .& (df.DType .== "absolute") .& (df.Exponent .<= 4) .& (df.Exponent .>= -25), :]
#filter_max_rel(df, precision) = df[(df.Precision .== precision) .& (df.DType .== "relative") .& (df.Exponent .<= 4) .& (df.Exponent .>= -25), :]
filter_max_rel(df, precision) = df[(df.Precision .== precision) .& (df.DType .== "relative"), :]

function load_toolchain_data(toolchain)
    df = CSV.read("$(toolchain)/unitary_approx_overview.csv", DataFrame)
    if toolchain == "oneAPI"
        df.ALUTs += 20 * df.MLABs
        df.DSPs += 0.5 * df.FracDSPs
    end
    df_lib = CSV.read("$(toolchain)/unitary_lib_overview.csv", DataFrame)
    df_lib.strategy .= 0
    if toolchain == "oneAPI"
        df_lib.ALUTs += 20 * df_lib.MLABs
        df_lib.DSPs += 0.5 * df_lib.FracDSPs
    end
    return df, df_lib
end

function prepare_erf_group(toolchain, precision, f)
    df, df_lib = load_toolchain_data(toolchain)

    df_erf = filter(:Operation => x -> startswith(String(x), "$(f)_approximation_"), df)
    df_erf = filter(:Precision => ==(precision), df_erf)
    transform!(groupby(df_erf, :Operation), :strategy => minimum => :strategy_min)
    df_pick = innerjoin(df_erf, unique(df_erf[:, [:Operation, :strategy_min]]);
                        on=[:Operation => :Operation, :strategy => :strategy_min])
    select!(df_pick, Not(:strategy_min))

    # order by numeric suffix
    op_order_key(op::AbstractString) = (m = match(r".*_(\d+)$", op); isnothing(m) ? typemax(Int) : parse(Int, m.captures[1]))
    sort!(df_pick, :Operation, by=op_order_key)

    df_lib_erf = filter(:Precision => ==(precision), df_lib)
    if precision == "single" || f == "erfc" || toolchain == "Vitis"
        df_lib_erf = filter(:Operation => ==("$(f)"), df_lib_erf)
    else
        df_lib_erf = filter(:Operation => op -> op == "sun_erf" || op == "$(f)", df_lib_erf)
    end

    # For erf plots, ensure a consistent empty slot for sun_erf when it's not present
    if f == "erf"
        has_sun = any(op -> op == "sun_erf", df_lib_erf.Operation)
        if !has_sun
            if nrow(df_lib_erf) > 0
                # clone an existing library row and zero out resource metrics
                newrow = deepcopy(df_lib_erf[1, :])
                newrow.Operation = "sun_erf"
                for m in metrics_order[toolchain]
                    newrow[Symbol(m)] = 0
                end
                push!(df_lib_erf, newrow)
            end
        end
        # enforce library order: erf first, sun_erf second
        df_lib_erf = vcat(filter(:Operation => ==("$(f)"), df_lib_erf),
                          filter(:Operation => ==("sun_erf"), df_lib_erf))
    end

    df_pick_max_d_list = []
    for i in 0:5
        name = if toolchain == "oneAPI"
            "$(f)_approximation_$(i)"
        else
            "$(f)_approximation_$(precision)_$(i)"
        end
        df_max_d = CSV.read("build_max_deviations/$(toolchain)/$(name).csv", DataFrame)
        df_max_d.name .= name
        push!(df_pick_max_d_list, filter_max_abs(df_max_d, precision))
    end

    df_erf_max_d = CSV.read("build_max_deviations/$(toolchain)/$(f).csv", DataFrame)
    df_erf_max_d.name .= "$(f)"
    df_erf_max_d_filtered = filter_max_abs(df_erf_max_d, precision)
    push!(df_pick_max_d_list,  df_erf_max_d_filtered)

    if precision == "double" && f == "erf" && toolchain == "oneAPI"
        df_sun_erf_max_d = CSV.read("build_max_deviations/$(toolchain)/sun_erf.csv", DataFrame)
        df_sun_erf_max_d.name .= "sun_erf"
        df_filtered = filter_max_abs(df_sun_erf_max_d, precision)
        push!(df_pick_max_d_list, df_filtered)
    end

    eticks = if toolchain == "oneAPI" && precision == "double"
        [eticks_map[precision]; -13]
    else
        eticks_map[precision]
    end

    return vcat(df_pick, df_lib_erf), vcat(df_pick_max_d_list...), eticks, "Maximum Absolute Error per Input Binade"
end

function prepare_group(toolchain, precision, g::Vector{String}; relative=false)
    df, df_lib = load_toolchain_data(toolchain)
    df_pick = DataFrame[]
    for f in g
        push!(df_pick, df[(df.Precision .== precision) .&& (occursin.("$(f)_approximation", df.Operation) .&& (df.strategy .== 0)), :])
        push!(df_pick, df_lib[(df_lib.Precision .== precision) .&& (df_lib.Operation .== f), :])
    end
    df_pick_max_d = DataFrame[]
    for f in g
        name = if toolchain == "oneAPI"
            "$(f)_approximation"
        else
            "$(f)_approximation_$(precision)"
        end
        df_max_d_approx = CSV.read("build_max_deviations/$(toolchain)/$(name).csv", DataFrame)
        df_max_d_approx.name .= name
        if relative
            push!(df_pick_max_d, filter_max_rel(df_max_d_approx, precision))
        else
            push!(df_pick_max_d, filter_max_abs(df_max_d_approx, precision))
        end

        df_max_d_lib = CSV.read("build_max_deviations/$(toolchain)/$(f).csv", DataFrame)
        df_max_d_lib.name .= "$(f)"
        if relative
            push!(df_pick_max_d, filter_max_rel(df_max_d_lib, precision))
        else
            push!(df_pick_max_d, filter_max_abs(df_max_d_lib, precision))
        end
    end

    dlabel = relative ? "Maximum Relative Error per Input Binade" : "Maximum Absolute Error per Input Binade"
    return vcat(df_pick...), vcat(df_pick_max_d...), nothing, dlabel
end

function ensure_outdir()
    try
        mkpath("build_plots/resources")
    catch
    end
end

function make_multifig_erf_like(f::String)
    ensure_outdir()
    fig = Figure(size=(595, 842))  # A4 portrait in points

    rows = [("Vitis", "single"), ("Vitis", "double"), ("oneAPI", "single"), ("oneAPI", "double")]
    axes_for_leg = Any[]
    for (i, (toolchain, precision)) in enumerate(rows)
        df_comb, df_max_d, eticks, dlabel = prepare_erf_group(toolchain, precision, f)
        title = "$(toolchain) - $(precision)"
        ax_for_legend = plot_resources!(fig[i, 1], df_comb, df_max_d, toolchain, precision, eticks, dlabel; title=title, show_xticks=(i == length(rows)))
        push!(axes_for_leg, ax_for_legend)
    end

    # remove inter-row spacing and set compact fixed row heights to fit A4 (no extra legend rows)
    fig.layout.default_rowgap = Fixed(0)
    fig.layout.default_colgap = Fixed(0)
    rowsize!(fig.layout, 1, Fixed(160))
    rowsize!(fig.layout, 2, Fixed(160))
    rowsize!(fig.layout, 3, Fixed(160))
    rowsize!(fig.layout, 4, Fixed(200))  # give extra room for bottom x labels
    colsize!(fig.layout, 1, Relative(1))

    # Add two shared legends that do not consume layout space: overlay blocks
    # Place at the top of the lower row and nudge downward slightly
    leg1 = Legend(fig, axes_for_leg[1]; orientation=:horizontal, patchsize=(6,6), labelsize=8, padding=(220,0,30,0), framevisible=false)
    leg1.tellwidth = false; leg1.tellheight = false
    fig[2, 1, Makie.TopLeft()] = leg1
    translate!(leg1.blockscene, 0, -6)  # move a bit lower

    leg2 = Legend(fig, axes_for_leg[3]; orientation=:horizontal, patchsize=(6,6), labelsize=8, padding=(220,0,30,0), framevisible=false)
    leg2.tellwidth = false; leg2.tellheight = false
    fig[4, 1, Makie.TopLeft()] = leg2
    translate!(leg2.blockscene, 0, -6)

    save("build_plots/resources/$(f)_resources_multifigure.pdf", fig)
end

function make_multifig_group(g::Vector{String}; name::String, relative=false)
    ensure_outdir()
    fig = Figure(size=(595, 842))  # A4 portrait in points

    rows = [("Vitis", "single"), ("Vitis", "double"), ("oneAPI", "single"), ("oneAPI", "double")]
    axes_for_leg = Any[]
    for (i, (toolchain, precision)) in enumerate(rows)
        df_comb, df_max_d, eticks, dlabel = prepare_group(toolchain, precision, g; relative=relative)
        title = "$(toolchain) - $(precision)"
        ax_for_legend = plot_resources!(fig[i, 1], df_comb, df_max_d, toolchain, precision, eticks, dlabel; title=title, show_xticks=(i == length(rows)))
        push!(axes_for_leg, ax_for_legend)
    end

    # remove inter-row spacing and set compact fixed row heights to fit A4 (no extra legend rows)
    fig.layout.default_rowgap = Fixed(0)
    fig.layout.default_colgap = Fixed(0)
    rowsize!(fig.layout, 1, Fixed(160))
    rowsize!(fig.layout, 2, Fixed(160))
    rowsize!(fig.layout, 3, Fixed(160))
    rowsize!(fig.layout, 4, Fixed(200))  # give extra room for bottom x labels
    colsize!(fig.layout, 1, Relative(1))

    # Two shared legends overlaid as blocks at the top of lower rows
    leg1 = Legend(fig, axes_for_leg[1]; orientation=:horizontal, patchsize=(6,6), labelsize=8, padding=(220,0,30,0), framevisible=false)
    leg1.tellwidth = false; leg1.tellheight = false
    fig[2, 1, Makie.TopLeft()] = leg1
    translate!(leg1.blockscene, 0, -6)

    leg2 = Legend(fig, axes_for_leg[3]; orientation=:horizontal, patchsize=(6,6), labelsize=8, padding=(220,0,30,0), framevisible=false)
    leg2.tellwidth = false; leg2.tellheight = false
    fig[4, 1, Makie.TopLeft()] = leg2
    translate!(leg2.blockscene, 0, -6)

    save("build_plots/resources/$(name)_resources_multifigure.pdf", fig)
end

# --- Build the four multi-figures (each with 4 rows toolchain×precision) ---
make_multifig_erf_like("erf")
make_multifig_erf_like("erfc")
make_multifig_group(["cos", "sin", "atan"]; name="cos_sin_atan", relative=false)
make_multifig_group(["exp", "cosh", "sinh"]; name="exp_cosh_sinh", relative=true)
