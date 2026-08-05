"""Generate deterministic shell-only FEM fixtures for the offline seam backend."""
from __future__ import annotations

import json
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "python"))

from hmworkflow.core.mesh_model import Component, Element, MeshModel
from hmworkflow.fem_auto_seam.backend import write_fem_bundle


class MeshBuilder:
    def __init__(self):
        self.nodes = {}
        self.elements = {}
        self.components = {}
        self.element_properties = {}
        self.pshell = {}
        self.materials = {1: ["210000", "", "0.3"]}
        self.next_node = 1
        self.next_element = 1
        self.next_component = 1
        self.next_property = 1

    def component(self, name, thickness=1.0):
        component_id = self.next_component
        self.next_component += 1
        property_id = self.next_property
        self.next_property += 1
        self.components[component_id] = Component(component_id, name, "SHELL")
        self.pshell[property_id] = {"material_id": 1, "thickness": float(thickness)}
        return component_id, property_id

    def node(self, point):
        node_id = self.next_node
        self.next_node += 1
        self.nodes[node_id] = tuple(float(value) for value in point)
        return node_id

    def quad(self, component_id, property_id, node_ids):
        element_id = self.next_element
        self.next_element += 1
        self.elements[element_id] = Element(element_id, component_id, "CQUAD4", tuple(node_ids))
        self.element_properties[element_id] = property_id
        return element_id

    def grid(self, name, origin, u_step, v_step, u_count, v_count, thickness=1.0, omit=None):
        component_id, property_id = self.component(name, thickness)
        node_grid = []
        for v_index in range(v_count + 1):
            row = []
            for u_index in range(u_count + 1):
                point = tuple(
                    origin[axis] + u_index * u_step[axis] + v_index * v_step[axis]
                    for axis in range(3)
                )
                row.append(self.node(point))
            node_grid.append(row)
        omitted = set(omit or [])
        for v_index in range(v_count):
            for u_index in range(u_count):
                if (u_index, v_index) in omitted:
                    continue
                self.quad(component_id, property_id, (
                    node_grid[v_index][u_index],
                    node_grid[v_index][u_index + 1],
                    node_grid[v_index + 1][u_index + 1],
                    node_grid[v_index + 1][u_index],
                ))
        return component_id

    def ruled(self, name, bottom_points, height_vector, layers=2, thickness=1.0):
        component_id, property_id = self.component(name, thickness)
        grid = []
        for layer in range(layers + 1):
            fraction = layer / float(layers)
            grid.append([
                self.node(tuple(point[axis] + fraction * height_vector[axis] for axis in range(3)))
                for point in bottom_points
            ])
        for layer in range(layers):
            for index in range(len(bottom_points) - 1):
                self.quad(component_id, property_id, (
                    grid[layer][index], grid[layer][index + 1],
                    grid[layer + 1][index + 1], grid[layer + 1][index],
                ))
        return component_id

    def model(self):
        model = MeshModel(dict(self.components), dict(self.nodes), dict(self.elements))
        model.element_properties = dict(self.element_properties)
        model.pshell = dict(self.pshell)
        model.materials = dict(self.materials)
        return model


def line_points(start, stop, step, y=0.0, z=3.0):
    count = int(round((stop - start) / step))
    return [(start + index * step, y, z) for index in range(count + 1)]


def straight_t():
    builder = MeshBuilder()
    builder.grid("BASE_T2", (-10, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4, 2.0)
    builder.ruled("WEB_T1", line_points(0, 60, 10), (0, 0, 20), 2, 1.0)
    return builder.model(), {"minimum_created": 1, "minimum_t": 1}


def angled_t():
    builder = MeshBuilder()
    builder.grid("BASE_T2", (-10, -30, 0), (10, 0, 0), (0, 10, 0), 8, 6, 2.0)
    builder.ruled("ANGLED_WEB_T1", line_points(0, 60, 10), (0, 10, 17.3205080757), 2, 1.0)
    return builder.model(), {"minimum_created": 1, "minimum_t": 1}


def curved_t():
    builder = MeshBuilder()
    builder.grid("BASE_T2", (-50, -20, 0), (10, 0, 0), (0, 10, 0), 10, 7, 2.0)
    bottom = []
    for index in range(9):
        x = -40.0 + index * 10.0
        y = 10.0 + 8.0 * math.sin(math.pi * index / 8.0)
        bottom.append((x, y, 3.0))
    builder.ruled("CURVED_WEB_T1", bottom, (0, 0, 20), 2, 1.0)
    return builder.model(), {"minimum_created": 1, "minimum_t": 1}


def partial_overlap_t():
    builder = MeshBuilder()
    builder.grid("PARTIAL_BASE_T2", (23, -17, 0), (8.5, 0, 0), (0, 10, 0), 4, 4, 2.0)
    builder.ruled("LONG_WEB_T1", line_points(0, 80, 10), (0, 0, 20), 2, 1.0)
    return builder.model(), {"minimum_created": 1, "minimum_t": 1, "minimum_created_t_length": 33.999, "maximum_created_t_length": 34.001, "minimum_source_inserted_nodes": 2}


def multi_target_same_edge():
    builder = MeshBuilder()
    builder.grid("UPPER_TARGET_T2", (-10, -20, 0), (10, 0, 0), (0, 10, 0), 8, 4, 2.0)
    builder.grid("LOWER_TARGET_T2", (-10, -20, -3), (10, 0, 0), (0, 10, 0), 8, 4, 2.0)
    builder.ruled("SHARED_SOURCE_WEB_T1", line_points(0, 60, 10), (0, 0, 20), 2, 1.0)
    return builder.model(), {
        "minimum_created": 2,
        "minimum_t": 2,
        "minimum_distinct_targets": 2,
        "minimum_same_source_target_count": 2,
    }


def four_target_t():
    builder = MeshBuilder()
    for index in range(4):
        builder.grid("BASE{}_T2".format(index + 1), (index * 20, -20, 0), (10, 0, 0), (0, 10, 0), 2, 4, 2.0)
    builder.ruled("CENTER_WEB_T1", line_points(0, 80, 10), (0, 0, 20), 2, 1.0)
    return builder.model(), {"minimum_created": 4, "minimum_t": 4, "minimum_distinct_targets": 4}


def patch():
    builder = MeshBuilder()
    builder.grid("LARGE_PATCH_TARGET_T2", (0, 0, 0), (10, 0, 0), (0, 10, 0), 8, 6, 2.0)
    builder.grid("SMALL_PATCH_T1", (15, 15, 3), (10, 0, 0), (0, 10, 0), 4, 2, 1.0)
    return builder.model(), {"minimum_created": 1, "minimum_patch": 1, "minimum_deleted_mother_elements": 1, "minimum_created_nodes": 1}


def patch_small_hole():
    builder = MeshBuilder()
    builder.grid("LARGE_PATCH_TARGET_T2", (0, 0, 0), (10, 0, 0), (0, 10, 0), 8, 6, 2.0)
    builder.grid(
        "PATCH_WITH_SMALL_HOLE_T1", (10, 10, 3), (10, 0, 0), (0, 10, 0), 6, 4, 1.0,
        omit={(2, 1), (3, 1), (2, 2), (3, 2)},
    )
    return builder.model(), {"minimum_created": 0, "maximum_created": 0, "minimum_patch_review": 1}


def near_free_edges():
    builder = MeshBuilder()
    builder.grid("EDGE_PLATE_A_T1", (0, 0, 0), (10, 0, 0), (0, 10, 0), 4, 3, 1.0)
    builder.grid("EDGE_PLATE_B_T1", (45, 0, 0), (10, 0, 0), (0, 10, 0), 4, 3, 1.0)
    return builder.model(), {"minimum_created": 0, "maximum_created": 0, "minimum_near_edge": 1}


def negative_far_apart():
    builder = MeshBuilder()
    builder.grid("FAR_A_T1", (0, 0, 0), (10, 0, 0), (0, 10, 0), 3, 3, 1.0)
    builder.grid("FAR_B_T1", (200, 0, 0), (10, 0, 0), (0, 10, 0), 3, 3, 1.0)
    return builder.model(), {"minimum_created": 0, "maximum_created": 0, "maximum_candidates": 0}


CASES = {
    "case_01_straight_t": straight_t,
    "case_02_angled_t": angled_t,
    "case_03_curved_t": curved_t,
    "case_04_partial_overlap_t": partial_overlap_t,
    "case_05_multi_target_same_edge": multi_target_same_edge,
    "case_06_four_target_t": four_target_t,
    "case_07_patch": patch,
    "case_08_patch_small_hole_review": patch_small_hole,
    "case_09_near_free_edges_review": near_free_edges,
    "case_10_negative_far_apart": negative_far_apart,
}


def generate_combined(output_dir, spacing=500.0):
    """Merge every acceptance scenario into one cross-case-isolated FEM."""
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    components = {}
    nodes = {}
    elements = {}
    element_properties = {}
    pshell = {}
    materials = {1: ["210000", "", "0.3"]}
    next_node = 1
    next_element = 1
    next_component = 1
    next_property = 1
    case_rows = []

    for case_index, (name, factory) in enumerate(CASES.items(), 1):
        source, expected = factory()
        translation = ((case_index - 1) * float(spacing), 0.0, 0.0)
        node_map = {}
        component_map = {}
        property_map = {}

        for old_node_id, coordinates in sorted(source.nodes.items()):
            node_map[old_node_id] = next_node
            nodes[next_node] = tuple(
                float(coordinates[axis]) + translation[axis] for axis in range(3)
            )
            next_node += 1

        prefix = "F{:02d}_{}__".format(case_index, name.upper())
        for old_component_id, component in sorted(source.components.items()):
            component_map[old_component_id] = next_component
            components[next_component] = Component(
                next_component,
                prefix + component.component_name,
                component.mesh_class,
            )
            next_component += 1

        for old_property_id, values in sorted(getattr(source, "pshell", {}).items()):
            property_map[old_property_id] = next_property
            pshell[next_property] = {
                "material_id": 1,
                "thickness": float(values["thickness"]),
            }
            next_property += 1

        case_element_ids = []
        for old_element_id, element in sorted(source.elements.items()):
            new_element_id = next_element
            next_element += 1
            elements[new_element_id] = Element(
                new_element_id,
                component_map[element.component_id],
                element.element_type,
                tuple(node_map[node_id] for node_id in element.node_ids),
            )
            old_property_id = getattr(source, "element_properties", {}).get(old_element_id, 0)
            element_properties[new_element_id] = property_map.get(old_property_id, 0)
            case_element_ids.append(new_element_id)

        case_rows.append({
            "case_index": case_index,
            "case_name": name,
            "translation": list(translation),
            "component_ids": sorted(component_map.values()),
            "node_id_min": min(node_map.values()),
            "node_id_max": max(node_map.values()),
            "element_id_min": min(case_element_ids),
            "element_id_max": max(case_element_ids),
            "expected": expected,
        })

    combined = MeshModel(components, nodes, elements)
    combined.element_properties = element_properties
    combined.pshell = pshell
    combined.materials = materials
    fem_path = output_dir / "combined_all_cases.fem"
    manifest_path = output_dir / "combined_all_cases_manifest.json"
    write_fem_bundle(combined, fem_path, manifest_path)
    mapping_path = output_dir / "combined_cases.json"
    mapping_path.write_text(json.dumps({
        "schema_version": "1.0",
        "format": "fem_auto_seam_combined_acceptance_model",
        "fem_path": fem_path.name,
        "manifest_path": manifest_path.name,
        "case_spacing": float(spacing),
        "case_count": len(case_rows),
        "cases": case_rows,
    }, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return {
        "fem": str(fem_path.resolve()),
        "manifest": str(manifest_path.resolve()),
        "mapping": str(mapping_path.resolve()),
        "case_count": len(case_rows),
    }


def generate(output_dir):
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    generated = []
    for name, factory in CASES.items():
        model, expected = factory()
        case_dir = output_dir / name
        case_dir.mkdir(parents=True, exist_ok=True)
        manifest = write_fem_bundle(model, case_dir / "input.fem", case_dir / "input_manifest.json")
        expected_path = case_dir / "expected.json"
        expected_path.write_text(json.dumps(expected, sort_keys=True, indent=2) + "\n", encoding="utf-8")
        generated.append({"name": name, "manifest": str(manifest), "expected": str(expected_path)})
    (output_dir / "cases.json").write_text(json.dumps(generated, sort_keys=True, indent=2) + "\n", encoding="utf-8")
    return generated


if __name__ == "__main__":
    destination = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent / "generated"
    for row in generate(destination):
        print(row["manifest"])
    print(generate_combined(destination)["manifest"])
