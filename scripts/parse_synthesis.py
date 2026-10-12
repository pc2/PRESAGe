#!/usr/bin/env python3
"""Extract evaluator resource counts and scheduling evidence from vendor reports."""

import json
import math
import re
from fractions import Fraction
from pathlib import Path
import sys
import xml.etree.ElementTree as ET


def integer(value):
    if isinstance(value, bool) or str(value).strip() != str(int(value)) or int(value) < 0:
        raise ValueError("Expected a nonnegative integer count")
    return int(value)


def one(items, label):
    values = list(items)
    if len(values) != 1:
        raise ValueError("Expected exactly one {}, found {}".format(label, len(values)))
    return values[0]


def positive(value):
    number = float(value)
    if not math.isfinite(number) or number <= 0:
        raise ValueError("Expected positive finite timing data")
    return number


NAMES = ("luts", "ffs", "rams", "dsps", "mlabs")


def counts(values, packing=1):
    result = dict(zip(NAMES, values[:5]))
    result["dsps"] = Fraction(values[3]) + Fraction(values[5] if len(values) > 5 else 0, packing)
    return result


def finish_scope(result, total, excluded, components):
    # Logic area estimates can contain fractional attribution and accumulation noise.
    for row in [total] + excluded + components:
        for key in ("luts", "ffs"):
            if row[key] < 0:
                raise ValueError("Expected a nonnegative logic estimate")
            row[key] = Fraction(round(row[key]))
    for key in NAMES:
        value = total[key] - sum(row[key] for row in excluded)
        if value < 0 or key != "dsps" and value.denominator != 1:
            raise ValueError("Invalid evaluator resource partition")
        result[key] = value
    result["scope"] = "evaluator"
    result["components"] = [dict(name="kernel_total", **total)] + components


def vitis_details(path):
    sections = {}
    name = None
    for line in path.read_text().splitlines():
        match = re.match(r"\s*\* (Instance|Memory|Expression|Multiplexer|Register):", line)
        if match:
            name = match.group(1)
            sections[name] = []
        if name and line.startswith("    |"):
            fields = [item.strip() for item in line.split("|")[1:-1]]
            sections[name].append(fields)
    return sections


def vitis(directory, flow):
    path = (one((directory / "_x").rglob("presage_resource_operation*_csynth.xml"), "evaluator report")
            if flow == "vpp" else directory / "synthesis/solution/syn/report/presage_resource_kernel_csynth.xml")
    report = ET.parse(str(path)).getroot()
    resources = one(report.findall(".//AreaEstimates/Resources"), "resource summary")
    mapping = {"luts": "LUT", "ffs": "FF", "dsps": "DSP", "rams": "BRAM_18K"}
    result = {name: integer(resources.findtext(tag)) for name, tag in mapping.items()}
    result["mlabs"] = 0
    total = {name: Fraction(result[name]) for name in NAMES}
    details_path = path.with_suffix(".rpt")
    components, excluded = [], []
    if details_path.is_file():
        details = vitis_details(details_path)
        for fields in details.get("Instance", []):
            if len(fields) == 7 and "s_axi" in fields[1]:
                ram, dsp, ff, lut = map(integer, fields[2:6])
                row = counts([lut, ff, ram, dsp, 0])
                excluded.append(row)
                components.append(dict(name=fields[0], kind="interface", **row))
        for fields in details.get("Memory", []):
            if len(fields) == 10 and fields[0] != "Total" and fields[2].isdigit():
                ram, ff, lut = map(integer, fields[2:5])
                components.append(dict(name=fields[0], kind="rom", storage="block" if ram else "distributed",
                    word_bits=integer(fields[7]), rows=integer(fields[6]), banks=integer(fields[8]),
                    **counts([lut, ff, ram, 0, 0])))
    has_axi = any(node.findtext("IOProtocol") == "s_axi" for node in report.findall(".//RtlPorts"))
    if has_axi and not excluded:
        raise ValueError("AXI resource breakdown is required for evaluator scope")
    finish_scope(result, total, excluded, components)
    if flow == "vpp":
        loop = one((node for node in report.iter()
                    if (node.findtext("Name") or node.get("name")) == "presage_evaluate"), "evaluator loop")
        result["ii"] = integer(loop.findtext("PipelineII"))
    else:
        result["ii"] = integer(one(report.findall(".//SummaryOfOverallLatency/Interval-max"), "maximum II").text)
    result["reported_clock_ns"] = float(one(report.findall(".//UserAssignments/TargetClockPeriod"), "target clock").text)
    result["estimated_clock_ns"] = positive(one(report.findall(".//SummaryOfTimingAnalysis/EstimatedClockPeriod"), "estimated clock").text)
    result["estimated_fmax_mhz"] = 1000 / result["estimated_clock_ns"]
    result["reported_device"] = one(report.findall(".//UserAssignments/Part"), "part").text
    result["resource_units"] = ["LUT", "FF", "DSP_equivalent", "BRAM18K", "MLAB"]
    result["raw_reports"] = [str(path)] + ([str(details_path)] if details_path.is_file() else [])
    return result


def records(path):
    with path.open() as stream:
        return [json.loads(line) for line in stream if line.strip()]


def oneapi(directory, flow):
    root = directory / "synthesis.prj/reports/resources/json"
    area_path, loops_path = root / "area.ndjson", root / "mav.ndjson"
    area, loops = records(area_path), records(loops_path)
    children = {}
    for row in area:
        children.setdefault(row.get("parent"), []).append(row)

    def operation(row, visited=None):
        visited = set() if visited is None else visited
        if "OperationKernel" in row.get("name", ""):
            return True
        identity = row.get("id")
        if identity is None or identity in visited:
            return False
        visited.add(identity)
        return any(operation(child, visited) for child in children.get(identity, []))

    candidates = [row for row in area if "total_kernel_resources" in row and operation(row)]
    kernel = one(candidates, "OperationKernel resource summary")
    vector = kernel["total_kernel_resources"]
    if len(vector) != 6:
        raise ValueError("Unexpected Intel resource vector")
    packing = one((integer(row["dsp_packing_factor"]) for row in area if "dsp_packing_factor" in row), "DSP packing factor")
    if packing == 0:
        raise ValueError("DSP packing factor must be positive")
    total = counts([Fraction(str(v)) for v in vector[:2]] + list(map(integer, vector[2:])), packing)
    result = {"whole_dsps": integer(vector[3]), "fractional_dsps": integer(vector[5]), "dsp_packing_factor": packing}

    def subtree(row):
        if "data" in row:
            return counts([Fraction(str(v)) for v in row["data"]], packing)
        parts = [subtree(child) for child in children.get(row["id"], [])]
        return {name: sum(part[name] for part in parts) for name in NAMES}

    excluded, components = [], []

    def visit(row, in_loop=False):
        name = row.get("name", "")
        in_loop = in_loop or "presage_evaluate" in name
        if row.get("type") == "basicblock" and not in_loop or name in ("Feedback", "Cluster logic", "Pipe Read", "Pipe Write"):
            part = subtree(row)
            excluded.append(part)
            components.append(dict(name=name, kind="interface", **part))
            return
        if "(table)" in name and row.get("parent") == kernel["id"]:
            part = subtree(row)
            component = dict(name=name, kind="rom", storage="distributed" if part["mlabs"] else "block", **part)
            layouts = [detail for child in children.get(row["id"], []) for detail in child.get("details", []) if "Bank width" in detail]
            if len(layouts) == 1:
                for key, label in (("word_bits", "Bank width"), ("rows", "Bank depth"), ("banks", "Number of banks")):
                    component[key] = int(re.match(r"\d+", layouts[0][label]).group())
            components.append(component)
            return
        if name == "State":
            components.append(dict(name=name, kind="pipeline", **subtree(row)))
            return
        for child in children.get(row.get("id"), []):
            visit(child, in_loop)

    visit(kernel)
    finish_scope(result, total, excluded, components)
    evaluators = [row for row in loops if "presage_evaluate" in row.get("name", "")]
    if not evaluators:
        evaluators = [row for row in loops if "OperationKernel" in row.get("name", "")]
    schedules = [integer(detail["II"]) for row in evaluators
                 for detail in row.get("details", []) if "II" in detail]
    result["ii"] = one(schedules, "evaluator loop II")
    result["nested_loops"] = any(detail.get("Subloops") == "Yes" for row in evaluators
                                 for detail in row.get("details", []))
    result["resource_units"] = ["ALUT", "FF", "DSP_equivalent", "M20K", "MLAB"]
    result["raw_reports"] = [str(area_path), str(loops_path)]
    timing_path = root / "loop_attr.ndjson"
    if timing_path.is_file():
        timing = records(timing_path)
        clocks = [row for row in timing
                  if "OperationKernel" in row.get("name", "") and "fmax" in row]
        if clocks:
            clock = one(clocks, "evaluator clock")
            result["scheduled_fmax_mhz"] = positive(clock["fmax"])
            by_id = {row["id"]: row for row in timing if "id" in row}
            frequencies = []
            pending, visited = list(clock.get("children", [])), set()
            while pending:
                identity = pending.pop()
                if identity in visited:
                    raise ValueError("Cyclic evaluator timing hierarchy")
                visited.add(identity)
                row = by_id[identity]
                if "af" in row:
                    frequencies.append(positive(row["af"]))
                pending.extend(row.get("children", []))
            if frequencies:
                result["estimated_fmax_mhz"] = min(frequencies)
            result["raw_reports"].append(str(timing_path))
    return result


def main(args):
    if len(args) != 3 or args[0] not in ("vitis", "oneapi"):
        raise ValueError("Usage: parse_synthesis.py vitis|oneapi DIRECTORY FLOW")
    result = {"vitis": vitis, "oneapi": oneapi}[args[0]](Path(args[1]).resolve(), args[2])
    components = result.pop("components", [])
    def value_text(value):
        if isinstance(value, Fraction):
            value = value.numerator if value.denominator == 1 else str(value)
        return json.dumps(value, ensure_ascii=True, allow_nan=False)
    for key, value in sorted(result.items()):
        print("{} = {}".format(key, value_text(value)))
    for row in components:
        print("\n[[components]]")
        for key, value in sorted(row.items()):
            print("{} = {}".format(key, value_text(value)))


if __name__ == "__main__":
    main(sys.argv[1:])
