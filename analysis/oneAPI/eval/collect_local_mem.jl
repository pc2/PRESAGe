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

function insert_resources(df, segments, degree, precision, mem, rams, mlabs, numbanks, depth)#, details)
    push!(df, (
        Segments = segments,
        Degree = degree,
        Precision = precision,
        Mem = mem,
        RAMs = rams,
        MLABs = mlabs,
        NumBanks = numbanks,
        Depth = depth,
    ))
end

function parse_numbanks(s)
    pattern = r"[1-9]\d*"
    nums = [parse(Int, m.match) for m in eachmatch(pattern, s)]
    if (length(nums) == 1)
        return nums[1]
    elseif length(nums) == 2
        return nums[1] - nums[2]
    else
        throw(ArgumentError("too much nums"))
    end
end

function parse_number(resource)
    m = match(r"\d+", resource)
    m == nothing ? 0 : parse(Int, m.match)
end

function parse_resources(df, segments, degree, mem)
    new_lmv_path = "build_local_mem/s" * string(segments) * "_d" * string(degree) * "_" * mem * "/local_mem_report.prj/reports/resources/json/new_lmv.ndjson"
    if !isfile(new_lmv_path)
        println(new_lmv_path, " not found") 
        return
    end
    f = open(new_lmv_path, "r")
    new_lmv_lines = [JSON.parse(line) for line in eachline(f)]
    close(f)

    for line in new_lmv_lines
        #if haskey(line, "name") && haskey(line, "children") && line["name"] == "coeff_table"
        if haskey(line, "name") && line["name"] == "coeff_table"
            precision = if occursin("single", line["debug"][1][1]["filename"])
                "single"
            elseif occursin("double", line["debug"][1][1]["filename"])
                "double"
            else
                ""
            end
            if line["type"] == "unsynth"
                insert_resources(df, segments, degree, precision, mem, 0, 0, 0, 0)
                continue
            end
            details = line["details"][1]
            mem_usage = details["Memory Usage"]
            rams, mlabs = if occursin("MLAB", mem_usage)
                0, parse_number(mem_usage)
            elseif occursin("RAM", mem_usage)
                parse_number(mem_usage), 0
            else
                println("unexpected Memory Usage: $mem_usage")
                0, 0
            end
            numbanks = parse_numbanks(details["Number of banks"])
            depth = parse_number(details["Bank depth"])
            insert_resources(df, segments, degree, precision, mem, rams, mlabs, numbanks, depth)
        end
    end
end

config_str = read("../config.json", String)

config = JSON.parse(config_str)

df = DataFrame(
   Segments = Int64[],
   Degree = Int64[],
   Precision = String[],
   Mem = String[],
   RAMs = Int64[],
   MLABs = Int64[],
   NumBanks = Int64[],
   Depth = Int64[],
)

for s in [32, 64, 128, 256, 512, 1024]
    for d in 0:15
        for mem in ["lut", "ram", "auto"]
            parse_resources(df, s, d, mem)
        end
    end
end

CSV.write("local_mem.csv", df)
display(df)
println("data written to local_mem.csv")
