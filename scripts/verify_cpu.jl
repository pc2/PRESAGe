#!/usr/bin/env julia
using PRESAGe

function verification_inputs(plan;random_count=2048)
    f = plan.spec.input_format
    sign = PRESAGe._sign(f)
    words = UInt64[0,sign,1,sign|1,PRESAGe._inf(f),sign|PRESAGe._inf(f),
                   PRESAGe._inf(f)-1,sign|(PRESAGe._inf(f)-1),PRESAGe._nan(f),sign|PRESAGe._nan(f)]
    points = Rational{BigInt}[0,1//2,1,2,4,-1//2,-1,-2,-4]
    for s in plan.segments
        append!(points,[s.lower,s.upper,(s.lower+s.upper)/2])
    end
    plan.spec.domain === nothing || append!(points,collect(plan.spec.domain))
    for point in points
        word = round_ieee(point,f)
        for b in (word,xor(word,sign))
            push!(words,b)
            b > 0 && push!(words,b-1)
            b < PRESAGe._wordmask(f) && push!(words,b+1)
        end
    end
    state = UInt64(0x8baf672eb17227d9)
    for _ in 1:random_count
        state = state*UInt64(6364136223846793005)+UInt64(1442695040888963407)
        push!(words,state & PRESAGe._wordmask(f))
    end
    return unique(words)
end

function verify_cpu(plan,executable;words=verification_inputs(plan))
    p = plan.program
    p === nothing && error("plan has no evaluator")
    firstload = findfirst(n -> n isa IR.TableLoad,p.nodes)
    index = firstload === nothing ? nothing : p.nodes[firstload].index
    outsize = div(PRESAGe._width(plan.spec.output_format),8)
    mktempdir() do directory
        input,output = joinpath(directory,"input.bin"),joinpath(directory,"output.bin")
        open(input,"w") do io
            for word in words
                PRESAGe._write_word(io,word,div(PRESAGe._width(plan.spec.input_format),8),:little)
            end
        end
        run(pipeline(`$executable --trace-index`;stdin=input,stdout=output))
        bytes = read(output)
        length(bytes) == length(words)*(outsize+8) || error("incorrect CPU output size")
        for (i,word) in enumerate(words)
            trace = interpret_trace(p,word)
            offset = 1+(i-1)*(outsize+8)
            actual = PRESAGe._read_word(bytes,offset,outsize,:little)
            actual == trace.bits || error("CPU/interpreter mismatch at $(hex_bits(word,plan.spec.input_format))")
            selected = PRESAGe._read_word(bytes,offset+outsize,8,:little)
            expected = index === nothing ? typemax(UInt64) : get(trace.values,index,typemax(UInt64))
            selected == expected || error("table selection mismatch at $(hex_bits(word,plan.spec.input_format))")
        end
    end
    return length(words)
end
if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 2 || error("Usage: verify_cpu.jl PLAN.toml EXECUTABLE")
    count = verify_cpu(read_plan(ARGS[1]),abspath(ARGS[2]))
    println("CPU/interpreter outputs and table selections agree on ",count," inputs")
end
