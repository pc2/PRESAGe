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
for approximation in $(jq -r '.groups[] | select(.name == "all_oneAPI_approximations") | .approximations | map(.name) | .[1:][]' ../config.json); do
    path="${approximation}_0"
    sbatch -J "synth_${path}" \
        -o "synth_${path}_%j.out" \
        -e "synth_${path}_%j.out" \
        ./scripts/synth.sh "${path}" "${approximation}"
done
