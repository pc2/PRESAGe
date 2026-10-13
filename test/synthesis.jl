isdefined(Main, :check_resources_main) ||
    include(joinpath(@__DIR__, "..", "scripts", "check_resources.jl"))

function synthesis_fixture(root, toolchain; flow = toolchain == :vitis ? :hls : :auto)
    directory = joinpath(root, "identity")
    mkpath(directory)
    format = FixedFormat(16, 4)
    spec =
        FunctionSpec("x"; input_format = format, output_format = format, domain = (-1, 1))
    plan = polynomial_plan(spec, [0, 1]; internal_format = format)
    model = read_resource_model(
        joinpath(@__DIR__, "..", "config", "resources", "$toolchain.toml"),
    )
    backend = toolchain == :vitis ? :ap_fixed : :ac_fixed
    write_plan(joinpath(directory, "plan.toml"), plan)
    write_resource_model(joinpath(directory, "resource-model.toml"), model)
    write_resource_report(
        joinpath(directory, "resources.toml"),
        estimate_resources(plan; model),
    )
    emit_kernel(joinpath(directory, "evaluator.hpp"), plan; toolchain, backend)
    write(joinpath(directory, "kernel.cpp"), "#include \"evaluator.hpp\"\n")
    manifest = Dict(
        "schema" => "presage-resource-examples",
        "schema_version" => 1,
        "toolchain" => string(toolchain),
        "backend" => string(backend),
        "model" => model.name,
        "examples" => [
            Dict(
                "name" => "identity",
                "header" => "identity/evaluator.hpp",
                "kernel" => "identity/kernel.cpp",
                "plan" => "identity/plan.toml",
                "resources" => "identity/resources.toml",
                "model" => "identity/resource-model.toml",
            ),
        ],
    )
    manifest_path = joinpath(root, "examples.toml")
    PRESAGe._synthesis_write(manifest_path, manifest)
    project = prepare_synthesis(manifest_path; flow)
    return manifest, project, directory
end

@testset "Synthesis preparation preserves source identity" begin
    for (toolchain, flow) in ((:vitis, :hls), (:vitis, :auto), (:oneapi, :auto))
        mktempdir() do root
            _, project, directory = synthesis_fixture(root, toolchain; flow)
            data, _ = PRESAGe._synthesis_project(project)
            @test only(PRESAGe._synthesis_jobs(data, "identity"))["name"] == "identity"
            @test_throws ArgumentError PRESAGe._synthesis_jobs(data, "missing")
            @test data["required_ii"] == 1
            @test !haskey(data, "clock_mhz")
            @test data["stage"] == "hls_estimate"
            source = flow == :hls ? "synthesis.tcl" : "synthesis.cpp"
            @test isfile(joinpath(directory, source))
            @test !occursin("create_clock", read(joinpath(directory, source), String))
            @test !any(
                arg -> occursin(r"freqhz|Xsclock|hls.clock", arg),
                PRESAGe._synthesis_command(data),
            )
            if toolchain == :oneapi
                command = collect(PRESAGe._synthesis_command(data))
                @test all(
                    flag -> flag in command,
                    ("-fp-model=precise", "-no-fma", "-no-ftz"),
                )
            end
            write(joinpath(directory, "evaluator.hpp"), "changed")
            @test_throws ArgumentError PRESAGe._synthesis_project(project)
        end
    end
end

@testset "Vitis reports require throughput and matching provenance" begin
    for flow in (:hls, :vpp)
        mktempdir() do root
            manifest, project, directory = synthesis_fixture(root, :vitis; flow)
            report = joinpath(
                directory,
                flow == :hls ?
                "synthesis/solution/syn/report/presage_resource_kernel_csynth.xml" :
                "_x/presage_resource_kernel/syn/report/presage_resource_operation_csynth.xml",
            )
            mkpath(dirname(report))
            write(
                report,
                """
<Report>
  <UserAssignments><Part>xcu280-fsvh2892-2L-e</Part><TargetClockPeriod>4</TargetClockPeriod></UserAssignments>
  <AreaEstimates><Resources><LUT>101</LUT><FF>202</FF><DSP>3</DSP><BRAM_18K>4</BRAM_18K></Resources></AreaEstimates>
  <PerformanceEstimates>
    <SummaryOfOverallLatency><Interval-max>1</Interval-max></SummaryOfOverallLatency>
    <SummaryOfLoopLatency><LoopLatency><Name>presage_evaluate</Name><PipelineII>1</PipelineII></LoopLatency></SummaryOfLoopLatency>
    <SummaryOfTimingAnalysis><EstimatedClockPeriod>3.5</EstimatedClockPeriod></SummaryOfTimingAnalysis>
  </PerformanceEstimates>
</Report>
""",
            )
            PRESAGe._synthesis_write(
                joinpath(directory, "synthesis-run.toml"),
                Dict(
                    "success" => true,
                    "tool_version" => "synthetic parser fixture",
                    "command" => ["synthetic parser fixture"],
                    "project_sha256" => PRESAGe._synthesis_hash(project),
                ),
            )
            measured = TOML.parsefile(collect_synthesis(project))
            row = only(measured["examples"])
            @test row["estimated_fmax_mhz"] ≈ 1000 / 3.5
            @test [row[key] for key in ("luts", "ffs", "dsps", "rams")] == [101, 202, 3, 4]
            example = only(manifest["examples"])
            accept(data) =
                PRESAGe._synthesis_acceptance(data, manifest, example, root)["status"]
            @test accept(row) == "passed"
            @test accept(merge(row, Dict("ii" => 2))) == "failed"
            @test accept(merge(row, Dict("estimated_clock_ns" => 5))) == "passed"
            @test accept(merge(row, Dict("reported_device" => "wrong"))) == "failed"
            @test accept(
                merge(row, Dict("resource_units" => ["ALM", "FF", "DSP", "BRAM36K"])),
            ) == "unresolved"
            @test accept(merge(row, Dict("reports" => Dict()))) == "unresolved"
            @test accept(merge(row, Dict("sources" => Dict()))) == "unresolved"
            delete!(row, "ii")
            @test accept(row) == "unresolved"
            write(report, "changed")
            @test accept(row) == "unresolved"
        end
    end
end

@testset "Intel reports isolate evaluator resources and retain separate units" begin
    mktempdir() do root
        manifest, project, directory = synthesis_fixture(root, :oneapi)
        reports = joinpath(directory, "synthesis.prj/reports/resources/json")
        mkpath(reports)
        write(
            joinpath(reports, "area.ndjson"),
            """
{"id":0,"name":"Kernel System","dsp_packing_factor":2}
{"id":1,"name":"ReadKernel","total_kernel_resources":[9,8,7,6,0,0]}
{"id":2,"name":"OperationKernel","total_kernel_resources":[101,202,4,3,0,0]}
{"id":3,"name":"WriteKernel","total_kernel_resources":[9,8,7,6,0,0]}
""",
        )
        write(
            joinpath(reports, "mav.ndjson"),
            """
{"name":"ReadKernel.B1","details":[{"II":"5"}]}
{"name":"OperationKernel.presage_evaluate","details":[{"II":"1","Latency":"12","Subloops":"No"}]}
{"name":"OperationKernel.B2","details":[{"II":"4","Latency":"12"}]}
""",
        )
        write(
            joinpath(reports, "loop_attr.ndjson"),
            """
{"name":"ReadKernel","id":1,"clk":"No","fmax":"480"}
{"name":"OperationKernel","id":2,"clk":"No","fmax":"480","children":[3]}
{"name":"OperationKernel.presage_evaluate","id":3,"af":"412.5"}
""",
        )
        PRESAGe._synthesis_write(
            joinpath(directory, "synthesis-run.toml"),
            Dict(
                "success" => true,
                "tool_version" => "synthetic parser fixture",
                "command" => ["synthetic parser fixture"],
                "project_sha256" => PRESAGe._synthesis_hash(project),
            ),
        )
        row = only(TOML.parsefile(collect_synthesis(project))["examples"])
        @test [row[key] for key in ("luts", "ffs", "dsps", "rams")] == [101, 202, 3, 4]
        @test row["ii"] == 1
        @test row["estimated_fmax_mhz"] == 412.5
        @test row["scheduled_fmax_mhz"] == 480
        @test !row["nested_loops"]
        example = only(manifest["examples"])
        @test PRESAGe._synthesis_acceptance(row, manifest, example, root)["status"] ==
              "passed"
        @test PRESAGe._synthesis_acceptance(
            merge(row, Dict("nested_loops" => true)),
            manifest,
            example,
            root,
        )["status"] == "unresolved"
        row["mlabs"] = 1
        only(row["components"])["mlabs"] = 1
        @test PRESAGe._synthesis_acceptance(row, manifest, example, root)["status"] ==
              "passed"
        @test PRESAGe._synthesis_acceptance(
            merge(row, Dict("scope" => "kernel")),
            manifest,
            example,
            root,
        )["status"] == "unresolved"
        row["dsps"] = 9999
        measured = joinpath(root, "measured.toml")
        comparison = joinpath(root, "comparison.toml")
        PRESAGe._synthesis_write(
            measured,
            Dict(
                "schema" => "presage-resource-measurements",
                "schema_version" => 2,
                "examples" => [row],
            ),
        )
        @test check_resources_main([
            joinpath(root, "examples.toml"),
            measured,
            comparison,
        ]) == 1
        @test TOML.parsefile(comparison)["status"] == "failed"
    end
end

@testset "Vitis evaluator counts exclude only the AXI control instance" begin
    mktempdir() do root
        manifest, project, directory = synthesis_fixture(root, :vitis; flow = :hls)
        report = joinpath(
            directory,
            "synthesis/solution/syn/report/presage_resource_kernel_csynth.xml",
        )
        mkpath(dirname(report))
        write(
            report,
            """
<Report>
<UserAssignments><Part>xcu280-fsvh2892-2L-e</Part><TargetClockPeriod>10</TargetClockPeriod></UserAssignments>
<AreaEstimates><Resources><LUT>101</LUT><FF>202</FF><DSP>3</DSP><BRAM_18K>0</BRAM_18K></Resources></AreaEstimates>
<RtlPorts><IOProtocol>s_axi</IOProtocol></RtlPorts>
<SummaryOfOverallLatency><Interval-max>1</Interval-max></SummaryOfOverallLatency>
<SummaryOfTimingAnalysis><EstimatedClockPeriod>5</EstimatedClockPeriod></SummaryOfTimingAnalysis>
</Report>
""",
        )
        PRESAGe._synthesis_write(
            joinpath(directory, "synthesis-run.toml"),
            Dict(
                "success" => true,
                "tool_version" => "synthetic parser fixture",
                "command" => ["synthetic parser fixture"],
                "project_sha256" => PRESAGe._synthesis_hash(project),
            ),
        )
        @test_throws ProcessFailedException collect_synthesis(project)
        write(
            replace(report, ".xml" => ".rpt"),
            """
    * Instance:
    |control_s_axi_U|control_s_axi|0|0|70|40|0|
    |multiply_U|mul_16s_16s|0|3|0|10|0|
    |Total||0|3|70|50|0|
""",
        )
        row = only(TOML.parsefile(collect_synthesis(project))["examples"])
        @test [row[key] for key in ("luts", "ffs", "dsps", "rams", "mlabs")] == [61, 132, 3, 0, 0]
        @test length(row["reports"]) == 3
        @test PRESAGe._synthesis_acceptance(
            row,
            manifest,
            only(manifest["examples"]),
            root,
        )["status"] == "passed"
    end
end

@testset "Intel DSP equivalents and interface partitions retain exact counts" begin
    mktempdir() do root
        manifest, project, directory = synthesis_fixture(root, :oneapi)
        reports = joinpath(directory, "synthesis.prj/reports/resources/json")
        mkpath(reports)
        write(
            joinpath(reports, "area.ndjson"),
            """
{"id":0,"dsp_packing_factor":2}
{"id":1,"name":"OperationKernel","total_kernel_resources":[40,80,8,3,4,1]}
{"id":2,"parent":1,"type":"basicblock","name":"OperationKernel.B0"}
{"id":3,"parent":2,"name":"State","data":[10,20,0,0,0,0]}
{"id":4,"parent":1,"type":"basicblock","name":"OperationKernel.presage_evaluate"}
{"id":5,"parent":4,"name":"Pipe Read","data":[2,3,6,0,1,0]}
{"id":6,"parent":4,"name":"Computation","data":[28,57,2,3,3,1]}
""",
        )
        write(
            joinpath(reports, "mav.ndjson"),
            """
{"name":"OperationKernel.presage_evaluate","details":[{"II":"1"}]}
""",
        )
        PRESAGe._synthesis_write(
            joinpath(directory, "synthesis-run.toml"),
            Dict(
                "success" => true,
                "tool_version" => "synthetic parser fixture",
                "command" => ["synthetic parser fixture"],
                "project_sha256" => PRESAGe._synthesis_hash(project),
            ),
        )
        row = only(TOML.parsefile(collect_synthesis(project))["examples"])
        @test row["dsps"] == "7/2"
        @test row["whole_dsps"] == 3
        @test row["mlabs"] == 3
        @test row["rams"] == 2
        @test row["luts"] == 28
        @test row["ffs"] == 57
        @test row["scope"] == "evaluator"
        @test PRESAGe._synthesis_acceptance(
            row,
            manifest,
            only(manifest["examples"]),
            root,
        )["status"] == "passed"
        @test PRESAGe._synthesis_acceptance(
            merge(row, Dict("dsps" => 3)),
            manifest,
            only(manifest["examples"]),
            root,
        )["status"] == "failed"
        area_path = joinpath(reports, "area.ndjson")
        area = read(area_path, String)
        write(
            area_path,
            replace(
                area,
                "[40,80,8,3,4,1]" => "[40.002,80.9999,8,3,4,1]",
                "[10,20,0,0,0,0]" => "[10.333333,20.333333,0,0,0,0]",
            ),
        )
        rounded = only(TOML.parsefile(collect_synthesis(project))["examples"])
        @test rounded["luts"] == 28
        @test rounded["ffs"] == 58
        @test rounded["dsps"] == "7/2"
        @test rounded["rams"] == 2
        @test PRESAGe._synthesis_acceptance(
            rounded,
            manifest,
            only(manifest["examples"]),
            root,
        )["status"] == "passed"
        for vector in ("[40,80,8.1,3,4,1]", "[40,80,8,3.1,4,1]")
            write(area_path, replace(area, "[40,80,8,3,4,1]" => vector))
            @test_throws ProcessFailedException collect_synthesis(project)
        end
    end
end

@testset "Arithmetic probes preserve independent operand bits and cost policies" begin
    format = FixedFormat(8, 4)
    plan = only(resource_probe_plans(; formats = [format], operations = (:add,))).second
    program = plan.program
    for (a, b) in ((0, 0), (1, 2), (0xff, 1), (0x80, 1))
        @test interpret_trace(program, a | b << 8).bits ==
              round_fixed(decode_fixed(a, format) + decode_fixed(b, format), format)
    end
    @test_throws OverflowError interpret_trace(program, 0x7f7f)
    cpu_check(plan, BigInt[0, 1, 0x0102, 0xff01])
    @test get(plan.settings, "resource_probe", "") == "independent_operands"
    variants = resource_probe_plans(;
        formats = [format, FixedFormat(8, 4; signed = false), FixedFormat(8, 3)],
        operations = (:add,),
    )
    @test length(unique(first.(variants))) == 3
    model =
        read_resource_model(joinpath(@__DIR__, "..", "config", "resources", "generic.toml"))
    signature = last(estimate_resources(program; model).nodes).signature
    @test signature.intermediate_bits == 9
    @test signature.rounding_bits == 0
    @test signature.overflow_bits == 1
    rule = ResourceRule(
        :add;
        format = :fixed,
        result_width = 8,
        operand_widths = (8, 8),
        integer_bits = 4,
        overflow = :reject,
        luts = 20,
        ffs = 10,
        dsps = 1 // 2,
        rams = 0,
        mlabs = 1,
    )
    calibrated = ResourceModel(rules = (rule, model.rules...))
    @test estimate_resources(program; model = calibrated).totals.dsps == 1 // 2
    @test ResourceBudget(dsps = 3 // 2).dsps == 3 // 2
    @test_throws ArgumentError ResourceBudget(dsps = 1.5)
    @test_throws ArgumentError ResourceBudget(mlabs = 1 // 2)
    replay =
        read_resource_model(IOBuffer(sprint(io -> write_resource_model(io, calibrated))))
    @test estimate_resources(program; model = replay).totals ==
          estimate_resources(program; model = calibrated).totals
end

@testset "Calibration rules retain operand patterns and target provenance" begin
    mktempdir() do root
        model = read_resource_model(
            joinpath(@__DIR__, "..", "config", "resources", "vitis.toml"),
        )
        format = FixedFormat(16, 4)
        plans = resource_probe_plans(; formats = [format])
        mixed = only(
            resource_probe_plans(;
                formats = [FixedFormat(16, 5)],
                operations = (:fma,),
                operand_formats = [
                    FixedFormat(8, 3),
                    FixedFormat(12, 4),
                    FixedFormat(10, 5),
                ],
            ),
        )
        push!(plans, mixed)
        extended = only(
            resource_probe_plans(;
                formats = [format],
                operations = (:fma,),
                input_formats = [format, FixedFormat(10, 3), format],
            ),
        )
        push!(plans, extended)
        manifest = write_resource_examples(root; model, plans, certify = false)
        project = prepare_synthesis(joinpath(root, "examples.toml"); flow = :hls)
        for example in manifest["examples"]
            directory = joinpath(root, example["name"])
            report = joinpath(
                directory,
                "synthesis/solution/syn/report/presage_resource_kernel_csynth.xml",
            )
            mkpath(dirname(report))
            write(
                report,
                """
<Report>
<UserAssignments><Part>xcu280-fsvh2892-2L-e</Part><TargetClockPeriod>10</TargetClockPeriod></UserAssignments>
<AreaEstimates><Resources><LUT>101</LUT><FF>202</FF><DSP>3</DSP><BRAM_18K>0</BRAM_18K></Resources></AreaEstimates>
<SummaryOfOverallLatency><Interval-max>1</Interval-max></SummaryOfOverallLatency>
<SummaryOfTimingAnalysis><EstimatedClockPeriod>5</EstimatedClockPeriod></SummaryOfTimingAnalysis>
</Report>
""",
            )
            PRESAGe._synthesis_write(
                joinpath(directory, "synthesis-run.toml"),
                Dict(
                    "success" => true,
                    "tool_version" => "synthetic parser fixture",
                    "command" => ["synthetic parser fixture"],
                    "project_sha256" => PRESAGe._synthesis_hash(project),
                ),
            )
        end
        destination = joinpath(root, "calibrated.toml")
        calibrated = calibrate_resource_model(project, destination)
        duplicate =
            calibrate_resource_model([project, project], joinpath(root, "duplicate.toml"))
        @test PRESAGe._resource_model_data(duplicate) ==
              PRESAGe._resource_model_data(calibrated)
        @test calibrated.device == "xcu280-fsvh2892-2L-e"
        @test calibrated.compiler == "synthetic parser fixture"
        @test TOML.parsefile(destination * ".evidence.toml")["profile_sha256"] ==
              PRESAGe._synthesis_hash(destination)
        for (_, plan) in resource_probe_plans(; formats = [format])
            @test estimate_resources(plan; model = calibrated).totals ==
                  (luts = 101, ffs = 202, dsps = 3, rams = 0, mlabs = 0)
        end
        @test estimate_resources(mixed.second; model = calibrated).totals ==
              (luts = 101, ffs = 202, dsps = 3, rams = 0, mlabs = 0)
        @test estimate_resources(extended.second; model = calibrated).totals ==
              (luts = 101, ffs = 202, dsps = 3, rams = 0, mlabs = 0)
        constant =
            only(
                resource_probe_plans(;
                    formats = [format],
                    operations = (:mul,),
                    constants = (1 // 3, nothing),
                ),
            ).second
        @test last(estimate_resources(constant; model = calibrated).nodes).rule_index > 2
        unsigned =
            only(
                resource_probe_plans(;
                    formats = [FixedFormat(16, 4; signed = false)],
                    operations = (:mul,),
                ),
            ).second
        @test last(estimate_resources(unsigned; model = calibrated).nodes).rule_index > 2
        replay = read_resource_model(destination)
        @test PRESAGe._resource_model_data(replay) ==
              PRESAGe._resource_model_data(calibrated)
        other = joinpath(root, "other")
        write_resource_probes(other; model = calibrated, formats = [format])
        @test_throws ArgumentError prepare_synthesis(
            joinpath(other, "examples.toml");
            device = "wrong-device",
            flow = :hls,
        )
        PRESAGe._synthesis_write(
            joinpath(root, first(manifest["examples"])["name"], "emulation-run.toml"),
            Dict("success" => false),
        )
        @test_throws ArgumentError calibrate_resource_model(
            project,
            joinpath(root, "failed.toml"),
        )
    end
end

@testset "Mixed fixed probes preserve each operand format and boundary encoding" begin
    output = FixedFormat(16, 5)
    shapes = [FixedFormat(8, 3), FixedFormat(12, 4), FixedFormat(10, 5)]
    plan =
        only(
            resource_probe_plans(;
                formats = [output],
                operations = (:fma,),
                operand_formats = shapes,
            ),
        ).second
    @test plan.spec.input_format.width == 30
    references = IR.refs(last(plan.program.nodes))
    @test IR.format.(Ref(plan.program), references) == Tuple(shapes)
    a, b, c = (
        round_fixed(value, shape) for
        (value, shape) in zip((1 // 2, -3 // 4, 1 // 8), shapes)
    )
    word = BigInt(a) | BigInt(b) << 8 | BigInt(c) << 20
    @test interpret_trace(plan.program, word).bits == round_fixed(-1 // 4, output)
    words = PRESAGe._emulation_words(plan)
    @test (big(0x80) | big(0xfff) << 8 | big(0x1ff) << 20) in words
    @test all(word -> 0 <= word < big(1) << 30, words)
    @test words == PRESAGe._emulation_words(plan)
    cpu_check(plan, BigInt[word])
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check([(; program = plan.program, words)], backend)
    end
    @test_throws ArgumentError resource_probe_plans(;
        formats = [output],
        operations = (:fma,),
        operand_formats = shapes[1:2],
    )
    @test_throws ArgumentError resource_probe_plans(;
        formats = [IEEE32],
        operations = (:mul,),
        operand_formats = [IEEE32, IEEE64],
    )
    extended =
        only(
            resource_probe_plans(;
                formats = [FixedFormat(20, 4)],
                operations = (:fma,),
                input_formats = [
                    FixedFormat(20, 4),
                    FixedFormat(10, 3),
                    FixedFormat(20, 4),
                ],
            ),
        ).second
    @test extended.spec.input_format.width == 50
    words = PRESAGe._emulation_words(extended)
    @test all(word -> 0 <= word < big(1) << 50, words)
    for backend in (:ap_fixed, :ac_fixed)
        kernel_trace_check([(; program = extended.program, words)], backend)
    end
    @test_throws ArgumentError resource_probe_plans(;
        formats = [FixedFormat(20, 4)],
        operations = (:fma,),
        input_formats = [FixedFormat(20, 4), FixedFormat(20, 3), FixedFormat(20, 4)],
    )
end

@testset "Intel arithmetic calibration does not duplicate shared pipeline storage" begin
    mktempdir() do root
        model = read_resource_model(
            joinpath(@__DIR__, "..", "config", "resources", "oneapi.toml"),
        )
        format = FixedFormat(16, 4)
        manifest = write_resource_probes(root; model, formats = [format])
        project = prepare_synthesis(joinpath(root, "examples.toml"))
        for example in manifest["examples"]
            directory = joinpath(root, example["name"])
            reports = joinpath(directory, "synthesis.prj/reports/resources/json")
            mkpath(reports)
            write(
                joinpath(reports, "area.ndjson"),
                """
{"id":0,"dsp_packing_factor":2}
{"id":1,"name":"OperationKernel","total_kernel_resources":[101,202,2,1,3,1]}
{"id":2,"parent":1,"type":"basicblock","name":"OperationKernel.presage_evaluate"}
{"id":3,"parent":2,"name":"State","data":[40,90,2,0,3,0]}
{"id":4,"parent":2,"name":"Computation","data":[61,112,0,1,0,1]}
""",
            )
            write(
                joinpath(reports, "mav.ndjson"),
                """
{"name":"OperationKernel.presage_evaluate","details":[{"II":"1"}]}
""",
            )
            PRESAGe._synthesis_write(
                joinpath(directory, "synthesis-run.toml"),
                Dict(
                    "success" => true,
                    "tool_version" => "synthetic parser fixture",
                    "command" => ["synthetic parser fixture"],
                    "project_sha256" => PRESAGe._synthesis_hash(project),
                ),
            )
        end
        path = joinpath(root, "calibrated.toml")
        calibrated = calibrate_resource_model(project, path)
        program = IR.Program([IR.Input(format), IR.Add(1, 1, format), IR.Mul(2, 1, format)])
        estimate = estimate_resources(program; model = calibrated)
        @test estimate.status == :partial
        @test estimate.datapath == (luts = 122, ffs = 224, dsps = 3, rams = 0, mlabs = 0)
        @test estimate.pipeline ==
              (luts = nothing, ffs = nothing, dsps = 0, rams = nothing, mlabs = nothing)
        @test estimate.totals ==
              (luts = nothing, ffs = nothing, dsps = 3, rams = nothing, mlabs = nothing)
        @test estimate_resources(program; model = read_resource_model(path)).totals ==
              estimate.totals
        data = TOML.parse(sprint(io -> write_resource_report(io, estimate)))
        @test data["pipeline"]["rams"] == "unknown"
        @test data["datapath"]["rams"] == 0
        @test TOML.parsefile(path * ".evidence.toml")["validation"] == "primitive_only"
    end
end
