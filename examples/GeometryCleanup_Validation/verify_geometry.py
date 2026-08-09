# -*- coding: utf-8 -*-
"""Geometry Cleanup 验证模型自检脚本。

读取生成的两个 STEP 文件，用 cadquery 公开 API（cq.importers.importStep）逐项校验：

  1. 每个 STEP 读回的实体数 == 对应场景数；
  2. 每个实体的体积为正；
  3. 每个实体的面数与 manifest 记录的期望值一致；
  4. 每个实体恰好位于 manifest 记录的 bbox 范围内；
  5. 关键结构不变量（只对仍然有效的形态生效，供后续回归使用）：
     - CHAMFER 场景存在圆柱（圆角）面；
     - POCKET 场景沉台底面存在（双环平面）；
     - REJECT 场景（C06）不含圆柱面、不含双环平面。

用法（仓库根目录执行，需系统 Python 3.14 + cadquery 2.8.0）：

    python examples/GeometryCleanup_Validation/verify_geometry.py

任何一项不通过都会 raise 并返回非零退出码。
"""

import json
from pathlib import Path

import cadquery as cq
from cadquery import importers

HERE = Path(__file__).resolve().parent
MANIFEST = HERE / "GeometryCleanup_Validation_manifest.json"
STEP_CHAMFER = HERE / "GeometryCleanup_Chamfer_Validation.step"
STEP_POCKET = HERE / "GeometryCleanup_Pocket_Validation.step"

TOL = 1e-6


def face_list(shape):
    fs = shape.faces()
    if hasattr(fs, "vals"):
        return fs.vals()
    return list(fs)


def bbox_of(solid):
    bb = solid.BoundingBox()
    return {
        "xmin": bb.xmin, "xmax": bb.xmax,
        "ymin": bb.ymin, "ymax": bb.ymax,
        "zmin": bb.zmin, "zmax": bb.zmax,
    }


def same_bbox(actual, expected):
    return all(abs(actual[k] - expected[k]) <= 0.25 for k in ("xmin", "xmax", "ymin", "ymax", "zmin", "zmax"))


def main():
    manifest = json.loads(MANIFEST.read_text(encoding="utf-8"))
    assert manifest.get("schema_version") == "1.0", "manifest schema_version 应为 1.0"
    cases = manifest["cases"]
    assert len(cases) == 8, "应有 8 个 case"

    by_case = {c["case_id"]: c for c in cases}
    by_file = {}
    for cid, step_file in [
        ("C01", STEP_CHAMFER), ("C02", STEP_CHAMFER), ("C07", STEP_CHAMFER), ("C08", STEP_CHAMFER),
        ("C03", STEP_POCKET), ("C04", STEP_POCKET), ("C05", STEP_POCKET), ("C06", STEP_POCKET),
    ]:
        by_file.setdefault(step_file, []).append(cid)

    total_solids = 0
    for step_file, cids in by_file.items():
        assert step_file.exists(), "缺少 %s，请先运行 generate_geometry.py" % step_file.name
        obj = importers.importStep(str(step_file))
        solids = obj.val().Solids()
        assert len(solids) == len(cids), \
            "%s 读回实体数 %d != 场景数 %d" % (step_file.name, len(solids), len(cids))
        for solid in solids:
            total_solids += 1
            assert solid.Volume() > 0.0, "%s 存在体积非正实体" % step_file.name

    # 逐场景精确校验
    for cid in ["C01", "C02", "C03", "C04", "C05", "C06", "C07", "C08"]:
        case = by_case[cid]
        step_file = HERE / case["file"]
        obj = importers.importStep(str(step_file))
        solids = obj.val().Solids()
        exp_faces = case["expected_results"]["faces"]
        exp_bbox = case["expected_results"]["bbox"]

        matched = False
        for solid in solids:
            if same_bbox(bbox_of(solid), exp_bbox):
                matched = True
                nfaces = len(face_list(solid))
                assert nfaces == exp_faces, \
                    "%s 面数 %d != 期望 %d" % (cid, nfaces, exp_faces)
                assert solid.Volume() > 0.0, "%s 体积非正" % cid
                # 结构不变量
                if case["expected_mode"] == "CHAMFER":
                    assert any(f.geomType() == "CYLINDER" for f in face_list(solid)), \
                        "%s CHAMFER 场景应含圆角（圆柱）面" % cid
                if case["expected_mode"] == "POCKET":
                    assert any(
                        f.geomType() == "PLANE" and len(f.Wires()) == 2
                        for f in face_list(solid)
                    ), "%s POCKET 场景应含沉台底面（双环平面）" % cid
                if cid == "C06":  # REJECT 光顺件：无圆柱面无双环面
                    assert not any(f.geomType() == "CYLINDER" for f in face_list(solid)), \
                        "C06 不应含圆柱面"
                    assert not any(
                        f.geomType() == "PLANE" and len(f.Wires()) == 2
                        for f in face_list(solid)
                    ), "C06 不应含双环平面"
                break
        assert matched, "%s 未在 %s 中找到与 manifest bbox 匹配的实体" % (cid, case["file"])

    print("== GeometryCleanup 验证模型自检通过 ==")
    print("  STEP 文件: %s, %s" % (STEP_CHAMFER.name, STEP_POCKET.name))
    print("  场景数: 8，实体总数: %d" % total_solids)
    for cid in ["C01", "C02", "C03", "C04", "C05", "C06", "C07", "C08"]:
        print("    %s %-6s 面数=%d" % (
            cid, by_case[cid]["expected_mode"], by_case[cid]["expected_results"]["faces"]))


if __name__ == "__main__":
    main()
