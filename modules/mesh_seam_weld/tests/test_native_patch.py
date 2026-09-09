import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
FIXTURES = ROOT / "modules" / "mesh_seam_weld" / "tests" / "fixtures"


def load_curved_strip_fixture():
    """Boundary edges and node coordinates captured from HyperMesh 2019."""
    nodes = {}
    before = []
    after = []
    text = (FIXTURES / "curved_strip_remesh_hm2019.txt").read_text(encoding="utf-8")
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split()
        if parts[0] == "NODE":
            nodes[parts[1]] = parts[2:5]
        elif parts[0] == "BEFORE":
            before.append((parts[1], parts[2]))
        elif parts[0] == "AFTER":
            after.append((parts[1], parts[2]))
    return nodes, before, after


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class NativePatchTests(unittest.TestCase):
    def setUp(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval(
            """
namespace eval ::MeshSeamWeld {
    variable cfg
    array set cfg {weld_mesh_size 6.5 strict_patch_boundary_check 0}
}
namespace eval ::HybridCore {
    proc log args {}
    proc progressUpdate args {}
}
"""
        )
        self.tcl.call(
            "source", str(ROOT / "modules" / "mesh_seam_weld" / "tcl" / "executor.tcl")
        )
        self.tcl.eval(
            """
set events {}
set mesh {90}
set remeshMode normal
proc ::MeshSeamWeld::uniq {ids} {return [lsort -unique -integer $ids]}
proc ::MeshSeamWeld::componentIdsFromNodes args {return 10}
proc ::MeshSeamWeld::seamComponentForRelatedComps args {
    lappend ::events thickness
    return SEAM_T1.2
}
proc ::MeshSeamWeld::ensureOutputComponent args {return 30}
proc ::MeshSeamWeld::shouldUpdatePathProgress args {return 1}
proc *currentcollector {type name} {lappend ::events [list current $name]}
proc ::MeshSeamWeld::componentElementIds args {return $::mesh}
proc ::MeshSeamWeld::idsAddedToCollection {before after} {
    set result {}
    foreach id $after {
        if {[lsearch -exact $before $id] < 0} {lappend result $id}
    }
    return $result
}
proc ::MeshSeamWeld::runImprintNodeList args {
    lappend ::events [linsert $args 0 imprint]
    if {$::remeshMode eq "curved" || $::remeshMode eq "wrongrail"} {
        # Three-quad strip of the curved generalized-T fixture.
        set ::mesh {90 100 101 102}
    } else {
        set ::mesh {90 100}
    }
}
proc ::MeshSeamWeld::readShellElementConnectivityBulk {ids mark} {
    if {$::remeshMode eq "curved" || $::remeshMode eq "wrongrail"} {
        set curved {100 {1 11 12 2} 101 {2 12 13 3} 102 {3 13 14 4}
            103 {1 11 31 21} 104 {21 31 12 2} 105 {2 12 32 22}
            106 {22 32 13 3} 107 {3 13 33 23} 108 {23 33 14 4}}
        set result {}
        foreach id $ids {
            if {[dict exists $curved $id]} { dict set result $id [dict get $curved $id] }
        }
        return $result
    }
    set result {}
    foreach id $ids {
        if {$id == 101 && $::remeshMode eq "broken"} {
            dict set result $id {1 2 4 9}
        } elseif {$id == 101 && $::remeshMode eq "split"} {
            dict set result $id {1 9 2 4}
        } elseif {$id == 102} {
            dict set result $id {1 4 3}
        } else {
            dict set result $id {1 2 4 3}
        }
    }
    return $result
}
proc ::MeshSeamWeld::nodeXYZ id {
    if {$::remeshMode eq "curved" || $::remeshMode eq "wrongrail"} {
        # Concentric cylinders R=97 (source rail) / R=100 (target rail) at
        # 10 degree steps; 21/22/23 and 31/32/33 are the arc midpoints the
        # remesher inserted on the curve, off the chord by the chord sagitta.
        set curved {1 {0 97.0 0.0} 2 {0 95.526352 16.843873} 3 {0 91.150184 33.175954}
            4 {0 84.004464 48.5} 11 {0 100.0 0.0} 12 {0 98.480775 17.364818}
            13 {0 93.969262 34.202014} 14 {0 86.602540 50.0}
            21 {0 96.627832 8.453840} 22 {0 93.691844 25.104654} 23 {0 87.909077 40.992676}
            31 {0 99.616322 8.715299} 32 {0 96.589530 25.881087} 33 {0 90.627915 42.260491}}
        if {$::remeshMode eq "wrongrail"} {
            # Node 21 lands on the target rail instead of on the source rail
            # whose chord 1-2 it subdivides.
            dict set curved 21 {0 99.5 8.7}
        }
        if {[dict exists $curved $id]} { return [dict get $curved $id] }
        return {0 0 0}
    }
    return [dict get {1 {0 0 0} 2 {1 0 0} 3 {1 1 0} 4 {0 1 0} 9 {0.5 0 0}} $id]
}
proc *createmark args {lappend ::events [linsert $args 0 mark]}
proc *elementsaddnodesfixed args {lappend ::events fixed}
proc *defaultremeshelems args {
    lappend ::events [linsert $args 0 automesh]
    switch -- $::remeshMode {
        split { set ::mesh {90 101 102} }
        curved { set ::mesh {90 103 104 105 106 107 108} }
        wrongrail { set ::mesh {90 103 104 105 106 107 108} }
        default { set ::mesh {90 101} }
    }
}
proc ::MeshSeamWeld::clearLocalTopologyCaches args {}
proc ::MeshSeamWeld::stageError {stage err} {error "$stage:$err"}
"""
        )

    def run_path(self):
        return self.tcl.eval(
            "::MeshSeamWeld::processWeldPathNativePatch "
            "{1 2} {20} 0 0 1 1 {} {} {200} 0"
        )

    def test_create_patch_order_scope_and_mixed_remesh(self):
        self.run_path()
        events = self.tcl.eval("set events")
        self.assertLess(events.index("thickness"), events.index("current SEAM_T1.2"))
        self.assertLess(events.index("current SEAM_T1.2"), events.index("imprint"))
        self.assertIn("imprint {1 2} 20 0 200 1", events)
        self.assertIn("mark elems 1 100", events)
        self.assertIn("automesh 1 6.5 2 2 1 1 1 1 0 0 0 0 2 30", events)
        self.assertEqual(self.tcl.eval("set mesh"), "90 101")

    def test_relaxed_attachment_allows_in_place_edge_subdivision(self):
        # The remesh split boundary edge 1-2 by inserting node 9 on it and
        # retriangulated the strip (90 kept, 101/102 new).  The attachment
        # polyline is unchanged, so the relaxed default accepts the result.
        self.tcl.eval("set ::remeshMode split")
        result = self.run_path()
        self.assertIn("weldElems {101 102}", result)

    def test_relaxed_attachment_still_rejects_moved_boundary(self):
        # Element 101 no longer reaches boundary nodes 3/4; its boundary moved
        # to node 9 off the original attachment edges.  Rejected even relaxed.
        self.tcl.eval("set ::remeshMode broken")
        with self.assertRaisesRegex(
            tkinter.TclError, "AUTOMESH:Native patch remesh moved"
        ):
            self.run_path()

    def test_relaxed_attachment_allows_curved_rail_subdivision(self):
        # Generalized T-joint: the source rail is an arc (R=97).  HM's remesh
        # split every rail chord at its arc midpoint and put the new node on
        # the curve -- 0.366 mm off the chord, 2.2% of its length.  That is
        # legitimate in-place refinement, not a moved attachment.
        self.tcl.eval("set ::remeshMode curved")
        result = self.run_path()
        self.assertIn("weldElems {103 104 105 106 107 108}", result)

    def test_relaxed_attachment_rejects_curved_rail_node_on_wrong_rail(self):
        # Same refinement topology, but the inserted node sits on the target
        # rail instead of the source-rail chord it subdivides.
        self.tcl.eval("set ::remeshMode wrongrail")
        with self.assertRaisesRegex(
            tkinter.TclError, "AUTOMESH:Native patch remesh moved"
        ):
            self.run_path()

    def _load_curved_strip(self):
        nodes, before, after = load_curved_strip_fixture()
        coords = " ".join(
            "%s {%s}" % (node_id, " ".join(xyz)) for node_id, xyz in nodes.items()
        )
        self.tcl.eval("array set ::curvedStripCoords {%s}" % coords)
        self.tcl.eval(
            "proc ::MeshSeamWeld::nodeXYZ {id} {return $::curvedStripCoords($id)}"
        )
        return (
            " ".join("{%s %s}" % edge for edge in before),
            " ".join("{%s %s}" % edge for edge in after),
        )

    def test_real_hm2019_curved_strip_remesh_is_accepted(self):
        # Replay the boundary measured on HyperMesh 2019 for the isolated
        # curved strip (R=97 source rail, R=100 target rail, 10 degree steps):
        # the remesh split all 18 rail chords at their arc midpoints and placed
        # the new nodes 0.366-0.377 mm off the chords.  The attachment is
        # preserved, so the check must accept it.
        before, after = self._load_curved_strip()
        self.assertEqual(
            self.tcl.eval(
                "::MeshSeamWeld::patchBoundaryAttachmentProblem {%s} {%s}"
                % (before, after)
            ),
            "",
        )

    def test_real_hm2019_curved_strip_node_on_wrong_rail_is_rejected(self):
        before, after = self._load_curved_strip()
        # Same subdivision topology, but the node inserted into source chord
        # 1-3 is moved onto the target rail.
        self.tcl.eval(
            "set ::curvedStripCoords(38) {0 99.616321950956 8.7152988728573}"
        )
        problem = self.tcl.eval(
            "::MeshSeamWeld::patchBoundaryAttachmentProblem {%s} {%s}"
            % (before, after)
        )
        self.assertIn(
            "inserted node 38 does not belong to attachment edge 1-3", problem
        )

    def test_strict_attachment_change_rejects_and_rolls_back_at_caller(self):
        self.tcl.eval("set ::remeshMode broken")
        self.tcl.eval("set ::MeshSeamWeld::cfg(strict_patch_boundary_check) 1")
        with self.assertRaisesRegex(tkinter.TclError, "AUTOMESH:Native patch remesh changed"):
            self.run_path()

    def test_strict_mode_accepts_identical_boundary(self):
        self.tcl.eval("set ::MeshSeamWeld::cfg(strict_patch_boundary_check) 1")
        result = self.run_path()
        self.assertIn("weldElems 101", result)

    def test_empty_patch_never_remeshes_existing_weld(self):
        self.tcl.eval("proc ::MeshSeamWeld::runImprintNodeList args {}")
        with self.assertRaisesRegex(tkinter.TclError, "IMPRINT:Native imprint did not create"):
            self.run_path()
        self.assertNotIn("automesh", self.tcl.eval("set events"))

    def test_imprint_create_patch_option_is_enabled(self):
        module = (ROOT / "modules" / "mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body = module.split("proc ::MeshSeamWeld::runImprintNodeList", 1)[1].split(
            "proc ::MeshSeamWeld::targetNodesFromImprintList", 1
        )[0]
        self.assertIn("create_joint_elems 1", body)
        self.assertIn("if {$createPatch} { break }", body)


if __name__ == "__main__":
    unittest.main()
