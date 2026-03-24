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
using Printf

# Totals and metric order mirror approximation_resources.jl
const TOTALS = Dict(
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

const METRICS_ORDER = Dict(
    "oneAPI" => ["ALUTs", "FFs", "RAMs", "DSPs"],
    "Vitis" => ["LUT", "FF", "BRAM", "DSP"],
)

function ensure_outdir()
    try
        mkpath("build_plots/resources")
    catch
    end
end

function load_lib_data(toolchain::String)
    df_lib = CSV.read("$(toolchain)/unitary_lib_overview.csv", DataFrame)
    df_lib.strategy .= 0
    if toolchain == "oneAPI"
        df_lib.ALUTs += 20 * df_lib.MLABs
        df_lib.DSPs += df_lib.FracDSPs
    end
    return df_lib
end

function load_approx_data(toolchain::String)
    df = CSV.read("$(toolchain)/unitary_approx_overview.csv", DataFrame)
    if toolchain == "oneAPI"
        df.ALUTs += 20 * df.MLABs
        df.DSPs += df.FracDSPs
    end
    return df
end

"""
    combined_usage(row::DataFrameRow, toolchain::String)

Compute the sum of resource usage percentages across all metrics for a given row.
"""
function combined_usage(row::DataFrameRow, toolchain::String)
    metrics = METRICS_ORDER[toolchain]
    s = 0.0
    for m in metrics
        s += (Float64(row[Symbol(m)]) / TOTALS[toolchain][m]) * 100
    end
    return s
end

"""
    find_combined(df_lib, toolchain, precision, op)

Return combined usage percentage or `missing` if not found.
"""
function find_combined_lib(df_lib::DataFrame, toolchain::String, precision::String, op::String)
    df = filter(row -> row.Precision == precision && String(row.Operation) == op, df_lib)
    if nrow(df) == 0
        return missing
    end
    # If multiple rows exist, take the first (library should be unique per precision)
    return combined_usage(df[1, :], toolchain)
end

function find_combined_approx(df_approx::DataFrame, toolchain::String, precision::String, op::String)
    sub = filter(row -> row.Precision == precision && String(row.Operation) == op, df_approx)
    if nrow(sub) == 0
        return missing
    end
    # select row(s) with minimal strategy value for this operation/precision
    min_strategy = minimum(sub.strategy)
    sub2 = filter(row -> row.strategy == min_strategy, sub)
    return combined_usage(sub2[1, :], toolchain)
end

function find_combined_approx_any(df_approx::DataFrame, toolchain::String, precision::String, ops::Vector{String})
    if isempty(ops)
        return missing
    end
    sub = filter(row -> row.Precision == precision && (String(row.Operation) in ops), df_approx)
    if nrow(sub) == 0
        return missing
    end
    min_strategy = minimum(sub.strategy)
    sub2 = filter(row -> row.strategy == min_strategy, sub)
    return combined_usage(sub2[1, :], toolchain)
end

function fmt(v)
    ismissing(v) && return "-"
    return @sprintf("%.2f", Float64(v))
end

function main()
    ensure_outdir()

    amd_lib = load_lib_data("Vitis")
    intel_lib = load_lib_data("oneAPI")
    amd_apx = load_approx_data("Vitis")
    intel_apx = load_approx_data("oneAPI")

    outpath = "build_plots/resources/approximation_resources_usage.tex"
    open(outpath, "w") do io
        println(io, "\\begin{table}[h!]")
        println(io, "\\centering")
        # Use 4 numeric columns (U280 float/double, Stratix 10 float/double)
        println(io, "\\begin{tabular}{|l|l| *{4}{r|}}")
        println(io, "\\hline")
        println(io, "\\multirow{2}{*}{Function}    & \\multirow{2}{*}{Resource} & \\multicolumn{2}{c}{U280} & \\multicolumn{2}{c}{Stratix 10} \\\\")
        println(io, "    & & float & double & float & double \\\\")
        println(io, "\\hline")

        # Escape underscores for LaTeX
        latex_escape(s::AbstractString) = replace(s, "_" => "\\_")

        # Build function list
        lib_ops = Set(String.(amd_lib.Operation)) ∪ Set(String.(intel_lib.Operation))
        approx_ops_all = Set(String.(amd_apx.Operation)) ∪ Set(String.(intel_apx.Operation))
        base_from_approx = Set(replace(op, r"_approximation.*" => "") for op in approx_ops_all)
        # Only lib functions that have approximations
        functions = sort!(collect(intersect(lib_ops, base_from_approx)))

        for f in functions
            f_disp = latex_escape(f)

            # library row (only if present in at least one toolchain)
            amd_single = find_combined_lib(amd_lib, "Vitis", "single", f)
            amd_double = find_combined_lib(amd_lib, "Vitis", "double", f)
            int_single = find_combined_lib(intel_lib, "oneAPI", "single", f)
            int_double = find_combined_lib(intel_lib, "oneAPI", "double", f)
            if !(ismissing(amd_single) && ismissing(amd_double) && ismissing(int_single) && ismissing(int_double))
                println(io, "$(f_disp) & lib & $(fmt(amd_single)) & $(fmt(amd_double)) & $(fmt(int_single)) & $(fmt(int_double)) \\\\")
                println(io, "\\hline")
            end

            # approximation rows: merge *_approximation_single_* and *_approximation_double_* into *_approximation_*
            all_ops_for_f = sort(collect(filter(op -> startswith(op, string(f, "_approximation")), approx_ops_all)))
            # Merge variants like ..._approximation_single or ..._approximation_double,
            # with or without a trailing underscore (e.g., _single_0 or just _single)
            normalize_op(op::String) = replace(op, r"_approximation_(single|double)(?=(_|$))" => "_approximation")
            # build mapping from normalized op -> all original ops that map to it
            by_norm = Dict{String, Vector{String}}()
            for op in all_ops_for_f
                n = normalize_op(op)
                push!(get!(by_norm, n, String[]), op)
            end
            # order normalized ops by trailing integer when present
            function apx_sort_key_norm(op::String)
                m = match(r".*_(\d+)$", op)
                return isnothing(m) ? (typemax(Int), op) : (parse(Int, m.captures[1]), op)
            end
            norm_keys = sort(collect(keys(by_norm)); by=apx_sort_key_norm)
            for nkey in norm_keys
                ops_group = by_norm[nkey]
                # resource label: drop '<function>_' prefix
                res_label = startswith(nkey, string(f, "_")) ? nkey[length(f)+2:end] : nkey
                label = latex_escape(res_label)
                amd_single = find_combined_approx_any(amd_apx, "Vitis", "single", ops_group)
                amd_double = find_combined_approx_any(amd_apx, "Vitis", "double", ops_group)
                int_single = find_combined_approx_any(intel_apx, "oneAPI", "single", ops_group)
                int_double = find_combined_approx_any(intel_apx, "oneAPI", "double", ops_group)
                println(io, "$(f_disp) & $(label) & $(fmt(amd_single)) & $(fmt(amd_double)) & $(fmt(int_single)) & $(fmt(int_double)) \\\\")
                println(io, "\\hline")
            end

            # explicit sun_erf row for intel double (others shown as '-')
            if f == "erf"
                int_double = find_combined_lib(intel_lib, "oneAPI", "double", "sun_erf")
                println(io, "$(f_disp) & $(latex_escape("sun_erf")) & - & - & - & $(fmt(int_double)) \\\\")
                println(io, "\\hline")
            end
        end

        println(io, "\\end{tabular}")
        println(io, "\\end{table}")
    end

    println("Wrote LaTeX table to $(outpath)")
end

main()
