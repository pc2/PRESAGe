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
for group in approximations erf_approximations erfc_approximations; do
    for approximation in $(jq --arg g ${group} -r '.groups[] | select(.name == $g) | .approximations[] | .name' ../config.json); do
        sbatch -J "run_${approximation}" \
            -o "run_${approximation}_%j.out" \
            -e "run_${approximation}_%j.out" \
            ./scripts/run.sh "${group}_0" "${group}" "${approximation}"
    done
done
