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
using JSON
using CSV
using DataFrames

config_str = read("../config.json", String)
config = JSON.parse(config_str)

chosen_df = DataFrame()

for group in config["groups"]
    if haskey(group, "approximations") && !occursin("oneAPI", group["name"]) && !occursin("local_mem", group["name"])
        for approximation in group["approximations"]
            folder = "build_$(group["name"])_0"
            path = "$(folder)/kernels/$(approximation["name"]).cpp.approximation.cpp"
            line = readline(path)
            m = match(r"\"([^\"]+)\.cpp\"", line)
            if m != nothing
                name = m.captures[1]
                path = "$(folder)/$(name).csv"
                df = CSV.read(path, DataFrame)
                df.memory = [isodd(i) ? "lut" : "ram" for i in axes(df, 1)]
                df.name .= approximation["name"]
                display(df)
                CSV.write("build_estimations/$(approximation["name"]).csv", df)
                append!(chosen_df, df)
                CSV.write("build_estimations/chosen.csv", chosen_df)
            end
        end
    end
end

display(chosen_df)
