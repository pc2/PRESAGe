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

rm -rf build_plots
mkdir -p build_plots/Vitis/deviations
mkdir -p build_plots/Vitis/output
mkdir -p build_plots/oneAPI/deviations
mkdir -p build_plots/oneAPI/output

cp oneAPI/build_*/*.png build_plots/oneAPI/output
cp build_deviations/oneAPI/*.png build_plots/oneAPI/deviations

cp Vitis/build_*/*.png build_plots/Vitis/output
cp build_deviations/Vitis/*.png build_plots/Vitis/deviations
