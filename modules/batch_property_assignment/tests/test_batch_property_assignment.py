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
        # The module routes UI and command-stream text through the shared
        # runtime; provide the English stubs when the toolkit core is not
        # sourced by this isolated Tcl test.
        self.tcl.eval(
            "namespace eval ::HWFlow {}; "
            "proc ::HWFlow::txt {zh en} {return $en}; "
            "proc ::HWFlow::ctxt {zh en} {return $en}"
        )

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

    def test_ignores_hypermesh_duplicate_suffix_on_material(self):
        name = "V2_BRACKET_T1.500_Al6061.2"
        self.assertEqual(self.field(name, "material"), "Al6061")
        self.assertEqual(self.field(name, "property_name"), "Al6061_T1.5")

    def test_ignores_hypermesh_duplicate_suffix_on_part_name(self):
        name = "V2_BRACKET.1_T1.500_Al6061"
        self.assertEqual(self.field(name, "part_number"), "BRACKET")
        self.assertEqual(self.field(name, "property_name"), "Al6061_T1.5")

    def test_part_ignores_characters_after_thickness_and_uses_last_material_token(self):
        name = "V01_xxxx_T10aaa_355"
        self.assertEqual(self.field(name, "kind"), "PART")
        self.assertEqual(self.field(name, "thickness_token"), "10")
        self.assertEqual(self.field(name, "material"), "355")
        self.assertEqual(self.field(name, "property_name"), "355_T10")

    def test_material_lookup_matches_reimported_material_name(self):
        self.tcl.eval(
            r"""
            proc *clearmark {entityType markId} {}
            proc *createmark {entityType markId selector} {}
            proc hm_getmark {entityType markId} {return {7}}
            proc hm_getvalue {entityType selector args} {
                if {$selector eq "id=7"} {return Q235.1}
                error "name lookup is intentionally unavailable"
            }
            """
        )
        self.assertEqual(
            int(self.tcl.call("::BatchPropertyAssignment::materialIdByName", "Q235")),
            7,
        )

    def test_missing_steel_material_is_created_with_default_mat1_values(self):
        self.tcl.eval(
            r"""
            rename ::BatchPropertyAssignment::materialIdByName ::BatchPropertyAssignment::materialIdByName_real
            set ::steelId ""
            proc ::BatchPropertyAssignment::materialIdByName {name} {return $::steelId}
            proc *createentity {args} {set ::steelId 17}
            set ::materialValues {}
            proc *setvalue {args} {lappend ::materialValues $args}
            """
        )
        self.assertEqual(
            int(self.tcl.call("::BatchPropertyAssignment::ensureSteelMaterial")),
            17,
        )
        values = self.tcl.eval("set ::materialValues")
        self.assertIn("E=210000.0", values)
        self.assertIn("Nu=0.30", values)
        self.assertIn("Rho=7.85e-9", values)

    def test_missing_named_material_is_created_empty(self):
        self.tcl.eval(
            r"""
            rename ::BatchPropertyAssignment::materialIdByName ::BatchPropertyAssignment::materialIdByName_real
            set ::newMaterialId ""
            set ::emptyMaterialCreateArgs {}
            proc ::BatchPropertyAssignment::materialIdByName {name} {return $::newMaterialId}
            proc *createentity {args} {
                lappend ::emptyMaterialCreateArgs $args
                set ::newMaterialId 23
            }
            """
        )
        self.assertEqual(
            int(self.tcl.call("::BatchPropertyAssignment::ensureEmptyMaterial", "Q690")),
            23,
        )
        create_args = self.tcl.eval("set ::emptyMaterialCreateArgs")
        self.assertIn("cardimage=MAT1", create_args)
        self.assertIn("name=Q690", create_args)
        self.assertNotIn("E=", create_args)
        self.assertNotIn("Nu=", create_args)
        self.assertNotIn("Rho=", create_args)

    def test_seam_solid_property_is_created_as_psolid_without_thickness(self):
        self.tcl.eval(
            r"""
            rename ::BatchPropertyAssignment::entityIdByName ::BatchPropertyAssignment::entityIdByName_real
            rename ::BatchPropertyAssignment::trySetValue ::BatchPropertyAssignment::trySetValue_real
            rename ::BatchPropertyAssignment::propertyMaterialMatches ::BatchPropertyAssignment::propertyMaterialMatches_real
            set ::newPropertyId ""
            set ::solidPropertyCreateArgs {}
            proc ::BatchPropertyAssignment::entityIdByName {types name} {return $::newPropertyId}
            proc ::BatchPropertyAssignment::trySetValue {types selector field value} {return 1}
            proc ::BatchPropertyAssignment::propertyMaterialMatches {propertyId materialId} {return 1}
            proc *createentity {args} {
                lappend ::solidPropertyCreateArgs $args
                set ::newPropertyId 31
            }
            proc *setvalue {args} {}
            proc hm_getthickness {args} {error "PSOLID must not query shell thickness"}
            """
        )
        self.assertEqual(
            int(
                self.tcl.call(
                    "::BatchPropertyAssignment::ensureProperty",
                    "SEAM_SOLID",
                    "",
                    17,
                    "PSOLID",
                )
            ),
            31,
        )
        create_args = self.tcl.eval("set ::solidPropertyCreateArgs")
        self.assertIn("cardimage=PSOLID", create_args)
        self.assertIn("name=SEAM_SOLID", create_args)

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

    def test_seam_solid_uses_steel_and_psolid(self):
        name = "SEAM_SOLID"
        self.assertEqual(self.field(name, "kind"), "SEAM_SOLID")
        self.assertEqual(self.field(name, "material"), "Steel")
        self.assertEqual(self.field(name, "property_name"), "SEAM_SOLID")
        self.assertEqual(self.field(name, "card_image"), "PSOLID")

    def test_tt_thickness_marker_is_ignored(self):
        for name in ("V01_FLOOR_TT_Q355", "part_TT", "PART_tt.surf"):
            with self.subTest(name=name):
                self.assertEqual(
                    int(self.tcl.call("::BatchPropertyAssignment::isIgnoredThicknessName", name)),
                    1,
                )
        self.assertEqual(
            int(self.tcl.call("::BatchPropertyAssignment::isIgnoredThicknessName", "V01_TTOWER_T2_Q355")),
            0,
        )

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
rename ::BatchPropertyAssignment::ensureEmptyMaterial ::BatchPropertyAssignment::ensureEmptyMaterial_real
rename ::BatchPropertyAssignment::componentHasAnyProperty ::BatchPropertyAssignment::componentHasAnyProperty_real
rename ::BatchPropertyAssignment::isIgnoredOneDimensionalName ::BatchPropertyAssignment::isIgnoredOneDimensionalName_real
rename ::BatchPropertyAssignment::ensureProperty ::BatchPropertyAssignment::ensureProperty_real
rename ::BatchPropertyAssignment::assignProperty ::BatchPropertyAssignment::assignProperty_real
rename ::BatchPropertyAssignment::ensureReviewEntry ::BatchPropertyAssignment::ensureReviewEntry_real
proc ::BatchPropertyAssignment::allComponentIds {} {return {1 2 3 4 5 6 7 8 9}}
proc ::BatchPropertyAssignment::nativeEmptyComponentIds {} {return {6}}
proc ::BatchPropertyAssignment::componentName {id} {
    return [dict get {1 V01_FLOOR_T10_Q355 2 SEAM_T20 3 BAD_NAME 4 V01_DONE_T3_Q355 5 auto_RBE2_output 6 BAD_EMPTY_NAME 7 V01_UNKNOWN_TT_Q355 8 SEAM_SOLID 9 V01_BRACKET_T2_NEWSTEEL} $id]
}
proc ::BatchPropertyAssignment::materialIdByName {name} {
    if {[dict exists {Q355 101 Steel 102} $name]} {
        return [dict get {Q355 101 Steel 102} $name]
    }
    return {}
}
set ::emptyMaterialCalls {}
proc ::BatchPropertyAssignment::ensureEmptyMaterial {name} {
    lappend ::emptyMaterialCalls $name
    return 103
}
proc ::BatchPropertyAssignment::componentHasAnyProperty {componentId} {
    return [expr {$componentId == 4}]
}
proc ::BatchPropertyAssignment::isIgnoredOneDimensionalName {name} {
    return [expr {[string first RBE [string toupper $name]] >= 0}]
}
set ::propertyCalls {}
proc ::BatchPropertyAssignment::ensureProperty {name thickness materialId {cardImage PSHELL}} {
    lappend ::propertyCalls [list $name $thickness $materialId $cardImage]
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
        self.assertEqual(self.tcl.call("dict", "get", result, "scanned"), 9)
        self.assertEqual(self.tcl.call("dict", "get", result, "assigned"), 4)
        self.assertEqual(self.tcl.call("dict", "get", result, "skipped_empty"), 1)
        self.assertEqual(
            self.tcl.splitlist(self.tcl.call("dict", "get", result, "skipped_empty_names")),
            ("BAD_EMPTY_NAME",),
        )
        self.assertEqual(self.tcl.call("dict", "get", result, "skipped_existing"), 1)
        self.assertEqual(self.tcl.call("dict", "get", result, "skipped_1d"), 1)
        self.assertEqual(self.tcl.call("dict", "get", result, "skipped_tt"), 1)
        self.assertEqual(
            self.tcl.splitlist(self.tcl.call("dict", "get", result, "property_names")),
            ("Q355_T10", "SEAM_T20", "SEAM_SOLID", "NEWSTEEL_T2"),
        )
        self.assertEqual(self.tcl.splitlist(self.tcl.eval("set ::reviewCalls")), ("BAD_NAME",))
        self.assertEqual(
            self.tcl.splitlist(self.tcl.call("dict", "get", result, "created_material_names")),
            ("NEWSTEEL",),
        )
        property_calls = self.tcl.splitlist(self.tcl.eval("set ::propertyCalls"))
        self.assertEqual(self.tcl.splitlist(property_calls[0]), ("Q355_T10", "10.0", "101", "PSHELL"))
        self.assertEqual(self.tcl.splitlist(property_calls[1]), ("SEAM_T20", "20.0", "102", "PSHELL"))
        self.assertEqual(self.tcl.splitlist(property_calls[2]), ("SEAM_SOLID", "", "102", "PSOLID"))
        self.assertEqual(self.tcl.splitlist(property_calls[3]), ("NEWSTEEL_T2", "2.0", "103", "PSHELL"))

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
        self.assertIn("{cardImage PSHELL}", body)
        self.assertIn("cardimage=$cardImage", body)
        self.assertIn("*attributeupdatedouble properties $propertyId 95", body)
        self.assertIn("materialid", body)
        self.assertIn('if {$cardImage eq "PSOLID"}', body)

    def test_empty_components_are_filtered_before_property_checks(self):
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::BatchPropertyAssignment::execute", 1)[1].split(
            "\nproc ::BatchPropertyAssignment::", 1
        )[0]
        self.assertIn("nativeEmptyComponentIds", body)
        self.assertLess(body.index("componentId in $emptyComponentIds"), body.index("componentHasAnyProperty"))


if __name__ == "__main__":
    unittest.main()
