#!/usr/bin/env python3
"""generate_all.py -- regenerate the whole HMWorkFlow validation model suite.

Runs every generator in tools/model_generation/ in a subprocess (isolated,
deterministic) and prints a summary table:

    python tools/model_generation/generate_all.py [--only gen_shell_washer]

Output root: HMW_MODEL_OUTPUT env var, or examples/model_suite/ by default.
The interactive/portable-Python driver is tools/model_generation/model_cli.py.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import common

TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parent.parent
SUITE = common.output_root()

GENERATORS = common.GENERATORS


def run_one(name: str) -> dict:
    script = TOOLS / (name + ".py")
    started = time.time()
    env = dict(os.environ)
    env["HMW_MODEL_OUTPUT"] = str(common.output_root())
    proc = subprocess.run(
        [sys.executable, str(script)],
        cwd=str(REPO), env=env, capture_output=True, text=True, encoding="utf-8",
        timeout=1800,
    )
    elapsed = time.time() - started
    tail = (proc.stdout or "")[-400:]
    err = (proc.stderr or "")[-600:]
    ok = proc.returncode == 0
    return {"name": name, "ok": ok, "elapsed": round(elapsed, 1),
            "tail": tail.strip(), "stderr": err.strip()}


def summarize_suite() -> None:
    """Build examples/model_suite/README.md index from the manifests."""
    if not SUITE.exists():
        return
    rows = []
    for folder in sorted(SUITE.iterdir()):
        if not folder.is_dir():
            continue
        manifests = list(folder.glob("*_manifest.json"))
        fem = list(folder.glob("*.fem"))
        steps = list(folder.glob("*.step"))
        stats = {}
        module = ""
        if manifests:
            data = json.loads(manifests[0].read_text(encoding="utf-8"))
            module = data.get("module", "")
            stats = data.get("statistics", {})
        sizes = sum(f.stat().st_size for f in fem + steps)
        rows.append({
            "folder": folder.name,
            "module": module,
            "files": len(fem) + len(steps),
            "size_mb": round(sizes / 1e6, 2),
            "stats": stats,
        })
    lines = [
        "# HMWorkFlow 验证模型套件（model_suite）",
        "",
        "本目录由 `tools/model_generation/` 下的生成器**全新生成**（确定性、可一键重建）：",
        "",
        "    python tools/model_generation/generate_all.py",
        "",
        "每个模型文件夹含模型文件（.fem / .step）、`*_manifest.json`（机器可读描述）与 README.md（中文操作说明）。",
        "本目录产物已在 `.gitignore` 覆盖（`/examples/**`），不参与打包。",
        "",
        "## 模型清单",
        "",
        "| 目录 | 模块 | 文件数 | 大小(MB) | 规模摘要 |",
        "|---|---|---|---|---|",
    ]
    for r in rows:
        s = r["stats"]
        brief = ""
        for k in ("node_count", "element_count", "part_count", "face_count",
                  "washer_hole_count", "hole_count", "component_count", "region_count"):
            if k in s:
                brief += "{}={} ".format(k, s[k])
        brief = brief.strip() or "-"
        lines.append("| {} | {} | {} | {} | {} |".format(
            r["folder"], r["module"] or "-", r["files"], r["size_mb"], brief))
    lines.append("")
    lines.append("## 生成器")
    lines.append("")
    lines.append("| 生成器 | 输出目录 | 说明 |")
    lines.append("|---|---|---|")
    for g in common.GENERATORS:
        lines.append("| {}.py | {} | {} |".format(g["script"], g["outdir"], g["label"]))
    lines.append("")
    (SUITE / "README.md").write_text("\n".join(lines), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", help="run only this generator (basename without .py)")
    args = parser.parse_args()

    todo = [g["script"] for g in GENERATORS if not args.only or g["script"] == args.only]
    if args.only and not todo:
        print("unknown generator:", args.only)
        return 2

    failed = []
    results = []
    for i, name in enumerate(todo, 1):
        print("[{}/{}] {} ...".format(i, len(todo), name), flush=True)
        res = run_one(name)
        results.append(res)
        if res["ok"]:
            print("   OK in {}s".format(res["elapsed"]))
            if res["tail"]:
                print("   " + res["tail"].replace("\n", "\n   "))
        else:
            print("   FAILED in {}s".format(res["elapsed"]))
            if res["tail"]:
                print("   stdout: " + res["tail"].replace("\n", "\n   "))
            if res["stderr"]:
                print("   stderr: " + res["stderr"].replace("\n", "\n   "))
            failed.append(name)

    print("\n===== SUMMARY =====")
    for res in results:
        print("{:28s} {}  {:6.1f}s".format(res["name"], "OK " if res["ok"] else "FAIL", res["elapsed"]))
    summarize_suite()
    print("\nSuite index: examples/model_suite/README.md")
    if failed:
        print("FAILED:", ", ".join(failed))
        return 1
    print("ALL GENERATORS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
