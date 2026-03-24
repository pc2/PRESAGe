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
# IEEE 754 Table 3.5

function floatfilemeta(num_bytes)
    if num_bytes == 131072
        Float16, UInt16, 6
    elseif num_bytes == 262144
        Float32, UInt32, 6
    elseif num_bytes == 536870912
        Float32, UInt32, 9
    elseif num_bytes == 1073741824
        Float64, UInt64, 9
    elseif num_bytes == 68719476736
        Float64, UInt64, 12
    elseif num_bytes == 137438953472
        Float128, UInt128, 12
    else
        throw(AssertionError("unsupported filesize"))
    end
end

k(::Type{F}) where {F <: AbstractFloat} = sizeof(F) * 8

function p(::Type{F}) where {F <: AbstractFloat}
    if k(F) == 16
        11
    elseif k(F) == 32
        24
    elseif k(F) == 64
        53
    elseif (k(F) >= 128) && (mod(k(F), 32) == 0)
        k(F) - Int(round(4 * log(2, k(F)))) + 13
    else
        throw(AssertionError("unsupported AbstractFloat"))
    end
end

emax(::Type{F}) where {F <: AbstractFloat} = 2^(k(F) - p(F) - 1) - 1

bias(::Type{F}) where {F <: AbstractFloat} = emax(F)

function w(::Type{F}) where {F <: AbstractFloat}
    if k(F) == 16
        5
    elseif k(F) == 32
        8
    elseif k(F) == 64
        11
    elseif (k(F) >= 128) && (mod(k(F), 32) == 0)
        Int(round(4 * log(2, k(F)))) - 13
    else
        throw(AssertionError("unsupported AbstractFloat"))
    end
end

t(::Type{F}) where {F <: AbstractFloat} = k(F) - w(F) - 1

function binade_to_exp(i, ::Type{F}) where {F <: AbstractFloat}
    num_exp = 2^(k(F) - p(F) - 1)
    if i > div(num_exp) / 2
        i -= div(num_exp) / 2
    end
    i - bias(F) - 1
end

binade_to_sign(i, ::Type{F}) where {F <: AbstractFloat} = i >  div(2^(k(F) - p(F) - 1), 2)

subnormal_exponent_dict = Dict(
    "half" => -15,
    "single" => -127,
    "double" => -1023,
)

nan_exponent_dict = Dict(
    "half" => 16,
    "single" => 128,
    "double" => 1024,
)

function consecutive_map(bytes::B) where {B <: Unsigned}
    signmask = one(B) << (sizeof(B) * 8 - 1)
    if (bytes & signmask) == zero(B)
        bytes | signmask
    else
        ~bytes
    end
end
