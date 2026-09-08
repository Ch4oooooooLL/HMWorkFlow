#!/usr/bin/env python3
"""model_cli.py -- interactive CLI that drives the HMWorkFlow model generators.

Runs the generator scripts (tools/model_generation/gen_*.py) with a selected
Python interpreter and writes the models into a dedicated output folder that
is NOT tracked by git.

Interpreter strategy (--runner):
  auto      (default) FEM generators run on the portable Python 3.8 runtime
            (runtime/python/windows-x64/python.exe) when available; STEP
            generators need cadquery/OCCT and always run on the interpreter
            that launched this CLI (fall back to it for FEM too when the
            portable runtime is missing).
  portable  everything on the portable runtime (STEP generators will fail
            there -- cadquery is not shipped; use auto or system for STEP).
  system    everything on the interpreter that launched this CLI.
  --python PATH forces a single interpreter for everything.

Output folder (--outdir):
  default: tools/generated_models/  (sibling of tools/model_generation/)
  The chosen root is passed to every generator via HMW_MODEL_OUTPUT and is
  ignored by git (see .gitignore).  Override with --outdir <path>.

Usage:
  python tools/model_generation/model_cli.py            # interactive menu
  python tools/model_generation/model_cli.py --list     # list generators
  python tools/model_generation/model_cli.py --all      # generate everything
  python tools/model_generation/model_cli.py --only gen_temp_nodes,gen_midsurf
  python tools/model_generation/model_cli.py --all --runner system
  runtime\\python\\windows-x64\\python.exe tools\\model_generation\\model_cli.py --all
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

REPO = common.REPO_ROOT
TOOLS = common.TOOLS_DIR
DEFAULT_OUTDIR = TOOLS.parent / "generated_models"  # tools/generated_models/

PORTABLE_CANDIDATES = [
    REPO / "runtime" / "python" / "windows-x64" / "python.exe",
    REPO / "runtime" / "python" / "windows-x64" / "python38" / "python.exe",
]


# ---------------------------------------------------------------------------
# Interpreter detection
# ---------------------------------------------------------------------------


def find_portable_python() -> Optional[Path]:
    for p in PORTABLE_CANDIDATES:
        if p.exists():
            return p
    return None


def has_cadquery(python: Path) -> bool:
    try:
        proc = subprocess.run([str(python), "-c", "import cadquery"],
                              capture_output=True, timeout=120)
        return proc.returncode == 0
    except Exception:
        return False


def resolve_runners(strategy: str, explicit: Optional[str]) -> Dict[str, Optional[Path]]:
    """Return {kind: interpreter path} for the requested strategy.
    kind is "fem" or "step"."""
    system = Path(sys.executable)
    portable = find_portable_python()
    if explicit:
        p = Path(explicit).resolve()
        if not p.exists():
            raise SystemExit("指定解释器不存在: {}".format(p))
        return {"fem": p, "step": p}
    if strategy == "system":
        return {"fem": system, "step": system}
    if strategy == "portable":
        if portable is None:
            raise SystemExit("便携 Python 未找到（runtime/python/windows-x64/python.exe）")
        return {"fem": portable, "step": portable}
    # auto
    fem = portable if portable is not None else system
    step = system
    if not has_cadquery(step):
        raise SystemExit(
            "当前解释器 {} 缺少 cadquery（STEP 生成器需要 OCCT）。\n"
            "请用带 cadquery 的解释器启动本 CLI，或 --python 指定。".format(step))
    return {"fem": fem, "step": step}


# ---------------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------------


def run_generator(gen: Dict[str, str], python: Path, outdir: Path,
                  timeout: int = 1800) -> Dict[str, object]:
    script = TOOLS / (gen["script"] + ".py")
    env = dict(os.environ)
    env["HMW_MODEL_OUTPUT"] = str(outdir)
    started = time.time()
    proc = subprocess.run(
        [str(python), str(script)],
        cwd=str(REPO), env=env, capture_output=True, text=True,
        encoding="utf-8", errors="replace", timeout=timeout,
    )
    elapsed = time.time() - started
    out_dir = outdir / gen["outdir"]
    produced = out_dir.exists() and any(out_dir.iterdir())
    return {
        "gen": gen, "ok": proc.returncode == 0, "produced": produced,
        "elapsed": round(elapsed, 1),
        "stdout": (proc.stdout or "")[-500:].strip(),
        "stderr": (proc.stderr or "")[-800:].strip(),
    }


def generate(gens: List[Dict[str, str]], runners: Dict[str, Optional[Path]],
             outdir: Path, verbose: bool = True) -> List[Dict[str, object]]:
    results = []
    for i, gen in enumerate(gens, 1):
        python = runners[gen["kind"]]
        if python is None:
            print("[{}/{}] {}  SKIP（无可用解释器）".format(i, len(gens), gen["script"]))
            results.append({"gen": gen, "ok": False, "skipped": True})
            continue
        if verbose:
            print("[{}/{}] {}  ({} / {})".format(
                i, len(gens), gen["script"], python.name, gen["label"]), flush=True)
        res = run_generator(gen, python, outdir)
        results.append(res)
        if res["ok"] and res["produced"]:
            if verbose:
                print("   OK in {}s -> {}/".format(res["elapsed"], outdir / gen["outdir"]))
                if res["stdout"]:
                    print("   " + res["stdout"].replace("\n", "\n   "))
        else:
            print("   FAILED in {}s".format(res["elapsed"]))
            if res["stdout"]:
                print("   stdout: " + res["stdout"].replace("\n", "\n   "))
            if res["stderr"]:
                print("   stderr: " + res["stderr"].replace("\n", "\n   "))
    return results


def print_summary(results: List[Dict[str, object]]) -> int:
    failed = []
    print("\n===== 汇总 =====")
    for res in results:
        gen = res["gen"]
        if res.get("skipped"):
            print("{:24s} SKIP".format(gen["script"]))
        elif res["ok"] and res["produced"]:
            print("{:24s} OK    {:6.1f}s".format(gen["script"], res["elapsed"]))
        else:
            print("{:24s} FAIL  {:6.1f}s".format(gen["script"], res["elapsed"]))
            failed.append(gen["script"])
    if failed:
        print("失败: " + ", ".join(failed))
        return 1
    print("全部生成成功")
    return 0


def select_generators(pattern: Optional[str]) -> List[Dict[str, str]]:
    """--only accepts script basenames and/or output-dir names, comma separated."""
    if not pattern:
        return list(common.GENERATORS)
    wanted = [p.strip() for p in pattern.split(",") if p.strip()]
    gens = []
    for w in wanted:
        hit = [g for g in common.GENERATORS if g["script"] == w or g["outdir"] == w]
        if not hit:
            raise SystemExit("未知生成器: {}（用 --list 查看）".format(w))
        gens.extend(hit)
    # keep registry order, drop duplicates
    seen = set()
    ordered = []
    for g in common.GENERATORS:
        if g["script"] in {x["script"] for x in gens} and g["script"] not in seen:
            seen.add(g["script"])
            ordered.append(g)
    return ordered


# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------


def interactive(outdir: Path, runners: Dict[str, Optional[Path]]) -> int:
    while True:
        print("\n" + "=" * 60)
        print(" HMWorkFlow 验证模型生成 CLI")
        print(" 输出目录: {}".format(outdir))
        print(" 解释器: FEM={}  STEP={}".format(
            runners["fem"].name if runners["fem"] else "-",
            runners["step"].name if runners["step"] else "-"))
        print("=" * 60)
        print(" 1) 生成全部模型（{} 个）".format(len(common.GENERATORS)))
        print(" 2) 生成指定模型")
        print(" 3) 列出模型清单")
        print(" 0) 退出")
        choice = input("请选择: ").strip()
        if choice == "0":
            return 0
        if choice == "1":
            results = generate(common.GENERATORS, runners, outdir)
            rc = print_summary(results)
            if rc == 0:
                input("\n按回车返回菜单...")
        elif choice == "2":
            show_list()
            picked = input("\n输入编号（逗号分隔，如 1,3,12）: ").strip()
            try:
                idxs = [int(x) for x in picked.replace("，", ",").split(",") if x.strip()]
                gens = [common.GENERATORS[i - 1] for i in idxs if 1 <= i <= len(common.GENERATORS)]
            except ValueError:
                gens = []
            if not gens:
                print("未选择有效模型")
                continue
            results = generate(gens, runners, outdir)
            print_summary(results)
            input("\n按回车返回菜单...")
        elif choice == "3":
            show_list()
            input("\n按回车返回菜单...")
        else:
            print("无效选择")


def show_list() -> None:
    print("\n{:<4} {:<24} {:<6} {:<34} {}".format(
        "编号", "生成器", "类型", "模型", "输出目录"))
    for i, g in enumerate(common.GENERATORS, 1):
        kind = "STEP" if g["kind"] == "step" else "FEM "
        print("{:<4} {:<24} {:<6} {:<34} {}".format(
            i, g["script"], kind, g["label"], g["outdir"]))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _setup_console() -> None:
    """Best-effort UTF-8 console (Windows code page 65001) so Chinese output
    displays correctly in cmd/PowerShell."""
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:
        pass
    if os.name == "nt":
        try:
            import ctypes
            ctypes.windll.kernel32.SetConsoleOutputCP(65001)
            ctypes.windll.kernel32.SetConsoleCP(65001)
        except Exception:
            pass


def main() -> int:
    _setup_console()
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--list", action="store_true", help="列出全部生成器")
    parser.add_argument("--all", action="store_true", help="生成全部模型")
    parser.add_argument("--only", metavar="A,B", help="只生成指定模型（脚本名或输出目录名，逗号分隔）")
    parser.add_argument("--runner", choices=("auto", "portable", "system"), default="auto",
                        help="解释器策略（默认 auto）")
    parser.add_argument("--python", metavar="PATH", help="强制使用指定解释器")
    parser.add_argument("--outdir", metavar="PATH", default=str(DEFAULT_OUTDIR),
                        help="输出根目录（默认 tools/generated_models/）")
    parser.add_argument("--yes", action="store_true", help="--all 时跳过确认")
    args = parser.parse_args()

    outdir = Path(args.outdir).resolve()

    if args.list:
        show_list()
        return 0

    runners = resolve_runners(args.runner, args.python)

    if args.all or args.only:
        gens = select_generators(args.only)
        if not args.yes and args.all:
            print("将生成 {} 个模型到: {}".format(len(gens), outdir))
            confirm = input("确认? [y/N] ").strip().lower()
            if confirm not in ("y", "yes"):
                print("已取消")
                return 0
        results = generate(gens, runners, outdir)
        rc = print_summary(results)
        if rc == 0:
            print("\n输出目录: {}".format(outdir))
            print("该目录已被 .gitignore 忽略（/tools/generated_models/），不会被 git 跟踪。")
        return rc

    # no flags -> interactive menu
    if not sys.stdin.isatty():
        print("非交互环境：请使用 --list / --all / --only 参数。")
        parser.print_help()
        return 2
    return interactive(outdir, runners)


if __name__ == "__main__":
    raise SystemExit(main())
