from __future__ import annotations

import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover - depends on the local Python build
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "bom_material_assignment.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class BomMaterialAssignmentTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source {{{MODULE.as_posix()}}}")

    def test_normalizes_midsurface_name_to_q355(self):
        cases = {
            "V01_FRONT_FLOOR_LH_T2": "V01_FRONT_FLOOR_LH_T2_Q355",
            "V01_FRONT_FLOOR_LH_T2_Q235": "V01_FRONT_FLOOR_LH_T2_Q355",
            "V01_FRONT_FLOOR_LH_T1.500_Q235.1": "V01_FRONT_FLOOR_LH_T1.5_Q355",
            "SEAM_T10": "SEAM_T10_Q355",
            "PLAIN_COMPONENT": "PLAIN_COMPONENT_Q355",
        }
        for old_name, expected in cases.items():
            with self.subTest(old_name=old_name):
                self.assertEqual(
                    self.tcl.call(
                        "::BomMaterialAssignment::componentNameWithMaterial",
                        old_name,
                        "Q355",
                    ),
                    expected,
                )

    def test_assembly_component_lookup_uses_assembly_id(self):
        self.tcl.eval(
            r"""
            rename ::BomMaterialAssignment::assemblyIdByName ::BomMaterialAssignment::assemblyIdByName_real
            proc ::BomMaterialAssignment::assemblyIdByName {name} {return 42}
            proc *clearmark {args} {}
            proc *createmark {args} {set ::lastCreateMark $args}
            proc hm_getmark {entityType markId} {return {7 3 7}}
            """
        )
        result = self.tcl.call(
            "::BomMaterialAssignment::assemblyComponentIds", "MIDSURFED"
        )
        self.assertEqual(self.tcl.splitlist(result), (3, 7))
        mark = self.tcl.splitlist(self.tcl.eval("set ::lastCreateMark"))
        self.assertEqual(mark[:4], ("comps", "1", "by assem id", "42"))

    def test_creates_q355_mat1_with_default_values(self):
        self.tcl.eval(
            r"""
            rename ::BomMaterialAssignment::materialIdByName ::BomMaterialAssignment::materialIdByName_real
            set ::q355Id ""
            proc ::BomMaterialAssignment::materialIdByName {name} {return $::q355Id}
            proc *createentity {args} {set ::q355Id 17}
            set ::materialValues {}
            proc *setvalue {args} {lappend ::materialValues $args}
            """
        )
        self.assertEqual(
            int(self.tcl.call("::BomMaterialAssignment::ensureQ355Material")),
            17,
        )
        values = self.tcl.eval("set ::materialValues")
        self.assertIn("E=206000.0", values)
        self.assertIn("Nu=0.30", values)
        self.assertIn("Rho=7.85e-9", values)

    def test_execute_applies_default_material_to_every_assembly_component(self):
        self.tcl.eval(
            r"""
            rename ::BomMaterialAssignment::assemblyComponentIds ::BomMaterialAssignment::assemblyComponentIds_real
            rename ::BomMaterialAssignment::ensureQ355Material ::BomMaterialAssignment::ensureQ355Material_real
            rename ::BomMaterialAssignment::componentName ::BomMaterialAssignment::componentName_real
            rename ::BomMaterialAssignment::renameComponent ::BomMaterialAssignment::renameComponent_real
            rename ::BomMaterialAssignment::assignMaterial ::BomMaterialAssignment::assignMaterial_real
            set ::BomMaterialAssignment::ONLY_MIDSURFED_ASSEMBLY 1
            set ::BomMaterialAssignment::SETTINGS_LOADED 1
            proc ::BomMaterialAssignment::assemblyComponentIds {name} {return {1 2}}
            proc ::BomMaterialAssignment::ensureQ355Material {} {return 99}
            proc ::BomMaterialAssignment::componentName {id} {
                return [dict get {1 V01_A_T2 2 V01_B_T3_Q235} $id]
            }
            set ::renamedCalls {}
            proc ::BomMaterialAssignment::renameComponent {oldName newName} {
                lappend ::renamedCalls [list $oldName $newName]
                return $newName
            }
            set ::materialCalls {}
            proc ::BomMaterialAssignment::assignMaterial {componentId materialId} {
                lappend ::materialCalls [list $componentId $materialId]
                return 1
            }
            """
        )
        result = self.tcl.call("::BomMaterialAssignment::execute")
        self.assertEqual(self.tcl.call("dict", "get", result, "scanned"), 2)
        self.assertEqual(self.tcl.call("dict", "get", result, "renamed"), 2)
        self.assertEqual(self.tcl.call("dict", "get", result, "material_assigned"), 2)
        self.assertEqual(self.tcl.splitlist(self.tcl.call("dict", "get", result, "failures")), ())
        renamed = self.tcl.splitlist(self.tcl.eval("set ::renamedCalls"))
        self.assertEqual(self.tcl.splitlist(renamed[0]), ("V01_A_T2", "V01_A_T2_Q355"))
        self.assertEqual(self.tcl.splitlist(renamed[1]), ("V01_B_T3_Q235", "V01_B_T3_Q355"))
        material_calls = self.tcl.splitlist(self.tcl.eval("set ::materialCalls"))
        self.assertEqual(self.tcl.splitlist(material_calls[0]), ("1", "99"))
        self.assertEqual(self.tcl.splitlist(material_calls[1]), ("2", "99"))

    def test_scope_can_include_all_model_components(self):
        self.tcl.eval(
            r"""
            set ::BomMaterialAssignment::ONLY_MIDSURFED_ASSEMBLY 0
            set ::BomMaterialAssignment::SETTINGS_LOADED 1
            rename ::BomMaterialAssignment::allEntityIds ::BomMaterialAssignment::allEntityIds_real
            proc ::BomMaterialAssignment::allEntityIds {types} {
                set ::allEntityTypes $types
                return {9 4 9}
            }
            """
        )
        result = self.tcl.call("::BomMaterialAssignment::targetComponentIds")
        self.assertEqual(self.tcl.splitlist(result), ("9", "4", "9"))
        self.assertEqual(
            self.tcl.splitlist(self.tcl.eval("set ::allEntityTypes")),
            ("comps", "components"),
        )

    def test_setting_load_and_save_are_persistent(self):
        self.tcl.eval(
            r"""
            rename ::HWFlow::loadState ::HWFlow::loadState_real
            rename ::HWFlow::saveState ::HWFlow::saveState_real
            proc ::HWFlow::loadState {moduleKey} {
                set ::loadedModule $moduleKey
                return {only_midsurfed_assembly 0}
            }
            proc ::HWFlow::saveState {moduleKey state} {
                set ::savedModule $moduleKey
                set ::savedState $state
            }
            """
        )
        self.assertEqual(
            int(self.tcl.call("::BomMaterialAssignment::loadSettings", 1)), 0
        )
        self.assertEqual(self.tcl.eval("set ::loadedModule"), "bom_material_assignment")
        self.tcl.eval("set ::BomMaterialAssignment::ONLY_MIDSURFED_ASSEMBLY 1")
        self.tcl.call("::BomMaterialAssignment::saveSettings")
        self.assertEqual(self.tcl.eval("set ::savedModule"), "bom_material_assignment")
        saved = self.tcl.eval("set ::savedState")
        self.assertEqual(self.tcl.call("dict", "get", saved, "only_midsurfed_assembly"), "1")


class BomMaterialAssignmentIntegrationTests(unittest.TestCase):
    def test_module_is_registered_and_visible(self):
        core = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        block = core.split("bom_material_assignment {", 1)[1].split(
            "\n        }", 1
        )[0]
        self.assertIn('group    "Geometry"', block)
        self.assertIn('proc     "::BomMaterialAssignment::runAction"', block)
        self.assertIn('settings_proc "::BomMaterialAssignment::runSettings"', block)
        self.assertNotIn("hidden", block)

    def test_bom_reader_is_explicitly_reserved_for_follow_up(self):
        source = MODULE.read_text(encoding="utf-8")
        self.assertIn("proc ::BomMaterialAssignment::readBom", source)
        self.assertIn("BOM reading is not implemented yet", source)
        self.assertIn("defaultBomAssignments", source)


if __name__ == "__main__":
    unittest.main()
