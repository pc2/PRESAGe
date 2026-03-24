#!/usr/bin/bash
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

segments=(32 64 128 256 512 1024)
for (( d = 0; d <= 15; d++ )); do
    pids=()
    for s in ${segments[@]}; do
        for p in single double; do
            for mem in lut ram auto; do
            (
                target=local_mem_${p}
                path=build_${target}/s${s}_d${d}_${mem}
                rm -rf ${path}
                mkdir -p ${path}
                cd ${path}
                cmake ../.. -DEXTRA_ARGS="--degree ${d} --fix_segments=${s} --range=0,${s} --random_coefficients --memory ${mem}"
                make ${target}_reports
            ) &
            pids+=($!)
            done
        done
    done
    for pid in "${pids[@]}"; do
        wait "${pid}"
    done
done
