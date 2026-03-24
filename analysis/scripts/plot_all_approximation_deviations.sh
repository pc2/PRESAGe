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

single_accuracies=("2^-23" "2^-21" "2^-19" "2^-17" "2^-15" "2^-13")
double_accuracies=("2^-52" "2^-46" "2^-40" "2^-34" "2^-28" "2^-23")

declare -A erf_bound
erf_bound[single]="4.0"
erf_bound[double]="10.0"

for accuracy in single double; do
    declare -n accuracies="${accuracy}_accuracies"
    for i in 0 1 2 3 4 5; do
        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/cos_approximation_${accuracy}_${accuracy}.bin -5pi 5pi 1pi -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/sin_approximation_${accuracy}_${accuracy}.bin -5pi 5pi 1pi -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/atan_approximation_${accuracy}_${accuracy}.bin -7.0 7.0 1.0 -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/cosh_approximation_${accuracy}_${accuracy}.bin -8.0 8.0 1.0 -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/sinh_approximation_${accuracy}_${accuracy}.bin -8.0 8.0 1.0 -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/exp_approximation_${accuracy}_${accuracy}.bin -8.0 8.0 1.0 -10.0 10.0 "${accuracies[0]}"

        bound="${erf_bound[$accuracy]}"
        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/erf_approximation_${accuracy}_${i}_${accuracy}.bin -$bound $bound 1.0 -10.0 10.0 "${accuracies[$i]}"
        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/Vitis/erfc_approximation_${accuracy}_${i}_${accuracy}.bin -$bound $bound 1.0 -10.0 10.0 "${accuracies[$i]}"
    done
done

for accuracy in single double; do
    for i in 0 1 2 3 4 5; do
        declare -n accuracies="${accuracy}_accuracies"
        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/cos_approximation_${accuracy}.bin -5pi 5pi 1pi -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/sin_approximation_${accuracy}.bin -5pi 5pi 1pi -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/atan_approximation_${accuracy}.bin -7.0 7.0 1.0 -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/cosh_approximation_${accuracy}.bin -8.0 8.0 1.0 -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/sinh_approximation_${accuracy}.bin -8.0 8.0 1.0 -10.0 10.0 "${accuracies[0]}"

        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/exp_approximation_${accuracy}.bin -8.0 8.0 1.0 -10.0 10.0 "${accuracies[0]}"

        bound="${erf_bound[$accuracy]}"
        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/erf_approximation_${i}.bin -$bound $bound 1.0 -10.0 10.0 "${accuracies[$i]}"
        julia plot/linear.jl build_input/in_${accuracy}.bin build_float_deviations/oneAPI/erfc_approximation_${i}.bin -$bound $bound 1.0 -10.0 10.0 "${accuracies[$i]}"
    done
done
