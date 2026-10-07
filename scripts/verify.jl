#!/usr/bin/env julia
using PRESAGe

function verification_main(args)
    length(args) >= 3 || error(
        "Usage: scripts/verify.jl PLAN.toml OUTPUT_DIR --checker=EXEC [--evaluator=EXEC] [--backend=sollya|mpfr] [--exhaustive-bits=N]",
    )
    options = Dict{String, String}()
    for arg in args[3:end]
        parts = split(arg, '='; limit = 2)
        length(parts) == 2 &&
            parts[1] in ("--checker", "--evaluator", "--backend", "--exhaustive-bits") &&
            !isempty(parts[2]) &&
            !haskey(options, parts[1]) || error("Invalid or duplicate option: $arg")
        options[parts[1]] = parts[2]
    end
    haskey(options, "--checker") || error("--checker is required")
    report = verify_samples(
        read_plan(args[1]);
        checker = options["--checker"],
        evaluator = get(options, "--evaluator", nothing),
        directory = args[2] == "-" ? nothing : args[2],
        backend = Symbol(get(options, "--backend", "sollya")),
        sampling = VerificationSampling(
            exhaustive_bits = parse(Int, get(options, "--exhaustive-bits", "12")),
        ),
    )
    println(
        "Verification $(report["status"]): $(report["counts"]["tested"]) inputs; $(report["counts"]["bit_mismatches"]) bit mismatches, $(report["counts"]["accuracy_failed"]) accuracy failures",
    )
    return Dict("passed" => 0, "failed" => 1, "unresolved" => 2)[report["status"]]
end

if abspath(PROGRAM_FILE) == @__FILE__
    exit(verification_main(ARGS))
end
