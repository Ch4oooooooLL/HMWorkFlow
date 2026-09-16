from pathlib import Path
import tkinter


ROOT = Path(__file__).resolve().parents[3]
MODULE = ROOT / "modules" / "node_patch_builder.tcl"
TOOLKIT = ROOT / "hw_toolkit_core.tcl"
INSTALLER = ROOT / "install_update.tcl"


def interp():
    tcl = tkinter.Tcl()
    tcl.eval(f'source -encoding utf-8 {{{MODULE.as_posix()}}}')
    return tcl


def shell_interp():
    tcl = interp()
    tcl.eval(r"""
        array set ::xyz {
            1 {0.0 0.0 0.0} 2 {1.0 0.0 0.0} 3 {2.0 0.0 0.0}
            4 {0.0 1.0 0.0} 5 {1.0 1.0 0.0} 6 {2.0 1.0 0.0}
        }
        array set ::conn {10 {1 2 5 4} 11 {2 3 6 5}}
        array set ::around {1 {10} 2 {10 11} 3 {11} 4 {10} 5 {10 11} 6 {11}}
        proc hm_getvalue {entity args} {
            set joined [join $args " "]
            regexp {id=([0-9]+)} $joined -> id
            regexp {dataname=([^ ]+)} $joined -> field
            if {$entity eq "nodes"} {
                if {$field eq "elems" || $field eq "elements"} {return $::around($id)}
                set index [lsearch -exact {x y z} $field]
                if {$index >= 0} {return [lindex $::xyz($id) $index]}
            }
            if {$entity eq "elems" && $field eq "nodes"} {return $::conn($id)}
            error "unsupported mock query: $entity $joined"
        }
    """)
    return tcl


# 3 x 2 block of QUAD4 shells: ids 1-12, elements 10-15, all unit sized so
# every corner neighbourhood reports the same local mesh size.
BLOCK_MESH = r"""
    array set ::xyz {
        1 {0.0 0.0 0.0} 2 {1.0 0.0 0.0} 3 {2.0 0.0 0.0} 4 {3.0 0.0 0.0}
        5 {0.0 1.0 0.0} 6 {1.0 1.0 0.0} 7 {2.0 1.0 0.0} 8 {3.0 1.0 0.0}
        9 {0.0 2.0 0.0} 10 {1.0 2.0 0.0} 11 {2.0 2.0 0.0} 12 {3.0 2.0 0.0}
    }
    array set ::conn {
        10 {1 2 6 5} 11 {2 3 7 6} 12 {3 4 8 7}
        13 {5 6 10 9} 14 {6 7 11 10} 15 {7 8 12 11}
    }
    array set ::around {
        1 {10} 2 {10 11} 3 {11 12} 4 {12}
        5 {10 13} 6 {10 11 13 14} 7 {11 12 14 15} 8 {12 15}
        9 {13} 10 {13 14} 11 {14 15} 12 {15}
    }
    proc hm_getvalue {entity args} {
        set joined [join $args " "]
        regexp {id=([0-9]+)} $joined -> id
        regexp {dataname=([^ ]+)} $joined -> field
        if {$entity eq "nodes"} {
            if {$field eq "elems" || $field eq "elements"} {return $::around($id)}
            set index [lsearch -exact {x y z} $field]
            if {$index >= 0} {return [lindex $::xyz($id) $index]}
        }
        if {$entity eq "elems" && $field eq "nodes"} {return $::conn($id)}
        error "unsupported mock query: $entity $joined"
    }
"""


def block_interp():
    tcl = interp()
    tcl.eval(BLOCK_MESH)
    return tcl


def analyze(tcl, corners, h=0.0):
    return tcl.eval("::NodePatch::analysisSummary [::NodePatch::analyze {%s} %s]" % (corners, h))


def test_module_is_registered_and_source_has_no_side_effect_ui():
    text = TOOLKIT.read_text(encoding="utf-8")
    assert "node_patch_builder {" in text
    assert 'proc     "::NodePatch::runAction"' in text
    tcl = interp()
    assert tcl.eval("namespace exists ::NodePatch") == "1"
    assert tcl.eval("info commands ::NodePatch::runAction")


def test_ordered_pairs_never_add_diagonals():
    tcl = interp()
    assert tcl.splitlist(tcl.eval("::NodePatch::boundaryPairs {10 20 30}")) == (
        "10 20", "20 30", "30 10"
    )
    assert tcl.splitlist(tcl.eval("::NodePatch::boundaryPairs {1 2 3 4}")) == (
        "1 2", "2 3", "3 4", "4 1"
    )
    assert tcl.splitlist(tcl.eval("::NodePatch::boundaryPairs {1 2 3 4 5 6}")) == (
        "1 2", "2 3", "3 4", "4 5", "5 6", "6 1"
    )


def test_corner_count_accepts_any_boundary_of_three_or_more():
    tcl = block_interp()
    for count in range(3, 13):
        corners = " ".join(str(node) for node in range(1, count + 1))
        assert tcl.eval("llength [::NodePatch::validateCorners {%s}]" % corners) == str(count)


def test_corner_count_rejects_two_nodes_and_duplicates():
    tcl = block_interp()
    assert tcl.eval("catch {::NodePatch::validateCorners {1 2}} message") == "1"
    assert "F01" in tcl.eval("set message")
    assert tcl.eval("catch {::NodePatch::validateCorners {1 1 2}} message") == "1"
    assert "F02" in tcl.eval("set message")


def test_corner_count_is_capped_by_the_boundary_budget():
    tcl = block_interp()
    cap = int(tcl.eval("set ::NodePatch::cfg(max_boundary_corners)"))
    corners = " ".join(str(node) for node in range(1, cap + 2))
    assert tcl.eval("catch {::NodePatch::validateCorners {%s}} message" % corners) == "1"
    assert "F01" in tcl.eval("set message")
    assert str(cap) in tcl.eval("set message")


def test_per_side_budgets_keep_the_historical_allowance_and_shrink_proportionally():
    tcl = interp()
    # 3/4 sides reproduce the pre-existing flat caps exactly.
    assert tcl.splitlist(tcl.eval("::NodePatch::sideBudgets 3 10 30")) == ("3", "30")
    assert tcl.splitlist(tcl.eval("::NodePatch::sideBudgets 4 120 360")) == ("30", "360")
    assert tcl.splitlist(tcl.eval("::NodePatch::sideBudgets 4 10 30")) == ("2", "30")
    # Many sides divide the per-side cap but never below one side's floor.
    assert tcl.splitlist(tcl.eval("::NodePatch::sideBudgets 8 120 360")) == ("15", "360")
    assert tcl.splitlist(tcl.eval("::NodePatch::sideBudgets 12 10 30")) == ("1", "30")
    assert tcl.splitlist(tcl.eval("::NodePatch::sideBudgets 1 10 30")) == ("10", "30")


def test_element_edges_exclude_quad_diagonals():
    tcl = interp()
    assert tcl.splitlist(tcl.eval("::NodePatch::elementEdges {1 2 3 4}")) == (
        "1 2", "2 3", "3 4", "4 1"
    )


def test_segment_intersection_and_bow_tie_geometry():
    tcl = interp()
    hit = tuple(map(float, tcl.splitlist(tcl.eval(
        "::NodePatch::segmentIntersection2 {0 0} {2 2} {0 2} {2 0}"
    ))))
    assert hit == (0.5, 0.5)
    assert tcl.eval("::NodePatch::segmentsCrossStrict {0 0} {2 2} {0 2} {2 0}") == "1"


def test_split_polygon_opposite_quad_edges_produces_two_quads():
    tcl = interp()
    plans = tcl.splitlist(tcl.eval(
        "::NodePatch::splitPolygonPlans {1 2 3 4} {10 edge 0} {11 edge 2}"
    ))
    assert len(plans) == 2
    assert all(len(tcl.splitlist(plan)) == 4 for plan in plans)
    all_nodes = [set(tcl.splitlist(plan)) for plan in plans]
    assert all({"10", "11"}.issubset(nodes) for nodes in all_nodes)


def test_flatten_chains_removes_shared_corners_and_closing_duplicate():
    tcl = interp()
    boundary = tcl.splitlist(tcl.eval(
        "::NodePatch::flattenChains {{1 5 2} {2 6 3} {3 7 1}}"
    ))
    assert boundary == ("1", "5", "2", "6", "3", "7")


def test_existing_chain_is_local_and_uses_real_shell_edges():
    tcl = shell_interp()
    chain = tcl.splitlist(tcl.eval("::NodePatch::existingEdgeChain 1 3 1.0"))
    assert chain == ("1", "2", "3")


def test_line_trace_crosses_two_quads_monotonically():
    tcl = shell_interp()
    steps = tcl.splitlist(tcl.eval("::NodePatch::traceAcrossShell 1 6 1.0"))
    assert len(steps) == 2
    first = dict(zip(tcl.splitlist(steps[0])[::2], tcl.splitlist(steps[0])[1::2]))
    second = dict(zip(tcl.splitlist(steps[1])[::2], tcl.splitlist(steps[1])[1::2]))
    assert first["element"] == "10"
    assert first["exit_edge"] in {"2 5", "5 2"}
    assert float(first["exit_t"]) == 0.5
    assert second["element"] == "11"
    assert float(second["exit_t"]) == 1.0


def test_line_trace_reuses_existing_vertex_without_duplicate_node():
    tcl = interp()
    tcl.eval(r"""
        array set ::xyz {
            1 {0.0 0.0 0.0} 2 {1.0 0.0 0.0} 3 {2.0 0.0 0.0}
            4 {0.0 1.0 0.0} 5 {1.0 1.0 0.0} 6 {2.0 1.0 0.0}
            7 {0.0 2.0 0.0} 8 {1.0 2.0 0.0} 9 {2.0 2.0 0.0}
        }
        array set ::conn {10 {1 2 5 4} 11 {2 3 6 5} 12 {4 5 8 7} 13 {5 6 9 8}}
        array set ::around {1 {10} 2 {10 11} 3 {11} 4 {10 12} 5 {10 11 12 13} 6 {11 13} 7 {12} 8 {12 13} 9 {13}}
        proc hm_getvalue {entity args} {
            set joined [join $args " "]; regexp {id=([0-9]+)} $joined -> id; regexp {dataname=([^ ]+)} $joined -> field
            if {$entity eq "nodes"} {if {$field in {elems elements}} {return $::around($id)}; set ix [lsearch -exact {x y z} $field]; if {$ix>=0} {return [lindex $::xyz($id) $ix]}}
            if {$entity eq "elems" && $field eq "nodes"} {return $::conn($id)}
            error "unsupported"
        }
    """)
    steps = tcl.splitlist(tcl.eval("::NodePatch::traceAcrossShell 1 9 1.0"))
    assert len(steps) == 2
    first = dict(zip(tcl.splitlist(steps[0])[::2], tcl.splitlist(steps[0])[1::2]))
    second = dict(zip(tcl.splitlist(steps[1])[::2], tcl.splitlist(steps[1])[1::2]))
    assert first["snap_node"] == "5"
    assert second["element"] == "13"


def test_analysis_reports_every_side_of_a_larger_boundary():
    tcl = block_interp()
    # Four corners on a 3 x 2 quad block: every side is an existing edge chain.
    four = analyze(tcl, "1 4 12 9")
    assert four.startswith("Boundary: 4 corners / 4 sides")
    assert four.count("\n") == 4
    assert "Edge 9-1: EXISTING (3 nodes)" in four
    # A pentagon reuses one node of the block interior and still resolves each
    # side independently, which the old fixed 3/4-node contract could not do.
    five = analyze(tcl, "1 4 12 9 5")
    assert five.startswith("Boundary: 5 corners / 5 sides")
    assert five.count("\n") == 5
    assert "Edge 9-5: EXISTING (2 nodes)" in five


def test_hint_mesh_size_is_reused_across_sides():
    tcl = block_interp()
    resolved = tcl.eval("dict get [::NodePatch::analyze {1 4 12 9}] h")
    hinted = tcl.eval("dict get [::NodePatch::analyze {1 4 12 9} %s] h" % resolved)
    assert resolved == hinted


def test_hm2019_compatible_tcl_avoids_new_split_api_and_python_dependency():
    text = MODULE.read_text(encoding="utf-8")
    assert "*splitelementbyedges" not in text
    assert "exec python" not in text.lower()
    assert "package require" not in text.lower()
    for required in ("max_trace_elements", "surface_angle_tol", "path_length_ratio_max", "*undohistorystate"):
        assert required in text


def test_failure_codes_follow_spec_contract():
    text = MODULE.read_text(encoding="utf-8")
    for code in range(1, 14):
        assert f"F{code:02d}" in text


def test_build_refuses_to_mutate_without_native_rollback_commands():
    tcl = interp()
    code = tcl.eval(
        "catch {::NodePatch::buildFromAnalysis {corners {1 2 3} pairs {} h 1.0}} message"
    )
    assert code == "1"
    assert "Required rollback command" in tcl.eval("set message")


def test_installer_cleans_and_verifies_registered_module():
    text = INSTALLER.read_text(encoding="utf-8")
    assert "::MeshSeamWeld ::NodePatch ::MidSurf" in text
    assert "::MeshSeamWeld ::NodePatch ::ContactSetup" in text
    assert "dict exists $::HWToolkit::MODULES node_patch_builder" in text
    assert "::NodePatch::runAction" in text
