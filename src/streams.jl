"""A reference could not be decided. It is never silently written as NaN."""
struct ReferenceFailure <: Exception
    index::Int
    result::ReferenceResult
end
Base.showerror(io::IO, e::ReferenceFailure) =
    print(io, "reference ", e.index, ": ", e.result.status, " (", e.result.detail, ")")

function _read_word(bytes, offset::Int, size::Int, order::Symbol)
    value = size <= 8 ? UInt64(0) : BigInt(0)
    for k = 0:(size - 1)
        shift = order == :little ? 8k : 8(size - 1 - k)
        value |=
            (size <= 8 ? UInt64(bytes[offset + k]) : BigInt(bytes[offset + k])) << shift
    end
    return value
end
function _write_word(io::IO, value::Integer, size::Int, order::Symbol)
    for k = 0:(size - 1)
        shift = order == :little ? 8k : 8(size - 1 - k)
        write(io, UInt8((value >> shift) & 0xff))
    end
end

function _reference_stream(
    input::IO,
    output::IO,
    statuses::IO,
    oracle::ReferenceOracle;
    chunk_elements::Int,
    byteorder::Symbol,
    summary::Dict,
)
    infmt, outfmt = oracle.spec.input_format, oracle.spec.output_format
    insize, outsize = _word_bytes(infmt), _word_bytes(outfmt)
    println(statuses, "index\tinput_bits\toutput_bits\tstatus\tprecision\tdetail")
    while true
        bytes = read(input, chunk_elements * insize)
        isempty(bytes) && break
        length(bytes) % insize == 0 || throw(ArgumentError("truncated final input word"))
        summary["maximum_chunk_elements"] =
            max(summary["maximum_chunk_elements"], length(bytes) ÷ insize)
        for offset = 1:insize:length(bytes)
            bits = _read_word(bytes, offset, insize, byteorder)
            result = reference(oracle, bits)
            summary["inputs_read"] += 1
            counts = summary["status_counts"]
            key = string(result.status)
            counts[key] = get(counts, key, 0) + 1
            summary["maximum_precision"] =
                max(summary["maximum_precision"], result.precision)
            outputbits = result.bits === nothing ? "" : hex_bits(result.bits, outfmt)
            detail = replace(result.detail, '\t' => ' ', '\n' => ' ', '\r' => ' ')
            println(
                statuses,
                summary["inputs_read"],
                '\t',
                hex_bits(bits, infmt),
                '\t',
                outputbits,
                '\t',
                result.status,
                '\t',
                result.precision,
                '\t',
                detail,
            )
            result.bits === nothing &&
                throw(ReferenceFailure(summary["inputs_read"], result))
            _write_word(output, result.bits, outsize, byteorder)
            summary["outputs_written"] += 1
        end
    end
    return summary
end

"""
    generate_references(spec, input_path, output_path; chunk_elements=4096,
                        byteorder=:little, backend=:sollya, config=OracleConfig())

Bounded-memory binary references, with a TOML manifest and a status TSV. Partial
final chunks are accepted; truncated words are rejected. An unresolved result
aborts generation, records its status, and leaves the final binary unpublished.
An existing output is refused. No process-global BigFloat settings are changed.
"""
function generate_references(
    spec::FunctionSpec,
    input_path::AbstractString,
    output_path::AbstractString;
    chunk_elements::Integer = 4096,
    byteorder::Symbol = :little,
    backend::Symbol = :sollya,
    config::OracleConfig = OracleConfig(),
)
    insize, outsize = _word_bytes(spec.input_format), _word_bytes(spec.output_format)
    1 <= chunk_elements <= typemax(Int) ÷ insize ||
        throw(ArgumentError("invalid chunk size"))
    byteorder in (:little, :big) ||
        throw(ArgumentError("byteorder must be :little or :big"))
    input, output = abspath(input_path), abspath(output_path)
    input == output && throw(ArgumentError("input and output must differ"))
    isfile(input) || throw(ArgumentError("input file not found"))
    for path in (output, output * ".toml", output * ".status.tsv")
        ispath(path) && throw(ArgumentError("refusing to overwrite $path"))
    end
    mkpath(dirname(output))
    summary = Dict{String, Any}(
        "schema" => "presage-reference-stream",
        "schema_version" => (
            spec.input_format isa FixedFormat || spec.output_format isa FixedFormat ? 2 : 1
        ),
        "complete" => false,
        "input_path" => input,
        "output_path" => output,
        "byteorder" => string(byteorder),
        "input_format" => _format_data(spec.input_format),
        "output_format" => _format_data(spec.output_format),
        "expression" => spec.expression,
        "backend" => string(backend),
        "initial_precision" => config.initial_precision,
        "precision_limit" => config.max_precision,
        "precision_growth" => config.growth,
        "chunk_elements" => Int(chunk_elements),
        "maximum_chunk_elements" => 0,
        "inputs_read" => 0,
        "outputs_written" => 0,
        "maximum_precision" => 0,
        "status_counts" => Dict{String, Int}(),
    )
    if spec.input_format isa FixedFormat ||
       spec.output_format isa FixedFormat ||
       _width(spec.input_format) % 8 != 0 ||
       _width(spec.output_format) % 8 != 0
        summary["input_word_bytes"], summary["output_word_bytes"] = insize, outsize
        summary["padding"] = "zero_high_bits"
    end
    spec.domain === nothing || (summary["domain"] = _rational_text.(collect(spec.domain)))
    temporary, tmpio = mktemp(dirname(output))
    try
        with_oracle(spec; backend, config) do oracle
            open(input, "r") do inio
                open(output * ".status.tsv", "w") do statuses
                    _reference_stream(
                        inio,
                        tmpio,
                        statuses,
                        oracle;
                        chunk_elements = Int(chunk_elements),
                        byteorder,
                        summary,
                    )
                end
            end
        end
        close(tmpio)
        mv(temporary, output)
        summary["complete"] = true
    catch error
        summary["failure"] = sprint(showerror, error)
        rethrow()
    finally
        isopen(tmpio) && close(tmpio)
        ispath(temporary) && rm(temporary)
        open(output * ".toml", "w") do io
            TOML.print(io, summary; sorted = true)
        end
    end
    return summary
end
