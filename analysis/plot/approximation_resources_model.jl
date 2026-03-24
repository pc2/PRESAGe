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
using CSV, DataFrames, JSON
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

# Per-FMA costs from generator cost model (toolchain × format)
const LUTS_PER_FMA = Dict(
    "Vitis" => Dict("single" => 276, "double" => 762),
    "oneAPI" => Dict("single" => 64,  "double" => 2850),
)
const FFS_PER_FMA = Dict(
    "Vitis" => Dict("single" => 461, "double" => 1073),
    "oneAPI" => Dict("single" => 128, "double" => 389),
)

# Reduction costs measured from synthesis (from resources_reductions.tex)
const REDUCTIONS = Dict(
    "boundary" => Dict(
        "Vitis" => Dict("single" => (LUT=189,  FF=69,   DSP=0,  RAM=0),  "double" => (LUT=283,   FF=264,  DSP=0,  RAM=0)),
        "oneAPI" => Dict("single" => (LUT=110,  FF=36,   DSP=0,  RAM=0),  "double" => (LUT=219,   FF=6,    DSP=0,  RAM=0)),
    ),
    "symmetry" => Dict(
        "Vitis" => Dict("single" => (LUT=71,   FF=0,    DSP=0,  RAM=0),  "double" => (LUT=134,   FF=0,    DSP=0,  RAM=0)),
        "oneAPI" => Dict("single" => (LUT=1,    FF=0,    DSP=0,  RAM=0),  "double" => (LUT=191,   FF=0,    DSP=0,  RAM=0)),
    ),
    "periodic" => Dict(
        "Vitis" => Dict("single" => (LUT=3171, FF=1884, DSP=12, RAM=0),  "double" => (LUT=4475,  FF=7545, DSP=25, RAM=0)),
        "oneAPI" => Dict("single" => (LUT=1074, FF=131,  DSP=1,  RAM=0),  "double" => (LUT=6965,  FF=1729, DSP=0,  RAM=0)),
    ),
    "exponential" => Dict(
        "Vitis" => Dict("single" => (LUT=1599, FF=1391, DSP=11, RAM=0),  "double" => (LUT=3272,  FF=3190, DSP=27, RAM=0)),
        "oneAPI" => Dict("single" => (LUT=1208, FF=615,  DSP=3,  RAM=0),  "double" => (LUT=9917,  FF=4326, DSP=4,  RAM=0)),
    ),
    "hyperbolic" => Dict(
        "Vitis" => Dict("single" => (LUT=549,  FF=1406, DSP=8,  RAM=0),  "double" => (LUT=1115,  FF=2103, DSP=19, RAM=0)),
        "oneAPI" => Dict("single" => (LUT=940,  FF=553,  DSP=7,  RAM=6),  "double" => (LUT=12594, FF=6279, DSP=32, RAM=40)),
    ),
)

# Polynomial multiplier and active reductions per function
# poly_reductions: instantiated once per polynomial (scaled by poly_mult)
# reductions: instantiated once per function (not scaled)
const FUNCTION_MODEL = Dict(
    "cos"  => (poly_mult=1, poly_reductions=String[],         reductions=["periodic", "boundary"]),
    "sin"  => (poly_mult=1, poly_reductions=String[],         reductions=["periodic", "boundary"]),
    "atan" => (poly_mult=1, poly_reductions=String[],         reductions=["symmetry", "boundary"]),
    "exp"  => (poly_mult=1, poly_reductions=String[],         reductions=["exponential", "boundary"]),
    "cosh" => (poly_mult=2, poly_reductions=["exponential"],  reductions=["hyperbolic", "boundary"]),
    "sinh" => (poly_mult=2, poly_reductions=["exponential"],  reductions=["hyperbolic", "boundary"]),
    "erf"  => (poly_mult=1, poly_reductions=String[],         reductions=["symmetry", "boundary"]),
    "erfc" => (poly_mult=1, poly_reductions=String[],         reductions=["boundary"]),
)

"""
Hardcoded list of model-estimation CSV files provided for both toolchains.
We build a toolchain→function→precision mapping from this list and use it to
load model estimates without scanning the filesystem.
"""
const MODEL_FILE_LIST = [
    # oneAPI
    "oneAPI/build_atan_approximation_0/f_atan_x__double__0_8__64_7.csv",
    "oneAPI/build_atan_approximation_0/f_atan_x__single__0_8__8_6.csv",
    "oneAPI/build_cos_approximation_0/f_cos_x__double__0_3_141592653589793115997963468544185161590576171875__48_6.csv",
    "oneAPI/build_cos_approximation_0/f_cos_x__single__0_3_1415927410125732421875__5_5.csv",
    "oneAPI/build_cosh_approximation_0/cosh_exp_x__double___1_1__32_5.csv",
    "oneAPI/build_cosh_approximation_0/cosh_exp_x__single___1_1__6_3.csv",
    "oneAPI/build_erf_approximation_0_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__55_7.csv",
    "oneAPI/build_erf_approximation_0_0/f_erf_x__single__0_3_9200000762939453125__6_6.csv",
    "oneAPI/build_erf_approximation_1_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__57_6.csv",
    "oneAPI/build_erf_approximation_1_0/f_erf_x__single__0_3_9200000762939453125__6_5.csv",
    "oneAPI/build_erf_approximation_2_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__61_5.csv",
    "oneAPI/build_erf_approximation_2_0/f_erf_x__single__0_3_9200000762939453125__5_5.csv",
    "oneAPI/build_erf_approximation_3_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__67_4.csv",
    "oneAPI/build_erf_approximation_3_0/f_erf_x__single__0_3_9200000762939453125__6_4.csv",
    "oneAPI/build_erf_approximation_4_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__72_3.csv",
    "oneAPI/build_erf_approximation_4_0/f_erf_x__single__0_3_9200000762939453125__5_4.csv",
    "oneAPI/build_erf_approximation_5_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__31_3.csv",
    "oneAPI/build_erf_approximation_5_0/f_erf_x__single__0_3_9200000762939453125__3_4.csv",
    "oneAPI/build_erfc_approximation_0_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__76_8.csv",
    "oneAPI/build_erfc_approximation_0_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__7_8.csv",
    "oneAPI/build_erfc_approximation_1_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__115_6.csv",
    "oneAPI/build_erfc_approximation_1_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__7_7.csv",
    "oneAPI/build_erfc_approximation_2_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__65_6.csv",
    "oneAPI/build_erfc_approximation_2_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__11_5.csv",
    "oneAPI/build_erfc_approximation_3_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__63_5.csv",
    "oneAPI/build_erfc_approximation_3_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__7_6.csv",
    "oneAPI/build_erfc_approximation_4_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__57_4.csv",
    "oneAPI/build_erfc_approximation_4_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__7_5.csv",
    "oneAPI/build_erfc_approximation_5_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__63_3.csv",
    "oneAPI/build_erfc_approximation_5_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__7_4.csv",
    "oneAPI/build_exp_approximation_0/exp_exp_x__double___1_1__32_5.csv",
    "oneAPI/build_exp_approximation_0/exp_exp_x__single___1_1__6_3.csv",
    "oneAPI/build_sin_approximation_0/f_sin_x__double__0_3_141592653589793115997963468544185161590576171875__46_6.csv",
    "oneAPI/build_sin_approximation_0/f_sin_x__single__0_3_1415927410125732421875__3_6.csv",
    "oneAPI/build_sinh_approximation_0/sinh_exp_x__double___1_1__32_5.csv",
    "oneAPI/build_sinh_approximation_0/sinh_exp_x__single___1_1__6_3.csv",
    # Vitis
    "Vitis/build_approximations_0/cosh_exp_x__double___1_1__32_5.csv",
    "Vitis/build_approximations_0/cosh_exp_x__single___1_1__6_3.csv",
    "Vitis/build_approximations_0/exp_exp_x__double___1_1__32_5.csv",
    "Vitis/build_approximations_0/exp_exp_x__single___1_1__6_3.csv",
    "Vitis/build_approximations_0/f_atan_x__double__0_8__42_8.csv",
    "Vitis/build_approximations_0/f_atan_x__single__0_8__17_4.csv",
    "Vitis/build_approximations_0/f_cos_x__double__0_3_141592653589793115997963468544185161590576171875__23_7.csv",
    "Vitis/build_approximations_0/f_cos_x__single__0_3_1415927410125732421875__9_4.csv",
    "Vitis/build_approximations_0/f_sin_x__double__0_3_141592653589793115997963468544185161590576171875__23_7.csv",
    "Vitis/build_approximations_0/f_sin_x__single__0_3_1415927410125732421875__11_4.csv",
    "Vitis/build_approximations_0/sinh_exp_x__double___1_1__32_5.csv",
    "Vitis/build_approximations_0/sinh_exp_x__single___1_1__6_3.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__28_4.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__31_3.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__31_5.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__32_6.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__35_7.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__double__0_5_92999999999999971578290569595992565155029296875__55_7.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__single__0_3_9200000762939453125__10_3.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__single__0_3_9200000762939453125__15_3.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__single__0_3_9200000762939453125__15_4.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__single__0_3_9200000762939453125__22_3.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__single__0_3_9200000762939453125__6_3.csv",
    "Vitis/build_erf_approximations_0/f_erf_x__single__0_3_9200000762939453125__8_3.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__33_4.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__39_6.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__43_7.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__44_8.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__57_4.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__double___5_87000000000000010658141036401502788066864013671875_27_25__76_8.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__13_3.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__17_3.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__17_4.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__21_3.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__22_4.csv",
    "Vitis/build_erfc_approximations_0/f_erfc_x__single___3_8399999141693115234375_10_06000041961669921875__31_4.csv",
]

# Build toolchain→function→precision→[files]
const MODEL_FILES = let
    d = Dict{String, Dict{String, Dict{String, Vector{String}}}}()
    function ensure_tmap!(dd::Dict{String, Dict{String, Dict{String, Vector{String}}}}, k::String)
        haskey(dd, k) || (dd[k] = Dict{String, Dict{String, Vector{String}}}())
        return dd[k]
    end
    function ensure_fmap!(dd::Dict{String, Dict{String, Vector{String}}}, k::String)
        haskey(dd, k) || (dd[k] = Dict{String, Vector{String}}())
        return dd[k]
    end
    function add_model_file!(toolchain::String, f::String, precision::String, path::String)
        tmap = ensure_tmap!(d, toolchain)
        fmap = ensure_fmap!(tmap, f)
        haskey(fmap, precision) || (fmap[precision] = String[])
        Base.push!(fmap[precision], path)
    end
    for p in MODEL_FILE_LIST
        toolchain = startswith(p, "oneAPI/") ? "oneAPI" : startswith(p, "Vitis/") ? "Vitis" : continue
        b = split(p, '/')[end]
        # precision
        precision = occursin("__double__", b) ? "double" : occursin("__single__", b) ? "single" : begin
            # fallback if precision not captured by __double__/__single__ (should not happen)
            occursin("double", b) ? "double" : occursin("single", b) ? "single" : "single"
        end
        # function name
        f = if occursin("f_", b)
            m = match(r"f_([a-z]+)_x", b); isnothing(m) ? nothing : String(m.captures[1])
        elseif occursin("exp_exp_x", b)
            "exp"
        elseif occursin("cosh_exp_x", b)
            "cosh"
        elseif occursin("sinh_exp_x", b)
            "sinh"
        else
            nothing
        end
        isnothing(f) && continue
        add_model_file!(toolchain, f, precision, p)
    end
    d
end

function list_model_csvs_fixed(toolchain::String, f::String, precision::String)
    haskey(MODEL_FILES, toolchain) || return String[]
    tmap = MODEL_FILES[toolchain]
    haskey(tmap, f) || return String[]
    fmap = tmap[f]
    haskey(fmap, precision) || return String[]
    return fmap[precision]
end

function get_model_estimate_row(toolchain::String, f::String, precision::String; accuracy_level::Union{Nothing,Int}=nothing)
    files = list_model_csvs_fixed(toolchain, f, precision)
    isempty(files) && error("No model CSV files for toolchain=$(toolchain) f=$(f) precision=$(precision)")

    # Filter by accuracy level for erf/erfc
    if !isnothing(accuracy_level)
        if toolchain == "oneAPI"
            pattern = "build_$(f)_approximation_$(accuracy_level)_"
            files = filter(p -> occursin(pattern, p), files)
        elseif toolchain == "Vitis"
            seg_of(p) = (m = match(r"__(\d+)_\d+\.csv$", p); isnothing(m) ? 0 : parse(Int, m.captures[1]))
            sorted = sort(files, by=seg_of, rev=true)
            if accuracy_level < length(sorted)
                files = [sorted[accuracy_level + 1]]
            end
        end
    end
    isempty(files) && error("No model CSV files after filtering for accuracy_level=$(accuracy_level)")

    best = nothing
    best_luts = typemax(Int)
    for path in files
        dfm = CSV.read(path, DataFrame)
        cols_ok = all(x -> x in Symbol.(names(dfm)), [:LUTs, :FFs, :RAMs, :DSPs])
        cols_ok || continue
        idx = if :MinLUTs in Symbol.(names(dfm)) && any(dfm.MinLUTs .== true)
            findfirst(dfm.MinLUTs .== true)
        else
            argmin(dfm.LUTs)
        end
        row = dfm[idx, :]
        if row.LUTs < best_luts
            best_luts = row.LUTs
            best = row
        end
    end
    isnothing(best) && error("No valid rows for toolchain=$(toolchain) f=$(f) precision=$(precision)")

    luts = Int(best.LUTs)
    ffs  = Int(best.FFs)
    dsps = Int(best.DSPs)
    rams = Int(best.RAMs)
    degree = Int(best.Degree)

    # Apply polynomial multiplier and reduction costs
    model = get(FUNCTION_MODEL, f, (poly_mult=1, poly_reductions=String[], reductions=String[]))
    if model.poly_mult > 1
        luts_poly = LUTS_PER_FMA[toolchain][precision] * degree
        ffs_poly  = FFS_PER_FMA[toolchain][precision] * degree
        luts = model.poly_mult * luts_poly + (luts - luts_poly)
        ffs  = model.poly_mult * ffs_poly  + (ffs  - ffs_poly)
        dsps *= model.poly_mult
        rams *= model.poly_mult
    end
    for red in model.poly_reductions
        haskey(REDUCTIONS, red) || continue
        r = REDUCTIONS[red][toolchain][precision]
        luts += r.LUT * model.poly_mult
        ffs  += r.FF  * model.poly_mult
        dsps += r.DSP * model.poly_mult
        rams += r.RAM * model.poly_mult
    end
    for red in model.reductions
        haskey(REDUCTIONS, red) || continue
        r = REDUCTIONS[red][toolchain][precision]
        luts += r.LUT
        ffs  += r.FF
        dsps += r.DSP
        rams += r.RAM
    end

    println("model: $(f) acc=$(accuracy_level) $(toolchain)/$(precision): LUTs=$(luts) FFs=$(ffs) DSPs=$(dsps) RAMs=$(rams)")
    segments = Int(best.Segments)
    if toolchain == "Vitis"
        return Dict(:LUT => luts, :FF => ffs, :BRAM => rams, :DSP => dsps, :Degree => degree, :Segments => segments)
    else
        return Dict(:ALUTs => luts, :FFs => ffs, :RAMs => rams, :DSPs => dsps, :Degree => degree, :Segments => segments)
    end
end

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
        var = tryparse(Int, String(splitted[end]))
        if isnothing(var)
            rich(" approx. ", string(splitted[1]))
        else
            rich(
                " approx. ",
                string(splitted[1]),
                " (2",
                superscript(string(eticks_map["single"][var+1])),
                "|2",
                superscript(string(eticks_map["double"][var+1])),
                ")"
            )
        end
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
function plot_resources!(parent, df, df_max_d, toolchain, precision, eticks, dlabel; title="", show_xticks::Bool=true, show_ylabels::Bool=true, top_ylims::Union{Nothing, Tuple{<:Real,<:Real}}=nothing)
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

    # Precompute model estimates per approximation group
    model_map = Dict{String, Dict{Symbol, Int}}()
    for g in groups
        occursin("_approximation", g) || continue
        f = replace(g, r"_approximation.*" => "")
        acc = let m = match(r"_approximation_(?:single_|double_)?(\d+)$", g)
            isnothing(m) ? nothing : parse(Int, m.captures[1])
        end
        try
            model_map[g] = get_model_estimate_row(toolchain, f, precision; accuracy_level=acc)
        catch
        end
    end

    ax, ax2 = if has_break
        # uniform y-ticks at step 1.0, formatted with one decimal
        bot_tick_vals = collect(0.0:1.0:5.0)
        yticks_bot = (bot_tick_vals, [string(v) for v in bot_tick_vals])
        top_lo, top_hi = isnothing(top_ylims) ? (10.0, ymax * 1.15) : (Float64(top_ylims[1]), Float64(top_ylims[2]))
        top_tick_vals = collect(ceil(top_lo):1.0:floor(top_hi))
        yticks_top = (top_tick_vals, [string(v) for v in top_tick_vals])

        ax_top = Axis(gl[1, 1];
                      ylabel = show_ylabels ? "Usage [%]" : "",
                      xticklabelrotation = π/16,
                      xticks=1:n_groups,
                      yticks=yticks_top,
                      xticklabelsize=8,
                      yticklabelsize=8,
                      xlabelsize=9,
                      ylabelsize=9)
        hidespines!(ax_top, :b)
        ax_top.ygridstyle[] = :dash
        ax_bot = Axis(gl[2, 1];
                      xticks=(1:n_groups, transform_label.(groups, precision)),
                      xticklabelrotation = π/16,
                      yticks=yticks_bot,
                      xticklabelsize=8,
                      yticklabelsize=8,
                      xlabelsize=9,
                      ylabelsize=9)
        hidespines!(ax_bot, :t)
        ax_bot.ygridstyle[] = :dash
        # defer linking until the spanning right axis is created
        hidexdecorations!(ax_top; grid=false)
        # size axes so both halves share the same y-scale (units/pixel)
        bot_range = 5.0
        top_range = isnothing(top_ylims) ? (ymax * 1.15 - 10.0) : (top_ylims[2] - top_ylims[1])
        total_range = top_range + bot_range
        rowsize!(gl, 1, Relative(top_range / total_range))
        rowsize!(gl, 2, Relative(bot_range / total_range))
        # increase the visual break between axes to ~one fontsize
        rowgap!(gl, Fixed(10))
        ylims!(ax_bot, 0, bot_range)
        if isnothing(top_ylims)
            ylims!(ax_top, 10, ymax * 1.15)
        else
            ylims!(ax_top, top_ylims[1], top_ylims[2])
        end
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

        # Overlay model-estimation lines per approximation and metric
        for (i, gname) in enumerate(groups)
            if !occursin("_approximation", gname)
                continue
            end
            haskey(model_map, gname) || continue
            est = model_map[gname]
            for (j, metric) in enumerate(metrics)
                mkey = Symbol(metric)
                haskey(est, mkey) || continue
                y_abs = est[mkey]
                y_pct = y_abs / totals[toolchain][metric] * 100
                x = xslot(i, j, n_total)
                x0 = x - 0.35*bar_width
                x1 = x + 0.35*bar_width
                if y_pct <= 5.0 + 1e-9
                    lines!(ax_bot, [x0, x1], [y_pct, y_pct]; color=:black, linewidth=1.5, linestyle=:dot)
                elseif y_pct >= 10.0 - 1e-9
                    lines!(ax_top, [x0, x1], [y_pct, y_pct]; color=:black, linewidth=1.5, linestyle=:dot)
                else
                    # within the break: place near the bottom break edge
                    yb = 5.0 - 0.10
                    lines!(ax_bot, [x0, x1], [yb, yb]; color=:black, linewidth=1.5, linestyle=:dot)
                end
            end
        end

        # Place labels per group following a simple neighbor-based staggering rule
        top_display_range = isnothing(top_ylims) ? max(ymax - 10.0, 1e-6) : (top_ylims[2] - top_ylims[1])
        yoff_low   = 0.02 * 5.0
        yoff_high  = 0.02 * top_display_range
        step_bot   = 0.10 * 5.0
        step_top   = 0.10 * top_display_range
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
                    dx = length(lbl) * 0.12 * bar_width
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
            ylabel = show_ylabels ? "Usage [%]" : "",
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

        # Overlay model-estimation lines per approximation and metric (single-axis case)
        for (i, gname) in enumerate(groups)
            if !occursin("_approximation", gname)
                continue
            end
            haskey(model_map, gname) || continue
            est = model_map[gname]
            for (j, metric) in enumerate(metrics)
                mkey = Symbol(metric)
                haskey(est, mkey) || continue
                y_abs = est[mkey]
                y_pct = y_abs / totals[toolchain][metric] * 100
                x = xslot(i, j, n_total)
                x0 = x - 0.35*bar_width
                x1 = x + 0.35*bar_width
                lines!(ax, [x0, x1], [y_pct, y_pct]; color=:black, linewidth=1.5, linestyle=:dot)
            end
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
                             ylabel=show_ylabels ? dlabel : "",
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
                      ylabel=show_ylabels ? dlabel : "",
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
        Label(gl[1, 1, Makie.Top()], title; fontsize=10, tellwidth=false, tellheight=true, padding=(0, 0, 2, 0))
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

function make_multifig_erf_like(f::String; rows=nothing, figname=nothing)
    ensure_outdir()
    if isnothing(rows)
        rows = [("Vitis", "single"), ("Vitis", "double"), ("oneAPI", "single"), ("oneAPI", "double")]
    end
    n = length(rows)
    fig = Figure(size=(595, 110 * (n - 1) + 220), figure_padding=(6, 6, 32, 30))

    axes_for_leg = Any[]
    dlabel_shared = ""
    for (i, (toolchain, precision)) in enumerate(rows)
        df_comb, df_max_d, eticks, dlabel = prepare_erf_group(toolchain, precision, f)
        dlabel_shared = dlabel
        title_str = "$(toolchain) - $(precision)"
        ax = plot_resources!(fig[i, 2], df_comb, df_max_d, toolchain, precision, eticks, dlabel;
                             title="", show_xticks=(i == n),
                             show_ylabels=false, top_ylims=(12.0, 13.0))
        title_lbl = Label(fig[i, 2, Makie.Top()], title_str; fontsize=10, tellwidth=false, tellheight=false, padding=(0, 0, 0, 0))
        translate!(title_lbl.blockscene, 0, -10)
        push!(axes_for_leg, ax)
    end

    Label(fig[1:n, 1], "Usage [%]"; rotation=π/2, fontsize=9, padding=(2,2,0,0))
    Label(fig[1:n, 3], dlabel_shared; rotation=π/2, fontsize=9, padding=(2,2,0,0))

    fig.layout.default_colgap = Fixed(0)
    for i in 1:n
        rowsize!(fig.layout, i, i == n ? Fixed(140) : Fixed(110))
    end

    leg = Legend(fig, axes_for_leg[end]; orientation=:horizontal, patchsize=(6,6), labelsize=8, padding=(220,0,30,0), framevisible=false)
    leg.tellwidth = false; leg.tellheight = false
    fig[n, 2, Makie.TopLeft()] = leg
    translate!(leg.blockscene, 0, -6)

    outname = isnothing(figname) ? "$(f)_resources_multifigure" : figname
    save("build_plots/resources/$(outname).pdf", fig)
end

function make_multifig_group(g::Vector{String}; name::String, relative=false, rows=nothing)
    ensure_outdir()
    if isnothing(rows)
        rows = [("Vitis", "single"), ("Vitis", "double"), ("oneAPI", "single"), ("oneAPI", "double")]
    end
    n = length(rows)
    fig = Figure(size=(595, 110 * (n - 1) + 146), figure_padding=(6, 6, 32, 30))

    axes_for_leg = Any[]
    dlabel_shared = ""
    for (i, (toolchain, precision)) in enumerate(rows)
        df_comb, df_max_d, eticks, dlabel = prepare_group(toolchain, precision, g; relative=relative)
        dlabel_shared = dlabel
        title_str = "$(toolchain) - $(precision)"
        ax = plot_resources!(fig[i, 2], df_comb, df_max_d, toolchain, precision, eticks, dlabel;
                             title="", show_xticks=(i == n), show_ylabels=false)
        title_lbl = Label(fig[i, 2, Makie.Top()], title_str; fontsize=10, tellwidth=false, tellheight=false, padding=(0, 0, 0, 0))
        translate!(title_lbl.blockscene, 0, -10)
        push!(axes_for_leg, ax)
    end

    Label(fig[1:n, 1], "Usage [%]"; rotation=π/2, fontsize=9, padding=(2,2,0,0))
    Label(fig[1:n, 3], dlabel_shared; rotation=π/2, fontsize=9, padding=(2,2,0,0))

    fig.layout.default_colgap = Fixed(0)
    for i in 1:n
        rowsize!(fig.layout, i, i == n ? Fixed(140) : Fixed(110))
    end

    leg = Legend(fig, axes_for_leg[end]; orientation=:horizontal, patchsize=(6,6), labelsize=8, padding=(220,0,30,0), framevisible=false)
    leg.tellwidth = false; leg.tellheight = false
    fig[n, 2, Makie.TopLeft()] = leg
    translate!(leg.blockscene, 0, -6)

    save("build_plots/resources/$(name)_resources_multifigure.pdf", fig)
end

# --- Build figures ---
make_multifig_erf_like("erf";
    rows=[("oneAPI", "single"), ("oneAPI", "double")],
    figname="erf_intel_resources")
let
    ensure_outdir()
    fig = Figure(size=(595, 156))
    df_comb, df_max_d, eticks, dlabel = prepare_group("Vitis", "double", ["cosh", "sinh", "atan"]; relative=false)
    dlabel = "Maximum Absolute Error\nper Input Binade"
    ax = plot_resources!(fig[1, 1], df_comb, df_max_d, "Vitis", "double", eticks, dlabel; title="Vitis - double", show_xticks=true)

    leg = Legend(fig, ax; orientation=:horizontal, patchsize=(6,6), labelsize=8, padding=(220,0,30,0), framevisible=false)
    leg.tellwidth = false; leg.tellheight = false
    fig[1, 1, Makie.TopLeft()] = leg
    translate!(leg.blockscene, 0, -6)

    save("build_plots/resources/cosh_sinh_atan_amd_resources.pdf", fig)
end

function get_intel_kernel_clock(name::String)
    json_path = "oneAPI/build_$(name)_0/$(name).prj/reports/resources/json/quartus.ndjson"
    isfile(json_path) || return nothing
    data = JSON.parse(read(json_path, String))
    haskey(data, "quartusFitClockSummary") || return nothing
    for node in data["quartusFitClockSummary"]["nodes"]
        haskey(node, "kernel clock") && return parse(Float64, string(node["kernel clock"]))
    end
    return nothing
end

function write_comparison_table(outpath::String)
    ensure_outdir()
    io = IOBuffer()

    println(io, "\\begin{tabular}{l ll rr rrrr rrrr r}")
    println(io, "\\toprule")
    println(io, " & & & & & \\multicolumn{4}{c}{Synthesis} & \\multicolumn{4}{c}{Model} & \\\\")
    println(io, "\\cmidrule(lr){6-9} \\cmidrule(lr){10-13}")
    println(io, "Toolchain & Function & Precision & \$d\$ & \$\\#S\$ & LUTs & FFs & RAMs & DSPs & LUTs & FFs & RAMs & DSPs & \$f_\\text{clock}\$ \\\\")
    println(io, "\\midrule")

    # --- oneAPI erf ---
    df_oneapi, _ = load_toolchain_data("oneAPI")
    intel_rows = String[]
    for precision in ["single", "double"]
        eticks = eticks_map[precision]
        for i in 0:5
            op = "erf_approximation_$(i)"
            rows = df_oneapi[(df_oneapi.Operation .== op) .& (df_oneapi.Precision .== precision) .& (df_oneapi.strategy .== 0), :]
            nrow(rows) == 0 && continue
            actual = rows[1, :]
            model = get_model_estimate_row("oneAPI", "erf", precision; accuracy_level=i)
            label = "erf (\$2^{$(eticks[i+1])}\$)"
            a = (Int(round(actual.ALUTs)), Int(round(actual.FFs)), Int(round(actual.RAMs)), Int(round(actual.DSPs)))
            m = (model[:ALUTs], model[:FFs], model[:RAMs], model[:DSPs])
            freq = get_intel_kernel_clock("erf_approximation_$(i)")
            freq_str = isnothing(freq) ? "" : string(Int(round(freq)))
            push!(intel_rows, " & $(label) & $(precision) & $(model[:Degree]) & $(model[:Segments]) & $(a[1]) & $(a[2]) & $(a[3]) & $(a[4]) & $(m[1]) & $(m[2]) & $(m[3]) & $(m[4]) & $(freq_str) \\\\")
        end
        precision == "single" && push!(intel_rows, "\\addlinespace")
    end
    n_intel = count(!startswith("\\"), intel_rows)
    println(io, "\\multirow{$(n_intel)}{*}{oneAPI}")
    for row in intel_rows
        println(io, row)
    end

    # --- Vitis cosh/sinh/atan double ---
    println(io, "\\midrule")
    df_vitis, _ = load_toolchain_data("Vitis")
    vitis_rows = String[]
    for f in ["cosh", "sinh", "atan"]
        rows = df_vitis[(df_vitis.Precision .== "double") .& occursin.("$(f)_approximation", df_vitis.Operation) .& (df_vitis.strategy .== 0), :]
        nrow(rows) == 0 && continue
        actual = rows[1, :]
        model = get_model_estimate_row("Vitis", f, "double")
        a = (Int(round(actual.LUT)), Int(round(actual.FF)), Int(round(actual.BRAM)), Int(round(actual.DSP)))
        m = (model[:LUT], model[:FF], model[:BRAM], model[:DSP])
        push!(vitis_rows, " & $(f) & double & $(model[:Degree]) & $(model[:Segments]) & $(a[1]) & $(a[2]) & $(a[3]) & $(a[4]) & $(m[1]) & $(m[2]) & $(m[3]) & $(m[4]) & 300 \\\\")
    end
    n_vitis = length(vitis_rows)
    println(io, "\\multirow{$(n_vitis)}{*}{Vitis}")
    for row in vitis_rows
        println(io, row)
    end

    println(io, "\\bottomrule")
    println(io, "\\end{tabular}")

    write(outpath, String(take!(io)))
end

write_comparison_table("build_plots/resources/resource_model_comparison_table.tex")
