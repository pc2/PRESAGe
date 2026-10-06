using PRESAGe
using Serialization

directory = only(ARGS)
request = deserialize(joinpath(directory, "request"))
mode = ENV["PRESAGE_WORKER_TEST_MODE"]

if mode == "late_result"
    PRESAGe._polynomial_worker_main(ARGS)
    sleep(120)
end

if (mode == "total" && request.degree == 1) || (mode != "total" && request.degree == 0)
    # Save an actual candidate before interrupting proof. No slow numerical call
    # is used to simulate a native hang or crash.
    candidate =
        polynomial_plan(request.spec, [0]; internal_format = request.internal_format)
    PRESAGe._worker_save(joinpath(directory, "candidate"), PRESAGe._plan_data(candidate))
    write(joinpath(directory, "ready"), "ready")
    if mode in ("timeout", "total")
        sleep(120)
    elseif mode == "crash"
        println(stderr, "controlled native-worker crash")
        exit(7)
    elseif mode == "bad_result"
        write(joinpath(directory, "result"), "invalid serialized response")
        exit(0)
    elseif mode == "no_result"
        exit(0)
    elseif mode == "exception"
        PRESAGe._worker_save(joinpath(directory, "error"), "controlled worker exception")
        exit(0)
    else
        error("unknown test worker mode")
    end
end

PRESAGe._polynomial_worker_main(ARGS)
