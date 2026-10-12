const _SYNTHESIS_DEFAULT_TARGETS =
    Dict(:vitis => "xcu280-fsvh2892-2L-e", :oneapi => "p520_hpc_sg280l")

function _synthesis_manifest(path)
    data = TOML.parsefile(path)
    get(data, "schema", "") == "presage-resource-examples" ||
        throw(ArgumentError("expected a resource example manifest"))
    get(data, "schema_version", 0) === 1 ||
        throw(ArgumentError("unsupported example schema"))
    names = [row["name"] for row in data["examples"]]
    !isempty(names) && length(unique(names)) == length(names) ||
        throw(ArgumentError("example names must be nonempty and unique"))
    return data
end

"""Build precision specific arithmetic rules from verified primitive synthesis reports."""
function _resource_calibration(project_path)
    project, root = _synthesis_project(project_path)
    manifest = _synthesis_manifest(joinpath(root, project["manifest"]))
    measurement_path = collect_synthesis(project_path)
    rows = TOML.parsefile(measurement_path)["examples"]
    isempty(rows) && throw(ArgumentError("calibration needs completed primitive reports"))
    data = _resource_model_data(
        read_resource_model(joinpath(root, first(manifest["examples"])["model"])),
    )
    rules, evidence = Dict{String, Any}[], Dict{String, Any}[]
    pipeline_unknown = Set{String}()
    for row in rows
        example =
            only(filter(example -> example["name"] == row["name"], manifest["examples"]))
        acceptance = _synthesis_acceptance(row, manifest, example, root)
        acceptance["status"] == "passed" ||
            throw(ArgumentError(join(acceptance["reasons"], ", ")))
        _resource_model_data(read_resource_model(joinpath(root, example["model"]))) ==
        data || throw(ArgumentError("calibration probes must share a base profile"))
        plan = read_plan(joinpath(root, example["plan"]))
        get(plan.settings, "resource_probe", "") == "independent_operands" ||
            throw(ArgumentError("calibration requires an independent operand probe"))
        program = plan.program
        node = program.nodes[program.output]
        node isa Union{IR.Add, IR.Mul, IR.FMA} ||
            throw(ArgumentError("unsupported calibration operation"))
        count(n -> n isa Union{IR.Add, IR.Mul, IR.FMA}, program.nodes) == 1 ||
            throw(ArgumentError("a calibration probe must isolate one operation"))
        all(
            n ->
                n isa Union{
                    IR.Input,
                    IR.Const,
                    IR.BitCast,
                    IR.ExtractBits,
                    IR.Add,
                    IR.Mul,
                    IR.FMA,
                },
            program.nodes,
        ) || throw(
            ArgumentError(
                "calibration operands must use only constants or input bit extraction",
            ),
        )
        format = IR.format(program)
        rule = Dict{String, Any}(
            "operation" => string(_resource_operation(node)),
            "format" => string(_resource_family(format)),
            "rounding" => string(node.rounding),
            "result_width" => _resource_width(format),
            "formats" => [
                Dict("format" => _format_data(f)) for
                f in (format, (IR.format(program, ref) for ref in IR.refs(node))...)
            ],
            "operand_widths" =>
                [_resource_width(IR.format(program, ref)) for ref in IR.refs(node)],
            "operand_constants" => [
                program.nodes[ref] isa IR.Const ? _ir_hex(program.nodes[ref].bits) :
                "variable" for ref in IR.refs(node)
            ],
        )
        if format isa FloatFormat
            rule["exponent_bits"], rule["fraction_bits"] =
                format.exponent_bits, format.fraction_bits
        else
            rule["integer_bits"], rule["overflow"] =
                format.integer_bits, string(format.overflow)
        end
        pipeline = filter(part -> get(part, "kind", "") == "pipeline", row["components"])
        for name in _RESOURCE_NAMES
            key = string(name)
            state = sum((_resource_exact(part[key]) for part in pipeline); init = 0)
            state > 0 && push!(pipeline_unknown, key)
            rule[key] = _resource_number_data(_resource_exact(row[key]) - state)
        end
        push!(rules, rule)
        proof = Dict{String, Any}(
            "example" => row["name"],
            "tool_version" => row["tool_version"],
            "device" => row["device"],
            "sources" => row["sources"],
            "reports" => row["reports"],
            "scope" => row["scope"],
            "pipeline" => pipeline,
            "resource_units" => row["resource_units"],
        )
        directory = dirname(joinpath(root, example["header"]))
        emulation_path = joinpath(directory, "emulation-run.toml")
        if isfile(emulation_path)
            emulation = TOML.parsefile(emulation_path)
            emulation["success"] &&
                emulation["project_sha256"] == _synthesis_hash(project_path) || throw(
                ArgumentError(
                    "calibration probe emulation failed or uses a different project",
                ),
            )
            all(
                _synthesis_hash(joinpath(directory, file)) == digest for
                (file, digest) in emulation["sources"]
            ) || throw(ArgumentError("calibration probe emulation sources changed"))
            proof["emulation"] =
                merge(emulation, Dict("record_sha256" => _synthesis_hash(emulation_path)))
        end
        push!(evidence, proof)
    end
    return (;
        data,
        rules,
        evidence,
        pipeline_unknown,
        toolchain = project["toolchain"],
        device = project["device"],
        flow = project["flow"],
        project_sha256 = _synthesis_hash(project_path),
        measurements_sha256 = _synthesis_hash(measurement_path),
    )
end

calibrate_resource_model(project::AbstractString, destination::AbstractString) =
    calibrate_resource_model([project], destination)

function calibrate_resource_model(
    projects::AbstractVector{<:AbstractString},
    destination::AbstractString,
)
    isempty(projects) && throw(ArgumentError("calibration needs at least one project"))
    parts = _resource_calibration.(projects)
    first_part = first(parts)
    all(
        part ->
            (part.toolchain, part.device, part.flow, part.data) ==
            (first_part.toolchain, first_part.device, first_part.flow, first_part.data),
        parts,
    ) || throw(
        ArgumentError("calibration projects must share target, flow and base profile"),
    )
    versions = unique(row["tool_version"] for part in parts for row in part.evidence)
    length(versions) == 1 ||
        throw(ArgumentError("calibration projects must use one compiler version"))
    data = deepcopy(first_part.data)
    rules = Dict{String, Any}[]
    seen = Dict{String, Dict}()
    for rule in reduce(vcat, [part.rules for part in parts])
        signature =
            Dict(key => value for (key, value) in rule if Symbol(key) ∉ _RESOURCE_NAMES)
        key = sprint(io -> TOML.print(io, signature; sorted = true))
        costs = Dict(name => rule[string(name)] for name in _RESOURCE_NAMES)
        if haskey(seen, key)
            seen[key] == costs ||
                throw(ArgumentError("conflicting costs for the same calibration rule"))
        else
            seen[key] = costs
            push!(rules, rule)
        end
    end
    data["rules"] = [rules; data["rules"]]
    data["name"] = "$(first_part.toolchain)-$(first_part.device)-calibrated"
    data["target"] = Dict("device" => first_part.device, "compiler" => only(versions))
    for key in union((part.pipeline_unknown for part in parts)...)
        data["pipeline"][key] = "unknown"
    end
    model = _read_resource_model(data)
    mkpath(dirname(abspath(destination)))
    write_resource_model(destination, model)
    _synthesis_write(
        destination * ".evidence.toml",
        Dict(
            "schema" => "presage-resource-calibration",
            "schema_version" => 1,
            "profile_sha256" => _synthesis_hash(destination),
            "validation" => "primitive_only",
            "projects" => [
                Dict(
                    "path" => relpath(abspath(path), dirname(abspath(destination))),
                    "project_sha256" => part.project_sha256,
                    "measurements_sha256" => part.measurements_sha256,
                ) for (path, part) in zip(projects, parts)
            ],
            "probes" => reduce(vcat, [part.evidence for part in parts]),
        ),
    )
    return model
end

_synthesis_hash(path) = bytes2hex(sha256(read(path)))
_synthesis_write(path, data) = open(io -> TOML.print(io, data; sorted = true), path, "w")

function _synthesis_oneapi_source(plan)
    input_width = _kernel_width(plan.spec.input_format)
    output_width = _kernel_width(plan.spec.output_format)
    return """
#include <sycl/sycl.hpp>
#include <sycl/ext/intel/fpga_extensions.hpp>
#include <array>
#include "evaluator.hpp"
using namespace presage_evaluator;
struct InputPacket { std::array<unsigned long long, $(cld(input_width, 64))> bits; };
struct OutputPacket { std::array<unsigned long long, $(cld(output_width, 64))> bits; unsigned status; };
struct EvaluatorPacket { OutputBits bits; unsigned status; };
using InputPipe = sycl::ext::intel::pipe<class InputPipeID, InputBits, 16384 / sizeof(InputBits)>;
using OutputPipe = sycl::ext::intel::pipe<class OutputPipeID, EvaluatorPacket, 16384 / sizeof(EvaluatorPacket)>;
void presage_resource_pipeline(sycl::queue& queue, sycl::buffer<InputPacket>& input,
    sycl::buffer<OutputPacket>& output, std::size_t count) {
    queue.submit([&](sycl::handler& handler) {
        sycl::accessor values(input, handler, sycl::read_only);
        handler.single_task<class ReadKernel>([=]() [[intel::kernel_args_restrict]] {
            for (std::size_t i = 0; i < count; ++i) {
                InputBits bits = 0;
                #pragma unroll
                for (unsigned bit = 0; bit < $input_width; ++bit)
                    bits[bit] = bool((values[i].bits[bit / 64] >> (bit % 64)) & 1);
                InputPipe::write(bits);
            }
        });
    });
    queue.submit([&](sycl::handler& handler) {
        handler.single_task<class OperationKernel>([=]() [[intel::kernel_args_restrict]] {
            presage_evaluate:
            [[intel::initiation_interval(1)]]
            for (std::size_t i = 0; i < count; ++i) {
                auto result = evaluate_bits(InputPipe::read());
                OutputPipe::write({result.bits, static_cast<unsigned>(result.status)});
            }
        });
    });
    queue.submit([&](sycl::handler& handler) {
        sycl::accessor values(output, handler, sycl::write_only, sycl::no_init);
        handler.single_task<class WriteKernel>([=]() [[intel::kernel_args_restrict]] {
            for (std::size_t i = 0; i < count; ++i) {
                auto result = OutputPipe::read();
                OutputPacket packet{};
                packet.status = result.status;
                #pragma unroll
                for (unsigned bit = 0; bit < $output_width; ++bit)
                    packet.bits[bit / 64] |= static_cast<unsigned long long>(bool(result.bits[bit])) << (bit % 64);
                values[i] = packet;
            }
        });
    });
    queue.wait_and_throw();
}
"""
end

function _synthesis_vitis_source(plan)
    input_width = nextpow(2, max(8, _kernel_width(plan.spec.input_format)))
    output_width = _kernel_width(plan.spec.output_format)
    bus_width = nextpow(2, max(8, output_width + 8))
    return """
#include <hls_stream.h>
#include "evaluator.hpp"
using InputWord = ap_uint<$input_width>;
using OutputWord = ap_uint<$bus_width>;
using InputStream = hls::stream<InputWord, 16384 / sizeof(InputWord)>;
using OutputStream = hls::stream<OutputWord, 16384 / sizeof(OutputWord)>;
static void read_inputs(unsigned count, const InputWord* input, InputStream& stream) {
    for (unsigned i = 0; i < count; ++i) {
#pragma HLS pipeline II=1
        stream.write(input[i]);
    }
}
void presage_resource_operation(unsigned count, InputStream& input, OutputStream& output) {
#pragma HLS inline off
    presage_evaluate:
    for (unsigned i = 0; i < count; ++i) {
#pragma HLS pipeline II=1
        auto result = presage_evaluator::evaluate_bits(input.read());
        OutputWord word = 0;
        word.range($(output_width - 1), 0) = result.bits;
        word.range($(output_width + 7), $output_width) = static_cast<unsigned>(result.status);
        output.write(word);
    }
}
static void write_outputs(unsigned count, OutputStream& stream, OutputWord* output) {
    for (unsigned i = 0; i < count; ++i) {
#pragma HLS pipeline II=1
        output[i] = stream.read();
    }
}
extern "C" void presage_resource_kernel(unsigned count, const InputWord* input, OutputWord* output) {
#pragma HLS interface m_axi port=input bundle=gmem0
#pragma HLS interface m_axi port=output bundle=gmem1
#pragma HLS dataflow
    InputStream inputs;
    OutputStream outputs;
    read_inputs(count, input, inputs);
    presage_resource_operation(count, inputs, outputs);
    write_outputs(count, outputs, output);
}
"""
end

"""Prepare vendor synthesis inputs and hash their source files without running tools."""
function prepare_synthesis(
    path::AbstractString;
    device = nothing,
    flow::Symbol = :auto,
    platform = "xilinx_u280_gen3x16_xdma_1_202211_1",
)
    manifest = _synthesis_manifest(path)
    toolchain = Symbol(manifest["toolchain"])
    haskey(_SYNTHESIS_DEFAULT_TARGETS, toolchain) ||
        throw(ArgumentError("synthesis requires a vendor toolchain"))
    device = something(device, _SYNTHESIS_DEFAULT_TARGETS[toolchain])
    flow = flow == :auto ? (toolchain == :vitis ? :vpp : :oneapi_hls) : flow
    flow in (toolchain == :vitis ? (:hls, :vpp) : (:oneapi_hls,)) ||
        throw(ArgumentError("synthesis flow does not match toolchain"))
    occursin(r"^[A-Za-z0-9_.:/-]+$", device) || throw(ArgumentError("invalid device name"))
    root = abspath(dirname(path))
    jobs = Dict{String, Any}[]
    for example in manifest["examples"]
        directory = dirname(joinpath(root, example["header"]))
        model = read_resource_model(joinpath(root, example["model"]))
        model.toolchain == toolchain ||
            throw(ArgumentError("example model toolchain mismatch"))
        model.device === nothing ||
            model.device == device ||
            throw(ArgumentError("calibrated model device does not match synthesis target"))
        plan = read_plan(joinpath(root, example["plan"]))
        support = target_support(
            plan,
            TargetProfile(toolchain; backend = Symbol(manifest["backend"])),
        )
        support.supported || throw(ArgumentError(join(support.reasons, ", ")))
        source = if flow == :hls
            file = joinpath(directory, "synthesis.tcl")
            write(
                file,
                """
open_project synthesis
set_top presage_resource_kernel
add_files kernel.cpp -cflags {-std=c++17}
open_solution solution -flow_target vitis
set_part {$device}
csynth_design
exit
""",
            )
            file
        else
            file = joinpath(directory, "synthesis.cpp")
            write(
                file,
                flow == :vpp ? _synthesis_vitis_source(plan) :
                _synthesis_oneapi_source(plan),
            )
            file
        end
        inputs = [
            joinpath(root, example[key]) for
            key in ("header", "kernel", "plan", "model", "resources")
        ]
        push!(inputs, source)
        push!(
            jobs,
            Dict(
                "name" => example["name"],
                "directory" => relpath(directory, root),
                "sources" =>
                    Dict(relpath(file, root) => _synthesis_hash(file) for file in inputs),
            ),
        )
    end
    project = Dict(
        "schema" => "presage-synthesis-project",
        "schema_version" => 1,
        "manifest" => basename(path),
        "manifest_sha256" => _synthesis_hash(path),
        "toolchain" => string(toolchain),
        "device" => device,
        "flow" => string(flow),
        "platform" => toolchain == :vitis ? platform : "",
        "required_ii" => 1,
        "stage" => "hls_estimate",
        "jobs" => jobs,
    )
    destination = joinpath(root, "synthesis.toml")
    _synthesis_write(destination, project)
    return destination
end

function _synthesis_command(project)
    board = project["device"]
    project["flow"] == "hls" && return `vitis_hls -f synthesis.tcl`
    if project["flow"] == "vpp"
        platform = project["platform"]
        return `v++ --compile --platform $platform --target hw --save-temps --debug
            --temp_dir _x --kernel presage_resource_kernel --output synthesis.xo
            --advanced.prop kernel.presage_resource_kernel.kernel_flags=-std=c++17 synthesis.cpp`
    end
    return `icpx -std=c++17 -fintelfpga -fsycl -qactypes -qopenmp -Wall -Xshardware
        -fp-model=precise -no-fma -no-ftz
        -fsycl-link=early -DREPORT -Xsboard=$board synthesis.cpp -o synthesis`
end

function _synthesis_project(path)
    project = TOML.parsefile(path)
    get(project, "schema", "") == "presage-synthesis-project" &&
        get(project, "schema_version", 0) === 1 ||
        throw(ArgumentError("invalid synthesis project"))
    root = abspath(dirname(path))
    _synthesis_hash(joinpath(root, project["manifest"])) == project["manifest_sha256"] ||
        throw(ArgumentError("example manifest changed after synthesis preparation"))
    for job in project["jobs"], (file, digest) in job["sources"]
        _synthesis_hash(joinpath(root, file)) == digest ||
            throw(ArgumentError("synthesis input changed: $file"))
    end
    return project, root
end

function _synthesis_jobs(project, example)
    jobs = project["jobs"]
    example === nothing && return jobs
    selected = filter(job -> job["name"] == example, jobs)
    isempty(selected) && throw(ArgumentError("unknown synthesis example $example"))
    return selected
end

"""Generate HLS reports and preserve logs and tool versions without hardware linkage."""
function run_synthesis(path::AbstractString; example = nothing)
    project, root = _synthesis_project(path)
    jobs = _synthesis_jobs(project, example)
    toolchain = Symbol(project["toolchain"])
    tool = project["flow"] == "hls" ? "vitis_hls" : toolchain == :vitis ? "v++" : "icpx"
    version = mktempdir(root; prefix = "version-") do temporary
        withenv("TMPDIR" => temporary, "TMP" => temporary, "TEMP" => temporary) do
            read(tool == "vitis_hls" ? `$tool -version` : `$tool --version`, String)
        end
    end
    for job in jobs
        directory = joinpath(root, job["directory"])
        manifest = _synthesis_manifest(joinpath(root, project["manifest"]))
        example_row = only(filter(row -> row["name"] == job["name"], manifest["examples"]))
        model = read_resource_model(joinpath(root, example_row["model"]))
        model.compiler === nothing ||
            model.compiler == version ||
            throw(
                ArgumentError(
                    "calibrated model compiler does not match the installed tool",
                ),
            )
        record = joinpath(directory, "synthesis-run.toml")
        isfile(record) && throw(ArgumentError("synthesis run already exists in $directory"))
        command = _synthesis_command(project)
        started = time()
        success = false
        try
            mktempdir(directory; prefix = "compiler-") do temporary
                withenv("TMPDIR" => temporary, "TMP" => temporary, "TEMP" => temporary) do
                    cd(directory) do
                        open("synthesis.log", "w") do log
                            run(pipeline(command; stdout = log, stderr = log))
                        end
                    end
                end
            end
            success = true
        finally
            _synthesis_write(
                record,
                Dict(
                    "success" => success,
                    "tool_version" => version,
                    "command" => collect(command),
                    "elapsed_seconds" => time() - started,
                    "project_sha256" => _synthesis_hash(path),
                ),
            )
        end
    end
    return nothing
end

"""Normalize vendor reports while retaining source identity and report provenance."""
function collect_synthesis(path::AbstractString; python = "python3")
    project, root = _synthesis_project(path)
    manifest = _synthesis_manifest(joinpath(root, project["manifest"]))
    rows = Dict{String, Any}[]
    parser = joinpath(@__DIR__, "..", "scripts", "parse_synthesis.py")
    for job in project["jobs"]
        directory = joinpath(root, job["directory"])
        record_path = joinpath(directory, "synthesis-run.toml")
        isfile(record_path) || continue
        record = TOML.parsefile(record_path)
        record["success"] || continue
        record["project_sha256"] == _synthesis_hash(path) ||
            throw(ArgumentError("synthesis project does not match completed run"))
        toolchain = project["toolchain"]
        flow = project["flow"]
        row = TOML.parse(read(`$python $parser $toolchain $directory $flow`, String))
        row["name"] = job["name"]
        row["tool_version"] = record["tool_version"]
        row["command"] = record["command"]
        row["device"] = project["device"]
        row["stage"] = project["stage"]
        row["parser_sha256"] = _synthesis_hash(parser)
        row["sources"] = job["sources"]
        row["reports"] = Dict(
            relpath(file, root) => _synthesis_hash(file) for file in row["raw_reports"]
        )
        row["reports"][relpath(record_path, root)] = _synthesis_hash(record_path)
        delete!(row, "raw_reports")
        push!(rows, row)
    end
    destination = joinpath(root, "measured.toml")
    _synthesis_write(
        destination,
        Dict(
            "schema" => "presage-resource-measurements",
            "schema_version" => 3,
            "model" => manifest["model"],
            "backend" => manifest["backend"],
            "toolchain" => manifest["toolchain"],
            "examples" => rows,
        ),
    )
    return destination
end

function _synthesis_acceptance(row, manifest, example, root)
    reasons = String[]
    failed = false
    for key in (
        "ii",
        "device",
        "tool_version",
        "command",
        "stage",
        "sources",
        "reports",
        "resource_units",
    )
        haskey(row, key) || push!(reasons, "missing $key")
    end
    if haskey(row, "ii") && row["ii"] !== 1
        failed = true
        push!(reasons, "evaluator initiation interval must be one")
    end
    get(row, "nested_loops", false) &&
        push!(reasons, "nested evaluator loops need additional throughput evidence")
    for key in ("device", "tool_version")
        value = get(row, key, "")
        value isa AbstractString && !isempty(strip(value)) || push!(reasons, "empty $key")
    end
    isempty(get(row, "command", [])) && push!(reasons, "missing compiler command")
    if haskey(row, "reported_device") &&
       row["reported_device"] != get(row, "device", nothing)
        failed = true
        push!(reasons, "reported device does not match synthesis target")
    end
    units =
        manifest["toolchain"] == "vitis" ?
        ["LUT", "FF", "DSP_equivalent", "BRAM18K", "MLAB"] :
        ["ALUT", "FF", "DSP_equivalent", "M20K", "MLAB"]
    get(row, "resource_units", []) == units ||
        push!(reasons, "resource units do not match toolchain")
    get(row, "stage", "") == "hls_estimate" ||
        push!(reasons, "unsupported measurement stage")
    get(row, "scope", "") == "evaluator" ||
        push!(reasons, "measurement scope must be evaluator")
    get(row, "parser_sha256", "") ==
    _synthesis_hash(joinpath(@__DIR__, "..", "scripts", "parse_synthesis.py")) ||
        push!(reasons, "measurement importer identity is missing or changed")
    components = get(row, "components", [])
    isempty(components) && push!(reasons, "missing resource partition")
    totals = filter(part -> get(part, "name", "") == "kernel_total", components)
    if length(totals) == 1
        for name in _RESOURCE_NAMES
            key = string(name)
            actual_count = _resource_exact(get(row, key, 0))
            excluded = sum(
                (
                    _resource_exact(part[key]) for
                    part in components if get(part, "kind", "") == "interface"
                );
                init = 0,
            )
            if actual_count + excluded != _resource_exact(only(totals)[key])
                failed = true
                push!(reasons, "$key resource partition does not match the kernel total")
            end
        end
    else
        push!(reasons, "resource partition needs one kernel total")
    end
    estimate = TOML.parsefile(joinpath(root, example["resources"]))
    model = read_resource_model(joinpath(root, example["model"]))
    if model.device !== nothing && model.device != get(row, "device", "") ||
       model.compiler !== nothing && model.compiler != get(row, "tool_version", "")
        failed = true
        push!(reasons, "calibrated model target or compiler does not match the report")
    end
    expected = [
        table["storage"] for table in get(estimate, "tables", []) for
        bank = 1:(manifest["toolchain"] == "vitis" ? table["banks"] : 1)
    ]
    actual = [
        part["storage"] for part in components if get(part, "kind", "") == "rom" for
        bank = 1:(manifest["toolchain"] == "vitis" ? get(part, "banks", 1) : 1)
    ]
    if sort(expected) != sort(actual)
        failed = true
        push!(reasons, "inferred ROM storage does not match the requested table policy")
    end
    sources = get(row, "sources", Dict())
    for key in ("header", "kernel", "plan", "model", "resources")
        file = example[key]
        get(sources, file, "") == _synthesis_hash(joinpath(root, file)) ||
            push!(reasons, "source identity mismatch for $file")
    end
    reports = get(row, "reports", Dict())
    isempty(reports) && push!(reasons, "missing raw reports")
    for (file, digest) in reports
        isfile(joinpath(root, file)) && _synthesis_hash(joinpath(root, file)) == digest ||
            push!(reasons, "raw report identity mismatch for $file")
    end
    return Dict(
        "status" => failed ? "failed" : isempty(reasons) ? "passed" : "unresolved",
        "reasons" => reasons,
    )
end
