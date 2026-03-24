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

function insert_resources(df, segments, degree, precision, mem, bram, ff, lut, uram, words, bits, banks)
    push!(df, (
        Segments = segments,
        Degree = degree,
        Precision = precision,
        Mem = mem,
        BRAM18K = bram,
        FF = ff,
        LUT = lut,
        URAM = uram,
        Words = words,
        Bits = bits,
        Banks = banks,
    ))
end

function parse_single_resource(resource)
    m = match(r"\d+", resource)
    m == nothing ? 0 : parse(Int, m.match)
end

function parse_resources(df, s, d, precision, mem)
    target = "build_local_mem_" * precision* "/s" * string(s) * "_d" * string(d) * "_" * mem
    name = "local_mem_" * precision
    path = target * "/_x_" * name * "_hw/" * name * "_hw/" * name * "/" * name * "/solution/syn/report/horner_evaluator_csynth.rpt"
    if !isfile(path)
        new_path = target * "/_x_" * name * "_hw/" * name * "_hw/" * name * "/" * name * "/solution/syn/report/csynth.rpt"
        if !isfile(new_path)
            println(path, " not found")
        else
            #horner evaluator was optimized away
            insert_resources(df, s, d, precision, mem, 0, 0, 0, 0, 0, 0, 0)
        end
        return
    end
    resources = readlines(path)

    line_index = findfirst(line -> occursin("W*Bits*Banks", line), resources)

    if line_index == nothing
        return
    end

    while line_index <= length(resources)
        if occursin("Total", resources[line_index])
            split_line = split(resources[line_index], "|")
            insert_resources(df, s, d, precision, mem,
                             parse_single_resource(split_line[4]),
                             parse_single_resource(split_line[5]),
                             parse_single_resource(split_line[6]),
                             parse_single_resource(split_line[7]),
                             parse_single_resource(split_line[8]),
                             parse_single_resource(split_line[9]),
                             parse_single_resource(split_line[10]),
                            )
            break
        else
            line_index += 1
        end
    end
end

df = DataFrame(
    Segments = Int[],
    Degree = Int[],
    Precision = String[],
    Mem = String[],
    BRAM18K = Int64[],
    FF = Int64[],
    LUT = Int64[],
    URAM = Int64[],
    Words = Int64[],
    Bits = Int64[],
    Banks = Int64[],
)

for s in [32, 64, 128, 256, 512, 1024]
    for d in 0:15
        for precision in ["single", "double"]
            for mem in ["lut", "ram", "auto"]
                parse_resources(df, s, d, precision, mem)
            end
        end
    end
end

display(df)
CSV.write("local_mem.csv", df)
println("data written to local_mem.csv")
