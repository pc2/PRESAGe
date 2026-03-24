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

function convert_precision(precision)
    m = match(r"\d+", precision)
    if m == nothing
        return ""
    else
        return m.match * ">"
    end
end

function parse_report(path, precision, type)
    f = open(path, "r")
    lines = [JSON.parse(line) for line in eachline(f)]
    close(f)
    name = if type == "unitary"
        if precision == "half"
            "short>"
        elseif precision == "single"
            "int>"
        else
            "long>"
        end
    else
        if precision == "half"
            "-16>"
        elseif precision == "single"
            "-32>"
        elseif precision == "double"
            "-64>"
        else
            convert_precision(precision)
        end
    end
    for line in lines
        if haskey(line, "name") && line["name"] == name
            for child in lines
                if haskey(child, "parent") && child["parent"] == line["id"] &&
                    haskey(child, "name") && occursin(r"OperationKernel.*.B1", child["name"])
                    return tryparse(Int, child["details"][1]["Latency"]), tryparse(Int, child["details"][1]["II"])
                end
            end
        end
    end
    nothing, nothing
end

df = CSV.read("resources.csv", DataFrame)

df[!, :Latency] = Vector{Union{Nothing,Int}}(nothing, nrow(df))
df[!, :Interval] = Vector{Union{Nothing,Int}}(nothing, nrow(df))

for df_op in groupby(df, "Operation")
    for row in eachrow(df_op)
        report_path = "./build_" * row.Group * "/" * row.Operation * "_report.prj/reports/resources/json/mav.ndjson"
        row.Latency, row.Interval = parse_report(report_path, row.Precision, row.OperationType)
    end
end

resource_cols = names(df, Int)

df_unitary = df[(df.OperationType .== "unitary"), :]

df_identity = df_unitary[df_unitary.Operation .== "identity", :]

df_unitary = df_unitary[df_unitary.Operation .!= "identity", :]

for df_op in groupby(df_unitary, "Group")
    foreach(col -> df_op[!, col] .-= df_identity[(4-nrow(df_op)):3, col], resource_cols) 
    df_op[!, :Latency] .-= df_identity[(4-nrow(df_op)):3, :Latency]
end

#df_unitary = select(df_unitary, Not([:Group, :OperationType]))

df_unitary_lib = filter(row -> !occursin("approximation", row.Operation), df_unitary)

select!(df_unitary_lib, Not([:Group, :OperationType]))

CSV.write("unitary_lib_overview.csv", df_unitary_lib; transform=(col, val) -> something(val, missing))
display(df_unitary_lib)

df_unitary_approx = filter(row -> occursin("approximation", row.Operation), df_unitary)

df_unitary_approx.strategy = parse.(Int, last.(split.(df_unitary_approx.Group, "_")))
select!(df_unitary_approx, Not([:Group, :OperationType]))

CSV.write("unitary_approx_overview.csv", df_unitary_approx; transform=(col, val) -> something(val, missing))
display(df_unitary_approx)

df_binary = df[(df.OperationType .== "binary"), :]

df_select = df_binary[df_binary.Operation .== "select", :]

df_binary = df_binary[df_binary.Operation .!= "select", :]

for df_op in groupby(df_binary, "Operation")
    foreach(col -> df_op[!, col] .-= df_select[!, col], resource_cols)
    df_op[!, :Latency] .-= df_select[!, :Latency]
end

df_binary = select(df_binary, Not([:Group, :OperationType]))

df_binary_float = filter(row -> !occursin("int", row.Precision), df_binary)
CSV.write("binary_float_overview.csv", df_binary_float; transform=(col, val) -> something(val, missing))
display(df_binary_float)

df_binary_int = filter(row -> occursin("int", row.Precision), df_binary)
CSV.write("binary_int_overview.csv", df_binary_int; transform=(col, val) -> something(val, missing))
display(df_binary_int)
