"""Synthetic broad-phase benchmark; uses no external packages."""
from __future__ import annotations

import argparse
import json
import sys
import time
import tracemalloc
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))
from hmworkflow.core.mesh_model import Component, Element, MeshModel
from hmworkflow.mesh_seam_weld.auto_workflow import detect


def model(component_count, segments):
    components, nodes, elements = {}, {}, {}; node_id = 1; element_id = 1
    for component_index in range(component_count):
        component_id = component_index + 1; components[component_id] = Component(component_id, "BENCH_T8_{}".format(component_id), "SHELL")
        y = component_index * 100.0
        lower, upper = [], []
        for index in range(segments + 1): nodes[node_id] = (float(index), y, 0.0); lower.append(node_id); node_id += 1
        for index in range(segments + 1): nodes[node_id] = (float(index), y + 1.0, 0.0); upper.append(node_id); node_id += 1
        for index in range(segments): elements[element_id] = Element(element_id, component_id, "CQUAD4", (lower[index], lower[index+1], upper[index+1], upper[index])); element_id += 1
    return MeshModel(components, nodes, elements)


def main():
    parser=argparse.ArgumentParser(); parser.add_argument("--components",type=int,default=100); parser.add_argument("--segments",type=int,default=1000); parser.add_argument("--repeat",type=int,default=3); parser.add_argument("--output",type=Path); args=parser.parse_args()
    mesh=model(args.components,args.segments); settings={"search_distance":12.0,"min_seam_length":20.0,"min_path_nodes":3,"parallel_angle_max":15.0,"perpendicular_angle_min":70.0,"max_distance_variation_ratio":0.35,"existing_weld_search_distance":4.0}
    timings=[]; tracemalloc.start(); candidates=[]
    for _ in range(max(1,args.repeat)):
        started=time.perf_counter(); candidates=detect(mesh,settings); timings.append(time.perf_counter()-started)
    _,peak=tracemalloc.get_traced_memory(); tracemalloc.stop()
    report={"schema_version":"1.0","benchmark":"auto_shell_seam_detection","component_count":len(mesh.components),"element_count":len(mesh.elements),"candidate_count":len(candidates),"repeat_count":len(timings),"seconds":{"minimum":min(timings),"average":sum(timings)/len(timings),"maximum":max(timings)},"peak_python_bytes":peak,"notes":["Synthetic broad-phase benchmark; excludes HyperMesh export/import.","Compare with a recorded legacy imprint/ruled run on the same engineering model."]}
    encoded=json.dumps(report,ensure_ascii=False,sort_keys=True,indent=2)
    print(encoded)
    if args.output: args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(encoded+"\n",encoding="utf-8")


if __name__=="__main__": main()
