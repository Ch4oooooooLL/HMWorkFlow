#!/usr/bin/env python3
"""common.py -- shared conventions for the HMWorkFlow model generation suite.

Output layout (generated files are gitignored):

    <output_root>/<module_key>_<case>/     one folder per validation model
        <model>.fem | <model>.step         the model file(s)
        <model>_manifest.json              machine-readable model description
        README.md                          module-specific usage notes
        setup.tcl                          optional import-time assembly setup

<output_root> defaults to examples/model_suite/ (repository convention) and can
be redirected with the environment variable HMW_MODEL_OUTPUT -- the CLI
(tools/model_generation/model_cli.py) uses that to write into a dedicated,
gitignored output folder.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
MODEL_SUITE = REPO_ROOT / "examples" / "model_suite"
TOOLS_DIR = Path(__file__).resolve().parent

GENERATORS_DIR = "tools/model_generation"

# ---------------------------------------------------------------------------
# Generator registry (single source of truth, shared with generate_all.py
# and model_cli.py).  kind: "fem" = stdlib-only (portable Python OK),
# "step" = requires cadquery/OCCT (system Python).
# ---------------------------------------------------------------------------

GENERATORS: List[Dict[str, str]] = [
    # geometry (STEP, needs cadquery)
    {"script": "gen_midsurf",        "module": "midsurf",                "kind": "step",
     "label": "抽中面：24 件钣金实体", "outdir": "midsurf_sheetmetal_24parts"},
    {"script": "gen_geom_cleanup",   "module": "geometry_cleanup",       "kind": "step",
     "label": "几何清理：倒角/沉台实体", "outdir": "geom_cleanup_multi_feature"},
    {"script": "gen_seam_surface",   "module": "seam_surface",           "kind": "step",
     "label": "几何焊缝：13 区域开放曲面", "outdir": "seam_surface_13regions"},
    {"script": "gen_batch_mesher",   "module": "batch_mesher",           "kind": "step",
     "label": "BatchMesher：12 部件曲面", "outdir": "batch_mesher_surfaces_12parts"},
    # component management (FEM)
    {"script": "gen_preprocess",     "module": "geometry_preprocess",    "kind": "fem",
     "label": "预处理：40 组件（同名族/SKELL）", "outdir": "preprocess_40comp"},
    {"script": "gen_bom_material",   "module": "bom_material_assignment", "kind": "fem",
     "label": "BOM 材料：40 组件 + setup.tcl", "outdir": "bom_material_40comp"},
    {"script": "gen_batch_property", "module": "batch_property_assignment", "kind": "fem",
     "label": "批量属性：50 组件命名矩阵", "outdir": "batch_property_50comp"},
    # mesh (FEM)
    {"script": "gen_mesh_seam_weld", "module": "mesh_seam_weld",         "kind": "fem",
     "label": "网格焊缝：T/搭接 + 600 孔性能", "outdir": "mesh_seam_weld_large"},
    {"script": "gen_fem_auto_seam",  "module": "fem_auto_seam",          "kind": "fem",
     "label": "FEM 自动焊缝：T/贴片/近边", "outdir": "fem_auto_seam_large"},
    {"script": "gen_weld_integrity", "module": "weld_integrity_check",   "kind": "fem",
     "label": "焊缝完整性：30 组件对", "outdir": "weld_integrity_30pairs"},
    {"script": "gen_local_mesh_opt", "module": "local_mesh_optimizer",   "kind": "fem",
     "label": "局部网格优化：24 万单元 + 缺陷", "outdir": "local_mesh_opt_80k"},
    # connectors (FEM)
    {"script": "gen_shell_washer",   "module": "shell_washer_hole_rbe2", "kind": "fem",
     "label": "壳孔 RIGIDS：401 孔", "outdir": "shell_washer_large"},
    {"script": "gen_solid_hole",     "module": "auto_hole_rbe2",         "kind": "fem",
     "label": "实体孔 RIGIDS：52 孔", "outdir": "solid_hole_large"},
    {"script": "gen_bolt_chain",     "module": "rbe2_bolt_connector",    "kind": "fem",
     "label": "螺栓连接：576 共轴 RBE2", "outdir": "bolt_chain_576rbe2"},
    {"script": "gen_cbush",          "module": "cbush_creator",          "kind": "fem",
     "label": "CBUSH：200 源节点", "outdir": "cbush_200nodes"},
    {"script": "gen_temp_nodes",     "module": "batch_temp_nodes",       "kind": "fem",
     "label": "批量临时节点：500 坐标", "outdir": "temp_nodes_500coords"},
    {"script": "gen_contact_setup",  "module": "contact_setup",          "kind": "fem",
     "label": "接触创建：10 对相向板", "outdir": "contact_setup_10pairs"},
    {"script": "gen_adhesive",       "module": "adhesive_connector",     "kind": "fem",
     "label": "模型打胶：8 条胶带", "outdir": "adhesive_8patches"},
    {"script": "gen_solid_seam",     "module": "solid_seam_connector",   "kind": "fem",
     "label": "实体焊缝：10 组接头", "outdir": "solid_seam_10joints"},
]

FEM_GENERATORS = [g for g in GENERATORS if g["kind"] == "fem"]
STEP_GENERATORS = [g for g in GENERATORS if g["kind"] == "step"]

# ---------------------------------------------------------------------------
# Output root
# ---------------------------------------------------------------------------


def output_root() -> Path:
    """Directory that receives the generated model folders.  HMW_MODEL_OUTPUT
    overrides the repository default (examples/model_suite/)."""
    env = os.environ.get("HMW_MODEL_OUTPUT")
    if env:
        return Path(env).resolve()
    return MODEL_SUITE


def ensure_tools_import() -> None:
    if str(TOOLS_DIR) not in sys.path:
        sys.path.insert(0, str(TOOLS_DIR))


def model_dir(key: str) -> Path:
    d = output_root() / key
    d.mkdir(parents=True, exist_ok=True)
    return d


def write_manifest(path: Path, data: Dict[str, Any]) -> None:
    data.setdefault("schema_version", "1.0")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_readme(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def write_setup_tcl(path: Path, text: str) -> None:
    """Companion Tcl that prepares HM-only entities (assemblies) after import.
    Best effort: HyperMesh command names follow the toolkit's own usage."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def summary(model, extra: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    stats = model.stats()
    if extra:
        stats.update(extra)
    return stats
