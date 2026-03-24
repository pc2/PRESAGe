#!/usr/bin/env julia
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

using JSON

function parse_frequency_data()
    # Read config.json
    config = JSON.parsefile("config.json")
    
    # Find all_intel_approximations group
    all_oneAPI_group = nothing
    for group in config["groups"]
        if group["name"] == "all_oneAPI_approximations"
            all_oneAPI_group = group
            break
        end
    end
    
    if all_oneAPI_group === nothing
        println("Error: all_oneAPI_approximations group not found in config.json")
        return
    end
    
    # Extract approximation names
    approximation_names = [approx["name"] for approx in all_oneAPI_group["approximations"]]

    println("Found $(length(approximation_names)) oneAPI approximations:")
    for name in approximation_names
        println("  - $name")
    end
    println()
    
    # Frequency overview
    frequency_data = []
    
    for name in approximation_names
        json_path = "oneAPI/build_$(name)_0/$(name).prj/reports/resources/json/quartus.ndjson"
        
        if !isfile(json_path)
            println("Warning: File not found: $json_path")
            continue
        end
        
        try
            # Read the NDJSON file
            content = read(json_path, String)
            data = JSON.parse(content)
            
            # Extract frequency information
            if haskey(data, "quartusFitClockSummary") && haskey(data["quartusFitClockSummary"], "nodes")
                nodes = data["quartusFitClockSummary"]["nodes"]
                for node in nodes
                    if haskey(node, "kernel clock")
                        kernel_clock = node["kernel clock"]
                        kernel_clock_fmax = get(node, "kernel clock fmax", "N/A")
                        
                        push!(frequency_data, Dict(
                            "name" => name,
                            "kernel_clock" => kernel_clock,
                            "kernel_clock_fmax" => kernel_clock_fmax
                        ))
                        
                        println("$name: Kernel Clock = $kernel_clock MHz, Fmax = $kernel_clock_fmax MHz")
                        break
                    end
                end
            else
                println("Warning: No clock summary found in $json_path")
            end
        catch e
            println("Error processing $json_path: $e")
        end
    end
    
    println("\n=== Frequency Overview ===")
    println("Name\t\t\t\tKernel Clock (MHz)\tFmax (MHz)")
    println("="^70)
    
    for entry in frequency_data
        name_padded = rpad(entry["name"], 30)
        println("$name_padded\t$(entry["kernel_clock"])\t\t$(entry["kernel_clock_fmax"])")
    end
 
    return frequency_data
end

if abspath(PROGRAM_FILE) == @__FILE__
    parse_frequency_data()
end
