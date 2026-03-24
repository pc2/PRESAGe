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
#SBATCH -p fpga
#SBATCH -t 0:30:00
#SBATCH --mail-type=ALL
#SBATCH --constraint=bittware_520n_20.4.0_hpc

source env.sh

if [ -z "$1" ]; then
    echo "pass folder name as first argument"
    exit
fi

if [ -z "$2" ]; then
    echo "pass approximation name as second argument"
    exit
fi

cd build_$1
./$2.fpga
