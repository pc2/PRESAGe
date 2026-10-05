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

function verify_cpu(plan,executable;words=verification_inputs(plan),
    trace_fixed=plan.program !== nothing && PRESAGe._has_fixed(plan.program))
    p = plan.program
    p === nothing && error("plan has no evaluator")
    firstload = findfirst(n -> n isa IR.TableLoad,p.nodes)
    index = firstload === nothing ? nothing : p.nodes[firstload].index
    outsize = div(PRESAGe._width(plan.spec.output_format),8)
    fixed = trace_fixed ? [(i,f) for (i,f) in enumerate(p.types) if f isa FixedFormat] : []
    stride = outsize+8+sum((1+cld(f.width,8) for (_,f) in fixed);init=0)
    mktempdir() do directory
        input,output = joinpath(directory,"input.bin"),joinpath(directory,"output.bin")
        open(input,"w") do io
            for word in words
                PRESAGe._write_word(io,word,div(PRESAGe._width(plan.spec.input_format),8),:little)
            end
        end
        option = trace_fixed ? "--trace-fixed" : "--trace-index"
        run(pipeline(`$executable $option`;stdin=input,stdout=output))
        bytes = read(output)
        length(bytes) == length(words)*stride || error("incorrect CPU output size")
        for (i,word) in enumerate(words)
            trace = interpret_trace(p,word)
            offset = 1+(i-1)*stride
            actual = PRESAGe._read_word(bytes,offset,outsize,:little)
            actual == trace.bits || error("CPU/interpreter mismatch at $(hex_bits(word,plan.spec.input_format))")
            selected = PRESAGe._read_word(bytes,offset+outsize,8,:little)
            expected = index === nothing ? typemax(UInt64) : get(trace.values,index,typemax(UInt64))
            selected == expected || error("table selection mismatch at $(hex_bits(word,plan.spec.input_format))")
            offset += outsize+8
            for (node,f) in fixed
                ready = bytes[offset]
                visited = haskey(trace.values,node)
                ready == visited || error("fixed node $node visitation mismatch at $(hex_bits(word,plan.spec.input_format))")
                payload = BigInt(0)
                for byte in 0:cld(f.width,8)-1
                    payload |= BigInt(bytes[offset+1+byte]) << (8byte)
                end
                expected = visited ? trace.values[node].bits : BigInt(0)
                payload == expected || error("fixed node $node payload mismatch at $(hex_bits(word,plan.spec.input_format))")
                offset += 1+cld(f.width,8)
            end
        end
    end
    return length(words)
end
if abspath(PROGRAM_FILE) == @__FILE__
    length(ARGS) == 2 || error("Usage: verify_cpu.jl PLAN.toml EXECUTABLE")
    count = verify_cpu(read_plan(ARGS[1]),abspath(ARGS[2]))
    println("CPU/interpreter outputs, table selections and fixed intermediates agree on ",count," inputs")
end
