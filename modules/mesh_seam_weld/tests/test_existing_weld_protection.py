import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "mesh_seam_weld.tcl"


def extract_procs(interpreter, source, names):
    """Eval only the named top-level procs into `interpreter`.

    The module is a 7000-line HyperMesh script which cannot be sourced into a
    bare Tcl interpreter, so the helpers under test are lifted out as complete
    top-level commands.  Splitting with Tcl's own `info complete` keeps braces
    and quotes inside comments from confusing a naive counter.
    """
    buffer = ""
    pending = False
    for line in source.splitlines(keepends=True):
        if not pending and not line.startswith("proc "):
            continue
        pending = True
        buffer += line
        # `info complete` returns 1 when the buffer is a whole command, so the
        # buffer is only ready to evaluate on a true result.
        if interpreter.call("info", "complete", buffer):
            if any("proc ::MeshSeamWeld::%s " % name in buffer for name in names):
                interpreter.eval(buffer)
            buffer = ""
            pending = False
    missing = [name for name in names
               if not interpreter.call("info", "procs", "::MeshSeamWeld::%s" % name)]
    if missing:
        raise ValueError("could not extract procs: %s" % ", ".join(missing))


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class ExistingWeldProtectionTests(unittest.TestCase):
    """The by-adjacent halo must not remesh an existing SEAM_* weld mesh."""

    def setUp(self):
        self.tcl = tkinter.Tcl()
        source = MODULE.read_text(encoding="utf-8")
        self.tcl.eval(
            """
namespace eval ::MeshSeamWeld {
    variable cfg
    array set cfg {allow_break_existing_weld 0}
    variable elemComponentCache
    array set elemComponentCache {}
}
namespace eval ::HybridCore {
    proc log args {puts "LOG: $args"}
}
namespace eval ::HWFlow {}
"""
        )
        extract_procs(self.tcl, source, (
            "uniq", "isWeldComponentName", "componentNames",
            "elemComponentId", "elemIsExistingWeldElement",
            "filterProtectedWeldElements"))
        # Component ownership: 10/11 are ordinary shells, 20/21 are welds.
        self.tcl.eval(
            """
set ::compNames {10 PANEL_A 11 PANEL_SEAMLESS 20 SEAM_T2 21 MESH_SEAM_WELD_X 22 ^MSWE_1}
proc ::HWFlow::componentName {compId} {
    if {[dict exists $::compNames $compId]} {return [dict get $::compNames $compId]}
    return "COMP_$compId"
}
set ::elemComp {100 10 101 10 102 11 103 20 104 20 105 21 106 22}
proc hm_getvalue {args} {
    set id ""
    foreach arg $args {
        if {[string match "id=*" $arg]} {set id [string range $arg 3 end]}
    }
    if {[dict exists $::elemComp $id]} {return [dict get $::elemComp $id]}
    return ""
}
proc ::HWFlow::componentIdByName {name} {
    foreach {id compName} $::compNames {if {$compName eq $name} {return $id}}
    return ""
}
"""
        )

    def filter(self, elem_ids):
        # tcl.call collapses a two-element list result into one scalar, so read
        # the kept/removed pair back out with splitlist.  Tcl yields integer
        # element IDs and an empty string for an empty list; normalize both.
        kept, removed = self.tcl.splitlist(
            self.tcl.call("::MeshSeamWeld::filterProtectedWeldElements", elem_ids))
        return ([int(value) for value in kept], [int(value) for value in removed])

    def test_default_off_excludes_weld_elements(self):
        kept, removed = self.filter([100, 101, 103, 104])
        self.assertEqual(kept, [100, 101])
        self.assertEqual(removed, [103, 104])

    def test_weld_component_prefixes_are_protected(self):
        kept, removed = self.filter([105, 106])
        self.assertEqual(kept, [])
        self.assertEqual(removed, [105, 106])

    def test_all_weld_patch_filters_to_empty(self):
        kept, removed = self.filter([103, 104, 105])
        self.assertEqual(kept, [])
        self.assertEqual(removed, [103, 104, 105])

    def test_enabling_setting_keeps_every_element(self):
        self.tcl.eval("set ::MeshSeamWeld::cfg(allow_break_existing_weld) 1")
        kept, removed = self.filter([100, 103, 104, 105, 106])
        self.assertEqual(kept, [100, 103, 104, 105, 106])
        self.assertEqual(removed, [])

    def test_panel_seamless_is_not_a_weld_component(self):
        # A normal collector whose name merely contains "SEAM" must stay in
        # scope; the module anchors its weld-name patterns to the prefix.
        self.assertEqual(int(self.tcl.call("::MeshSeamWeld::elemIsExistingWeldElement", 102)), 0)

    def test_ordinary_shells_are_not_protected(self):
        for elem_id in (100, 101):
            self.assertEqual(
                int(self.tcl.call("::MeshSeamWeld::elemIsExistingWeldElement", elem_id)), 0)

    def test_weld_elements_are_detected(self):
        for elem_id in (103, 104, 105, 106):
            self.assertEqual(
                int(self.tcl.call("::MeshSeamWeld::elemIsExistingWeldElement", elem_id)), 1)

    def test_missing_component_is_not_protected(self):
        self.assertEqual(int(self.tcl.call("::MeshSeamWeld::elemIsExistingWeldElement", 999)), 0)


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class AdjacentExpansionProtectionTests(unittest.TestCase):
    """The real by-adjacent expansion must drop welded halo elements."""

    def setUp(self):
        self.tcl = tkinter.Tcl()
        source = MODULE.read_text(encoding="utf-8")
        self.tcl.eval(
            """
namespace eval ::MeshSeamWeld {
    variable cfg
    array set cfg {allow_break_existing_weld 0 patch_expand_layers 2}
    variable elemComponentCache
    array set elemComponentCache {}
    variable verbosePathLogging 0
}
namespace eval ::HybridCore {
    proc log args {puts "LOG: $args"}
}
namespace eval ::HWFlow {}
"""
        )
        extract_procs(self.tcl, source, (
            "uniq", "isWeldComponentName", "componentNames", "elemComponentId",
            "elemIsExistingWeldElement", "filterProtectedWeldElements",
            "responsiveCheckpoint", "constrainTargetShells", "expandTargetElementPatch"))
        # Element ownership: 100/101 are ordinary shells; 103/104 belong to a
        # neighbouring SEAM_T2 weld strip that by-adjacent would otherwise pull
        # into the remesh halo.
        self.tcl.eval(
            """
set ::compNames {10 PANEL_A 20 SEAM_T2}
proc ::HWFlow::componentName {compId} {
    if {[dict exists $::compNames $compId]} {return [dict get $::compNames $compId]}
    return "COMP_$compId"
}
proc ::HWFlow::componentIdByName {name} {
    foreach {id compName} $::compNames {if {$compName eq $name} {return $id}}
    return ""
}
set ::elemComp {100 10 101 10 103 20 104 20}
proc hm_getvalue {args} {
    set id ""
    foreach arg $args {if {[string match "id=*" $arg]} {set id [string range $arg 3 end]}}
    if {[dict exists $::elemComp $id]} {return [dict get $::elemComp $id]}
    return ""
}
# Native mark layer: the halo deliberately includes the neighbouring weld.
set ::halo {100 101 103 104}
proc ::MeshSeamWeld::isLinearShellElement args {return 1}
proc ::MeshSeamWeld::markElements {elemIds markId} {
    set ::markContents [lsort -integer -unique $elemIds]
    foreach entityType {elements elems} {catch {*clearmark $entityType $markId}}
    if {[llength $::markContents] == 0} {return {}}
    return $::markContents
}
proc ::MeshSeamWeld::markedElementIds {markId} {return $::markContents}
proc *appendmark {args} {
    incr ::appendCalls
    set ::markContents [lsort -integer -unique [concat $::markContents $::halo]]
    return 1
}
proc ::MeshSeamWeld::targetShellConnectivity args {return {}}
proc ::MeshSeamWeld::nodeToElementsFromConnectivity args {return {}}
"""
        )

    def expand(self, seeds):
        return self.tcl.splitlist(
            self.tcl.call("::MeshSeamWeld::expandTargetElementPatch", seeds, [10], 1))

    def test_native_halo_drops_existing_weld_elements(self):
        result = [int(value) for value in self.expand([100])]
        self.assertEqual(result, [100, 101])

    def test_enabling_weld_break_does_not_allow_unselected_components(self):
        self.tcl.eval("set ::MeshSeamWeld::cfg(allow_break_existing_weld) 1")
        result = [int(value) for value in self.expand([100])]
        self.assertEqual(result, [100, 101])

    def test_halo_of_only_weld_elements_raises(self):
        # Model a halo that reaches nothing but the neighbouring weld strip.
        # The path must fail loudly rather than silently remesh that weld.
        self.tcl.eval("set ::halo {103 104}\nset ::markContents {103}")
        self.assertEqual(self.expand([103]), ())

    def test_ring_count_follows_configured_expansion_layers(self):
        # The by-adjacent expansion is the configured patch_expand_layers (the
        # old fixed 2..3 clamp is gone), so the imprint remesh rings always fit
        # inside the mark; a configured 0 keeps one ring as the usable floor.
        for layers, expected in ((0, 1), (2, 2), (4, 4)):
            with self.subTest(layers=layers):
                self.tcl.eval(
                    "set ::MeshSeamWeld::cfg(patch_expand_layers) %d\n"
                    "set ::appendCalls 0" % layers)
                result = [int(value) for value in self.expand([100])]
                self.assertEqual(result, [100, 101])
                self.assertEqual(int(self.tcl.eval("set ::appendCalls")), expected)


if __name__ == "__main__":
    unittest.main()
