import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class NativePatchTests(unittest.TestCase):
    def setUp(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval(
            """
namespace eval ::MeshSeamWeld {
    variable cfg
    array set cfg {weld_mesh_size 6.5}
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
set broken 0
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
    set ::mesh {90 100}
}
proc ::MeshSeamWeld::readShellElementConnectivityBulk {ids mark} {
    if {$::broken && $ids eq "101"} {return {101 {1 2 4 9}}}
    set result {}
    foreach id $ids {dict set result $id {1 2 4 3}}
    return $result
}
proc *createmark args {lappend ::events [linsert $args 0 mark]}
proc *elementsaddnodesfixed args {lappend ::events fixed}
proc *defaultremeshelems args {
    lappend ::events [linsert $args 0 automesh]
    set ::mesh {90 101}
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

    def test_attachment_change_rejects_and_rolls_back_at_caller(self):
        self.tcl.eval("set broken 1")
        with self.assertRaisesRegex(tkinter.TclError, "AUTOMESH:Native patch remesh changed"):
            self.run_path()

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
