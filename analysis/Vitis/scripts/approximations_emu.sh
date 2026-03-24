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
for approximations in approximations erf_approximations erfc_approximations; do
(
    path=build_${approximations}_0
    mkdir -p ${path}
    cd ${path}
    cmake .. -DBUILD_TARGET=hw
    make ${approximations}_reports -j20
    cmake .. -DBUILD_TARGET=sw_emu
    make ${approximations}_xclbin -j20
    make main
    echo "${approximations} finished" >&2
)
done
