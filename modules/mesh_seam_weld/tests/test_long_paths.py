import itertools
import unittest
from pathlib import Path
try:
    import tkinter
except ImportError:
    tkinter = None

ROOT = Path(__file__).resolve().parents[3]


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class LongPathTests(unittest.TestCase):
    def setUp(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval("source {{{}}}".format((ROOT / "modules/mesh_seam_weld.tcl").as_posix()))

    def test_twenty_thousand_projected_nodes_need_no_beam_search(self):
        self.tcl.eval("""
set source {}; set target {}; set edges [dict create]
for {set i 0} {$i < 20000} {incr i} {
    lappend source [expr {$i+1}]
    lappend target [expr {$i+30001}]
    if {$i > 0} {dict set edges [::MeshSeamWeld::canonicalEdgeKey [expr {$i+30000}] [expr {$i+30001}]] 1}
}
set ::MeshSeamWeld::lastLocalTargetEdges $edges
rename ::MeshSeamWeld::limitTargetTrackingStates ::MeshSeamWeld::originalLimit
proc ::MeshSeamWeld::limitTargetTrackingStates {args} {error {unnecessary beam search}}
""")
        self.assertEqual(self.tcl.eval("expr {[::MeshSeamWeld::matchContinuousTargetPathNodes $source $target 0 $target] eq $target}"), "1")
        self.tcl.eval("dict set ::MeshSeamWeld::lastLocalTargetEdges 30001,50000 1")
        self.assertEqual(self.tcl.eval("expr {[::MeshSeamWeld::matchContinuousTargetPathNodes $source $target 1 $target] eq $target}"), "1")

    def test_equal_and_nearly_equal_long_correspondence_has_bounded_work(self):
        self.tcl.eval("""
set source {}; set target {}
for {set i 0} {$i < 4000} {incr i} {lappend source $i; lappend target [expr {$i+10000}]}
set ::reads 0
rename ::MeshSeamWeld::nodeXYZ ::MeshSeamWeld::originalXYZ
proc ::MeshSeamWeld::nodeXYZ {id} {
    incr ::reads
    if {$::reads > 20000} {error {excessive coordinate reads}}
    return [list [expr {$id % 10000}] 0 0]
}
# A command budget catches quadratic scans, including loops skipping coordinates.
set ::env(TCL_LIBRARY) [info library]
interp create worker
""")
        # Use an interpreter alias to apply a Tcl command budget to production code.
        self.tcl.eval("worker eval [list source {%s}]" % (ROOT / "modules/mesh_seam_weld.tcl").as_posix())
        self.tcl.eval("interp alias worker ::MeshSeamWeld::nodeXYZ {} ::MeshSeamWeld::nodeXYZ")
        for extra in (0, 1):
            target = self.tcl.eval("set target") + (" 14000" if extra else "")
            self.tcl.call("worker", "eval", self.tcl.call("list", "set", "source", self.tcl.eval("set source")))
            self.tcl.call("worker", "eval", self.tcl.call("list", "set", "target", target))
            self.tcl.eval("interp limit worker command -value 1000000")
            result = self.tcl.eval("worker eval {dict get [::MeshSeamWeld::anchoredTargetCorrespondence $source $target] anchor_indices}")
            indices = [int(x) for x in self.tcl.splitlist(result)]
            self.assertEqual(len(indices), 4000)
            self.assertEqual(indices[0], 0)
            self.assertEqual(indices[-1], 3999 + extra)
            self.assertTrue(all(a < b for a, b in zip(indices, indices[1:])))

    def test_banded_correspondence_matches_exhaustive_minimum(self):
        self.tcl.eval("proc ::MeshSeamWeld::nodeXYZ {id} {return [list [expr {($id*17)%23}] 0 0]}")
        for closed in (0, 1):
            source = (1, 2, 3, 4)
            target = tuple(range(11, 18))
            result = self.tcl.call("::MeshSeamWeld::anchoredTargetCorrespondence", source, target, closed)
            indices = tuple(int(x) for x in self.tcl.splitlist(self.tcl.call("dict", "get", result, "anchor_indices")))
            def cost(path):
                return sum(((s*17)%23-(target[i]*17)%23)**2 for s, i in zip(source, path))
            choices = [(0,)+p for p in itertools.combinations(range(1, len(target)), 3) if closed or p[-1] == len(target)-1]
            self.assertEqual(cost(indices), min(map(cost, choices)))
