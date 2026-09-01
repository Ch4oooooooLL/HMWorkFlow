"""End-to-end CLI verification of the BatchMesher module worker flow.

Runs the module's real worker code (modules/batch_mesher/background_worker.tcl)
inside hmbatch for both locally installed releases (HyperMesh 2019 and
HyperWorks 2022), exactly as ::BatchMesher::writeBackgroundLauncher does:

    1. Generate a surface-only model snapshot with the release's own hmbatch.
    2. Write background_launcher.tcl carrying ::BatchMesherWorkerConfig.
    3. Launch `hmbatch -nocommand -nouserprofiledialog -tcl background_launcher.tcl`
       in the worker's private run directory.
    4. Wait for the terminal background.state and validate the artifacts:
       per-task status, created elements, task_result.fem, task_result.hm.

Usage:
    python tools\\verify_batch_mesher_cli.py [--work-root runtime/tasks/batch_mesher/cli_verify]
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import time
import tkinter
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

ROOT = Path(__file__).resolve().parents[1]

INSTALLS: Dict[str, Dict[str, Path]] = {
    "2019": {
        "hmbatch": Path(
            r"D:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe"
        ),
        "criteria": Path(
            r"D:\Program Files\Altair\2019\hm\batchmesh\general_8mm.criteria"
        ),
        "param": Path(
            r"D:\Program Files\Altair\2019\hm\batchmesh\general_8mm.param"
        ),
        "template": Path(
            r"D:\Program Files\Altair\2019\templates\feoutput\optistruct\optistruct"
        ),
    },
    "2022": {
        "hmbatch": Path(
            r"D:\Program Files\Altair\2020\hwdesktop\hm\bin\win64\hmbatch.exe"
        ),
        "criteria": Path(
            r"D:\Program Files\Altair\2020\hwdesktop\hm\batchmesh\general_8mm.criteria"
        ),
        "param": Path(
            r"D:\Program Files\Altair\2020\hwdesktop\hm\batchmesh\general_8mm.param"
        ),
        "template": Path(
            r"D:\Program Files\Altair\2020\hwdesktop\templates\feoutput\optistruct\optistruct"
        ),
    },
}

WORKER_TCL = ROOT / "modules" / "batch_mesher" / "background_worker.tcl"
MERGE_WORKER_TCL = ROOT / "modules" / "batch_mesher" / "background_merge_worker.tcl"

SNAPSHOT_TCL = r"""
set reportPath [file join [pwd] "snapshot_surfaces.txt"]
set modelPath [file join [pwd] "model_before_batchmesh.hm"]
set code [catch {
    hm_answernext "yes"
    *deletemodel
    *createentity comps name=CLI_VERIFY_PANEL_1
    *createentity comps name=CLI_VERIFY_PANEL_2
    *currentcollector comps CLI_VERIFY_PANEL_1
    *surfacemode 4
    *createplane 1 0.0 0.0 1.0 0.0 0.0 0.0
    *surfaceplane 1 200.0
    *currentcollector comps CLI_VERIFY_PANEL_2
    *createplane 1 0.0 0.0 1.0 350.0 0.0 0.0
    *surfaceplane 1 200.0
    *createmark surfs 1 all
    set ids [hm_getmark surfs 1]
    if {[llength $ids] != 2} { error "expected two surfaces, got [llength $ids]: $ids" }
    set ch [open $reportPath w]
    fconfigure $ch -encoding utf-8 -translation lf
    puts $ch "surface_ids=$ids"
    close $ch
    *writefile $modelPath 1
    if {![file isfile $modelPath] || [file size $modelPath] == 0} {
        error "snapshot model was not written: $modelPath"
    }
    set ch [open $reportPath a]
    fconfigure $ch -encoding utf-8 -translation lf
    puts $ch "model_path=$modelPath"
    puts $ch "model_bytes=[file size $modelPath]"
    puts $ch "status=PASS"
    close $ch
} errorMessage errorOptions]
if {$code} {
    set ch [open $reportPath w]
    fconfigure $ch -encoding utf-8 -translation lf
    puts $ch "status=FAIL"
    puts $ch "error=$errorMessage"
    if {[dict exists $errorOptions -errorinfo]} {
        puts $ch "error_info=[string map {\n { | }} [dict get $errorOptions -errorinfo]]"
    }
    close $ch
}
"""

LAUNCHER_WRAPPER = r"""
set __bm_launch_code [catch {source $__bm_worker} __bm_launch_error __bm_launch_options]
if {$__bm_launch_code} {
    set __bm_detail $__bm_launch_error
    if {[dict exists $__bm_launch_options -errorinfo]} { append __bm_detail "\n" [dict get $__bm_launch_options -errorinfo] }
    set __bm_log [file join [dict get $::BatchMesherWorkerConfig run_dir] launcher_error.log]
    set __bm_ch [open $__bm_log w]
    fconfigure $__bm_ch -encoding utf-8 -translation lf
    puts $__bm_ch $__bm_detail
    close $__bm_ch
    set __bm_state [dict create schema_version 1 overall_status failed current_index -1 \
        total [llength [dict get $::BatchMesherWorkerConfig tasks]] \
        message "Background worker could not be loaded: $__bm_detail" updated_ms [clock milliseconds] \
        tasks [dict get $::BatchMesherWorkerConfig tasks] result_fem [dict get $::BatchMesherWorkerConfig result_fem]]
    set __bm_state_path [dict get $::BatchMesherWorkerConfig state_path]
    set __bm_ch [open $__bm_state_path w]
    fconfigure $__bm_ch -encoding utf-8 -translation lf
    puts -nonewline $__bm_ch $__bm_state
    close $__bm_ch
    return
}
"""


def tcl_quote(value: str) -> str:
    """Wrap a value so Tcl treats it as one literal word."""
    return "{" + value.replace("{", r"\{").replace("}", r"\}") + "}"


def tcl_list(values: Sequence[str]) -> str:
    return " ".join(tcl_quote(v) for v in values)


def run_process(
    command: List[str],
    cwd: Path,
    stdout_path: Path,
    stderr_path: Path,
    timeout_seconds: int,
) -> Tuple[int, str]:
    with stdout_path.open("wb") as stdout, stderr_path.open("wb") as stderr:
        completed = subprocess.run(
            command,
            cwd=str(cwd),
            stdout=stdout,
            stderr=stderr,
            timeout=timeout_seconds,
        )
    return completed.returncode, (stdout_path.read_text(errors="replace"))


def tcl_dict_get(state_text: str, key: str) -> str:
    interp = tkinter.Tcl()
    interp.eval(f"set __state {{{state_text}}}")
    return interp.eval(f"dict get $__state {key}")


def parse_tasks(state_text: str) -> List[Dict[str, str]]:
    interp = tkinter.Tcl()
    interp.eval(f"set __state {{{state_text}}}")
    raw = interp.eval("dict get $__state tasks")
    interp.eval(f"set __tasks {{{raw}}}")
    count = int(interp.eval("llength $__tasks"))
    tasks: List[Dict[str, str]] = []
    for index in range(count):
        interp.eval(f"set __task [lindex $__tasks {index}]")
        keys = set(interp.eval("dict keys $__task").split())
        tasks.append(
            {
                "task_id": interp.eval("dict get $__task task_id"),
                "status": interp.eval("dict get $__task status"),
                "created_elements": interp.eval(
                    "dict get $__task created_elements"
                )
                if "created_elements" in keys
                else "",
                "connectivity_status": interp.eval(
                    "dict get $__task connectivity_status"
                )
                if "connectivity_status" in keys
                else "",
                "connectivity_components": interp.eval(
                    "dict get $__task connectivity_components"
                )
                if "connectivity_components" in keys
                else "",
                "quality_status": interp.eval("dict get $__task quality_status")
                if "quality_status" in keys
                else "",
                "quality_failed_elements": interp.eval(
                    "dict get $__task quality_failed_elements"
                )
                if "quality_failed_elements" in keys
                else "",
                "optimization_status": interp.eval(
                    "dict get $__task optimization_status"
                )
                if "optimization_status" in keys
                else "",
                "error_message": interp.eval("dict get $__task error_message")
                if "error_message" in keys
                else "",
            }
        )
    return tasks


def generate_snapshot(release: str, workdir: Path, install: Dict[str, Path]) -> List[str]:
    script = workdir / "make_snapshot.tcl"
    script.write_text(SNAPSHOT_TCL, encoding="utf-8")
    stdout_path = workdir / "snapshot_stdout.log"
    stderr_path = workdir / "snapshot_stderr.log"
    returncode, stdout = run_process(
        [str(install["hmbatch"]), "-nocommand", "-nouserprofiledialog", "-tcl", str(script)],
        workdir,
        stdout_path,
        stderr_path,
        300,
    )
    report = workdir / "snapshot_surfaces.txt"
    if not report.is_file():
        raise RuntimeError(
            f"[{release}] snapshot generation failed rc={returncode}; "
            f"report missing; stderr={stderr_path.read_text(errors='replace')[-2000:]}"
        )
    lines = dict(
        line.split("=", 1) for line in report.read_text(encoding="utf-8").splitlines()
    )
    if lines.get("status") != "PASS":
        raise RuntimeError(f"[{release}] snapshot report not PASS: {lines}")
    surface_ids = lines["surface_ids"].split()
    if len(surface_ids) != 2:
        raise RuntimeError(f"[{release}] expected 2 snapshot surfaces: {surface_ids}")
    return surface_ids


def write_worker_launcher(
    release: str,
    worker_dir: Path,
    model_path: Path,
    install: Dict[str, Path],
    surface_ids: List[str],
    worker_tcl: Path = WORKER_TCL,
) -> Path:
    worker_dir.mkdir(parents=True, exist_ok=True)
    criteria = install["criteria"]
    param = install["param"]
    tasks = [
        {
            "task_id": "T001",
            "group_id": "G001",
            "surface_ids": [surface_ids[0]],
            "component_names": ["CLI_VERIFY_PANEL_1"],
            "status": "pending",
        },
        {
            "task_id": "T002",
            "group_id": "G002",
            "surface_ids": [surface_ids[1]],
            "component_names": ["CLI_VERIFY_PANEL_2"],
            "status": "pending",
        },
    ]
    task_tcl = " ".join(
        "{" + " ".join(
            f"{key} {{{' '.join(value) if isinstance(value, list) else value}}}"
            for key, value in task.items()
        ) + "}" for task in tasks
    )
    config_entries = [
        ("run_dir", str(worker_dir)),
        ("model", str(model_path)),
        ("criteria", str(criteria)),
        ("param", str(param)),
        ("tasks", task_tcl),
        ("continue_after_failure", "1"),
        ("state_path", str(worker_dir / "background.state")),
        ("result_fem", str(worker_dir / "task_result.fem")),
        ("output_model", str(worker_dir / "task_result.hm")),
        ("main_release", release),
        ("criteria_mtime", str(int(criteria.stat().st_mtime))),
        ("criteria_size", str(criteria.stat().st_size)),
        ("param_mtime", str(int(param.stat().st_mtime))),
        ("param_size", str(param.stat().st_size)),
        ("export_template", str(install["template"])),
        ("run_log", str(worker_dir / "hmbatch_worker.log")),
    ]
    config_text = " ".join(
        f"{key} {{{value}}}" for key, value in config_entries
    )
    launcher = worker_dir / "background_launcher.tcl"
    launcher.write_text(
        "\n".join(
            [
                f"set ::BatchMesherWorkerConfig {{{config_text}}}",
                f"set __bm_worker {tcl_quote(str(worker_tcl))}",
                LAUNCHER_WRAPPER,
            ]
        ),
        encoding="utf-8",
    )
    return launcher


def run_worker(
    release: str,
    workdir: Path,
    install: Dict[str, Path],
    surface_ids: List[str],
    worker_tcl: Path = WORKER_TCL,
) -> Dict[str, object]:
    model_path = workdir / "model_before_batchmesh.hm"
    if not model_path.is_file():
        raise RuntimeError(f"[{release}] snapshot model missing: {model_path}")
    worker_dir = workdir / "workers" / "T001"
    launcher = write_worker_launcher(release, worker_dir, model_path, install, surface_ids, worker_tcl)

    stdout_path = worker_dir / "hmbatch_stdout.log"
    stderr_path = worker_dir / "hmbatch_stderr.log"
    started = time.time()
    returncode, stdout = run_process(
        [
            str(install["hmbatch"]),
            "-nocommand",
            "-nouserprofiledialog",
            "-tcl",
            str(launcher),
        ],
        worker_dir,
        stdout_path,
        stderr_path,
        600,
    )
    elapsed = time.time() - started
    state_path = worker_dir / "background.state"
    result: Dict[str, object] = {
        "release": release,
        "returncode": returncode,
        "elapsed_seconds": round(elapsed, 2),
        "state_path": str(state_path),
        "state_exists": state_path.is_file(),
    }
    if state_path.is_file():
        state_text = state_path.read_text(encoding="utf-8")
        result["overall_status"] = tcl_dict_get(state_text, "overall_status")
        result["message"] = tcl_dict_get(state_text, "message")
        result["tasks"] = parse_tasks(state_text)
    for name in ("task_result.fem", "task_result.hm", "hmbatch_worker.log"):
        artifact = worker_dir / name
        result[name] = {
            "exists": artifact.is_file(),
            "bytes": artifact.stat().st_size if artifact.is_file() else 0,
        }
    fem = worker_dir / "task_result.fem"
    if fem.is_file() and fem.stat().st_size > 0:
        text = fem.read_text(errors="replace")
        result["fem_element_cards"] = {
            card: text.count(card) for card in ("CQUAD4", "CTRIA3", "CQUAD8", "CTRIA6")
        }
        result["fem_grid_cards"] = text.count("GRID")
    return result


def run_merge_worker(
    release: str,
    workdir: Path,
    install: Dict[str, Path],
    worker_fems: List[Path],
    tasks_tcl: str,
) -> Dict[str, object]:
    merge_dir = workdir / "merge"
    merge_dir.mkdir(parents=True, exist_ok=True)
    config_entries = [
        ("run_dir", str(merge_dir)),
        ("tasks", tasks_tcl),
        ("inputs", " ".join(tcl_quote(str(p)) for p in worker_fems)),
        ("merge_mode", "fem"),
        ("main_release", release),
        ("merged_model", str(merge_dir / "merged_result.hm")),
        ("state_path", str(merge_dir / "merge.state")),
        ("result_fem", str(workdir / "batchmesh_result.fem")),
        ("export_template", str(install["template"])),
        ("run_log", str(merge_dir / "hmbatch_merge.log")),
    ]
    config_text = " ".join(f"{key} {{{value}}}" for key, value in config_entries)
    launcher = merge_dir / "background_launcher.tcl"
    launcher.write_text(
        "\n".join(
            [
                f"set ::BatchMesherWorkerConfig {{{config_text}}}",
                f"set __bm_worker {tcl_quote(str(MERGE_WORKER_TCL))}",
                LAUNCHER_WRAPPER,
            ]
        ),
        encoding="utf-8",
    )
    stdout_path = merge_dir / "hmbatch_stdout.log"
    stderr_path = merge_dir / "hmbatch_stderr.log"
    started = time.time()
    returncode, stdout = run_process(
        [
            str(install["hmbatch"]),
            "-nocommand",
            "-nouserprofiledialog",
            "-tcl",
            str(launcher),
        ],
        merge_dir,
        stdout_path,
        stderr_path,
        600,
    )
    elapsed = time.time() - started
    state_path = merge_dir / "merge.state"
    result: Dict[str, object] = {
        "returncode": returncode,
        "elapsed_seconds": round(elapsed, 2),
        "state_exists": state_path.is_file(),
    }
    if state_path.is_file():
        state_text = state_path.read_text(encoding="utf-8")
        result["overall_status"] = tcl_dict_get(state_text, "overall_status")
        result["message"] = tcl_dict_get(state_text, "message")
    for name in ("merged_result.hm", "hmbatch_merge.log"):
        artifact = merge_dir / name
        result[name] = {
            "exists": artifact.is_file(),
            "bytes": artifact.stat().st_size if artifact.is_file() else 0,
        }
    final_fem = workdir / "batchmesh_result.fem"
    result["batchmesh_result.fem"] = {
        "exists": final_fem.is_file(),
        "bytes": final_fem.stat().st_size if final_fem.is_file() else 0,
    }
    if final_fem.is_file() and final_fem.stat().st_size > 0:
        text = final_fem.read_text(errors="replace")
        result["fem_element_cards"] = {
            card: text.count(card) for card in ("CQUAD4", "CTRIA3", "CQUAD8", "CTRIA6")
        }
    return result


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--work-root",
        type=Path,
        default=ROOT / "runtime" / "tasks" / "batch_mesher" / "cli_verify",
    )
    parser.add_argument("--release", choices=("2019", "2022"))
    parser.add_argument(
        "--worker",
        type=Path,
        default=WORKER_TCL,
        help="background_worker.tcl variant to execute under hmbatch",
    )
    args = parser.parse_args(argv)
    worker_tcl = args.worker.resolve()

    failures: List[str] = []
    results: List[Dict[str, object]] = []
    for release, install in INSTALLS.items():
        if args.release and release != args.release:
            continue
        missing = [name for name, path in install.items() if not path.is_file()]
        if missing:
            failures.append(f"{release}: missing install files {missing}")
            continue
        workdir = args.work_root / f"hm{release}"
        if workdir.exists():
            shutil.rmtree(workdir)
        workdir.mkdir(parents=True)
        try:
            surface_ids = generate_snapshot(release, workdir, install)
            result = run_worker(release, workdir, install, surface_ids, worker_tcl)
            result["surface_ids"] = surface_ids
            ok = (
                result.get("state_exists")
                and result.get("overall_status") == "completed"
                and all(t["status"] == "completed" for t in result.get("tasks", []))
                and all(
                    t["connectivity_status"] == "valid"
                    and t["connectivity_components"] == "1"
                    and t["quality_status"] in {"passed", "needs_optimization"}
                    for t in result.get("tasks", [])
                )
                and result.get("task_result.fem", {}).get("exists")
                and result.get("task_result.hm", {}).get("exists")
            )
            worker_fems = [workdir / "workers" / "T001" / "task_result.fem"]
            tasks_tcl = " ".join(
                "{" + " ".join(
                    f"{key} {{{' '.join(value) if isinstance(value, list) else value}}}"
                    for key, value in task.items()
                ) + "}" for task in [
                    {
                        "task_id": "T001",
                        "group_id": "G001",
                        "surface_ids": [surface_ids[0]],
                        "component_names": ["CLI_VERIFY_PANEL_1"],
                        "status": "completed",
                    },
                    {
                        "task_id": "T002",
                        "group_id": "G002",
                        "surface_ids": [surface_ids[1]],
                        "component_names": ["CLI_VERIFY_PANEL_2"],
                        "status": "completed",
                    },
                ]
            )
            merge_result = run_merge_worker(release, workdir, install, worker_fems, tasks_tcl)
            result["merge"] = merge_result
            results.append(result)
            ok = ok and (
                merge_result.get("state_exists")
                and merge_result.get("overall_status") == "completed"
                and merge_result.get("merged_result.hm", {}).get("exists")
                and merge_result.get("batchmesh_result.fem", {}).get("exists")
            )
            print(
                f"{'PASS' if ok else 'FAIL'} release={release} "
                f"overall={result.get('overall_status')} "
                f"tasks={[(t['task_id'], t['status']) for t in result.get('tasks', [])]} "
                f"fem_bytes={result.get('task_result.fem', {}).get('bytes')} "
                f"hm_bytes={result.get('task_result.hm', {}).get('bytes')} "
                f"merge={merge_result.get('overall_status')} "
                f"merged_fem_bytes={merge_result.get('batchmesh_result.fem', {}).get('bytes')} "
                f"elapsed={result.get('elapsed_seconds')}s"
            )
            if not ok:
                failures.append(f"{release}: worker flow did not complete successfully")
                print(json.dumps(result, indent=2, ensure_ascii=False))
        except Exception as error:  # noqa: BLE001 - report and continue
            failures.append(f"{release}: {error}")
            print(f"FAIL release={release} error={error}")

    report = {
        "schema_version": "1.0",
        "status": "PASS" if not failures else "FAIL",
        "failures": failures,
        "releases": results,
    }
    report_path = args.work_root / "cli_verify_report.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"Report: {report_path}")
    return 0 if not failures else 1


if __name__ == "__main__":
    raise SystemExit(main())
