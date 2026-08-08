from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover - depends on the host Python build
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "adhesive_connector.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class AdhesiveConnectorTclTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source {{{MODULE.as_posix()}}}")
        self.tcl.eval("set ::HWFlow::LANGUAGE en_US; set ::HWFlow::LANGUAGE_LOADED 1")

    def install_mesh(self) -> None:
        self.tcl.eval(
            r"""
rename ::AdhesiveConnector::elementNodes ::AdhesiveConnector::elementNodes_real
rename ::AdhesiveConnector::nodeXYZ ::AdhesiveConnector::nodeXYZ_real
rename ::AdhesiveConnector::elementComponentId ::AdhesiveConnector::elementComponentId_real
rename ::AdhesiveConnector::componentElements ::AdhesiveConnector::componentElements_real
proc ::AdhesiveConnector::elementNodes {eid} {return $::mesh_nodes($eid)}
proc ::AdhesiveConnector::nodeXYZ {nid} {return $::mesh_xyz($nid)}
proc ::AdhesiveConnector::elementComponentId {eid} {return $::mesh_comp($eid)}
proc ::AdhesiveConnector::componentElements {cid} {return $::comp_elems($cid)}
array set ::mesh_nodes {
    10 {1 2 3 4}
    11 {5 6 7 8}
    20 {21 22 23 24}
}
array set ::mesh_xyz {
    1 {0 0 0} 2 {1 0 0} 3 {1 1 0} 4 {0 1 0}
    5 {1.5 0 0} 6 {2.5 0 0} 7 {2.5 1 0} 8 {1.5 1 0}
    21 {0 0 5} 22 {2 0 5} 23 {2 2 5} 24 {0 2 5}
}
array set ::mesh_comp {10 100 11 100 20 200}
array set ::comp_elems {100 {10 11} 200 {20}}
"""
        )

    def test_defaults_match_area_adhesive_workflow(self) -> None:
        self.assertEqual(self.tcl.eval("set ::AdhesiveConnector::cfg(tolerance)"), "50.0")
        self.assertEqual(self.tcl.eval("set ::AdhesiveConnector::cfg(coats)"), "1")
        self.assertEqual(self.tcl.eval("set ::AdhesiveConnector::cfg(thickness_type)"), "CONST_THICKNESS")
        self.assertEqual(self.tcl.eval("set ::AdhesiveConnector::cfg(const_thickness)"), "1.0")

    def test_picker_uses_elems_for_location_and_comps_for_links(self) -> None:
        self.tcl.eval(
            r"""
rename ::HWFlow::nativeMarkPanelSequence ::HWFlow::nativeMarkPanelSequence_real
proc ::HWFlow::nativeMarkPanelSequence {requests} {set ::picker_requests $requests; return {{10 11} {100 200}}}
"""
        )
        self.assertEqual(self.tcl.eval("::AdhesiveConnector::pickInputs"), "1")
        self.assertEqual(self.tcl.eval("set ::AdhesiveConnector::ui(selectedElems)"), "10 11")
        self.assertEqual(self.tcl.eval("set ::AdhesiveConnector::ui(selectedComps)"), "100 200")
        requests = self.tcl.eval("set ::picker_requests")
        self.assertIn("elems 1", requests)
        self.assertIn("comps 2", requests)

    def test_cleaner_keeps_only_elems_fully_projecting_inside_target(self) -> None:
        self.install_mesh()
        result = self.tcl.eval("::AdhesiveConnector::cleanLocationElems {10 11} {100 200} 50")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} kept"), "10")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} rejected"), "11")

    def test_cleaner_rejects_elem_when_target_is_beyond_tolerance(self) -> None:
        self.install_mesh()
        result = self.tcl.eval("::AdhesiveConnector::cleanLocationElems {10} {100 200} 4.9")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} kept"), "")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} rejected"), "10")

    def test_cleaner_does_not_build_projection_mesh_for_single_source_component(self) -> None:
        self.install_mesh()
        self.tcl.eval(
            r"""
rename ::AdhesiveConnector::componentElements ::AdhesiveConnector::componentElements_mock
proc ::AdhesiveConnector::componentElements {cid} {
    set ::component_requested($cid) 1
    return $::comp_elems($cid)
}
"""
        )
        self.tcl.eval("::AdhesiveConnector::cleanLocationElems {10 11} {100 200} 50")
        self.assertEqual(self.tcl.eval("info exists ::component_requested(100)"), "0")
        self.assertEqual(self.tcl.eval("info exists ::component_requested(200)"), "1")

    def test_cleaner_checks_edge_midpoints_not_only_vertices(self) -> None:
        self.install_mesh()
        self.tcl.eval(
            r"""
set ::mesh_xyz(21) {0 0 5}; set ::mesh_xyz(22) {0.4 0 5}
set ::mesh_xyz(23) {0.4 2 5}; set ::mesh_xyz(24) {0 2 5}
set ::mesh_xyz(1) {0 0 0}; set ::mesh_xyz(2) {1 0 0}
set ::mesh_xyz(3) {1 1 0}; set ::mesh_xyz(4) {0 1 0}
"""
        )
        result = self.tcl.eval("::AdhesiveConnector::cleanLocationElems {10} {100 200} 50")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} kept"), "")

    def test_spatial_index_limits_projection_checks_to_nearby_target_elems(self) -> None:
        result = self.tcl.eval(
            r"""
set polygons {}
for {set i 0} {$i < 500} {incr i} {
    set x [expr {$i*20.0}]
    set points [list [list $x 0 5] [list [expr {$x+2}] 0 5] [list [expr {$x+2}] 2 5] [list $x 2 5]]
    lappend polygons [dict create elem $i points $points normal {0 0 1}]
}
set grid [::AdhesiveConnector::buildPolygonGrid $polygons 6.0]
rename ::AdhesiveConnector::projectionHitsPolygon ::AdhesiveConnector::projectionHitsPolygon_real
proc ::AdhesiveConnector::projectionHitsPolygon {point direction polygon tolerance} {
    incr ::projection_checks
    return [::AdhesiveConnector::projectionHitsPolygon_real $point $direction $polygon $tolerance]
}
set ::projection_checks 0
set accepted [::AdhesiveConnector::pointsProjectInside {{0.5 0.5 0}} {0 0 1} $polygons $grid 6.0]
list $accepted $::projection_checks [dict size $grid]
"""
        )
        accepted, checks, grid_cells = map(int, self.tcl.splitlist(result))
        self.assertEqual(accepted, 1)
        self.assertLess(checks, 20)
        self.assertGreater(grid_cells, 1)

    def test_source_uses_bulk_config_cache_for_target_components(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        prime = source.split("proc ::AdhesiveConnector::primeGeometryCache", 1)[1].split(
            "proc ::AdhesiveConnector::vsub", 1
        )[0]
        self.assertIn("dataname=config", prime)
        self.assertIn("geometryElemConfig", prime)

    def test_cleaner_never_depends_on_hm_findprojected(self) -> None:
        # hm_findprojected (the Find Projected panel command) rejects every
        # call outside its panel context on 2019.0.0.70 / 2022.0.0.33, so the
        # cleaner must never call it; the geometry fallback decides instead.
        self.install_mesh()
        self.tcl.eval(
            r"""
proc hm_findprojected args {error "hm_findprojected must not be called"}
"""
        )
        result = self.tcl.eval("::AdhesiveConnector::cleanLocationElems {10 11} {100 200} 50")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} kept"), "10")
        self.assertEqual(self.tcl.eval(f"dict get {{{result}}} rejected"), "11")

    def test_production_cleaner_uses_geometry_fallback_without_hm_findprojected(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::AdhesiveConnector::cleanLocationElems {", 1)[1].split(
            "proc ::AdhesiveConnector::adhesivesFeType", 1
        )[0]
        self.assertIn("cleanLocationElemsFallback", body)
        self.assertNotIn("hm_findprojected elems", body)
        self.assertNotIn("nativeProjectionClean", body)
        self.assertIn("primeGeometryCache", body)

    def test_feconfig_type_is_resolved_by_solver_and_exact_name(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "feconfig.cfg"
            config.write_text(
                "CFG optistruct 10 adhesive-hemmings filter=area\n"
                "CFG optistruct 77 adhesives filter=area\n",
                encoding="utf-8",
            )
            result = self.tcl.call("::AdhesiveConnector::adhesivesFeType", config.as_posix())
            self.assertEqual(result, "77")

    def test_realization_options_request_no_script_coats_and_constant_thickness(self) -> None:
        options = self.tcl.splitlist(
            self.tcl.call("::AdhesiveConnector::realizationOptions", 50, 3, 1.25, "C:/hm/feconfig.cfg")
        )
        self.assertIn("ce_propertyscript=", options)
        self.assertIn("ce_areastacksize=3", options)
        self.assertIn("ce_areathicknesstype=3", options)
        self.assertIn("ce_areaconstthickness=1.250000", options)
        self.assertIn("tol=50.000000", options)

    def test_create_command_uses_cleaned_elems_as_area_location(self) -> None:
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::AdhesiveConnector::createAdhesive {}", 1)[1].split(
            "proc ::AdhesiveConnector::runAction", 1
        )[0]
        self.assertIn("cleanLocationElems", body)
        self.assertIn("*createmark elems 1", body)
        self.assertIn("*createmark comps 2", body)
        self.assertIn("*CE_ConnectorCreateByMarkAndRealizeWithDetails elems 1 area", body)

    def test_create_path_submits_only_cleaned_elems_and_verifies_realization(self) -> None:
        self.tcl.eval(
            r"""
set ::AdhesiveConnector::ui(selectedElems) {10 11}
set ::AdhesiveConnector::ui(selectedComps) {100 200}
set ::AdhesiveConnector::ui(tolerance) 50.0
set ::AdhesiveConnector::ui(coats) 1
set ::AdhesiveConnector::ui(thickness_type) CONST_THICKNESS
set ::AdhesiveConnector::ui(const_thickness) 1.0
rename ::AdhesiveConnector::primeGeometryCache ::AdhesiveConnector::primeGeometryCache_real
rename ::AdhesiveConnector::cleanLocationElems ::AdhesiveConnector::cleanLocationElems_real
rename ::AdhesiveConnector::adhesivesFeType ::AdhesiveConnector::adhesivesFeType_real
rename ::AdhesiveConnector::snapshotConnectors ::AdhesiveConnector::snapshotConnectors_real
rename ::AdhesiveConnector::saveState ::AdhesiveConnector::saveState_real
proc ::AdhesiveConnector::primeGeometryCache args {}
proc ::AdhesiveConnector::cleanLocationElems args {return [dict create kept {10} rejected {11}]}
proc ::AdhesiveConnector::adhesivesFeType {path} {return 77}
proc ::AdhesiveConnector::snapshotConnectors {} {incr ::snapshots; if {$::snapshots == 1} {return {5}}; return {5 6}}
proc ::AdhesiveConnector::saveState {} {}
proc hm_info args {return C:/hm}
proc hm_ce_state {connectorId} {return REALIZED}
proc *createmark {entity mark args} {lappend ::marks [list $entity $mark {*}$args]}
proc *createstringarray args {set ::string_array $args}
proc *CE_ConnectorCreateByMarkAndRealizeWithDetails args {set ::connector_command $args}
proc tk_messageBox args {set ::last_dialog $args}
set ::snapshots 0
set ::marks {}
"""
        )
        self.assertEqual(self.tcl.eval("::AdhesiveConnector::createAdhesive"), "1")
        self.assertIn("elems 1 10", self.tcl.eval("set ::marks"))
        self.assertIn("comps 2 100 200", self.tcl.eval("set ::marks"))
        command = self.tcl.splitlist(self.tcl.eval("set ::connector_command"))
        self.assertEqual(command[:9], ("elems", "1", "area", "2", "comps", "2", "optistruct", "1001", "77"))
        self.assertEqual(command[9], "50.0")

    def test_module_is_registered_in_main_connector_panel(self) -> None:
        core = (ROOT / "hw_toolkit_core.tcl").read_text(encoding="utf-8")
        self.assertIn("adhesive_connector {", core)
        self.assertIn('proc     "::AdhesiveConnector::runAction"', core)


if __name__ == "__main__":
    unittest.main()
