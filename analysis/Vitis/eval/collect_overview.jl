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

function parse_report(path, type)
    lines = readlines(path)
    to_find = type == "unitary" ? "o operation" : " + operation"
    line_index = findfirst(line -> occursin(to_find, line), lines)

    latency, interval = nothing, nothing
    latency_i, interval_i = 7, 8

    if type == "binary"
        line_index += 2
    end

    split_line = split(lines[line_index], "|")
    latency_m = match(r"\d+", split_line[latency_i])
    if latency_m != nothing
        latency = tryparse(Int, latency_m.match)
    end
        
    interval_m = match(r"\d+", split_line[interval_i])
    if interval_m != nothing
        interval = tryparse(Int, interval_m.match)
    end
    return latency, interval
end

function get_report_path(group, op_prec)
    return "build_" * group * "/_x_" * op_prec * "_hw/" * op_prec * "_hw/" * op_prec * "/" * op_prec * "/solution/syn/report/csynth.rpt"
end

df = CSV.read("resources.csv", DataFrame)

df[!, :Latency] = Vector{Union{Nothing,Int}}(nothing, nrow(df))
df[!, :Interval] = Vector{Union{Nothing,Int}}(nothing, nrow(df))

resource_cols = names(df, Int)

for df_op in groupby(df, "Operation")
    for row in eachrow(df_op)
        path = if occursin("approximation", row.Operation)
           get_report_path(row.Group, row.Operation)
        else
           get_report_path(row.Group, "$(row.Operation)_$(row.Precision)")
        end
        row.Latency, row.Interval = parse_report(path, row.OperationType)
    end
end

df_unitary = df[(df.OperationType .== "unitary") .& (df.Operation .!= "user_budget"), :]

df_identity = df_unitary[df_unitary.Operation .== "identity", :]

for df_op in groupby(df_unitary, ["Group", "Operation"])
    range = if nrow(df_op) == 1
        if df_op.Precision[1] == "single"
            2:2
        else
            3:3
        end
    else
        1:3
    end
    foreach(col -> df_op[!, col] .-= df_identity[range, col], resource_cols) 
    df_op[!, :Latency] .-= df_identity[range, :Latency]
end

df_unitary_approx = filter(row -> occursin("approximation", row.Operation), df_unitary)

df_unitary = filter(row -> !occursin("approximation", row.Operation), df_unitary)

df_unitary = select(df_unitary, Not([:Group, :OperationType]))

CSV.write("unitary_lib_overview.csv", df_unitary; transform=(col, val) -> something(val, missing))
display(df_unitary)

df_unitary_approx.strategy = parse.(Int, last.(split.(df_unitary_approx.Group, "_")))
df_unitary_approx = select(df_unitary_approx, Not([:Group, :OperationType]))

CSV.write("unitary_approx_overview.csv", df_unitary_approx; transform=(col, val) -> something(val, missing))
display(df_unitary_approx)

df_binary = df[(df.OperationType .== "binary") .& (df.Operation .!= "user_budget"), :]

df_select = df_binary[df_binary.Operation .== "select", :]

df_binary = df_binary[df_binary.Operation .!= "select", :]

resource_cols = names(df_binary, Int)

df_binary[!, :Latency] = Vector{Union{Nothing,Int}}(nothing, nrow(df_binary))
df_binary[!, :Interval] = Vector{Union{Nothing,Int}}(nothing, nrow(df_binary))

for df_op in groupby(df_binary, "Operation")
    foreach(col -> df_op[!, col] .-= df_select[!, col], resource_cols) 
    for row in eachrow(df_op)
        path = get_report_path(row.Group, "$(row.Operation)_$(row.Precision)")
        row.Latency, row.Interval = parse_report(path, "binary")
    end
end

df_binary = select(df_binary, Not([:Group, :OperationType]))

df_binary_float = filter(row -> !occursin("int", row.Precision), df_binary)
CSV.write("binary_float_overview.csv", df_binary_float; transform=(col, val) -> something(val, missing))
display(df_binary_float)

df_binary_int = filter(row -> occursin("int", row.Precision), df_binary)
CSV.write("binary_int_overview.csv", df_binary_int; transform=(col, val) -> something(val, missing))
display(df_binary_int)
