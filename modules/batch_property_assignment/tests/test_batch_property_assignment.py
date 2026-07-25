from __future__ import annotations

import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover - depends on the local Python build
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "batch_property_assignment.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class BatchPropertyAssignmentNamingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source {{{MODULE.as_posix()}}}")

    def field(self, name: str, field: str) -> str:
        return self.tcl.call(
            "dict",
            "get",
            self.tcl.call("::BatchPropertyAssignment::parseComponentName", name),
            field,
        )

    def test_parses_versioned_component_with_underscores_in_part_number(self):
        name = "V03_FRONT_FLOOR_LH_T10_Q355"
        self.assertEqual(self.field(name, "kind"), "PART")
        self.assertEqual(self.field(name, "material"), "Q355")
        self.assertEqual(self.field(name, "thickness_token"), "10")
        self.assertEqual(self.field(name, "property_name"), "Q355_T10")

    def test_normalizes_decimal_thickness_for_property_reuse(self):
        name = "V2_BRACKET_T1.500_Al6061"
        self.assertEqual(self.field(name, "thickness_token"), "1.5")
        self.assertEqual(self.field(name, "property_name"), "Al6061_T1.5")

    def test_part_ignores_characters_after_thickness_and_uses_last_material_token(self):
        name = "V01_xxxx_T10aaa_355"
        self.assertEqual(self.field(name, "kind"), "PART")
        self.assertEqual(self.field(name, "thickness_token"), "10")
        self.assertEqual(self.field(name, "material"), "355")
        self.assertEqual(self.field(name, "property_name"), "355_T10")

    def test_part_allows_extra_tokens_between_thickness_and_material(self):
        name = "V01_floor_T2.5.surf_revision_Q355"
        self.assertEqual(self.field(name, "thickness_token"), "2.5")
        self.assertEqual(self.field(name, "material"), "Q355")
        self.assertEqual(self.field(name, "property_name"), "Q355_T2.5")

    def test_parses_seam_and_forces_steel(self):
        name = "SEAM_T20"
        self.assertEqual(self.field(name, "kind"), "SEAM")
        self.assertEqual(self.field(name, "material"), "Steel")
        self.assertEqual(self.field(name, "property_name"), "SEAM_T20")

    def test_seam_ignores_suffix_after_thickness(self):
        for name in ("SEAM_T10_dff", "SEAM_T10.surf", "WELD_SEAM_NOTE_T10abc"):
            with self.subTest(name=name):
                self.assertEqual(self.field(name, "kind"), "SEAM")
                self.assertEqual(self.field(name, "thickness_token"), "10")
                self.assertEqual(self.field(name, "property_name"), "SEAM_T10")

    def test_rejects_incomplete_or_extended_names(self):
        for name in (
            "V01_PART_Q355",
            "V01_PART_T10",
            "PART_T10_Q355",
            "PROPERTY_REVIEW__V01_PART_T10_Q355",
        ):
            with self.subTest(name=name):
                parsed = self.tcl.call("::BatchPropertyAssignment::parseComponentName", name)
                self.assertEqual(parsed, "")

    def test_rejects_zero_or_negative_thickness(self):
        for name in ("V01_PART_T0_Q355", "V01_PART_T-2_Q355", "SEAM_T0"):
            with self.subTest(name=name):
                parsed = self.tcl.call("::BatchPropertyAssignment::parseComponentName", name)
                self.assertEqual(parsed, "")

    def test_one_dimensional_keywords_are_case_insensitive(self):
        for name in (
            "V01_Beam_T10_Q355",
            "auto_RBE2_output",
            "front_bush_connector",
            "Spring_LH",
        ):
            with self.subTest(name=name):
                self.assertEqual(
                    int(self.tcl.call("::BatchPropertyAssignment::isIgnoredOneDimensionalName", name)),
                    1,
                )
        self.assertEqual(
            int(
                self.tcl.call(
                    "::BatchPropertyAssignment::isIgnoredOneDimensionalName",
                    "V01_FLOOR_T10_Q355",
                )
            ),
            0,
        )

    def test_execute_groups_components_and_lists_only_failures_for_review(self):
        self.tcl.eval(
            r"""
rename ::BatchPropertyAssignment::allComponentIds ::BatchPropertyAssignment::allComponentIds_real
rename ::BatchPropertyAssignment::nativeEmptyComponentIds ::BatchPropertyAssignment::nativeEmptyComponentIds_real
rename ::BatchPropertyAssignment::componentName ::BatchPropertyAssignment::componentName_real
rename ::BatchPropertyAssignment::materialIdByName ::BatchPropertyAssignment::materialIdByName_real
rename ::BatchPropertyAssignment::componentHasAnyProperty ::BatchPropertyAssignment::componentHasAnyProperty_real
rename ::BatchPropertyAssignment::isIgnoredOneDimensionalName ::BatchPropertyAssignment::isIgnoredOneDimensionalName_real
rename ::BatchPropertyAssignment::ensureProperty ::BatchPropertyAssignment::ensureProperty_real
rename ::BatchPropertyAssignment::assignProperty ::BatchPropertyAssignment::assignProperty_real
rename ::BatchPropertyAssignment::ensureReviewEntry ::BatchPropertyAssignment::ensureReviewEntry_real
proc ::BatchPropertyAssignment::allComponentIds {} {return {1 2 3 4 5 6}}
proc ::BatchPropertyAssignment::nativeEmptyComponentIds {} {return {6}}
proc ::BatchPropertyAssignment::componentName {id} {
    return [dict get {1 V01_FLOOR_T10_Q355 2 SEAM_T20 3 BAD_NAME 4 V01_DONE_T3_Q355 5 auto_RBE2_output 6 BAD_EMPTY_NAME} $id]
}
proc ::BatchPropertyAssignment::materialIdByName {name} {
    return [dict get {Q355 101 Steel 102} $name]
}
proc ::BatchPropertyAssignment::componentHasAnyProperty {componentId} {
    return [expr {$componentId == 4}]
}
proc ::BatchPropertyAssignment::isIgnoredOneDimensionalName {name} {
    return [expr {[string first RBE [string toupper $name]] >= 0}]
}
set ::propertyCalls {}
proc ::BatchPropertyAssignment::ensureProperty {name thickness materialId} {
    lappend ::propertyCalls [list $name $thickness $materialId]
    return [expr {200 + [llength $::propertyCalls]}]
}
proc ::BatchPropertyAssignment::assignProperty {componentId propertyId propertyName} {return 1}
set ::reviewCalls {}
proc ::BatchPropertyAssignment::ensureReviewEntry {componentName} {
    lappend ::reviewCalls $componentName
    return 301
}
"""
        )
        result = self.tcl.call("::BatchPropertyAssignment::execute")
        self.assertEqual(self.tcl.call("dict", "get", result, "scanned"), 6)
        self.assertEqual(self.tcl.call("dict", "get", result, "assigned"), 2)
        self.assertEqual(self.tcl.call("dict", "get", result, "skipped_empty"), 1)
        self.assertEqual(
            self.tcl.splitlist(self.tcl.call("dict", "get", result, "skipped_empty_names")),
            ("BAD_EMPTY_NAME",),
        )
        self.assertEqual(self.tcl.call("dict", "get", result, "skipped_existing"), 1)
        self.assertEqual(self.tcl.call("dict", "get", result, "skipped_1d"), 1)
        self.assertEqual(
            self.tcl.splitlist(self.tcl.call("dict", "get", result, "property_names")),
            ("Q355_T10", "SEAM_T20"),
        )
        self.assertEqual(self.tcl.splitlist(self.tcl.eval("set ::reviewCalls")), ("BAD_NAME",))
        property_calls = self.tcl.splitlist(self.tcl.eval("set ::propertyCalls"))
        self.assertEqual(self.tcl.splitlist(property_calls[0]), ("Q355_T10", "10.0", "101"))
        self.assertEqual(self.tcl.splitlist(property_calls[1]), ("SEAM_T20", "20.0", "102"))

    def test_native_empty_detection_uses_hypermesh_preview_empty_once(self):
        self.tcl.eval(
            r"""
set ::previewEmptyCalls {}
proc *clearmark {entityType markId} {}
proc *EntityPreviewEmpty {entityType markId} {
    lappend ::previewEmptyCalls [list $entityType $markId]
}
proc hm_getmark {entityType markId} {return {9 3 9}}
"""
        )
        result = self.tcl.call("::BatchPropertyAssignment::nativeEmptyComponentIds")
        self.assertEqual(self.tcl.splitlist(result), (3, 9))
        calls = self.tcl.splitlist(self.tcl.eval("set ::previewEmptyCalls"))
        self.assertEqual(len(calls), 1)
        self.assertEqual(self.tcl.splitlist(calls[0]), ("comps", "2"))


class BatchPropertyAssignmentIntegrationPolicyTests(unittest.TestCase):
    def test_module_is_visible_under_mesh(self):
        core = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        block = core.split("batch_property_assignment {", 1)[1].split("\n        }", 1)[0]
        self.assertIn('group    "Mesh"', block)
        self.assertIn('proc     "::BatchPropertyAssignment::runAction"', block)
        self.assertNotIn("hidden", block)

    def test_review_entries_are_empty_collectors_not_content_duplicates(self):
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::BatchPropertyAssignment::ensureReviewEntry", 1)[1].split(
            "\nproc ::BatchPropertyAssignment::", 1
        )[0]
        self.assertIn("::HWFlow::createComponent", body)
        self.assertIn("::HWFlow::addComponentsToAssembly", body)
        self.assertNotIn("*duplicatemark", body)
        self.assertNotIn("*duplicateentities", body)
        self.assertNotIn("*movemark", body)

    def test_pshell_creation_uses_hm2019_thickness_attribute(self):
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::BatchPropertyAssignment::ensureProperty", 1)[1].split(
            "\nproc ::BatchPropertyAssignment::", 1
        )[0]
        self.assertIn("cardimage=PSHELL", body)
        self.assertIn("*attributeupdatedouble properties $propertyId 95", body)
        self.assertIn("materialid", body)

    def test_empty_components_are_filtered_before_property_checks(self):
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::BatchPropertyAssignment::execute", 1)[1].split(
            "\nproc ::BatchPropertyAssignment::", 1
        )[0]
        self.assertIn("nativeEmptyComponentIds", body)
        self.assertLess(body.index("componentId in $emptyComponentIds"), body.index("componentHasAnyProperty"))


if __name__ == "__main__":
    unittest.main()
