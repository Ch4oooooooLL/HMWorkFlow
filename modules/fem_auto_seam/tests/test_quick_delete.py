from __future__ import annotations

import tkinter
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "modules" / "fem_auto_seam" / "tcl" / "quick_delete.tcl"


class QuickDeleteTopologyTests(unittest.TestCase):
    def setUp(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval("namespace eval ::FemAutoSeam { variable cfg }")
        self.tcl.eval("array set ::FemAutoSeam::nodes {}")
        self.tcl.eval(
            "proc ::FemAutoSeam::elemNodes {id} { return $::FemAutoSeam::nodes($id) }"
        )
        self.tcl.eval(f"source {{{SCRIPT.as_posix()}}}")

    def test_island_uses_shared_edges_not_point_contacts(self):
        self.tcl.eval(
            "array set ::FemAutoSeam::nodes {"
            "10 {1 2 5 4} 11 {2 3 6 5} "
            "20 {7 8 11 10} 21 {8 9 12 11} "
            "30 {3 13 14 15}}"
        )
        result = self.tcl.eval(
            "::FemAutoSeam::quickDeleteWeldIsland 10 {10 11 20 21 30}"
        )
        self.assertEqual("10 11", result)

    def test_second_weld_in_same_component_stays_separate(self):
        self.tcl.eval(
            "array set ::FemAutoSeam::nodes {"
            "10 {1 2 5 4} 11 {2 3 6 5} "
            "20 {7 8 11 10} 21 {8 9 12 11}}"
        )
        result = self.tcl.eval(
            "::FemAutoSeam::quickDeleteWeldIsland 20 {10 11 20 21}"
        )
        self.assertEqual("20 21", result)

    def test_triangle_and_quad_can_form_one_weld(self):
        self.tcl.eval("array set ::FemAutoSeam::nodes {10 {1 2 3} 11 {2 4 5 3}}")
        result = self.tcl.eval("::FemAutoSeam::quickDeleteWeldIsland 10 {10 11}")
        self.assertEqual("10 11", result)


if __name__ == "__main__":
    unittest.main()
