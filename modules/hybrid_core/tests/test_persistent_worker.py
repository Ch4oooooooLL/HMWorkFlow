from __future__ import annotations

import importlib.util
import json
import tempfile
import tkinter
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
PYTHON_DIR = ROOT / "modules" / "hybrid_core" / "python"


def load_worker():
    spec = importlib.util.spec_from_file_location(
        "persistent_worker_under_test", PYTHON_DIR / "persistent_worker.py"
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


class EmbeddedWorkerBootstrapTests(unittest.TestCase):
    def test_worker_bootstraps_its_own_module_directory_before_worker_cache_import(self):
        source = (PYTHON_DIR / "persistent_worker.py").read_text(encoding="utf-8")
        path_insert = source.index("sys.path.insert(0, str(_WORKER_DIR))")
        cache_import = source.index("import worker_cache as _worker_cache")
        self.assertLess(path_insert, cache_import)


class PersistentWorkerTests(unittest.TestCase):
    def test_entry_and_its_imports_are_executed_only_once(self):
        worker = load_worker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            task_one = root / "task-one"
            task_two = root / "task-two"
            (root / "dependency.py").write_text(
                "from pathlib import Path\n"
                "marker = Path(__file__).with_name('imports.txt')\n"
                "marker.write_text(marker.read_text() + 'x' if marker.exists() else 'x')\n",
                encoding="utf-8",
            )
            entry = root / "main.py"
            entry.write_text(
                "import dependency\n"
                "def main(argv):\n"
                "    return 0\n",
                encoding="utf-8",
            )
            request = {"entry": str(entry), "arguments": [], "task_dir": str(task_one)}

            self.assertEqual(worker._run(request)[0], 0)
            request["task_dir"] = str(task_two)
            self.assertEqual(worker._run(request)[0], 0)

            self.assertEqual((root / "imports.txt").read_text(encoding="utf-8"), "x")

    def test_switching_entries_restores_each_module_namespace_without_reimport(self):
        worker = load_worker()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, value in (("one", "ONE"), ("two", "TWO")):
                module_dir = root / name
                module_dir.mkdir()
                (module_dir / "shared_name.py").write_text(
                    "VALUE = {!r}\n".format(value), encoding="utf-8"
                )
                (module_dir / "main.py").write_text(
                    "import shared_name\n"
                    "def main(argv):\n"
                    "    from pathlib import Path\n"
                    "    Path(argv[0]).write_text(shared_name.VALUE)\n"
                    "    return 0\n",
                    encoding="utf-8",
                )

            outputs = []
            for index, name in enumerate(("one", "two", "one")):
                output = root / "out-{}.txt".format(index)
                outputs.append(output)
                request = {
                    "entry": str(root / name / "main.py"),
                    "arguments": [str(output)],
                    "task_dir": str(root / "task-{}".format(index)),
                }
                self.assertEqual(worker._run(request)[0], 0)

            self.assertEqual([path.read_text() for path in outputs], ["ONE", "TWO", "ONE"])

    def test_mesh_cache_reuses_data_for_equal_tcl_fingerprints(self):
        worker = load_worker()
        cache = worker._worker_cache
        cache.clear()
        calls = []
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "task-one" / "mesh.json"
            second = Path(directory) / "task-two" / "mesh.json"
            first.parent.mkdir(); second.parent.mkdir()
            first.write_text("same mesh", encoding="utf-8")
            second.write_text("same mesh", encoding="utf-8")

            cache.begin_request({str(first): "mesh:v1"})
            value_one = cache.get_file_resource("mesh_model", first, lambda: calls.append(1) or object())
            cache.begin_request({str(second): "mesh:v1"})
            value_two = cache.get_file_resource("mesh_model", second, lambda: calls.append(2) or object())

        self.assertIs(value_one, value_two)
        self.assertEqual(calls, [1])

    def test_kdtree_and_adjacency_factories_run_once_per_identity(self):
        worker = load_worker()
        cache = worker._worker_cache
        cache.clear()
        calls = []

        tree_one = cache.get_kdtree("nodes:v1", lambda: calls.append("tree") or object())
        tree_two = cache.get_kdtree("nodes:v1", lambda: calls.append("tree") or object())
        graph_one = cache.get_adjacency("elements:v1", lambda: calls.append("graph") or object())
        graph_two = cache.get_adjacency("elements:v1", lambda: calls.append("graph") or object())

        self.assertIs(tree_one, tree_two)
        self.assertIs(graph_one, graph_two)
        self.assertEqual(calls, ["tree", "graph"])

    def test_tcl_request_includes_mesh_content_fingerprint(self):
        interpreter = tkinter.Tcl()
        interpreter.eval("namespace eval ::HybridCore {}")
        interpreter.eval("source {{{}}}".format((ROOT / "modules/hybrid_core/tcl/data_writer.tcl").as_posix()))
        interpreter.eval("source {{{}}}".format((ROOT / "modules/hybrid_core/tcl/process_runner.tcl").as_posix()))
        with tempfile.TemporaryDirectory() as directory:
            mesh = Path(directory) / "mesh.json"
            mesh.write_text('{"mesh": 1}', encoding="utf-8")
            raw = interpreter.call(
                "::HybridCore::workerRequestJson",
                "request-1",
                "entry.py",
                ("--mesh", str(mesh)),
                directory,
            )
        payload = json.loads(raw)
        self.assertIn(str(mesh.resolve()).replace("\\", "/"), payload["input_fingerprints"])

    def test_tcl_writer_keeps_fingerprint_without_rereading_file(self):
        interpreter = tkinter.Tcl()
        interpreter.eval("namespace eval ::HybridCore { variable workerFileFingerprints {} }")
        interpreter.eval("source {{{}}}".format((ROOT / "modules/hybrid_core/tcl/data_writer.tcl").as_posix()))
        interpreter.eval("source {{{}}}".format((ROOT / "modules/hybrid_core/tcl/process_runner.tcl").as_posix()))
        with tempfile.TemporaryDirectory() as directory:
            mesh = Path(directory) / "mesh.json"
            interpreter.call("::HybridCore::writeTextFile", str(mesh), "same mesh")
            mesh.unlink()
            fingerprint = interpreter.call("::HybridCore::workerFileFingerprint", str(mesh))
        self.assertTrue(str(fingerprint).startswith("mesh-v1:"))

    def test_tcl_fingerprint_has_pre_86_fallback_without_zlib(self):
        interpreter = tkinter.Tcl()
        interpreter.eval("namespace eval ::HybridCore {}")
        interpreter.eval("source {{{}}}".format((ROOT / "modules/hybrid_core/tcl/data_writer.tcl").as_posix()))
        interpreter.eval("rename zlib ::zlib_for_test")
        try:
            first = interpreter.call("::HybridCore::workerContentFingerprint", "mesh-data")
            second = interpreter.call("::HybridCore::workerContentFingerprint", "mesh-data")
        finally:
            interpreter.eval("rename ::zlib_for_test zlib")
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
