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
ml reset

ml fpga
ml xilinx/xrt/2.16
ml lib lang math compiler devel
ml Clang/17.0.6-GCCcore-13.2.0 CMake/3.27.6-GCCcore-13.2.0
ml math
ml MPFR/4.2.1-GCCcore-13.2.0

export OMP_NUM_THREADS=128
