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
using JSON
using DataFrames

function parse_single_resource(resource)
    m = match(r"\d+", resource)
    m == nothing ? 0 : parse(Int, m.match)
end

function parse_resources(df, operation, precision, op_prec, group, type)
    path = "build_" * group * "/_x_" * op_prec * "_hw/" * op_prec * "_hw/" * op_prec * "/" * op_prec * "/solution/syn/report/csynth.rpt"
    if !isfile(path)
        println(path, " not found")
        return
    end
    resources = readlines(path)

    line_index = findfirst(line -> occursin("+ " * op_prec, line), resources)

    split_line = split(resources[line_index], "|")
    push!(df, (
        Group = group,
        Operation = operation,
        OperationType = type,
        Precision = precision,
        BRAM = parse_single_resource(split_line[11]),
        DSP = parse_single_resource(split_line[12]),
        FF = parse_single_resource(split_line[13]),
        LUT = parse_single_resource(split_line[14]),
        URAM = parse_single_resource(split_line[15]),
    ))
end

df = DataFrame(Group = String[], Operation = String[], OperationType = String[], Precision = String[], BRAM = Int64[], DSP = Int64[], FF = Int64[], LUT = Int64[], URAM = Int64[])

config_str = read("../config.json", String)
config = JSON.parse(config_str)

for group in config["groups"]
    if haskey(group, "operations")
        for operation in group["operations"]
            precisions = ["half", "single", "double"]
            if group["type"] == "binary"
                precisions = vcat(precisions, ["uint" * string(i) for i in 1:64])
            end

            for precision in precisions
                parse_resources(df, operation, precision, "$(operation)_$(precision)", group["name"], group["type"])
            end
        end
    elseif haskey(group, "approximations") && (group["name"] == "approximations" || group["name"] == "erfc_approximations" || group["name"] == "erf_approximations")
        for approximation in group["approximations"]
            precision = approximation["precision"]
            if precision == "float"
                precision = "single"
            end
            for i in [0, 1, 2, 3, 4, 5]
                parse_resources(df, approximation["name"], precision, approximation["name"], "$(group["name"])_$(i)", group["type"])
            end
        end
    end
end

display(df)
CSV.write("resources.csv", df)
println("data written to resources.csv")
