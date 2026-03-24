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

for prec in half single; do
    for op in $(jq --arg group "${group}" -r '.groups[] | select(.type == "unitary") | .operations[]' config.json); do
            julia plot/linear.jl build_input/in_${prec}.bin oneAPI/build_${op}/${op}_${prec}.bin -10 10 -10 10
    done;
done;

for prec in double; do
    for op in $(jq --arg group "${group}" -r '.groups[] | select(.type == "unitary") | .operations[]' config.json); do
            julia plot/linear.jl build_input/in_${prec}.bin oneAPI/build_${op}/${op}_${prec}.bin -10 10 -10 10
    done;
done;

for prec in half single; do
    for group in $(jq -r '.groups[] | select(.type != "binary") | .name' config.json); do
        for op in $(jq --arg group "${group}" -r '.groups[] | select(.name == $group) | .operations[]' config.json); do
            julia plot/linear.jl build_input/in_${prec}.bin Vitis/build_${group}/${op}_${prec}.bin -10 10 -10 10
        done;
    done;
done;

for prec in double; do
    for group in $(jq -r '.groups[] | select(.type != "binary") | .name' config.json); do
        for op in $(jq --arg group "${group}" -r '.groups[] | select(.name == $group) | .operations[]' config.json); do
            julia plot/linear.jl build_input/in_${prec}.bin Vitis/build_${group}/${op}_${prec}.bin -10 10 -10 10
        done;
    done;
done;

wait
