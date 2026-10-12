function _emulation_words(plan)
    format = plan.spec.input_format
    width = _kernel_width(format)
    width <= 12 && return BigInt.(0:((1 << width) - 1))
    if format isa FloatFormat
        values = BigInt[round_ieee(i // 16, format) for i = -32:32]
        append!(
            values,
            [
                0,
                1,
                _sign(format),
                _sign(format) | 1,
                _inf(format),
                _inf(format) | _sign(format),
                _nan(format),
            ],
        )
        return unique(values)
    end
    maximum = (big(1) << width) - 1
    words = [big(0), big(1), maximum, [div(i * maximum, 256) for i = 1:255]...]
    if get(plan.settings, "resource_probe", "") == "independent_operands"
        operand = plan.spec.output_format
        bits = _kernel_width(operand)
        values =
            operand isa FloatFormat ?
            BigInt[
                0,
                1,
                _sign(operand),
                _sign(operand) | 1,
                _inf(operand),
                _inf(operand) | _sign(operand),
                _nan(operand),
                round_ieee(1, operand),
                round_ieee(-1, operand),
            ] :
            BigInt[
                0,
                1,
                (big(1) << bits) - 1,
                (big(1) << (bits - 1)) - 1,
                big(1) << (bits - 1),
            ]
        for operands in Iterators.product(fill(values, div(width, bits))...)
            push!(
                words,
                sum(
                    value << ((index - 1) * bits) for (index, value) in enumerate(operands)
                ),
            )
        end
    end
    return unique(words)
end

function _emulation_vectors(path, plan)
    words = _emulation_words(plan)
    bits, statuses = BigInt[], Int[]
    for word in words
        try
            push!(bits, interpret_trace(plan.program, word).bits)
            push!(statuses, 0)
        catch error
            status =
                error isa DomainError ? 1 :
                error isa OverflowError ? 2 : error isa BoundsError ? 3 : rethrow()
            push!(bits, 0)
            push!(statuses, status)
        end
    end
    open(path, "w") do io
        widths =
            (_kernel_width(plan.spec.input_format), _kernel_width(plan.spec.output_format))
        println(
            io,
            "constexpr unsigned input_width = $(widths[1]), output_width = $(widths[2]);",
        )
        for (name, values) in
            (("inputs", words), ("expected", bits), ("statuses", statuses))
            width = name == "inputs" ? widths[1] : widths[2]
            chunks = name == "statuses" ? "" : "[$(cld(width, 64))]"
            println(io, "constexpr unsigned long long $name[]$chunks = {")
            for value in values
                literal =
                    name == "statuses" ? string(value) : "{$(_kernel_chunks(value, width))}"
                println(io, "    $literal,")
            end
            println(io, "};")
        end
        println(io, "constexpr unsigned count = $(length(words));")
        println(
            io,
            """
template<class T, unsigned Width> T from_words(const unsigned long long* words) {
    T value = 0;
    for (unsigned bit = 0; bit < Width; ++bit)
        value[bit] = bool((words[bit / 64] >> (bit % 64)) & 1);
    return value;
}
""",
        )
    end
    return length(words)
end

function _emulation_source(toolchain; packed = false)
    if toolchain == :oneapi
        input_type = packed ? "InputPacket" : "InputBits"
        initialize =
            packed ? """
        for (unsigned i = 0; i < count; ++i)
            for (unsigned chunk = 0; chunk < (input_width + 63) / 64; ++chunk)
                input[i].bits[chunk] = inputs[i][chunk];
""" :
            "        for (unsigned i = 0; i < count; ++i) input[i] = from_words<InputBits, input_width>(inputs[i]);\n"
        compare =
            packed ? """
            bool mismatch = output[i].status != statuses[i];
            for (unsigned chunk = 0; chunk < (output_width + 63) / 64; ++chunk)
                mismatch |= output[i].bits[chunk] != expected[i][chunk];
""" :
            "            bool mismatch = output[i].bits != from_words<OutputBits, output_width>(expected[i]) || output[i].status != statuses[i];\n"
        return """
#include "synthesis.cpp"
#include "emulation-vectors.hpp"
#include <iostream>
#include <vector>
int main() {
    try {
        sycl::queue queue(sycl::ext::intel::fpga_emulator_selector_v);
        std::vector<$input_type> input(count);
        std::vector<OutputPacket> output(count);
$initialize
        {
            sycl::buffer<$input_type> in(input.data(), sycl::range<1>(count));
            sycl::buffer<OutputPacket> out(output.data(), sycl::range<1>(count));
            presage_resource_pipeline(queue, in, out, count);
        }
        for (unsigned i = 0; i < count; ++i) {
$compare
            if (mismatch) {
                std::cerr << "Mismatch at input " << i << std::endl;
                return 1;
            }
        }
        std::cout << "Passed " << count << " FPGA emulator inputs" << std::endl;
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << std::endl;
        return 2;
    }
}
"""
    end
    return """
#include "evaluator.hpp"
#include "emulation-vectors.hpp"
#include <iostream>
using namespace presage_evaluator;
extern "C" void presage_resource_kernel(InputBits, OutputBits&, unsigned&);
int main() {
    for (unsigned i = 0; i < count; ++i) {
        OutputBits bits = 0;
        unsigned status = 0;
        presage_resource_kernel(from_words<InputBits, input_width>(inputs[i]), bits, status);
        if (bits != from_words<OutputBits, output_width>(expected[i]) || status != statuses[i]) {
            std::cerr << "Mismatch at input " << i << std::endl;
            return 1;
        }
    }
    std::cout << "Passed " << count << " HLS C simulation inputs" << std::endl;
    return 0;
}
"""
end

"""Validate calibration kernels with the Intel FPGA emulator or Vitis HLS C simulation."""
function run_emulation(path::AbstractString; example = nothing)
    project, root = _synthesis_project(path)
    manifest = _synthesis_manifest(joinpath(root, project["manifest"]))
    toolchain = Symbol(project["toolchain"])
    for job in _synthesis_jobs(project, example)
        directory = joinpath(root, job["directory"])
        record_path = joinpath(directory, "emulation-run.toml")
        isfile(record_path) &&
            throw(ArgumentError("emulation run already exists in $directory"))
        example = only(filter(row -> row["name"] == job["name"], manifest["examples"]))
        plan = read_plan(joinpath(root, example["plan"]))
        count = _emulation_vectors(joinpath(directory, "emulation-vectors.hpp"), plan)
        packed =
            toolchain == :oneapi && occursin(
                "struct InputPacket",
                read(joinpath(directory, "synthesis.cpp"), String),
            )
        write(joinpath(directory, "emulation.cpp"), _emulation_source(toolchain; packed))
        commands = if toolchain == :oneapi
            compiler = `icpx -std=c++17 -fsycl -fintelfpga -qactypes -fp-model=strict -no-ftz`
            if _kernel_has_float_arithmetic(plan.program)
                library = normpath(
                    joinpath(
                        dirname(Sys.which("icpx")),
                        "..",
                        "opt",
                        "oclfpga",
                        "host",
                        "linux64",
                        "lib",
                    ),
                )
                compiler = `$compiler -D__EMULATION_FLOW__ -L$library
                    -Wl,-rpath,$library -lac_types_vpfp_library`
            end
            [`$compiler emulation.cpp -o emulate`, `./emulate`]
        else
            write(
                joinpath(directory, "emulation.tcl"),
                """
open_project emulation
set_top presage_resource_kernel
add_files kernel.cpp -cflags {-std=c++17}
add_files -tb emulation.cpp -cflags {-std=c++17}
open_solution solution -flow_target vitis
set_part {$(project["device"])}
csim_design
exit
""",
            )
            [`vitis_hls -f emulation.tcl`]
        end
        passed = false
        started = time()
        try
            mktempdir(directory; prefix = "emulator-") do temporary
                withenv(
                    "TMPDIR" => temporary,
                    "TMP" => temporary,
                    "TEMP" => temporary,
                    "CL_CONFIG_CPU_EMULATE_DEVICES" => "1",
                    "SYCL_CACHE_DIR" => temporary,
                ) do
                    cd(directory) do
                        open("emulation.log", "w") do log
                            for command in commands
                                run(pipeline(command; stdout = log, stderr = log))
                            end
                        end
                    end
                end
            end
            passed = true
        finally
            _synthesis_write(
                record_path,
                Dict(
                    "success" => passed,
                    "tested_inputs" => count,
                    "mode" => toolchain == :oneapi ? "fpga_emulator" : "hls_csim",
                    "commands" => collect.(commands),
                    "elapsed_seconds" => time() - started,
                    "project_sha256" => _synthesis_hash(path),
                    "sources" => Dict(
                        file => _synthesis_hash(joinpath(directory, file)) for
                        file in ("emulation.cpp", "emulation-vectors.hpp")
                    ),
                ),
            )
        end
    end
    return nothing
end
