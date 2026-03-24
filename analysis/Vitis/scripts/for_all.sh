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

if [ -z "$1" ]; then
    echo "pass operation as first argument"
    exit
fi

op=$1

if [ -z "$2" ]; then
    if [[ $1 == "run" ]]; then
        groups=$(jq -r '.groups[] | select(.type != "binary") | .name' ../config.json)
    else
        groups=$(jq -r '.groups[].name' ../config.json)
    fi
else
    shift
    groups=$@
fi

echo $groups

for group in $groups; do
    sbatch -o ${op}_${group}_%j.out -e ${op}_${group}_%j.out -J ${op}_${group} ./scripts/${op}.sh ${group}
done
