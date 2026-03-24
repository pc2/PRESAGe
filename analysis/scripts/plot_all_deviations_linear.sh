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

for prec in half single double; do
    for toolchain in Vitis oneAPI; do
        for op in $(jq -r '.groups[] | select(.type != "binary") | .operations[]' config.json); do
            julia plot/linear.jl build_input/in_${prec}.bin build_deviations/${toolchain}/${op}_${prec}.bin -10.0 10.0 -10 10
        done;
    done;
done
