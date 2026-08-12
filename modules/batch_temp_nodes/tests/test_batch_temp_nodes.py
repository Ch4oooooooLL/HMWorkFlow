from __future__ import annotations

import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "batch_temp_nodes.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class BatchTempNodesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source -encoding utf-8 {{{MODULE.as_posix()}}}")
        self.tcl.eval("set ::HWFlow::LANGUAGE en_US; set ::HWFlow::LANGUAGE_LOADED 1")

    def parse(self, text: str):
        return self.tcl.call("::BatchTempNodes::parseCoordinates", text)

    def test_parses_blank_lines_spaces_scientific_notation_and_chinese_comma(self):
        result = self.parse("1, 2, 3\n\n-4，5.5，6e2")
        self.assertEqual(self.tcl.splitlist(self.tcl.call("dict", "get", result, "errors")), ())
        points = self.tcl.splitlist(self.tcl.call("dict", "get", result, "points"))
        self.assertEqual(tuple(map(float, self.tcl.splitlist(points[0]))), (1.0, 2.0, 3.0))
        self.assertEqual(tuple(map(float, self.tcl.splitlist(points[1]))), (-4.0, 5.5, 600.0))

    def test_parses_arbitrary_whitespace_and_mixed_separators(self):
        result = self.parse("1 2 3\n4     5.5    -6\n7,  8\t9\n10，11  12")
        self.assertEqual(self.tcl.splitlist(self.tcl.call("dict", "get", result, "errors")), ())
        points = self.tcl.splitlist(self.tcl.call("dict", "get", result, "points"))
        self.assertEqual(len(points), 4)
        self.assertEqual(tuple(map(float, self.tcl.splitlist(points[1]))), (4.0, 5.5, -6.0))
        self.assertEqual(tuple(map(float, self.tcl.splitlist(points[2]))), (7.0, 8.0, 9.0))

    def test_reports_line_number_and_allows_valid_rows_to_be_inspected(self):
        result = self.parse("1,2,3\n4,nope,6\n7,8")
        points = self.tcl.splitlist(self.tcl.call("dict", "get", result, "points"))
        errors = self.tcl.splitlist(self.tcl.call("dict", "get", result, "errors"))
        self.assertEqual(len(points), 1)
        self.assertEqual(len(errors), 2)
        self.assertIn("Line 2", errors[0])
        self.assertIn("Line 3", errors[1])

    def test_rejects_non_finite_coordinates(self):
        result = self.parse("Inf,2,3\nNaN,5,6")
        self.assertEqual(
            len(self.tcl.splitlist(self.tcl.call("dict", "get", result, "errors"))),
            2,
        )

    def test_create_nodes_returns_ids_and_records_last_batch(self):
        self.tcl.eval(
            r"""
set ::latest_node 10
set ::commands {}
set ::numbersmark_calls 0
set ::latest_query_calls 0
proc hm_latestentityid {entity} {incr ::latest_query_calls; return $::latest_node}
proc *createnode args {lappend ::commands [linsert $args 0 createnode]; incr ::latest_node}
proc *createmark args {}
proc *numbersmark args {incr ::numbersmark_calls}
proc *clearmark args {}
proc *redraw args {}
"""
        )
        created = self.tcl.call("::BatchTempNodes::createNodes", "{1 2 3} {4 5 6}")
        self.assertEqual(self.tcl.splitlist(created), (11, 12))
        self.assertEqual(self.tcl.splitlist(self.tcl.eval("set ::BatchTempNodes::LAST_CREATED_NODE_IDS")), ("11", "12"))
        commands = [self.tcl.splitlist(x) for x in self.tcl.splitlist(self.tcl.eval("set ::commands"))]
        self.assertEqual(commands[0], ("createnode", "1", "2", "3", "0", "0", "0"))
        self.assertEqual(int(self.tcl.eval("set ::numbersmark_calls")), 0)
        self.assertEqual(int(self.tcl.eval("set ::latest_query_calls")), 0)

    def test_create_node_falls_back_to_latest_id_when_command_returns_empty(self):
        self.tcl.eval(
            r"""
set ::latest_node 40
set ::latest_query_calls 0
proc hm_latestentityid {entity} {incr ::latest_query_calls; return $::latest_node}
proc *createnode args {set ::latest_node 41; return {}}
"""
        )
        self.assertEqual(int(self.tcl.call("::BatchTempNodes::createOneNode", 1, 2, 3)), 41)
        self.assertEqual(int(self.tcl.eval("set ::latest_query_calls")), 1)

    def test_failure_rolls_back_nodes_already_created(self):
        self.tcl.eval(
            r"""
set ::latest_node 20
set ::create_count 0
set ::deleted {}
set ::BatchTempNodes::LAST_CREATED_NODE_IDS {9}
proc hm_latestentityid {entity} {return $::latest_node}
proc *createnode args {
    incr ::create_count
    if {$::create_count == 2} {error {simulated failure}}
    incr ::latest_node
}
proc *clearmark args {}
proc *createmark {entity mark selector args} {set ::marked $args}
proc *deletemark args {set ::deleted $::marked}
proc *redraw args {}
"""
        )
        with self.assertRaises(tkinter.TclError) as context:
            self.tcl.call("::BatchTempNodes::createNodes", "{1 2 3} {4 5 6}")
        self.assertIn("rolled back", str(context.exception))
        self.assertEqual(self.tcl.splitlist(self.tcl.eval("set ::deleted")), ("21",))
        self.assertEqual(
            self.tcl.splitlist(self.tcl.eval("set ::BatchTempNodes::LAST_CREATED_NODE_IDS")),
            ("9",),
        )

    def test_undo_clears_last_batch(self):
        self.tcl.eval(
            r"""
set ::BatchTempNodes::LAST_CREATED_NODE_IDS {31 32}
set ::deleted {}
proc *clearmark args {}
proc *createmark {entity mark selector args} {set ::marked $args}
proc *deletemark args {set ::deleted $::marked}
proc *redraw args {}
"""
        )
        self.assertEqual(int(self.tcl.call("::BatchTempNodes::undoLast")), 1)
        self.assertEqual(self.tcl.splitlist(self.tcl.eval("set ::deleted")), ("31", "32"))
        self.assertEqual(self.tcl.eval("set ::BatchTempNodes::LAST_CREATED_NODE_IDS"), "")


if __name__ == "__main__":
    unittest.main()
