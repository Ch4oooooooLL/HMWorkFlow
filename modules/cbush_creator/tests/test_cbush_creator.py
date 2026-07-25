from __future__ import annotations

import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover - depends on the host Python build
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "cbush_creator.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class CbushCreatorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source {{{MODULE.as_posix()}}}")
        self.tcl.eval("set ::HWFlow::LANGUAGE en_US; set ::HWFlow::LANGUAGE_LOADED 1")

    def test_output_name_preserves_source_component_name(self):
        self.assertEqual(
            self.tcl.call("::CBushCreator::outputComponentName", "Front Rail LH"),
            "CBUSH_Front Rail LH",
        )

    def test_offset_coordinates_add_five_only_to_global_z(self):
        result = self.tcl.call("::CBushCreator::offsetCoordinates", "1.25 -2.5 8")
        self.assertEqual(tuple(map(float, self.tcl.splitlist(result))), (1.25, -2.5, 13.0))

    def test_create_for_node_creates_z_offset_node_and_cbush_type(self):
        self.tcl.eval(
            r"""
rename ::CBushCreator::sourceComponentId ::CBushCreator::sourceComponentId_real
rename ::CBushCreator::nodeCoordinates ::CBushCreator::nodeCoordinates_real
rename ::HWFlow::componentName ::HWFlow::componentName_real
rename ::HWFlow::createComponent ::HWFlow::createComponent_real
proc ::CBushCreator::sourceComponentId {nodeId} {return 42}
proc ::CBushCreator::nodeCoordinates {nodeId} {return {10 20 30}}
proc ::HWFlow::componentName {componentId} {return {V01_FLOOR LH_T2_Q355}}
proc ::HWFlow::createComponent {name color} {set ::created_component [list $name $color]; return 91}
set ::commands {}
set ::latest_node 100
set ::latest_elem 200
proc hm_latestentityid {entityType} {
    if {$entityType eq "nodes"} {return $::latest_node}
    return $::latest_elem
}
proc *currentcollector {entityType name} {lappend ::commands [list currentcollector $entityType $name]}
proc *createnode {x y z a b c} {
    lappend ::commands [list createnode $x $y $z $a $b $c]
    set ::latest_node 101
}
proc *elementtype {config type} {lappend ::commands [list elementtype $config $type]}
proc *springos {node1 node2 property vector directionNode ox oy oz useComponents systemId} {
    lappend ::commands [list springos $node1 $node2 $property $vector $directionNode $ox $oy $oz $useComponents $systemId]
    set ::latest_elem 201
}
"""
        )

        result = self.tcl.call("::CBushCreator::createForNode", 7)

        self.assertEqual(self.tcl.call("dict", "get", result, "source_node"), 7)
        self.assertEqual(self.tcl.call("dict", "get", result, "offset_node"), 101)
        self.assertEqual(self.tcl.call("dict", "get", result, "element"), 201)
        self.assertEqual(
            self.tcl.call("dict", "get", result, "component"),
            "CBUSH_V01_FLOOR LH_T2_Q355",
        )
        self.assertEqual(
            self.tcl.eval("set ::created_component"),
            "{CBUSH_V01_FLOOR LH_T2_Q355} 6",
        )
        commands = [self.tcl.splitlist(item) for item in self.tcl.splitlist(self.tcl.eval("set ::commands"))]
        self.assertIn(("createnode", "10", "20", "35.0", "0", "0", "0"), commands)
        self.assertIn(("elementtype", "21", "6"), commands)
        self.assertIn(
            ("springos", "7", "101", "", "0", "0", "0", "0", "0", "0", "0"),
            commands,
        )

    def test_create_for_node_rejects_ambiguous_component_membership(self):
        self.tcl.eval(
            r"""
rename ::CBushCreator::sourceComponentIds ::CBushCreator::sourceComponentIds_real
proc ::CBushCreator::sourceComponentIds {nodeId} {return {8 9}}
"""
        )
        with self.assertRaises(tkinter.TclError) as context:
            self.tcl.call("::CBushCreator::sourceComponentId", 7)
        self.assertIn("multiple components", str(context.exception))

    def test_source_component_prefers_node_collector(self):
        self.tcl.eval(
            r"""
proc hm_getvalue {entity selector dataName} {
    if {$entity eq "nodes" && $dataName eq "dataname=collector.id"} {return 73}
    error unavailable
}
"""
        )
        self.assertEqual(self.tcl.call("::CBushCreator::sourceComponentIds", 7), (73,))

    def test_source_component_falls_back_to_connected_elements(self):
        self.tcl.eval(
            r"""
proc hm_getvalue {entity selector dataName} {
    if {$entity eq "nodes" && $dataName eq "dataname=elems"} {return {11 12}}
    if {$entity eq "elems" && $selector eq "id=11" && $dataName eq "dataname=collector.id"} {return 81}
    if {$entity eq "elems" && $selector eq "id=12" && $dataName eq "dataname=collector.id"} {return 81}
    error unavailable
}
"""
        )
        self.assertEqual(self.tcl.call("::CBushCreator::sourceComponentIds", 7), (81,))

    def test_failed_cbush_creation_removes_the_temporary_node(self):
        self.tcl.eval(
            r"""
rename ::CBushCreator::sourceComponentId ::CBushCreator::sourceComponentId_real
rename ::CBushCreator::nodeCoordinates ::CBushCreator::nodeCoordinates_real
rename ::HWFlow::componentName ::HWFlow::componentName_real
rename ::HWFlow::createComponent ::HWFlow::createComponent_real
proc ::CBushCreator::sourceComponentId {nodeId} {return 42}
proc ::CBushCreator::nodeCoordinates {nodeId} {return {1 2 3}}
proc ::HWFlow::componentName {componentId} {return SOURCE}
proc ::HWFlow::createComponent {name color} {return 91}
set ::latest_node 100
set ::deleted_node ""
proc hm_latestentityid {entityType} {
    if {$entityType eq "nodes"} {return $::latest_node}
    return 200
}
proc *currentcollector args {}
proc *createnode args {set ::latest_node 101}
proc *elementtype args {}
proc *springos args {error {simulated CBUSH failure}}
proc *clearmark args {}
proc *createmark {entity mark selector id} {set ::marked_node $id}
proc *deletemark {entity mark} {set ::deleted_node $::marked_node}
"""
        )
        with self.assertRaises(tkinter.TclError) as context:
            self.tcl.call("::CBushCreator::createForNode", 7)
        self.assertIn("simulated CBUSH failure", str(context.exception))
        self.assertEqual(self.tcl.eval("set ::deleted_node"), "101")

    def test_nodes_from_same_source_component_reuse_one_output_component(self):
        self.tcl.eval(
            r"""
rename ::CBushCreator::sourceComponentId ::CBushCreator::sourceComponentId_real
rename ::CBushCreator::nodeCoordinates ::CBushCreator::nodeCoordinates_real
rename ::HWFlow::componentName ::HWFlow::componentName_real
rename ::HWFlow::createComponent ::HWFlow::createComponent_real
proc ::CBushCreator::sourceComponentId {nodeId} {return 42}
proc ::CBushCreator::nodeCoordinates {nodeId} {return [list $nodeId 20 30]}
proc ::HWFlow::componentName {componentId} {return V01_COMMON_T2_Q355}
set ::component_requests {}
proc ::HWFlow::createComponent {name color} {
    lappend ::component_requests $name
    return 91
}
set ::latest_node 100
set ::latest_elem 200
proc hm_latestentityid {entityType} {
    if {$entityType eq "nodes"} {return $::latest_node}
    return $::latest_elem
}
proc *currentcollector args {}
proc *createnode args {incr ::latest_node}
proc *elementtype args {}
proc *springos args {incr ::latest_elem}
proc *createmark args {}
proc *numbersmark args {}
proc *clearmark args {}
proc hm_entityrecorder args {}
proc *redraw args {}
"""
        )

        first = self.tcl.call("::CBushCreator::createForNode", 7)
        second = self.tcl.call("::CBushCreator::createForNode", 8)

        self.assertEqual(
            self.tcl.call("dict", "get", first, "component"),
            "CBUSH_V01_COMMON_T2_Q355",
        )
        self.assertEqual(
            self.tcl.call("dict", "get", second, "component"),
            "CBUSH_V01_COMMON_T2_Q355",
        )
        self.assertEqual(
            self.tcl.splitlist(self.tcl.eval("set ::component_requests")),
            ("CBUSH_V01_COMMON_T2_Q355", "CBUSH_V01_COMMON_T2_Q355"),
        )

    def test_run_action_accepts_multiple_selected_nodes(self):
        self.tcl.eval(
            r"""
rename ::CBushCreator::pickSourceNode ::CBushCreator::pickSourceNode_real
rename ::CBushCreator::createForNodes ::CBushCreator::createForNodes_real
proc ::CBushCreator::pickSourceNode {} {return {1 2}}
proc ::CBushCreator::createForNodes {nodeIds} {
    set ::batch_nodes $nodeIds
    return [dict create selected_count 2 successful_count 2 failed_count 0 results {} failures {} components {CBUSH_SOURCE}]
}
set ::message_icon ""
proc tk_messageBox args {
    set index [lsearch -exact $args -icon]
    if {$index >= 0} {set ::message_icon [lindex $args [expr {$index + 1}]]}
}
"""
        )
        result = self.tcl.call("::CBushCreator::runAction")
        self.assertEqual(self.tcl.splitlist(self.tcl.eval("set ::batch_nodes")), ("1", "2"))
        self.assertEqual(int(self.tcl.call("dict", "get", result, "successful_count")), 2)
        self.assertEqual(self.tcl.eval("set ::message_icon"), "info")

    def test_batch_continues_after_one_node_fails(self):
        self.tcl.eval(
            r"""
rename ::CBushCreator::createForNode ::CBushCreator::createForNode_real
set ::processed_nodes {}
proc ::CBushCreator::createForNode {nodeId} {
    lappend ::processed_nodes $nodeId
    if {$nodeId == 2} {error {ambiguous source component}}
    return [dict create source_node $nodeId offset_node [expr {$nodeId + 100}] element [expr {$nodeId + 200}] component CBUSH_SOURCE]
}
"""
        )
        result = self.tcl.call("::CBushCreator::createForNodes", "1 2 3")
        self.assertEqual(self.tcl.splitlist(self.tcl.eval("set ::processed_nodes")), ("1", "2", "3"))
        self.assertEqual(self.tcl.call("dict", "get", result, "successful_count"), 2)
        self.assertEqual(self.tcl.call("dict", "get", result, "failed_count"), 1)
        failures = self.tcl.splitlist(self.tcl.call("dict", "get", result, "failures"))
        self.assertEqual(self.tcl.call("dict", "get", failures[0], "source_node"), 2)


if __name__ == "__main__":
    unittest.main()
