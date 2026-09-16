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
    if {$::remeshMode eq "persistent_nonmanifold"} {
        # Native Create Patch emitted three faces sharing edge 1-2.
        set ::mesh {90 100 102 103}
    } elseif {$::remeshMode eq "embedded" || $::remeshMode eq "embedded_broken"} {
        set ::mesh {90 100 101 102 103 104 105 106 107}
    } elseif {$::remeshMode eq "curved" || $::remeshMode eq "wrongrail"} {
        # Three-quad strip of the curved generalized-T fixture.
        set ::mesh {90 100 101 102}
    } else {
        set ::mesh {90 100}
    }
}
proc ::MeshSeamWeld::readShellElementConnectivityBulk {ids mark} {
    if {$::remeshMode eq "persistent_nonmanifold"} {
        # Three faces per state share edge 1-2; the remesh keeps that topology.
        set native {
            100 {1 2 4} 102 {2 1 5} 103 {1 2 6}
            101 {1 2 4} 104 {2 1 5} 105 {1 2 6}}
        set result {}
        foreach id $ids {
            if {[dict exists $native $id]} { dict set result $id [dict get $native $id] }
        }
        return $result
    }
    if {$::remeshMode eq "embedded" || $::remeshMode eq "embedded_broken"} {
        set embedded {
            100 {1 2 9} 101 {2 3 9} 102 {3 4 9} 103 {4 1 9}
            104 {1 11 12 2} 105 {2 12 13 3}
            106 {3 13 14 4} 107 {4 14 11 1}
            110 {1 2 9} 111 {2 3 9} 112 {3 4 9} 113 {4 1 9}
            114 {1 11 12 2} 115 {2 12 13 3}
            116 {3 13 14 4} 117 {4 14 11 1}
            120 {1 10 9} 121 {10 2 9} 122 {2 3 9} 123 {3 4 9}
            124 {4 1 9} 125 {1 11 12 10} 126 {10 12 2}
            127 {2 12 13 3} 128 {3 13 14 4} 129 {4 14 11 1}}
        set result {}
        foreach id $ids {
            if {[dict exists $embedded $id]} { dict set result $id [dict get $embedded $id] }
        }
        return $result
    }
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
    if {$::remeshMode eq "persistent_nonmanifold"} {
        return [dict get {1 {0 0 0} 2 {1 0 0} 4 {0 1 0} 5 {1 1 0} 6 {0.5 0.5 0}} $id]
    }
    if {$::remeshMode eq "embedded" || $::remeshMode eq "embedded_broken"} {
        return [dict get {1 {-1 -1 0} 2 {1 -1 0} 3 {1 1 0} 4 {-1 1 0}
            8 {0 -1 0} 9 {0 0 0} 10 {0 -0.4 0}
            11 {-2 -2 0} 12 {2 -2 0}
            13 {2 2 0} 14 {-2 2 0}} $id]
    }
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
proc *clearmark args {lappend ::events [linsert $args 0 clearmark]}
proc *deletemark args {lappend ::events [linsert $args 0 delete]}
proc *elementsaddnodesfixed args {lappend ::events fixed}
proc *defaultremeshelems args {
    lappend ::events [linsert $args 0 automesh]
    switch -- $::remeshMode {
        split { set ::mesh {90 101 102} }
        persistent_nonmanifold { set ::mesh {90 101 104 105} }
        embedded { set ::mesh {90 110 111 112 113 114 115 116 117} }
        embedded_broken { set ::mesh {90 120 121 122 123 124 125 126 127 128 129} }
        curved { set ::mesh {90 103 104 105 106 107 108} }
        wrongrail { set ::mesh {90 103 104 105 106 107 108} }
        default { set ::mesh {90 101} }
    }
}
proc ::MeshSeamWeld::clearLocalTopologyCaches args {}
proc ::MeshSeamWeld::structuralMeshSnapshot args {lappend ::events snapshot; return {}}
proc ::MeshSeamWeld::validateStructuralMesh args {lappend ::events structural_check}
proc ::MeshSeamWeld::stageError {stage err {flags {}}} {
    return -code error -errorcode [linsert $flags 0 MESH_SEAM_WELD $stage] "$stage:$err"
}
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

    def test_patch_boundary_edges_strict_rejects_but_relaxed_extracts_mod2(self):
        # Native Create Patch can briefly produce three faces on one edge.
        # Its odd-owner edge belongs to the mod-2 exterior used to fix the
        # patch for remeshing; the strict call still rejects that topology.
        self.tcl.eval(
            """
proc ::MeshSeamWeld::readShellElementConnectivityBulk {ids mark} {
    set topology {
        10 {1 2 3}
        11 {2 1 4}
        12 {1 2 5}}
    set result {}
    foreach id $ids {dict set result $id [dict get $topology $id]}
    return $result
}
"""
        )
        with self.assertRaisesRegex(tkinter.TclError, "non-manifold edge: 1 2"):
            self.tcl.eval("::MeshSeamWeld::patchBoundaryEdges {10 11 12}")
        relaxed = self.tcl.eval(
            "::MeshSeamWeld::patchBoundaryEdges {10 11 12} 1"
        )
        self.assertGreaterEqual(
            int(self.tcl.eval("lsearch -exact {%s} {1 2}" % relaxed)), 0
        )

    def test_persistent_three_owner_edge_is_kept_in_relaxed_mode(self):
        # Field T seam: the isolated mixed remesh kept the native three-owner
        # edge, and the manual workflow accepts that same HyperMesh result.
        # The default relaxed final check must therefore keep the weld instead
        # of blocking a location the user already decided is weldable.
        self.tcl.eval("set ::remeshMode persistent_nonmanifold")
        result = self.run_path()
        self.assertIn("weldElems {101 104 105}", result)

    def test_persistent_three_owner_edge_is_rejected_in_strict_mode(self):
        self.tcl.eval("set ::remeshMode persistent_nonmanifold")
        self.tcl.eval("set ::MeshSeamWeld::cfg(strict_patch_boundary_check) 1")
        with self.assertRaisesRegex(
            tkinter.TclError, "AUTOMESH:Native patch contains a non-manifold edge: 1 2"
        ):
            self.run_path()

    def test_failed_final_check_requests_full_transaction_rollback(self):
        # A failure after the native imprint must not leave weld shell
        # elements behind, but it keeps the imprint and raises the
        # KEEP_IMPRINT errorcode so the caller commits the history state.
        self.tcl.eval("set ::remeshMode persistent_nonmanifold")
        self.tcl.eval("set ::MeshSeamWeld::cfg(strict_patch_boundary_check) 1")
        errorcode = self.tcl.eval(
            "catch {::MeshSeamWeld::processWeldPathNativePatch "
            "{1 2} {20} 0 0 1 1 {} {} {200} 0} msg opts; "
            "dict get $opts -errorcode"
        )
        self.assertNotIn("KEEP_IMPRINT", errorcode)
        events = self.tcl.eval("set events")
        self.assertNotIn("delete elems 1", events)

    def test_relaxed_attachment_allows_in_place_edge_subdivision(self):
        # The remesh split boundary edge 1-2 by inserting node 9 on it and
        # retriangulated the strip (90 kept, 101/102 new).  The attachment
        # polyline is unchanged, so the relaxed default accepts the result.
        self.tcl.eval("set ::remeshMode split")
        result = self.run_path()
        self.assertIn("weldElems {101 102}", result)

    def test_embedded_closed_source_rail_is_accepted_and_fixed(self):
        # A closed source rail can be shared by two rows of the native joint
        # patch and therefore be absent from the exterior boundary.  It is a
        # valid attachment when every ordered source segment is present.
        self.tcl.eval("set ::remeshMode embedded")
        result = self.tcl.eval(
            "::MeshSeamWeld::processWeldPathNativePatch "
            "{1 2 3 4} {20} 1 0 1 1 {} {} {200} 1"
        )
        self.assertIn("weldElems {110 111 112 113 114 115 116 117}", result)
        self.assertIn("mark nodes 2 1 2 3 4 11 12 13 14", self.tcl.eval("set events"))

    def test_native_source_rail_rebuild_keeps_create_patch_success(self):
        # Create Patch may rebuild the source-side rail internally, so a rail
        # that differs from the input node pairs is a diagnostic: the weld is
        # still created instead of blocking a location the user selected.
        self.tcl.eval("set ::remeshMode embedded_broken")
        result = self.tcl.eval(
            "::MeshSeamWeld::processWeldPathNativePatch "
            "{1 2 3 4} {20} 1 0 1 1 {} {} {200} 1"
        )
        self.assertIn("weldElems {120 121 122 123 124 125 126 127 128 129}", result)

    def test_relaxed_attachment_still_rejects_moved_boundary(self):
        # Element 101 no longer reaches boundary nodes 3/4; its boundary moved
        # to node 9 off the original attachment edges.  Rejected even relaxed.
        self.tcl.eval("set ::remeshMode broken")
        with self.assertRaisesRegex(
            tkinter.TclError, "AUTOMESH:.*(remesh moved|complete source rail)"
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

    def test_create_patch_remesh_layers_come_from_the_expansion_setting(self):
        # The by-adjacent quality remesh around the seam is the configured
        # patch_expand_layers (default 2), never a hard-coded 0: a plain split
        # leaves the ring around the web-to-base junction distorted.
        module = (ROOT / "modules" / "mesh_seam_weld.tcl").read_text(encoding="utf-8")
        body = module.split("proc ::MeshSeamWeld::runImprintNodeList", 1)[1].split(
            "proc ::MeshSeamWeld::targetNodesFromImprintList", 1
        )[0]
        createBranch = body.split("if {$createPatch} {", 1)[1]
        self.assertIn("remesh_layers %s", createBranch)
        self.assertIn("$cfg(patch_expand_layers)", createBranch)
        self.assertNotIn("remesh_layers 0", createBranch)


if __name__ == "__main__":
    unittest.main()
