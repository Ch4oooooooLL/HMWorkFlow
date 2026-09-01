import tkinter
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "midsurf.tcl"


class TclHarness:
    def __init__(self):
        self.tcl = tkinter.Tcl()
        self.tcl.eval("namespace eval ::HWFlow {}")
        self.tcl.eval("proc ::HWFlow::txt {zh en} {return $en}")
        self.tcl.eval(
            "proc ::HWFlow::formatMidsurfName {source thickness} {"
            "regsub -nocase {^V[^_]*_} $source {} source; "
            "return \"Vxx_${source}_T${thickness}\"}"
        )
        self.tcl.eval(f"source -encoding utf-8 {{{MODULE.as_posix()}}}")

    def eval(self, script):
        return self.tcl.eval(script)


class MidsurfaceDisconnectedGeometryTests(unittest.TestCase):
    def setUp(self):
        self.h = TclHarness()

    def test_each_solid_is_an_independent_extraction_group(self):
        groups = self.h.eval("::MidSurf::inputGeometryGroups solids {17 23 41}")
        self.assertEqual(self.h.eval(f"llength {{{groups}}}"), "3")
        self.assertEqual(groups, "17 23 41")

    def test_component_input_prefers_solids_over_boundary_surfaces(self):
        body = self.h.eval("info body ::MidSurf::markInputGeometry")
        self.assertLess(
            body.index("getCompEntityIds $compId solids solids"),
            body.index("getCompEntityIds $compId surfaces surfs"),
        )

    def test_surface_geometry_is_split_into_connected_regions(self):
        self.h.eval(
            r"""
            set ::surfaceEdges [dict create \
                1 {{101 102}} 2 {{102 103}} 3 {{103 104}} \
                8 {{201 202}} 9 {{202 203}} 20 {{301 302}}]
            proc hm_getsurfaceedges {surfaceId} {
                return [dict get $::surfaceEdges $surfaceId]
            }
            """
        )
        groups = self.h.eval("::MidSurf::inputGeometryGroups surfaces {1 2 3 8 9 20}")
        self.assertEqual(self.h.eval(f"llength {{{groups}}}"), "3")
        self.assertEqual(self.h.eval(f"lindex {{{groups}}} 0"), "1 2 3")
        self.assertEqual(self.h.eval(f"lindex {{{groups}}} 1"), "8 9")
        self.assertEqual(self.h.eval(f"lindex {{{groups}}} 2"), "20")

    def test_surface_connectivity_cannot_bridge_through_unselected_geometry(self):
        self.h.eval(
            r"""
            # Surface 99 bridges 1 and 3 in the global model, but it is not a
            # target surface and therefore must not merge their groups.
            set ::surfaceEdges [dict create 1 {{10}} 3 {{30}} 99 {{10 30}}]
            proc hm_getsurfaceedges {surfaceId} {
                return [dict get $::surfaceEdges $surfaceId]
            }
            """
        )
        groups = self.h.eval("::MidSurf::inputGeometryGroups surfaces {1 3}")
        self.assertEqual(self.h.eval(f"llength {{{groups}}}"), "2")
        self.assertEqual(self.h.eval(f"lindex {{{groups}}} 0"), "1")
        self.assertEqual(self.h.eval(f"lindex {{{groups}}} 1"), "3")

    def test_process_component_extracts_every_group_and_aggregates_surfaces(self):
        body = self.h.eval("info body ::MidSurf::processComponent")
        self.assertIn("foreach group $groups", body)
        self.assertIn(
            "::MidSurf::moveGeometryToComponent $entityType $group $inputName",
            body,
        )
        self.assertIn("::MidSurf::markGeometryGroup $entityType $group", body)
        self.assertIn("set beforeSurfs [::MidSurf::allSurfaceIds]", body)
        self.assertIn(
            "set groupSurfs [::MidSurf::listDifference [::MidSurf::allSurfaceIds] $beforeSurfs]",
            body,
        )
        self.assertIn("::MidSurf::moveSurfacesToComponent $groupSurfs $resultName", body)
        self.assertIn("lappend results [list $outName [llength $groupSurfs] $thickness]", body)
        self.assertNotIn("existingOutputForSource", body)

    def test_result_detection_does_not_require_middle_surface_component(self):
        body = self.h.eval("info body ::MidSurf::processComponent")
        self.assertNotIn("extraction created no Middle Surface component", body)
        self.assertIn("native layout $extractLayout", body)

    def test_native_layout_return_value_identifies_compatibility_fallback(self):
        body = self.h.eval("info body ::MidSurf::extractMidsurface")
        self.assertIn("return 19", body)
        self.assertIn("return 17", body)

    def test_process_component_accepts_surfaces_created_in_current_component(self):
        self.h.eval(
            r"""
            set ::mockSurfaces {1 2 3}
            set ::extractCalls 0
            set ::movedSurfaces {}
            set ::hiddenSource 0
            proc ::MidSurf::getComponentName {id} {return PANEL}
            proc ::MidSurf::componentExistsByName {name} {return 0}
            proc ::MidSurf::componentIdByName {name} {return {}}
            proc ::MidSurf::markInputGeometry {id} {return {solids {101 102}}}
            proc ::MidSurf::createAccumulatorComponent {id} {return {TMP 900}}
            proc ::MidSurf::createTemporaryComponent {base} {return {INPUT 901}}
            proc ::MidSurf::moveGeometryToComponent {type ids name} {return [llength $ids]}
            proc ::MidSurf::markGeometryGroup {type ids} {return}
            proc ::MidSurf::allSurfaceIds {} {return $::mockSurfaces}
            proc ::MidSurf::extractMidsurface {type args} {
                incr ::extractCalls
                if {$::extractCalls == 1} {
                    set ::mockSurfaces [concat $::mockSurfaces {10 11}]
                } else {
                    set ::mockSurfaces [concat $::mockSurfaces {20 21 22}]
                }
                return 17
            }
            proc ::MidSurf::moveSurfacesToComponent {ids name} {
                set ::movedSurfaces [concat $::movedSurfaces $ids]
                return [llength $ids]
            }
            proc ::MidSurf::deleteComponentByName {name} {return 0}
            proc ::MidSurf::chooseThickness {id name midId} {return 2}
            proc ::MidSurf::renameMiddleSurface {source thickness midId current out} {return $out}
            proc ::MidSurf::organizeOutputComponent {name} {return 1}
            proc ::MidSurf::hideSourceComponent {name} {set ::hiddenSource 1}
            proc ::MidSurf::msg {text} {return}
            proc *currentcollector {args} {return}
            """
        )
        result = self.h.eval("::MidSurf::processComponent 7")
        self.assertEqual(result, "{V01_PANEL.1_T2 2 2} {V01_PANEL.2_T2 3 2}")
        self.assertEqual(self.h.eval("set ::extractCalls"), "2")
        self.assertEqual(self.h.eval("set ::movedSurfaces"), "10 11 20 21 22")
        self.assertEqual(self.h.eval("set ::hiddenSource"), "1")

    def test_output_versions_start_at_v01_and_advance_without_overwrite(self):
        self.h.eval(
            r"""
            set ::existingComponents {V01_PANEL_T2 V02_PANEL_T2}
            rename ::MidSurf::componentExistsByName ::MidSurf::componentExistsByName_real
            proc ::MidSurf::componentExistsByName {name} {
                expr {[lsearch -exact $::existingComponents $name] >= 0}
            }
            """
        )
        self.assertEqual(
            self.h.eval("::MidSurf::nextOutputNameForSource PANEL 2"),
            "V03_PANEL_T2",
        )
        self.h.eval("set ::existingComponents {}")
        self.assertEqual(
            self.h.eval("::MidSurf::nextOutputNameForSource PANEL 2"),
            "V01_PANEL_T2",
        )

    def test_source_placeholder_or_old_version_is_replaced(self):
        self.assertEqual(
            self.h.eval("::MidSurf::outputNameForSource Vxx_PANEL 1.5 1"),
            "V01_PANEL_T1.5",
        )
        self.assertEqual(
            self.h.eval("::MidSurf::outputNameForSource V17_PANEL 1.5 2"),
            "V02_PANEL_T1.5",
        )
        self.assertEqual(
            self.h.eval(
                "::MidSurf::outputNameForSource "
                "V01_A452801072_TT_Q355-Geometry 2 1"
            ),
            "V01_A452801072_T2",
        )

    def test_disconnected_regions_get_dot_number_before_thickness(self):
        self.assertEqual(
            self.h.eval("::MidSurf::outputNameForRegion PANEL 2 1 3 1"),
            "V01_PANEL.1_T2",
        )
        self.assertEqual(
            self.h.eval("::MidSurf::outputNameForRegion PANEL 2 3 3 2"),
            "V02_PANEL.3_T2",
        )
        self.assertEqual(
            self.h.eval("::MidSurf::outputNameForRegion PANEL 2 1 1 1"),
            "V01_PANEL_T2",
        )

    def test_partial_failure_keeps_source_visible(self):
        body = self.h.eval("info body ::MidSurf::processComponent")
        hide_branch = body.index("if {[llength $groupFailures] == 0}")
        warning = body.index("the source component remains visible")
        self.assertLess(hide_branch, warning)


if __name__ == "__main__":
    unittest.main()
