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
#SBATCH -p normal
#SBATCH -t 12:00:00
#SBATCH --cpus-per-task=32
#SBATCH --mem=64G
#SBATCH --mail-type=ALL

if [ -z "$1" ]; then
    echo "pass folder name as first argument"
    exit
fi

if [ -z "$2" ]; then
    echo "pass bitstream name as first argument"
    exit
fi

source env.sh

mkdir -p build_$1
cd build_$1
cmake .. -DBUILD_TARGET=hw -DEXTRA_ARGS="${3}"
make $2_xclbin -j 30
