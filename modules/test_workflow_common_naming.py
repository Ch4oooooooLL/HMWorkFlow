from __future__ import annotations

import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover - depends on the local Python build
    tkinter = None


ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "modules" / "workflow_common.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class WorkflowCommonNamingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source {{{MODULE.as_posix()}}}")

    def test_midsurface_name_is_canonical_and_replaces_thickness(self):
        result = self.tcl.call(
            "::HWFlow::formatMidsurfName",
            "V01_FRONT_FLOOR_LH_T2_Q235",
            "1.500",
        )
        self.assertEqual(result, "V01_FRONT_FLOOR_LH_T1.5_Q235")

    def test_material_is_optional_during_midsurface_extraction(self):
        result = self.tcl.call(
            "::HWFlow::formatMidsurfName",
            "V01_FRONT_FLOOR_LH",
            "2",
        )
        self.assertEqual(result, "V01_FRONT_FLOOR_LH_T2")
        with_material = self.tcl.call(
            "::HWFlow::formatMidsurfName",
            "V01_FRONT_FLOOR_LH_T2_Q235",
            "2",
        )
        self.assertEqual(with_material, "V01_FRONT_FLOOR_LH_T2_Q235")
        duplicate_part = self.tcl.call(
            "::HWFlow::formatMidsurfName",
            "V01_FRONT_FLOOR_LH.2",
            "2",
        )
        self.assertEqual(duplicate_part, "V01_FRONT_FLOOR_LH_T2")

    def test_duplicate_material_suffix_is_removed_when_material_is_carried_forward(self):
        result = self.tcl.call(
            "::HWFlow::formatMidsurfName",
            "V01_FRONT_FLOOR_LH_T2_Q235.1",
            "2",
        )
        self.assertEqual(result, "V01_FRONT_FLOOR_LH_T2_Q235")

    def test_material_is_only_required_by_downstream_property_parsing(self):
        optional = self.tcl.call(
            "::HWFlow::componentNameInfo",
            "V01_FRONT_FLOOR_LH_T2",
            "0",
        )
        self.assertEqual(self.tcl.call("dict", "get", optional, "material"), "")
        self.assertEqual(
            self.tcl.call("dict", "get", optional, "property_name"), ""
        )
        self.assertEqual(
            self.tcl.call(
                "::HWFlow::componentNameInfo", "V01_FRONT_FLOOR_LH_T2", "1"
            ),
            "",
        )

    def test_duplicate_suffixes_on_material_and_part_are_equivalent(self):
        base = "V01_FRONT_FLOOR_LH_T2_Q235"
        material_duplicate = "V01_FRONT_FLOOR_LH_T2_Q235.1"
        part_duplicate = "V01_FRONT_FLOOR_LH.2_T2_Q235"
        self.assertEqual(
            self.tcl.call("::HWFlow::componentNameMatchKey", base),
            self.tcl.call("::HWFlow::componentNameMatchKey", material_duplicate),
        )
        self.assertEqual(
            self.tcl.call("::HWFlow::componentNameMatchKey", base),
            self.tcl.call("::HWFlow::componentNameMatchKey", part_duplicate),
        )
        self.assertEqual(
            int(self.tcl.call("::HWFlow::componentNamesEquivalent", base, material_duplicate)),
            1,
        )

    def test_thickness_decimal_is_not_treated_as_duplicate_suffix(self):
        self.assertAlmostEqual(
            float(self.tcl.call("::HWFlow::thicknessFromComponentName", "V01_PANEL_T2.1_Q235")),
            2.1,
        )


if __name__ == "__main__":
    unittest.main()
