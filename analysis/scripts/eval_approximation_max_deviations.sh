#!/bin/bash
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

jq -r '.groups[] | select(.name == "all_oneAPI_approximations") | .approximations[] | select(.name != "local_mem") | "\(.name) \(.operation)"' config.json |
while read name operation; do
    toolchain=oneAPI
    i=0
    sbatch -J eval_max_deviations_${toolchain}_${name}_${i} -o eval_max_deviations_${toolchain}_${name}_${i}_%j.out -e eval_max_deviations_${toolchain}_${name}_${i}_%j.out ./scripts/run.sh ./eval/max_deviations.jl ${toolchain} ${operation} ${name}
done

jq -r '.groups[] | select(.name == "approximations" or .name == "erf_approximations" or .name == "erfc_approximations") | .approximations[] | "\(.name) \(.operation)"' config.json |
while read name operation; do
    toolchain=Vitis
    i=0
    sbatch -J eval_max_deviations_${toolchain}_${name}_${i} -o eval_max_deviations_${toolchain}_${name}_${i}_%j.out -e eval_max_deviations_${toolchain}_${name}_${i}_%j.out ./scripts/run.sh ./eval/max_deviations.jl ${toolchain} ${operation} ${name}
done

