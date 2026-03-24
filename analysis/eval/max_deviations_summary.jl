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
using JSON
using Quadmath

include("../ieee754.jl")

config_str = read("config.json", String)
config = JSON.parse(config_str)

precisions = [("half", Float16, Float32), ("single", Float32, Float64), ("double", Float64, Float128)]

ulp_bound(x) = x > 100 ? 100 : x

subnormal_input_dfs = []
special_input_dfs = []

worst_ulps = Dict{NTuple{3, String}, UInt64}()
ulp_off_counter = Dict{NTuple{3, String}, UInt64}()
sub_ulps = Dict{NTuple{3, String}, UInt64}()
num_binades = Dict(
    "half" => 60,
    "single" => 508,
    "double" => 4092,
)

bad_ulps_df = DataFrame(
    Toolchain = String[],
    Operation = String[],
    Precision = String[],
    Sign = UInt8[],
    Exponent = Int64[],
    Input = Float64[],
    Output = Float64[],
    Golden = Float64[],
    Value = Float64[],
)

function push_bad_ulp(df, row)
    push!(df, (
        Toolchain = row.Toolchain,
        Operation = row.Operation,
        Precision = row.Precision,
        Sign = row.Sign,
        Exponent = row.Exponent,
        Input = row.Input,
        Output = row.Output,
        Golden = row.Golden,
        Value = row.Value,
    ))
end

operations = [op for group in config["groups"] if group["type"] == "unitary" && haskey(group, "operations") for op in group["operations"]]

for toolchain in ["Vitis", "oneAPI"]
    for operation in operations
        if toolchain == "Vitis" && operation == "sun_erf"
            continue
        end
        path = "build_max_deviations/" * toolchain * "/" * operation * ".csv"
        df = CSV.read(path, DataFrame)
        for df_prec in groupby(df, "Precision")
            precision = first(df_prec[!, "Precision"])
            subnormal_exponent = subnormal_exponent_dict[precision]
            subnormals_all = filter(:Exponent => e -> e == subnormal_exponent, df_prec)
            push!(subnormal_input_dfs, subnormals_all)
            nan_exponent = nan_exponent_dict[precision]
            specials = filter(:Exponent => e -> e == nan_exponent, df_prec)
            push!(special_input_dfs, specials)
            normals_all = filter(:Exponent => e -> ((e != subnormal_exponent) && (e != nan_exponent)), df_prec)
            normals = filter(:DType => d -> d == "bit", normals_all)
            key = (precision, toolchain, operation)
            get!(ulp_off_counter, key, 0)
            subnormals = filter(:DType => d -> d == "bit", subnormals_all)
            for row in eachrow(normals)
                worst_ulps[key] = max(get!(worst_ulps, key, 0), row.Value)
                if row.Value <= 4
                    ulp_off_counter[key] = get!(ulp_off_counter, key, 0) + 1
                else
                    global bad_ulps_df
                    push_bad_ulp(bad_ulps_df, row)
                end
            end
        end
    end
end

worst_ulps_df = DataFrame(
    Toolchain = String[],
    Operation = String[],
    Precision = String[],
    Value = UInt64[],
)

table = ""

for operation in operations
    if operation == "sun_erf"
        continue
    end
    global table
    table *= "$(operation)"
    for toolchain in ["Vitis", "oneAPI"]
        for precision in [p[1] for p in precisions]
            key = (precision, toolchain, operation)
            if haskey(worst_ulps, key)
                value = worst_ulps[key]
                push!(worst_ulps_df, (
                    Toolchain = toolchain,
                    Operation = operation,
                    Precision = precision,
                    Value = value,
                ))
                if value <= 4
                    table *= "&\\textcolor{green}{$(value)}"
                else
                    percentage = ulp_off_counter[key] / num_binades[precision]
                    if percentage > 0.9
                        table *= "&\\textcolor{orange}{$(ulp_off_counter[key])/$(num_binades[precision])}"
                    else
                        table *= "&\\textcolor{red}{$(ulp_off_counter[key])/$(num_binades[precision])}"
                    end
                end
            else 
                table *= "&"
            end
        end
    end
    table *= "\\\\\n\\hline\n"
end

open("build_max_deviations/table.tex", "w") do io
    write(io, table)
end

CSV.write("build_max_deviations/bad_ulps.csv", bad_ulps_df)

CSV.write("build_max_deviations/worst_ulps.csv", worst_ulps_df)

CSV.write("build_max_deviations/subnormals.csv", vcat(subnormal_input_dfs...))

CSV.write("build_max_deviations/specials.csv", vcat(special_input_dfs...))

function sort_and_output(path, df)
    desired_order = ["half", "single", "double"]
    sort!(df, [:Operation, order(:Precision, by = v -> Dict(x => i for (i, x) in enumerate(desired_order))[v])])
    CSV.write(path, df)
end
