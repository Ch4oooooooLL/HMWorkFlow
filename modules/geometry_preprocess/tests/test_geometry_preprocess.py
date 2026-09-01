import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover
    tkinter = None


MODULE = Path(__file__).resolve().parents[2] / "geometry_preprocess.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class GeometryPreprocessTests(unittest.TestCase):
    def setUp(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source -encoding utf-8 {{{MODULE.as_posix()}}}")

    def call(self, proc, *args):
        return self.tcl.call(proc, *args)

    def test_family_base_strips_only_numeric_duplicate_suffix(self):
        self.assertEqual(self.call("::GeometryPreprocess::familyBase", "name.3"), "name")
        self.assertEqual(self.call("::GeometryPreprocess::familyBase", "name.rev"), "name.rev")
        self.assertEqual(self.call("::GeometryPreprocess::familyBase", "part.12a"), "part.12a")

    def test_same_family_matches_base_and_numeric_suffix_only(self):
        selected = "name.3"
        self.assertEqual(self.call("::GeometryPreprocess::sameFamily", "name", selected), 1)
        self.assertEqual(self.call("::GeometryPreprocess::sameFamily", "name.1", selected), 1)
        self.assertEqual(self.call("::GeometryPreprocess::sameFamily", "name.27", selected), 1)
        self.assertEqual(self.call("::GeometryPreprocess::sameFamily", "name.extra", selected), 0)
        self.assertEqual(self.call("::GeometryPreprocess::sameFamily", "name.+1", selected), 0)
        self.assertEqual(self.call("::GeometryPreprocess::sameFamily", "name2.1", selected), 0)

    def test_skeleton_matching_is_case_insensitive(self):
        self.tcl.eval("proc ::HWFlow::componentIds {{markId 2}} {return {1 2 3 4}}")
        self.tcl.eval(
            "proc ::HWFlow::componentName {id} {"
            "return [dict get {1 BODY 2 front_SKELL_main 3 skell_rear 4 SKELETON} $id]}"
        )
        self.assertEqual(tuple(self.call("::GeometryPreprocess::skeletonComponentIds")), (2, 3))

    def test_component_family_collects_base_and_numbered_duplicates(self):
        self.tcl.eval("proc ::HWFlow::componentIds {{markId 2}} {return {1 2 3 4 5}}")
        self.tcl.eval(
            "proc ::HWFlow::componentName {id} {"
            "return [dict get {1 name 2 name.1 3 name.3 4 name.rev 5 name2.1} $id]}"
        )
        self.assertEqual(
            tuple(self.call("::GeometryPreprocess::componentFamilyIds", "name.3")),
            (1, 2, 3),
        )

    def test_vehicle_transform_uses_legacy_two_step_rotation(self):
        self.tcl.eval("set ::rotation_calls {}")
        self.tcl.eval("proc *clearmark {args} {}")
        self.tcl.eval("proc *createmark {args} {}")
        self.tcl.eval("proc hm_getmark {args} {return {10 20}}")
        self.tcl.eval("proc *startnotehistorystate {args} {}")
        self.tcl.eval("proc *endnotehistorystate {args} {}")
        self.tcl.eval("proc *createplane {args} {lappend ::rotation_calls [list plane {*}$args]}")
        self.tcl.eval("proc *rotatemark {args} {lappend ::rotation_calls [list rotate {*}$args]}")
        self.assertEqual(self.call("::GeometryPreprocess::convertToVehicleCoordinates"), 2)
        calls = self.tcl.splitlist(self.tcl.eval("set ::rotation_calls"))
        self.assertEqual(
            [self.tcl.splitlist(item) for item in calls],
            [
                ("plane", "1", "1", "0", "0", "0", "0", "0"),
                ("rotate", "components", "1", "1", "90"),
                ("plane", "1", "0", "0", "1", "0", "0", "0"),
                ("rotate", "components", "1", "1", "-90"),
            ],
        )

    def test_archive_moves_to_useless_and_hides_every_component(self):
        self.tcl.eval("set ::archive_name {}; set ::archive_ids {}; set ::hidden_names {}")
        self.tcl.eval("proc *startnotehistorystate {args} {}")
        self.tcl.eval("proc *endnotehistorystate {args} {}")
        self.tcl.eval(
            "proc ::HWFlow::addComponentsToAssembly {name ids {color 9}} {"
            "set ::archive_name $name; set ::archive_ids $ids; return 99}"
        )
        self.tcl.eval(
            "proc ::HWFlow::componentName {id} {return [dict get {7 name 8 name.1} $id]}"
        )
        self.tcl.eval(
            "proc ::HWFlow::displayComponent {name state} {lappend ::hidden_names $name $state}"
        )
        self.assertEqual(self.call("::GeometryPreprocess::archiveComponents", (7, 8)), 2)
        self.assertEqual(self.tcl.eval("set ::archive_name"), "USELESS")
        self.assertEqual(tuple(self.tcl.splitlist(self.tcl.eval("set ::archive_ids"))), ("7", "8"))
        self.assertEqual(
            tuple(self.tcl.splitlist(self.tcl.eval("set ::hidden_names"))),
            ("name", "off", "name.1", "off"),
        )

    def test_panel_builds_with_shared_module_layout(self):
        try:
            root = tkinter.Tk()
        except tkinter.TclError as exc:
            self.skipTest(f"Tk display is unavailable: {exc}")
        root.withdraw()
        tcl = root.tk
        try:
            tcl.eval(f"source -encoding utf-8 {{{MODULE.as_posix()}}}")
            # Do not block the test in the module's normal modal wait.
            tcl.eval("rename tkwait ::GeometryPreprocess::__real_tkwait")
            tcl.eval("proc tkwait {args} {return}")
            tcl.call("::GeometryPreprocess::runAction")

            self.assertEqual(
                tcl.call(".geometry_preprocess.main.coordinates.run", "cget", "-text"),
                "Convert to Vehicle Coordinates",
            )
            self.assertEqual(
                tcl.call(".geometry_preprocess.main.organization.clean", "cget", "-text"),
                "Clean Irrelevant Components",
            )
            self.assertEqual(
                tcl.call(".geometry_preprocess.main.organization.skell", "cget", "-text"),
                "Remove Skeleton",
            )
            self.assertEqual(
                tcl.call("winfo", "class", ".geometry_preprocess.main.coordinates"),
                "Labelframe",
            )
        finally:
            try:
                tcl.call("destroy", ".geometry_preprocess")
            except tkinter.TclError:
                pass
            root.destroy()


if __name__ == "__main__":
    unittest.main()
