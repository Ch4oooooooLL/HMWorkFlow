import gc
import time
import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "contact_setup.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class ContactSetupTclTests(unittest.TestCase):
    def interp(self):
        # Python 3.14 on Windows can intermittently report "No error" while
        # opening init.tcl or a sourced Tcl file.  Keep every test isolated,
        # but retry that host-runtime condition without masking Tcl failures.
        for attempt in range(3):
            try:
                interp = tkinter.Tcl()
                interp.eval("source {{{}}}".format(MODULE.as_posix()))
                return interp
            except tkinter.TclError as exc:
                message = str(exc)
                transient = "No error" in message and (
                    "couldn't read" in message or "Can't find a usable init.tcl" in message
                )
                if not transient or attempt == 2:
                    raise
                gc.collect()
                time.sleep(0.02)

    def test_second_face_panel_is_deferred_to_a_new_event_callback(self):
        interp = self.interp()
        interp.eval("rename ::HWFlow::nativePanelSessionBegin ::HWFlow::nativePanelSessionBegin_real")
        interp.eval("rename ::HWFlow::nativeMarkPanelInSession ::HWFlow::nativeMarkPanelInSession_real")
        interp.eval("rename ::HWFlow::nativePanelSessionEnd ::HWFlow::nativePanelSessionEnd_real")
        interp.eval(
            "proc ::HWFlow::nativePanelSessionBegin {} {return {}};"
            "proc ::HWFlow::nativePanelSessionEnd {windows} {set ::session_ended 1};"
            "proc ::HWFlow::nativeMarkPanelInSession {entity mark prompt args} {"
            "lappend ::picker_marks $mark; if {$mark == 1} {return {11 12 13}}; return {21 22}}"
        )

        self.assertEqual(interp.eval("::ContactSetup::pickContactFaces"), "1")
        self.assertEqual(interp.eval("set ::picker_marks"), "1")
        interp.eval("after 150 {set ::wait_done 1}; vwait ::wait_done")
        self.assertEqual(interp.eval("set ::picker_marks"), "1 2")
        self.assertEqual(interp.eval("set ::session_ended"), "1")

    def test_common_native_picker_forwards_optional_face_arguments(self):
        interp = self.interp()
        interp.eval(
            "proc *createmarkpanel {entity mark prompt args} {"
            "set ::native_call [list $entity $mark {*}$args]};"
            "proc hm_getmark {entity mark} {return {31 32}}"
        )

        self.assertEqual(
            interp.eval("::HWFlow::nativeMarkPanel elems 2 choose 1 6"), "31 32"
        )
        self.assertEqual(interp.eval("set ::native_call"), "elems 2 1 6")

    def test_native_sequence_restores_tool_window_only_after_both_panels(self):
        interp = self.interp()
        interp.eval(
            "rename ::HWFlow::managedWindows ::HWFlow::managedWindows_real;"
            "proc ::HWFlow::managedWindows {} {return {.contact_setup}};"
            "proc winfo {action window} {return 1};"
            "proc wm {action window} {lappend ::events $action};"
            "proc raise {window} {lappend ::events raise};"
            "proc grab args {return {}}; proc update args {};"
            "proc *clearmark args {};"
            "proc *createmarkpanel {entity mark prompt args} {lappend ::events panel$mark};"
            "proc hm_getmark {entity mark} {return [list [expr {$mark * 10}]]}"
        )
        result = interp.eval(
            "::HWFlow::nativeMarkPanelSequence {{elems 1 A 1 6} {elems 2 B 1 6}}"
        )
        self.assertEqual(result, "10 20")
        self.assertEqual(
            interp.eval("set ::events"),
            "withdraw panel1 panel2 deiconify raise",
        )

    def test_two_face_picks_are_kept_on_separate_marks(self):
        interp = self.interp()
        interp.eval("rename ::HWFlow::nativePanelSessionBegin ::HWFlow::nativePanelSessionBegin_real")
        interp.eval("rename ::HWFlow::nativeMarkPanelInSession ::HWFlow::nativeMarkPanelInSession_real")
        interp.eval("rename ::HWFlow::nativePanelSessionEnd ::HWFlow::nativePanelSessionEnd_real")
        interp.eval(
            "proc ::HWFlow::nativePanelSessionBegin {} {return {}};"
            "proc ::HWFlow::nativePanelSessionEnd {windows} {};"
            "proc ::HWFlow::nativeMarkPanelInSession {entity mark prompt args} {"
            "if {$mark == 1} {return {10 11}}; return {20 21 22}}"
        )
        interp.eval("proc raise args {}; proc focus args {}")

        self.assertEqual(interp.eval("::ContactSetup::pickContactFaces"), "1")
        interp.eval("after 150 {set ::wait_done 1}; vwait ::wait_done")
        self.assertEqual(interp.eval("set ::ContactSetup::ui(selectedElemsA)"), "10 11")
        self.assertEqual(interp.eval("set ::ContactSetup::ui(selectedElemsB)"), "20 21 22")

    def test_default_contact_type_and_menu_are_stick_slide_freeze(self):
        interp = self.interp()
        self.assertEqual(interp.eval("set ::ContactSetup::cfg(contact_type)"), "STICK")
        source = MODULE.read_text(encoding="utf-8")
        menu_line = next(line for line in source.splitlines() if "tk_optionMenu" in line and "m_type" in line)
        self.assertIn("SLIDE STICK FREEZE", menu_line)
        self.assertNotIn("TIE", menu_line)

    def test_quick_action_waits_for_async_second_face_before_create(self):
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::ContactSetup::runAction {}", 1)[1].split(
            "proc ::ContactSetup::runSettings", 1
        )[0]
        self.assertIn("pickContactFaces 1", body)
        self.assertNotIn("::ContactSetup::createContact", body)

    def test_overlapping_face_picks_are_rejected(self):
        interp = self.interp()
        interp.eval("set ::ContactSetup::ui(selectedElemsA) {10 11}")
        interp.eval("set ::ContactSetup::ui(selectedElemsB) {11 20}")

        with self.assertRaises(tkinter.TclError):
            interp.eval("::ContactSetup::validateSelectedFaces")

    def test_reference_orientation_points_each_surface_at_the_other(self):
        interp = self.interp()
        interp.eval(
            "rename ::ContactSetup::centroidNodes ::ContactSetup::centroidNodes_real;"
            "rename ::ContactSetup::faceNormal ::ContactSetup::faceNormal_real;"
            "rename ::ContactSetup::elemNodes ::ContactSetup::elemNodes_real;"
            "proc ::ContactSetup::elemNodes {eid} {return [list $eid $eid $eid]};"
            "proc ::ContactSetup::centroidNodes {nodes} {"
            "if {[lindex $nodes 0] == 1} {return {0 0 0}}; return {0 0 1}};"
            "proc ::ContactSetup::faceNormal {nodes} {return {0 0 -1}}"
        )

        # A's -Z normal must reverse toward B; B's -Z normal already points at A.
        self.assertEqual(
            interp.eval("::ContactSetup::referenceOrientations {1 3} {2 4}"),
            "1 1 2 0",
        )

    def test_create_path_filters_common_region_without_scanning_components(self):
        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::ContactSetup::createContact {}", 1)[1].split(
            "proc ::ContactSetup::displayedComponents", 1
        )[0]
        self.assertIn("selectedElemsA", body)
        self.assertIn("selectedElemsB", body)
        self.assertIn("selectNearestContactFaces", body)
        self.assertNotIn("contactElemsForComponent", body)

    def test_create_contact_consumes_selected_faces_directly(self):
        interp = self.interp()
        interp.eval(
            "set ::ContactSetup::ui(selectedElemsA) {10 11};"
            "set ::ContactSetup::ui(selectedElemsB) {20 21 22};"
            "set ::ContactSetup::ui(contact_type) SLIDE;"
            "set ::ContactSetup::ui(main_side) FIRST;"
            "set ::ContactSetup::ui(friction) 0.2;"
            "set ::ContactSetup::ui(result_prefix) TEST;"
            "set ::ContactSetup::ui(try_group) 1;"
            "rename ::ContactSetup::saveRules ::ContactSetup::saveRules_real;"
            "rename ::ContactSetup::componentForElems ::ContactSetup::componentForElems_real;"
            "rename ::ContactSetup::referenceOrientations ::ContactSetup::referenceOrientations_real;"
            "rename ::ContactSetup::selectNearestContactFaces ::ContactSetup::selectNearestContactFaces_real;"
            "rename ::ContactSetup::primeGeometryCache ::ContactSetup::primeGeometryCache_real;"
            "rename ::ContactSetup::createContactSurf ::ContactSetup::createContactSurf_real;"
            "rename ::ContactSetup::createGroup ::ContactSetup::createGroup_real;"
            "rename ::ContactSetup::msg ::ContactSetup::msg_real;"
            "proc ::ContactSetup::saveRules {} {};"
            "proc ::ContactSetup::componentForElems {elems fallback} {return $fallback};"
            "proc ::ContactSetup::referenceOrientations {a b} {return {10 0 20 1}};"
            "proc ::ContactSetup::primeGeometryCache {elems} {};"
            "proc ::ContactSetup::selectNearestContactFaces {a b} {"
            "return [dict create elemsA {10} elemsB {20 21} searchTol 0.5 recordsA {} recordsB {} pairMapA {} pairMapB {}]};"
            "proc ::ContactSetup::createContactSurf {name elems color ref reverse} {"
            "lappend ::created_surfaces [list $elems $ref $reverse];"
            "return [expr {[llength $::created_surfaces] + 100}]};"
            "proc ::ContactSetup::createGroup {name main secondary} {"
            "set ::created_group [list $main $secondary]; return 200};"
            "proc ::ContactSetup::msg {text} {set ::last_message $text};"
            "proc tk_messageBox args {set ::dialog_error $args}"
        )

        interp.eval("::ContactSetup::createContact")
        self.assertEqual(
            interp.eval("set ::created_surfaces"),
            "{10 10 0} {{20 21} 20 1}",
        )
        self.assertEqual(interp.eval("set ::created_group"), "101 102")
        self.assertEqual(interp.eval("info exists ::dialog_error"), "0")

    def test_common_region_geometry_is_loaded_with_bulk_mark_queries(self):
        interp = self.interp()
        interp.eval(
            "proc *clearmark args {};"
            "proc *createmark {entity mark args} {set ::mark_${entity}_${mark} $args};"
            "proc hm_getmark {entity mark} {"
            "if {$entity eq {elems}} {return {10 20}}; return {1 2 3 4 5 6}};"
            "set ::bulk_queries 0;"
            "proc hm_getvalue {entity args} {"
            "if {[lsearch $args {mark=1}] >= 0} {incr ::bulk_queries; return {{1 2 3} {4 5 6}}};"
            "if {[lsearch $args {mark=2}] >= 0} {incr ::bulk_queries; return {{0 0 0} {1 0 0} {0 1 0} {0 0 1} {1 0 1} {0 1 1}}};"
            "error {unexpected per-entity query}}"
        )

        interp.eval("::ContactSetup::primeGeometryCache {10 20}")
        self.assertEqual(interp.eval("::ContactSetup::elemNodes 10"), "1 2 3")
        self.assertEqual(interp.eval("::ContactSetup::nodeXYZ 6"), "0 1 1")
        self.assertEqual(interp.eval("set ::bulk_queries"), "2")

    def test_common_region_excludes_selected_elements_outside_shared_footprint(self):
        interp = self.interp()
        interp.eval(
            "array set ::ContactSetup::geometryElemNodes {"
            "10 {1 2 3} 11 {4 5 6} 20 {7 8 9}};"
            "array set ::ContactSetup::geometryNodeXYZ {"
            "1 {0 0 0} 2 {1 0 0} 3 {0 1 0} "
            "4 {100 0 0} 5 {101 0 0} 6 {100 1 0} "
            "7 {0 0 1} 8 {1 0 1} 9 {0 1 1}}"
        )

        result = interp.eval("::ContactSetup::selectNearestContactFaces {10 11} {20}")
        self.assertEqual(interp.eval("dict get {{{}}} elemsA".format(result)), "10")
        self.assertEqual(interp.eval("dict get {{{}}} elemsB".format(result)), "20")

    def test_spatial_grid_is_reused_by_reference(self):
        interp = self.interp()
        result = interp.eval(
            "set records [list "
            "[dict create elem 10 center {0 0 0} normal {0 0 1} span 1] "
            "[dict create elem 20 center {2 0 0} normal {0 0 1} span 1]];"
            "array set grid {};"
            "::ContactSetup::buildRecordGrid $records 1.0 grid;"
            "set query [dict create elem 99 center {1.8 0 0} normal {0 0 1} span 1];"
            "set nearest [::ContactSetup::nearestRecord $query $records grid 1.0];"
            "list [array size grid] [lindex $nearest 0]"
        )
        self.assertEqual(result, "2 1")

        source = MODULE.read_text(encoding="utf-8")
        body = source.split("proc ::ContactSetup::nearestRecord", 1)[1].split(
            "proc ::ContactSetup::progress", 1
        )[0]
        self.assertIn("upvar 1 $gridVar grid", body)
        self.assertNotIn("array set grid $gridList", body)

    def test_threshold_match_stops_after_first_qualifying_record(self):
        interp = self.interp()
        result = interp.eval(
            "set records [list "
            "[dict create elem 10 center {0 0 0} normal {} span 1] "
            "[dict create elem 20 center {0.2 0 0} normal {} span 1]];"
            "array set grid {};"
            "::ContactSetup::buildRecordGrid $records 1.0 grid;"
            "rename ::ContactSetup::distance2 ::ContactSetup::distance2_real;"
            "proc ::ContactSetup::distance2 {a b} {incr ::distance_calls; return 0.25};"
            "set ::distance_calls 0;"
            "set query [dict create elem 99 center {0.1 0 0} normal {} span 1];"
            "set near [::ContactSetup::firstNearbyRecord $query $records grid 1.0 1.0];"
            "rename ::ContactSetup::distance2 {};"
            "rename ::ContactSetup::distance2_real ::ContactSetup::distance2;"
            "list [lindex $near 0] $::distance_calls"
        )
        self.assertEqual(result, "0 1")

    def test_face_geometry_data_combines_record_and_bbox_passes(self):
        interp = self.interp()
        interp.eval(
            "array set ::ContactSetup::geometryElemNodes {10 {1 2 3}};"
            "array set ::ContactSetup::geometryNodeXYZ {"
            "1 {0 0 0} 2 {2 0 0} 3 {0 2 0}}"
        )
        result = interp.eval("::ContactSetup::faceGeometryData {10}")
        self.assertEqual(
            interp.eval("dict get [lindex {{{}}} 2] min".format(result)),
            "0 0 0",
        )
        self.assertEqual(
            interp.eval("dict get [lindex {{{}}} 2] max".format(result)),
            "2 2 0",
        )
        self.assertEqual(
            interp.eval("dict get [lindex [lindex {{{}}} 0] 0] center".format(result)),
            "0.6666666666666666 0.6666666666666666 0.0",
        )

        no_normals = interp.eval("::ContactSetup::faceGeometryData {10} 0")
        self.assertEqual(
            interp.eval("dict get [lindex [lindex {{{}}} 0] 0] normal".format(no_normals)),
            "",
        )

    def test_contact_surface_is_created_with_computed_reverse_flag(self):
        interp = self.interp()
        interp.eval(
            "rename ::ContactSetup::deleteContactSurfByName ::ContactSetup::deleteContactSurfByName_real;"
            "rename ::ContactSetup::contactSurfIdByName ::ContactSetup::contactSurfIdByName_real;"
            "proc ::ContactSetup::deleteContactSurfByName {name} {return 0};"
            "proc ::ContactSetup::contactSurfIdByName {name} {return 77};"
            "proc *clearmark args {}; proc *createmark args {};"
            "proc *contactsurfcreatewithshells {name color mark reverse} {"
            "set ::surface_create [list $name $color $mark $reverse]};"
            "proc hm_info {args} {return {/tmp/optiStruct.tmpl}};"
            "proc hm_marklength {entity mark} {return 1};"
            "proc *dictionaryload args {};"
            "proc hm_getvalue {entity args} {"
            "if {[lsearch $args dataname=elements] >= 0} {return {10 11}};"
            "if {[lsearch $args dataname=cardimage] >= 0} {return SURF}; return {}}"
        )
        self.assertEqual(
            interp.eval("::ContactSetup::createContactSurf SURF_A {10 11} 13 10 1"),
            "77",
        )
        self.assertEqual(
            interp.eval("set ::surface_create"),
            "SURF_A 13 1 1",
        )

    def test_optistruct_group_declares_contact_surface_definitions(self):
        interp = self.interp()
        interp.eval(
            "set ::ContactSetup::ui(try_group) 1;"
            "set ::ContactSetup::ui(contact_type) SLIDE;"
            "set ::ContactSetup::ui(friction) 0.2;"
            "proc *clearmark args {}; proc *createmark args {}; proc *deletemark args {};"
            "proc hm_getmark args {return {}};"
            "proc *createentity {entity args} {set ::create_group [list $entity {*}$args]};"
            "proc ::HWFlow::entityIdByName {types name} {return 88};"
            "proc *setvalue {entity selector args} {lappend ::group_values [list $entity $selector {*}$args]};"
            "proc hm_attributelist {args} {return {CONTACT_PROP_TYPE TYPE}};"
            "proc hm_attributetype {name} {return 1};"
            "proc hm_getvalue {entity args} {"
            "if {[lsearch $args dataname=masterdefinition] >= 0 || "
            "[lsearch $args dataname=maindefinition] >= 0} {return 5};"
            "if {[lsearch $args dataname=slavedefinition] >= 0 || "
            "[lsearch $args dataname=secondarydefinition] >= 0} {return 5};"
            "if {[lsearch $args dataname=maincontactsurflist] >= 0 || "
            "[lsearch $args dataname=mastercontactsurflist] >= 0} {return 101};"
            "if {[lsearch $args dataname=secondarycontactsurflist] >= 0 || "
            "[lsearch $args dataname=slavecontactsurflist] >= 0} {return 102};"
            "if {[lsearch $args dataname=mainentityids] >= 0} {return 101};"
            "if {[lsearch $args dataname=secondaryentityids] >= 0} {return 102};"
            "if {[lsearch $args dataname=CONTACT_PROP_TYPE] >= 0} {return SLIDE}; return {}}"
        )

        self.assertEqual(interp.eval("::ContactSetup::createGroup CONTACT_1 101 102"), "88")
        self.assertEqual(
            interp.eval("set ::create_group"),
            "groups name=CONTACT_1 cardimage=CONTACT",
        )
        values = interp.eval("set ::group_values")
        self.assertIn("masterentityids=\\{contactsurfs 101\\}", values)
        self.assertIn("slaveentityids=\\{contactsurfs 102\\}", values)
        self.assertIn("CONTACT_PROP_TYPE=SLIDE", values)

    def test_group_verification_requires_contactsurf_definition_mode(self):
        interp = self.interp()
        interp.eval(
            "set ::ContactSetup::ui(try_group) 1;"
            "set ::ContactSetup::ui(contact_type) STICK;"
            "proc *clearmark args {}; proc *createmark args {}; proc *deletemark args {};"
            "proc hm_getmark args {return {}};"
            "proc *createentity args {};"
            "proc ::HWFlow::entityIdByName {types name} {return 88};"
            "proc *setvalue args {};"
            "proc hm_attributelist {args} {return {TYPE}};"
            "proc hm_attributetype {name} {return 1};"
            "proc hm_getvalue {entity args} {"
            "if {[lsearch $args dataname=TYPE] >= 0} {return 1};"
            "if {[lsearch $args dataname=masterdefinition] >= 0 || "
            "[lsearch $args dataname=maindefinition] >= 0} {return 4};"
            "if {[lsearch $args dataname=slavedefinition] >= 0 || "
            "[lsearch $args dataname=secondarydefinition] >= 0} {return 4};"
            "if {[lsearch $args dataname=maincontactsurflist] >= 0 || "
            "[lsearch $args dataname=mastercontactsurflist] >= 0} {return 101};"
            "if {[lsearch $args dataname=secondarycontactsurflist] >= 0 || "
            "[lsearch $args dataname=slavecontactsurflist] >= 0} {return 102};"
            "return {}}"
        )

        with self.assertRaises(tkinter.TclError):
            interp.eval("::ContactSetup::createGroup CONTACT_BAD 101 102")

    def test_optistruct_contact_type_values_match_requested_modes(self):
        interp = self.interp()
        self.assertEqual(interp.eval("::ContactSetup::contactTypeValue SLIDE"), "0")
        self.assertEqual(interp.eval("::ContactSetup::contactTypeValue STICK"), "1")
        self.assertEqual(interp.eval("::ContactSetup::contactTypeValue FREEZE"), "2")


if __name__ == "__main__":
    unittest.main()
