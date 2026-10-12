#!/usr/bin/env julia
using PRESAGe

function synthesize_main(args)
    length(args) >= 2 || error(
        "Usage: synthesize.jl prepare|run|collect|emulate|calibrate MANIFEST.toml [FLOW|EXAMPLE|PROFILE]",
    )
    action, path = args[1:2]
    if action == "prepare"
        length(args) in (2, 3) || error("prepare accepts an optional flow")
        println(prepare_synthesis(path; flow = length(args) == 3 ? Symbol(args[3]) : :auto))
    elseif action == "run"
        length(args) in (2, 3) ||
            error("run requires a synthesis project and optional example")
        run_synthesis(path; example = length(args) == 3 ? args[3] : nothing)
    elseif action == "collect"
        length(args) == 2 || error("collect requires a synthesis project")
        println(collect_synthesis(path))
    elseif action == "calibrate"
        length(args) == 3 ||
            error("calibrate requires a synthesis project and output profile")
        calibrate_resource_model(path, args[3])
    elseif action == "emulate"
        length(args) in (2, 3) ||
            error("emulate requires a synthesis project and optional example")
        run_emulation(path; example = length(args) == 3 ? args[3] : nothing)
    else
        error("unknown synthesis action $action")
    end
    return 0
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(synthesize_main(ARGS))
end
