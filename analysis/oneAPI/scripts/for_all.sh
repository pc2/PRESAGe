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

if [ -z "$1" ]; then
    echo "pass script name as first argument"
    exit
fi

for name in $(jq -r '.groups[].functions[]' ../config.json); do
    sbatch -J ${1}_${name} -o ${1}_${name}_%j.out -e ${1}_${name}_%j.out ./scripts/${1}.sh ${name}
done
