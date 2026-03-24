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
#SBATCH -t 2:00:00
#SBATCH --mail-type=ALL
#SBATCH --constraint=xilinx_u280_xrt2.16

if [ -z "$1" ]; then
    echo "pass folder name as first argument"
    exit
fi

if [ -z "$2" ]; then
    echo "pass group name as first argument"
    exit
fi

source env.sh

xbutil reset --force --device 0000:01:00.1

cd build_$1
make
./main $2 $3
