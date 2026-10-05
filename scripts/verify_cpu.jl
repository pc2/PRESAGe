#!/usr/bin/env julia
using PRESAGe

function verification_inputs(plan;random_count=2048)
    f = plan.spec.input_format
    sign = f isa FixedFormat ? BigInt(1)<<(f.width-1) : PRESAGe._sign(f)
    mask = f isa FixedFormat ? PRESAGe._fixed_mask(f) : PRESAGe._wordmask(f)
    words = f isa FixedFormat ? BigInt[0,1,mask,sign,sign-1,sign+1] : UInt64[0,sign,1,sign|1,PRESAGe._inf(f),sign|PRESAGe._inf(f),
                   PRESAGe._inf(f)-1,sign|(PRESAGe._inf(f)-1),PRESAGe._nan(f),sign|PRESAGe._nan(f)]
    filter!(x -> 0 <= x <= mask,words)
    points = Rational{BigInt}[0,1//2,1,2,4,-1//2,-1,-2,-4]
    for s in plan.segments
        append!(points,[s.lower,s.upper,(s.lower+s.upper)/2])
    end
    plan.spec.domain === nothing || append!(points,collect(plan.spec.domain))
    for point in points
        word = if f isa FixedFormat
            sample = FixedFormat(f.width,f.integer_bits;signed=f.signed,rounding=f.rounding,overflow=:saturate)
            round_fixed(point,sample)
        else
            round_ieee(point,f)
        end
        for b in (f isa FixedFormat ? (word,) : (word,xor(word,sign)))
            push!(words,b)
            b > 0 && push!(words,b-1)
            b < mask && push!(words,b+1)
        end
    end
    state = UInt64(0x8baf672eb17227d9)
    for _ in 1:random_count
        word = f isa FixedFormat ? BigInt(0) : UInt64(0)
        for _ in 1:cld(PRESAGe._width(f),64)
            state = state*UInt64(6364136223846793005)+UInt64(1442695040888963407)
            word = f isa FixedFormat ? (word<<64)|state : state
        end
        push!(words,word & mask)
    end
    f isa FixedFormat && f.width <= 12 && append!(words,BigInt.(0:Int(mask)))
    if plan.spec.output_format isa FixedFormat
        filter!(words) do word
            x = PRESAGe._decode_input(word,f)
            x.kind in (:finite,:zero) && (plan.spec.domain === nothing || plan.spec.domain[1] <= x.value <= plan.spec.domain[2])
        end
    end
    return unique(words)
end

function verify_cpu(plan,executable;words=verification_inputs(plan),
    trace_fixed=plan.program !== nothing && PRESAGe._has_fixed(plan.program))
    p = plan.program
    p === nothing && error("plan has no evaluator")
    firstload = findfirst(n -> n isa IR.TableLoad,p.nodes)
    index = firstload === nothing ? nothing : p.nodes[firstload].index
    outsize = PRESAGe._word_bytes(plan.spec.output_format)
    fixed = trace_fixed ? [(i,f) for (i,f) in enumerate(p.types) if f isa FixedFormat] : []
    stride = outsize+8+sum((1+cld(f.width,8) for (_,f) in fixed);init=0)
    mktempdir() do directory
        input,output = joinpath(directory,"input.bin"),joinpath(directory,"output.bin")
        open(input,"w") do io
            for word in words
                PRESAGe._write_word(io,word,PRESAGe._word_bytes(plan.spec.input_format),:little)
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
