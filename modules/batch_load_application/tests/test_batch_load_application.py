from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

try:
    import tkinter
except ImportError:  # pragma: no cover
    tkinter = None


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "batch_load_application.tcl"


@unittest.skipIf(tkinter is None, "tkinter Tcl runtime is unavailable")
class BatchLoadApplicationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tcl = tkinter.Tcl()
        self.tcl.eval(f"source -encoding utf-8 {{{MODULE.as_posix()}}}")
        self.tcl.eval("set ::HWFlow::LANGUAGE en_US; set ::HWFlow::LANGUAGE_LOADED 1")

    def dict_get(self, value, key):
        return self.tcl.call("dict", "get", value, key)

    def test_image_shaped_csv_is_cleaned_and_parsed_by_case(self):
        text = (
            ",,,,,,,,,,,,,,\n"
            "unrelated workbook title,,,,\n"
            "case14 整车左转弯工况（1/3轮胎力时）,,,,,,,,,,,,\n"
            ",,硬点坐标,,,硬点名称,序号,时间,FX,FY,FZ,TX,TY,TZ\n"
            "case14,front_susp,1550,0,-210,frontsusp_a,前A型架与车架连接点,1,5.00E+00,-1.42E+03,-3.09E+03,3.40E+04,0,0,0\n"
            ",,,0,-800,200,frontsusp_bumper_left,前限位块-左侧,4,5.00E+00,0,0,0,0,0,0\n"
            ",,,,,,,,,,,,,,\n"
            "case15 整车加速工况（0.2g）,,,,,,,,,,,,\n"
            ",,硬点坐标,,,硬点名称,序号,时间,FX,FY,FZ,TX,TY,TZ\n"
            "case15,rear_susp,2724,0,-135,mid_a,中A型架车架连接点,1,2.00E+00,6.56E+01,3.29E+04,0,0,0,0\n"
        )
        parsed = self.tcl.call("::BatchLoadApplication::parseText", text, "loads.txt")
        self.assertEqual(self.tcl.splitlist(self.dict_get(parsed, "errors")), ())
        records = self.tcl.splitlist(self.dict_get(parsed, "records"))
        self.assertEqual(len(records), 3)
        self.assertEqual(self.dict_get(records[0], "case"), "case14")
        self.assertEqual(self.dict_get(records[0], "case_description"), "整车左转弯工况（1/3轮胎力时）")
        self.assertEqual(self.dict_get(records[0], "english"), "frontsusp_a")
        self.assertEqual(float(self.dict_get(records[0], "x")), 1550.0)
        self.assertEqual(self.dict_get(records[1], "english"), "frontsusp_bumper_left")
        self.assertEqual(float(self.dict_get(records[1], "x")), 0.0)
        self.assertEqual(self.dict_get(records[2], "case"), "case15")

    def test_quoted_comma_in_chinese_name_does_not_shift_load_columns(self):
        text = (
            "case1 制动工况,,,,\n"
            'case1,front,1,2,3,P1,"前点,左侧",99,0.5,10,20,30,1,2,3\n'
        )
        parsed = self.tcl.call("::BatchLoadApplication::parseText", text, "loads.txt")
        records = self.tcl.splitlist(self.dict_get(parsed, "records"))
        self.assertEqual(len(records), 1)
        self.assertEqual(self.dict_get(records[0], "case"), "case1")
        self.assertEqual(self.dict_get(records[0], "chinese"), "前点,左侧")

    def test_aggregation_merges_same_point_and_keeps_case_references(self):
        text = (
            "case1 工况一,,,,\n"
            "case1,group,1,2,3,P1,点一,1,0,10,20,30,1,2,3\n"
            "case2 工况二,,,,\n"
            "case2,group,1,2,3,P1,点一,2,1,11,21,31,4,5,6\n"
        )
        parsed = self.tcl.call("::BatchLoadApplication::parseText", text, "loads.txt")
        records = self.dict_get(parsed, "records")
        aggregated = self.tcl.call("::BatchLoadApplication::aggregateRecords", records)
        order = self.tcl.splitlist(self.dict_get(aggregated, "order"))
        self.assertEqual(len(order), 1)
        point = self.tcl.call("dict", "get", self.dict_get(aggregated, "points"), order[0])
        self.assertEqual(len(self.tcl.splitlist(self.dict_get(point, "references"))), 2)

    def test_case_name_mapping_matches_keywords_and_always_keeps_case_number(self):
        self.tcl.eval(
            "set ::BatchLoadApplication::CASE_NAME_RULES [list "
            "[dict create keywords {左转弯;左转} suffix left_turn] "
            "[dict create keywords {加速} suffix acceleration]]; "
            "set ::BatchLoadApplication::CASE_NAME_RULES_LOADED 1"
        )
        self.assertEqual(
            self.tcl.call(
                "::BatchLoadApplication::caseEntityName",
                "case14",
                "整车左转弯工况（1/3轮胎力时）",
            ),
            "case14_left_turn",
        )
        self.assertEqual(
            self.tcl.call(
                "::BatchLoadApplication::caseEntityName", "case15", "整车急加速工况"
            ),
            "case15_acceleration",
        )
        self.assertEqual(
            self.tcl.call(
                "::BatchLoadApplication::caseEntityName", "case16", "未配置工况"
            ),
            "case16",
        )

    def test_default_case_name_rules_cover_the_confirmed_image_cases(self):
        rules = self.tcl.splitlist(
            self.tcl.call("::BatchLoadApplication::defaultCaseNameRules")
        )
        self.assertEqual(len(rules), 2)
        self.assertEqual(self.dict_get(rules[0], "suffix"), "left_turn")
        self.assertEqual(self.dict_get(rules[1], "suffix"), "acceleration")

    def test_edited_case_name_rules_are_persisted_as_utf8(self):
        with tempfile.TemporaryDirectory() as tmp:
            rule_path = (Path(tmp) / "case_rules.txt").as_posix()
            self.tcl.eval(
                f"rename ::BatchLoadApplication::caseNameRulePath "
                f"::BatchLoadApplication::caseNameRulePath_real; "
                f"proc ::BatchLoadApplication::caseNameRulePath {{}} {{return {{{rule_path}}}}}; "
                "set ::BatchLoadApplication::CASE_NAME_RULES [list "
                "[dict create keywords {制动;急刹车} suffix braking]]; "
                "set ::BatchLoadApplication::CASE_NAME_RULES_LOADED 1"
            )
            self.tcl.call("::BatchLoadApplication::saveCaseNameRules")
            self.tcl.eval(
                "set ::BatchLoadApplication::CASE_NAME_RULES {}; "
                "set ::BatchLoadApplication::CASE_NAME_RULES_LOADED 0"
            )
            rules = self.tcl.splitlist(
                self.tcl.call("::BatchLoadApplication::loadCaseNameRules")
            )
            self.assertEqual(len(rules), 1)
            self.assertEqual(self.dict_get(rules[0], "keywords"), "制动;急刹车")
            self.assertEqual(self.dict_get(rules[0], "suffix"), "braking")
            self.assertIn("制动;急刹车", Path(rule_path).read_text(encoding="utf-8"))

    def test_mapping_csv_quotes_names_and_contains_only_completed_points(self):
        self.tcl.eval(
            "set ::BatchLoadApplication::ORDER {p1 p2}; "
            "set ::BatchLoadApplication::POINTS [dict create "
            "p1 [dict create english {P,1} chinese {点\"一} node_id 1001] "
            "p2 [dict create english P2 chinese 点二 node_id {}]]"
        )
        csv_text = self.tcl.call("::BatchLoadApplication::mappingCsvText")
        self.assertIn('"P,1","点""一",1001', csv_text)
        self.assertNotIn("P2", csv_text)

    def test_selected_node_is_renumbered_to_requested_solver_id(self):
        self.tcl.eval(
            r"""
set ::existing_nodes {42}
set ::renumber_call {}
proc hm_getvalue {entity selector dataname} {
    regexp {id=([0-9]+)} $selector -> node_id
    if {[lsearch -exact $::existing_nodes $node_id] < 0} {error {missing node}}
    return $node_id
}
proc *createmark args {}
proc *renumbersolverid {entity mark start increment offset offset_flag r1 r2 r3} {
    set ::renumber_call [list $entity $mark $start $increment $offset $offset_flag $r1 $r2 $r3]
    set ::existing_nodes [list $start]
}
"""
        )
        assigned = self.tcl.call(
            "::BatchLoadApplication::renumberSelectedNode", 42, 1001
        )
        self.assertEqual(int(assigned), 1001)
        self.assertEqual(
            self.tcl.splitlist(self.tcl.eval("set ::renumber_call")),
            ("nodes", "1", "1001", "1", "0", "0", "0", "0", "0"),
        )

    def test_next_mapping_id_starts_at_1001_and_skips_used_ids(self):
        self.tcl.eval("set ::BatchLoadApplication::MAPPINGS [dict create p1 1001 p2 1003]")
        self.assertEqual(
            int(self.tcl.call("::BatchLoadApplication::nextMappingId")), 1002
        )

    def test_remove_point_deletes_all_case_references_and_mapping(self):
        text = (
            "case1 工况一,,,,\n"
            "case1,g,1,2,3,P1,点一,1,0,10,20,30,1,2,3\n"
            "case2 工况二,,,,\n"
            "case2,g,1,2,3,P1,点一,2,1,11,21,31,4,5,6\n"
            "case2,g,4,5,6,P2,点二,3,1,1,2,3,4,5,6\n"
        )
        parsed = self.tcl.call("::BatchLoadApplication::parseText", text, "loads.txt")
        aggregated = self.tcl.call(
            "::BatchLoadApplication::aggregateRecords",
            self.dict_get(parsed, "records"),
        )
        self.tcl.call(
            "set",
            "::BatchLoadApplication::POINTS",
            self.dict_get(aggregated, "points"),
        )
        self.tcl.call(
            "set",
            "::BatchLoadApplication::ORDER",
            self.dict_get(aggregated, "order"),
        )
        self.tcl.eval("set ::BatchLoadApplication::MAPPINGS [dict create en:p1 1001]")
        removed = self.tcl.call("::BatchLoadApplication::removePointData", "en:p1")
        self.assertEqual(int(self.dict_get(removed, "removed")), 1)
        self.assertEqual(int(self.dict_get(removed, "references")), 2)
        self.assertEqual(
            self.tcl.splitlist(self.tcl.eval("set ::BatchLoadApplication::ORDER")),
            ("en:p2",),
        )
        self.assertEqual(
            self.tcl.splitlist(
                self.tcl.call(
                    "dict", "keys", self.tcl.eval("set ::BatchLoadApplication::MAPPINGS")
                )
            ),
            (),
        )

    def test_clear_data_removes_files_points_and_mappings(self):
        self.tcl.eval(
            "set ::BatchLoadApplication::FILES {a.txt b.txt}; "
            "set ::BatchLoadApplication::ORDER {en:p1}; "
            "set ::BatchLoadApplication::POINTS [dict create en:p1 [dict create node_id 1001]]; "
            "set ::BatchLoadApplication::MAPPINGS [dict create en:p1 1001]"
        )
        counts = self.tcl.call("::BatchLoadApplication::clearData")
        self.assertEqual(int(self.dict_get(counts, "files")), 2)
        self.assertEqual(int(self.dict_get(counts, "points")), 1)
        self.assertEqual(self.tcl.eval("set ::BatchLoadApplication::ORDER"), "")
        self.assertEqual(
            self.tcl.call("dict", "size", self.tcl.eval("set ::BatchLoadApplication::POINTS")),
            0,
        )

    def test_case_plans_use_only_completed_points_and_sort_case_numbers(self):
        text = (
            "case10 工况十,,,,\n"
            "case10,g,1,2,3,P1,点一,1,0,10,20,30,1,2,3\n"
            "case2 工况二,,,,\n"
            "case2,g,1,2,3,P1,点一,2,1,11,21,31,4,5,6\n"
            "case2,g,4,5,6,P2,点二,3,1,1,2,3,4,5,6\n"
        )
        parsed = self.tcl.call("::BatchLoadApplication::parseText", text, "loads.txt")
        aggregated = self.tcl.call(
            "::BatchLoadApplication::aggregateRecords", self.dict_get(parsed, "records")
        )
        self.tcl.call("set", "::BatchLoadApplication::POINTS", self.dict_get(aggregated, "points"))
        self.tcl.call("set", "::BatchLoadApplication::ORDER", self.dict_get(aggregated, "order"))
        self.tcl.eval("dict set ::BatchLoadApplication::POINTS en:p1 node_id 1001")
        plan = self.tcl.call("::BatchLoadApplication::buildCasePlans")
        self.assertEqual(
            self.tcl.splitlist(self.dict_get(plan, "case_names")),
            ("case2", "case10"),
        )
        self.assertEqual(int(self.dict_get(plan, "completed_points")), 1)
        self.assertEqual(int(self.dict_get(plan, "skipped_points")), 1)
        self.assertEqual(int(self.dict_get(plan, "record_count")), 2)
        model_names = self.dict_get(plan, "model_names")
        self.assertEqual(self.dict_get(model_names, "case2"), "case2")
        self.assertEqual(self.dict_get(model_names, "case10"), "case10")

    def test_case_plans_apply_mapped_model_name_to_loadcollector_and_subcase(self):
        self.tcl.eval(
            "set ::BatchLoadApplication::CASE_NAME_RULES [list "
            "[dict create keywords {左转} suffix left_turn]]; "
            "set ::BatchLoadApplication::CASE_NAME_RULES_LOADED 1"
        )
        text = (
            "case14 整车左转弯工况,,,,\n"
            "case14,g,1,2,3,P1,点一,1,0,10,20,30,1,2,3\n"
        )
        parsed = self.tcl.call("::BatchLoadApplication::parseText", text, "loads.txt")
        aggregated = self.tcl.call(
            "::BatchLoadApplication::aggregateRecords", self.dict_get(parsed, "records")
        )
        self.tcl.call("set", "::BatchLoadApplication::POINTS", self.dict_get(aggregated, "points"))
        self.tcl.call("set", "::BatchLoadApplication::ORDER", self.dict_get(aggregated, "order"))
        self.tcl.eval("dict set ::BatchLoadApplication::POINTS en:p1 node_id 1001")
        plan = self.tcl.call("::BatchLoadApplication::buildCasePlans")
        self.assertEqual(
            self.dict_get(self.dict_get(plan, "model_names"), "case14"),
            "case14_left_turn",
        )

    def test_create_one_case_creates_force_moment_loadcollector_and_subcase(self):
        self.tcl.eval(
            r"""
set ::case_commands {}
proc ::BatchLoadApplication::nodeExists node_id {return 1}
proc ::HWFlow::entityIdByName {types name} {
    if {[lindex $types 0] eq "loadcols"} {return 21}
    if {[lindex $types 0] eq "loadsteps"} {return 31}
    return 0
}
proc *createentity args {lappend ::case_commands [linsert $args 0 createentity]}
proc *currentcollector args {lappend ::case_commands [linsert $args 0 currentcollector]}
proc *createmark args {lappend ::case_commands [linsert $args 0 createmark]}
proc *loadcreateonentity_curve args {lappend ::case_commands [linsert $args 0 loadcreate]}
proc *loadstepscreate args {lappend ::case_commands [linsert $args 0 loadstepscreate]}
proc *attributeupdateint args {lappend ::case_commands [linsert $args 0 attributeupdateint]}
proc *setvalue args {lappend ::case_commands [linsert $args 0 setvalue]}
proc *attributeupdateentity args {lappend ::case_commands [linsert $args 0 attributeupdateentity]}
set ::entry [dict create node_id 1001 english P1 chinese 点一 fx 10 fy 20 fz 30 tx 1 ty 2 tz 3]
"""
        )
        result = self.tcl.call(
            "::BatchLoadApplication::createOneCase",
            "case14_left_turn",
            self.tcl.call("list", self.tcl.eval("set ::entry")),
        )
        self.assertEqual(int(self.dict_get(result, "loadcol_id")), 21)
        self.assertEqual(int(self.dict_get(result, "loadstep_id")), 31)
        commands = [
            self.tcl.splitlist(item)
            for item in self.tcl.splitlist(self.tcl.eval("set ::case_commands"))
        ]
        load_commands = [command for command in commands if command[0] == "loadcreate"]
        self.assertEqual(len(load_commands), 2)
        self.assertIn(
            ("createentity", "loadcols", "name=case14_left_turn"), commands
        )
        self.assertIn(
            ("loadstepscreate", "case14_left_turn", "1"), commands
        )
        self.assertEqual(load_commands[0][3:8], ("1", "1", "10", "20", "30"))
        self.assertEqual(load_commands[1][3:8], ("2", "1", "1", "2", "3"))
        self.assertIn(
            ("attributeupdateentity", "loadsteps", "31", "4147", "1", "1", "0", "loadcols", "21"),
            commands,
        )

    def test_import_paths_aggregates_across_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            first = Path(tmp) / "lc1.txt"
            second = Path(tmp) / "lc2.txt"
            first.write_text("case1 工况一,,,,\ncase1,g,1,2,3,P1,点一,1,0,1,2,3,4,5,6\n", encoding="utf-8")
            second.write_text("case2 工况二,,,,\ncase2,g,1,2,3,P1,点一,1,0,6,5,4,3,2,1\n", encoding="utf-8")
            result = self.tcl.call(
                "::BatchLoadApplication::importPaths",
                self.tcl.call("list", first.as_posix(), second.as_posix()),
            )
            self.assertEqual(int(self.dict_get(result, "file_count")), 2)
            self.assertEqual(int(self.dict_get(result, "record_count")), 2)
            self.assertEqual(int(self.dict_get(result, "point_count")), 1)

    def test_gbk_encoded_txt_is_supported(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "gbk.txt"
            path.write_bytes(
                (
                    "case3 中文工况,,,,\n"
                    "case3,g,1,2,3,P_GBK,中文点,1,0,1,2,3,4,5,6\n"
                ).encode("gbk")
            )
            text = self.tcl.call(
                "::BatchLoadApplication::readInputFile", path.as_posix()
            )
            parsed = self.tcl.call(
                "::BatchLoadApplication::parseText", text, path.as_posix()
            )
            records = self.tcl.splitlist(self.dict_get(parsed, "records"))
            self.assertEqual(len(records), 1)
            self.assertEqual(self.dict_get(records[0], "case"), "case3")
            self.assertEqual(self.dict_get(records[0], "english"), "P_GBK")

    def test_file_selection_does_not_read_or_parse_immediately(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "selected.txt"
            path.write_text("case1 x,,,,\n", encoding="utf-8")
            self.tcl.eval(
                f"""
set ::read_calls 0
proc tk_getOpenFile args {{return [list {{{path.as_posix()}}}]}}
rename ::BatchLoadApplication::readInputFile ::BatchLoadApplication::readInputFile_real
proc ::BatchLoadApplication::readInputFile path {{incr ::read_calls; return {{}}}}
"""
            )
            self.tcl.call("::BatchLoadApplication::chooseFiles")
            self.assertEqual(int(self.tcl.eval("set ::read_calls")), 0)
            selected = self.tcl.splitlist(
                self.tcl.eval("set ::BatchLoadApplication::FILES")
            )
            self.assertEqual(len(selected), 1)

    def test_progress_is_reported_during_explicit_parse(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "progress.txt"
            rows = ["case1 progress,,,,"]
            rows.extend(
                f"case1,g,{i},2,3,P{i},点{i},1,0,1,2,3,4,5,6"
                for i in range(450)
            )
            path.write_text("\n".join(rows), encoding="utf-8")
            self.tcl.eval(
                r"""
set ::progress_updates {}
proc ::HWFlow::progressOpen args {return 1}
proc ::HWFlow::progressUpdate {percent args} {lappend ::progress_updates $percent; return 0}
"""
            )
            result = self.tcl.call(
                "::BatchLoadApplication::importPaths",
                self.tcl.call("list", path.as_posix()),
                1,
            )
            self.assertEqual(int(self.dict_get(result, "record_count")), 450)
            updates = tuple(
                map(float, self.tcl.splitlist(self.tcl.eval("set ::progress_updates")))
            )
            self.assertGreaterEqual(len(updates), 5)
            self.assertGreater(max(updates), 80.0)


if __name__ == "__main__":
    unittest.main()
