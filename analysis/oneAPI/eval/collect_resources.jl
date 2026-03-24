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

function insert_resources(df, group, operation, type, name, resources)
    precision = if type == "unitary"
        if name == "short>"
            "half"
        elseif name == "int>"
            "single"
        elseif name == "long>"
            "double"
        else
            name
        end
    else
        if name == "-16>"
            "half"
        elseif name == "-32>"
            "single"
        elseif name == "-64>"
            "double"
        else
            "uint" * name[1:length(name)-1]
        end
    end
    push!(df, (
        Group = group,
        Operation = operation,
        OperationType = type,
        Precision = precision,
        ALUTs = resources[1],
        FFs = resources[2],
        RAMs = resources[3],
        DSPs = resources[4],
        MLABs = resources[5],
        FracDSPs =resources[6]
    ))
end

function parse_resources(df, group, operation, type)
    path = "build_$(group)/$(operation)_report.prj/reports/resources/json/area.ndjson"
    if !isfile(path)
        println(path, " not found") 
        return
    end
        
    f = open(path, "r")
    lines = [JSON.parse(line) for line in eachline(f)]
    close(f)
    names = []
    names = if type == "unitary"
        ["short>", "int>", "long>"]
    elseif type == "binary"
        ["-16>", "-32>", "-64>"]
    else
        []
    end
    for name in names
        for index in findall(line -> line["name"] == name, lines)
            for child in lines
                if haskey(child, "parent") && child["parent"] == lines[index]["id"] && occursin(r"OperationKernel.*B1", child["name"])
                    insert_resources(df, group, operation, type, name, lines[index]["total_kernel_resources"]) 
                    break
                end
            end
        end
    end
    if type == "binary"
        for name in [string(i) * ">" for i in 1:64]
            index = findfirst(line -> line["name"] == name, lines)
            insert_resources(df, group, operation, type, name, lines[index]["total_kernel_resources"])
        end
    end
end

config_str = read("../config.json", String)

config = JSON.parse(config_str)

df = DataFrame(Group = String[], Operation = String[], OperationType = String[], Precision = String[], ALUTs = Int64[], FFs = Int64[], RAMs = Int64[], DSPs = Int64[], MLABs = Int64[], FracDSPs = Int64[])

for group in config["groups"]
    if haskey(group, "operations")
        for op in group["operations"]
            parse_resources(df, op, op, group["type"])
        end
    elseif group["name"] == "all_oneAPI_approximations"
        for approximation in group["approximations"]
            for i in [0, 1, 2, 3, 4, 5]
                name = approximation["name"]
                path = "$(name)_$(i)"
                if name != "local_mem"
                    parse_resources(df, path, name, group["type"])
                end
            end
        end
    end
end

CSV.write("resources.csv", df)
display(df)
println("data written to resources.csv")
