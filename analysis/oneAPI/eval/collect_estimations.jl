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

approximations = config["groups"][findfirst(x -> x["name"] == "all_oneAPI_approximations", config["groups"])]["approximations"]

chosen_df = DataFrame()

for approximation in filter(a -> !occursin("local_mem", a["name"]), approximations)
    for p in ["single", "double"]
        path = "build_$(approximation["name"])_0"
        reg = Regex(".*$(p).*\\.csv")
        for match in filter(f -> occursin(reg, basename(f)), readdir(path; join=true))
            df = CSV.read(match, DataFrame)
            df.memory = [isodd(i) ? "lut" : "ram" for i in axes(df, 1)]
            df.name .= approximation["name"]
            df.precision .= p
            CSV.write("build_estimations/$(approximation["name"])_$(p).csv", df)
            append!(chosen_df, df)
            CSV.write("build_estimations/chosen.csv", chosen_df)
            display(df)
        end
    end
end
display(chosen_df)
