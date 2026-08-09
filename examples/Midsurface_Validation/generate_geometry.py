#!/usr/bin/env python3
"""Generate the Midsurface Extraction validation STEP geometry.

Output: examples/Midsurface_Validation/Midsurface_SheetMetal_8Parts.step

Run from the repository root (requires system Python with cadquery 2.8.0):

    python examples/Midsurface_Validation/generate_geometry.py

Dependencies: cadquery 2.8.0 (OCCT backend).  The generated .step is a
deliverable that HyperMesh 2019 imports directly; the generator itself is a
development-time tool and does not need to run on the portable python38.

Layout: 8 solid sheet-metal parts in one STEP assembly, arranged along the
global X axis with a >= 300 mm gap between consecutive parts.  Every part is
a constant-thickness solid built by extrude/union of exact dimensions, so the
volume / midsurface-area thickness measurement is reproducible.

Component naming follows the workflow convention Vxx_<part>_T<thickness>;
the mid-surface module reads the thickness from the component name tag
(::HWFlow::thicknessFromComponentName, regex (^|_)T([0-9.]+)) before any
measurement.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Tuple

import cadquery as cq
from cadquery.occ_impl.exporters.assembly import exportAssembly

OUT_DIR = Path(__file__).resolve().parent
STEP_NAME = "Midsurface_SheetMetal_8Parts.step"
MANIFEST_NAME = "Midsurface_Validation_manifest.json"

GAP = 300.0  # minimum X clearance between consecutive parts

# --------------------------------------------------------------------------
# Part builders (each returns a cq.Workplane / Shape centered near local 0)
# --------------------------------------------------------------------------


def flat_plate() -> cq.Workplane:
    """V01: plain flat plate 200 x 120 x 1.5."""
    return cq.Workplane("XY").box(200, 120, 1.5)


def l_bracket() -> cq.Workplane:
    """V02: L-shaped bracket, base 150x100x2.0 with a 100-high vertical flange."""
    base = cq.Workplane("XY").box(150, 100, 2.0)
    flange = cq.Workplane("XY").center(0, 50).box(150, 2.0, 100)
    return base.union(flange)


def reinforced_plate() -> cq.Workplane:
    """V03: plate 180x120x1.0 with a center stiffening rib (180x12x12)."""
    base = cq.Workplane("XY").box(180, 120, 1.0)
    rib = cq.Workplane("XY").box(180, 12, 12).translate((0, 0, 6.5))
    return base.union(rib)


def stepped_plate() -> cq.Workplane:
    """V04: stepped plate, two 140x100x1.2 flats joined by a 15-high web."""
    flat1 = cq.Workplane("XY").box(140, 100, 1.2).translate((-70, 0, 0.6))
    web = cq.Workplane("XY").box(1.2, 100, 16.2).translate((0, 0, 8.1))
    flat2 = cq.Workplane("XY").box(140, 100, 1.2).translate((70, 0, 15.6))
    return flat1.union(web).union(flat2)


def arc_bent_plate() -> cq.Workplane:
    """V05: quarter-circle bent plate, bend radius 80, radial thickness 1.5, width 120."""
    r_o = 80.0 + 1.5 / 2.0
    r_i = 80.0 - 1.5 / 2.0
    c = 2.0 ** 0.5 / 2.0
    sketch = (
        cq.Workplane("XY")
        .moveTo(r_o, 0)
        .threePointArc((r_o * c, r_o * c), (0, r_o))
        .lineTo(0, r_i)
        .threePointArc((r_i * c, r_i * c), (r_i, 0))
        .close()
    )
    return sketch.extrude(120.0)


def wedge() -> cq.Workplane:
    """V06: variable-thickness wedge prism, thickness tapers 5 -> 25 mm (no _T tag)."""
    profile = cq.Workplane("XZ").polyline([(0, 0), (200, 0), (200, 25), (0, 5)]).close()
    return profile.extrude(100.0)


def solid_block() -> cq.Workplane:
    """V07: thick solid block 60 x 40 x 35 (not sheet metal)."""
    return cq.Workplane("XY").box(60, 40, 35)


def plate_with_holes() -> cq.Workplane:
    """V08: plate 240x160x1.0 with 8 through holes of diameter 12."""
    plate = cq.Workplane("XY").box(240, 160, 1.0)
    holes = [(x, y) for x in (-75, -25, 25, 75) for y in (-30, 30)]
    return (
        plate.faces(">Z")
        .workplane()
        .pushPoints(holes)
        .circle(6.0)
        .cutThruAll()
    )


# --------------------------------------------------------------------------
# Part specification
# --------------------------------------------------------------------------


@dataclass(frozen=True)
class PartSpec:
    name: str
    thickness: float | None  # None = no _T name tag / not sheet metal
    thickness_source: str  # "name-tag" / "measure" / "variable" / "non-sheet"
    builder: Callable[[], cq.Workplane]
    expected_mode: str  # normal / boundary / failure
    title: str
    notes: str


PART_SPECS: List[PartSpec] = [
    PartSpec(
        name="V01_PANEL_T1.5",
        thickness=1.5,
        thickness_source="name-tag",
        builder=flat_plate,
        expected_mode="normal",
        title="平直板抽中面（厚度取组件名 _T1.5）",
        notes="输入组件名自带 _T1.5，chooseThickness 直接采用 name-tag，不走测量。"
        "预期输出组件 V01_PANEL_T1.5 并入 MIDSURFED assembly。",
    ),
    PartSpec(
        name="V02_BRACKET_T2.0",
        thickness=2.0,
        thickness_source="name-tag",
        builder=l_bracket,
        expected_mode="normal",
        title="L 形翻边板抽中面（_T2.0）",
        notes="折弯件，中面由两块相交平面构成；名称 T2.0 规范为 T2 输出。",
    ),
    PartSpec(
        name="V03_REINF_T1.0",
        thickness=1.0,
        thickness_source="name-tag",
        builder=reinforced_plate,
        expected_mode="normal",
        title="带加强筋板抽中面（_T1.0）",
        notes="筋为实体特征，抽中面后仍应产出单一板厚 1.0 的中面；"
        "厚度 token 规范化为 T1（1.0 -> '1'）。",
    ),
    PartSpec(
        name="V04_STEP_T1.2",
        thickness=1.2,
        thickness_source="name-tag",
        builder=stepped_plate,
        expected_mode="normal",
        title="台阶板抽中面（_T1.2）",
        notes="两级平面 + 竖筋，中面含台阶特征，厚度统一为 1.2。",
    ),
    PartSpec(
        name="V05_ARC_T1.5",
        thickness=1.5,
        thickness_source="name-tag",
        builder=arc_bent_plate,
        expected_mode="normal",
        title="大圆弧弯板抽中面（_T1.5）",
        notes="弯曲件，期望得到沿曲率方向的中面；厚度取 name-tag 1.5。",
    ),
    PartSpec(
        name="V06_WEDGE",
        thickness=None,
        thickness_source="variable",
        builder=wedge,
        expected_mode="boundary",
        title="楔形变厚件（无 _T 标记，厚度 5~25 变化）",
        notes="边界场景：名称不含 _T，模块走测量路径。厚度拓扑值离散度大，"
        "chooseThickness 会用中位数并打印 relative spread 警告；若测不到厚度则"
        "回退输出 TUNKNOWN。行为需实机观察并记录。",
    ),
    PartSpec(
        name="V07_BLOCK",
        thickness=None,
        thickness_source="non-sheet",
        builder=solid_block,
        expected_mode="failure",
        title="厚实块 60x40x35（非钣金）",
        notes="失败/边界场景：非钣金实体。midsurface_extract_10 可能不产出有效"
        "中面曲面，processComponent 报错跳过（组件计入 skipped）；即使产出，"
        "体积/面积测得厚度约 35 mm，名称也无 _T 标记。行为需实机观察。",
    ),
    PartSpec(
        name="V08_PLATE_HOLES_T1.0",
        thickness=1.0,
        thickness_source="name-tag",
        builder=plate_with_holes,
        expected_mode="boundary",
        title="多孔板抽中面（_T1.0，8 个 Ø12 通孔）",
        notes="边界场景：孔是实体面真实特征，期望中面曲面上保留孔环（边界环）。"
        "厚度取 name-tag 1.0，输出 token 规范化为 T1。",
    ),
]


# --------------------------------------------------------------------------
# Build / place / self-check
# --------------------------------------------------------------------------


def place_parts() -> List[cq.Shape]:
    """Build all parts and translate them along X with a >= GAP clearance."""
    placed: List[cq.Shape] = []
    cursor = 0.0
    for spec in PART_SPECS:
        shape = spec.builder().val()
        bb = shape.BoundingBox()
        offset = cursor - bb.xmin
        shape = shape.translate((offset, 0.0, 0.0))
        placed.append(shape)
        cursor = shape.BoundingBox().xmax + GAP
    return placed


def check_geometry(shapes: List[cq.Shape]) -> Dict[str, object]:
    """Self-check topology/placement; raise ValueError on failure."""
    errors: List[str] = []
    if len(shapes) != len(PART_SPECS):
        errors.append("expected {} parts, got {}".format(len(PART_SPECS), len(shapes)))

    bounds: Dict[str, List[float]] = {}
    for spec, shape in zip(PART_SPECS, shapes):
        bb = shape.BoundingBox()
        bounds[spec.name] = [bb.xmin, bb.xmax, bb.ymin, bb.ymax, bb.zmin, bb.zmax]
        if bb.xmax <= bb.xmin or bb.ymax <= bb.ymin or bb.zmax <= bb.zmin:
            errors.append("{} has degenerate bounding box".format(spec.name))
        vol = shape.Volume()
        if vol <= 0.0:
            errors.append("{} has non-positive volume {}".format(spec.name, vol))

    # X clearance between consecutive parts must be >= GAP
    xmaxes = [shape.BoundingBox().xmax for shape in shapes]
    xmins = [shape.BoundingBox().xmin for shape in shapes]
    for i in range(1, len(shapes)):
        gap = xmins[i] - xmaxes[i - 1]
        if gap < GAP - 1e-6:
            errors.append("gap between part {} and {} is {:.3f} < {}".format(i - 1, i, gap, GAP))

    # Read-back check through the STEP importer
    step_path = OUT_DIR / STEP_NAME
    readback = cq.importers.importStep(str(step_path)).val()
    readback_solids = readback.Solids()
    if len(readback_solids) != len(PART_SPECS):
        errors.append("STEP read-back solids {} != expected {}".format(len(readback_solids), len(PART_SPECS)))
    for solid in readback_solids:
        if solid.Volume() <= 0.0:
            errors.append("read-back solid has non-positive volume")
    readback_text = step_path.read_text(encoding="utf-8", errors="replace")
    missing_names = [spec.name for spec in PART_SPECS if spec.name not in readback_text]
    if missing_names:
        errors.append("STEP file does not carry part names: {}".format(missing_names))

    if errors:
        raise ValueError("geometry validation failed:\n- " + "\n- ".join(errors))

    return {
        "step_solids": len(shapes),
        "step_readback_solids": len(readback_solids),
        "x_gap_min_mm": min(xmins[i] - xmaxes[i - 1] for i in range(1, len(shapes))),
        "bounds": bounds,
    }


# --------------------------------------------------------------------------
# Manifest
# --------------------------------------------------------------------------


def build_cases(bounds: Dict[str, List[float]]) -> List[Dict[str, object]]:
    cases = []
    for index, spec in enumerate(PART_SPECS, 1):
        cases.append(
            {
                "case_id": "G{:02d}".format(index),
                "title": spec.title,
                "component_ids": [index],
                "component_names": [spec.name],
                "bounds_mm": {"x": [bounds[spec.name][0], bounds[spec.name][1]],
                              "y": [bounds[spec.name][2], bounds[spec.name][3]],
                              "z": [bounds[spec.name][4], bounds[spec.name][5]]},
                "thickness_mm": spec.thickness,
                "expected_thickness_source": spec.thickness_source,
                "expected_mode": spec.expected_mode,
                "expected": {
                    "mode": spec.expected_mode,
                    "output_assembly": "MIDSURFED",
                },
                "notes": spec.notes,
            }
        )
    return cases


def write_manifest(statistics: Dict[str, object]) -> Dict[str, object]:
    """Write the merged manifest, preserving any existing FEM/BOM cases."""
    manifest_path = OUT_DIR / MANIFEST_NAME
    existing_cases = []
    if manifest_path.exists():
        try:
            previous = json.loads(manifest_path.read_text(encoding="utf-8"))
            existing_cases = [case for case in previous.get("cases", [])
                              if case.get("case_id", "").startswith("B")]
        except (ValueError, OSError):
            existing_cases = []
    manifest = {
        "schema_version": "1.0",
        "purpose": "Midsurface Extraction（抽中面）模块验证：8 件钣金/非钣金实体沿 X 排布，"
                   "覆盖正常抽中面、变厚件、非钣金块、带孔板等场景；FEM 部分覆盖 BOM 材料赋予。",
        "generator": "examples/Midsurface_Validation/generate_geometry.py + generate_fem.py",
        "geometry": "examples/Midsurface_Validation/" + STEP_NAME,
        "fem": "examples/Midsurface_Validation/Midsurface_Imported_State.fem",
        "parameters": {"layout": "8 parts along global X", "x_gap_min_mm": GAP},
        "statistics": statistics,
        "components": {"G{:02d}".format(i): spec.name for i, spec in enumerate(PART_SPECS, 1)},
        "cases": build_cases(statistics["bounds"]) + existing_cases,
    }
    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8"
    )
    return manifest


def main() -> int:
    shapes = place_parts()
    assembly = cq.Assembly()
    for spec, shape in zip(PART_SPECS, shapes):
        assembly.add(shape, name=spec.name)
    step_path = OUT_DIR / STEP_NAME
    exportAssembly(assembly, str(step_path), mode="default")
    statistics = check_geometry(shapes)
    write_manifest(statistics)
    print("wrote {}".format(step_path))
    print("statistics: {}".format(json.dumps(statistics, ensure_ascii=False)))
    print("all geometry self-checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
