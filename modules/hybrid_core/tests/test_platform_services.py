from __future__ import annotations

import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def proc_body(source: str, name: str, next_name: str = "") -> str:
    start = source.index(f"proc {name} {{")
    if next_name:
        return source[start : source.index(f"\nproc {next_name} {{", start)]
    return source[start:]


class PlatformServiceContractTests(unittest.TestCase):
    def test_storage_uses_appdata_scratch_retention_pin_and_quota(self) -> None:
        source = (ROOT / "modules/hybrid_core/tcl/storage_service.tcl").read_text(
            encoding="utf-8"
        )
        for value in (
            "APPDATA",
            "LOCALAPPDATA",
            "scratch_dir",
            "success_retention_days",
            "failure_retention_days",
            "success_keep_latest",
            "max_disk_gb",
            ".pinned",
            "pathWithin",
        ):
            self.assertIn(value, source)
        common = (ROOT / "modules/workflow_common.tcl").read_text(encoding="utf-8")
        self.assertIn("Dual-read migration", common)

    def test_detached_service_enforces_token_cancel_timeout_and_process_tree(self) -> None:
        source = (ROOT / "modules/hybrid_core/tcl/detached_task.tcl").read_text(
            encoding="utf-8"
        )
        for value in (
            "--task-token",
            "cancel.flag",
            "terminateProcessTree",
            "taskkill /PID $pid /T /F",
            "returnedToken ne $taskToken",
            "timed out",
        ):
            self.assertIn(value, source)

    def test_solid_seam_production_bridge_uses_binary_hybrid_result(self) -> None:
        source = (ROOT / "modules/solid_seam/tcl/python_bridge.tcl").read_text(
            encoding="utf-8"
        )
        body = proc_body(source, "::SolidSeam::runPythonDetection")
        self.assertIn("::HybridCore::runPythonEntry", body)
        self.assertIn("candidates.hmwfr", body)
        self.assertIn("::HybridCore::loadBinaryResult", body)
        self.assertNotIn("source $", body)

    def test_local_mesh_production_path_uses_shared_detached_service(self) -> None:
        source = (ROOT / "modules/local_mesh_optimizer.tcl").read_text(encoding="utf-8")
        body = proc_body(source, "::LocalMeshOptimizer::runPython", "::LocalMeshOptimizer::checkQuality")
        self.assertIn("::HybridCore::runDetachedPythonStage", body)
        self.assertIn("::HybridCore::taskToken", body)
        self.assertNotIn("exec {*}$command", body)

    def test_module_capability_manifest_is_distributed(self) -> None:
        self.assertTrue((ROOT / "modules/module_status.json").is_file())


if __name__ == "__main__":
    unittest.main()
