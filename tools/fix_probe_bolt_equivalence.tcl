# Fix probe: replacement for *replacenodes in ::RB2Bolt::replaceOneNode.
#
# Evidence: *replacenodes <src> <tgt> 1 0 and every variant tried in
# audit_rbe2_bolt_connector_repl failed on both 2019 and 2022 (RC=1, the
# source node survives).  Candidate replacement: *equivalence node merging
# (mark 1 keeps the node, mark 2 is absorbed).  This probe pins down the
# exact signature and the merge direction on the installed build.
#
# Run once per build:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/fix_probe_bolt_equivalence.tcl
# Results: runtime/fix_probe_bolt_equivalence_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "fix_probe_bolt_equivalence_${version}.log"]
set chan [open $reportPath w]
fconfigure $chan -encoding utf-8 -translation lf

proc P {key value} {
    variable chan
    puts $chan "${key}=${value}"
    flush $chan
}

proc T {key script} {
    set code [catch {uplevel 1 $script} value options]
    if {$code} {
        set msg [string map [list "\n" " " "\r" " " "{" "" "}" ""] $value]
        P "$key" "ERR: $msg"
        return 0
    }
    P "$key" "OK: $value"
    return 1
}

P "AUDIT" "fix_probe_bolt_equivalence"
P "VERSION" $version
P "EXISTS *equivalence" [expr {[info commands *equivalence] ne ""}]
P "EXISTS *nodeupdate" [expr {[info commands *nodeupdate] ne ""}]
P "EXISTS *deletemark" [expr {[info commands *deletemark] ne ""}]

# --- Helper: fresh node at (x y z) ----------------------------------------
proc newNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}

# --- Case 1: merge direction (mark1 keeps, mark2 absorbed), coincident ----
set tgt [newNode 1 1 1]
set src [newNode 1 1 1]
*createmark nodes 1 $tgt
*createmark nodes 2 $src
T "EQ_2MARK" {*equivalence 1 2 0.001}
catch {*createmark nodes 1 all}
set after [hm_getmark nodes 1]
set tgtAlive [expr {$tgt in $after}]
set srcAlive [expr {$src in $after}]
P "EQ_2MARK_TGT_ALIVE" $tgtAlive
P "EQ_2MARK_SRC_ALIVE" $srcAlive
P "EQ_2MARK_NODES_TOTAL" [llength $after]

# --- Case 2: node keyword signature ---------------------------------------
set tgt2 [newNode 2 2 2]
set src2 [newNode 2 2 2]
*createmark nodes 1 $tgt2
*createmark nodes 2 $src2
T "EQ_NODE_KW" {*equivalence nodes 1 2 0.001}
catch {*createmark nodes 1 all}
set after2 [hm_getmark nodes 1]
P "EQ_NODE_KW_TGT_ALIVE" [expr {$tgt2 in $after2}]
P "EQ_NODE_KW_SRC_ALIVE" [expr {$src2 in $after2}]

# --- Case 3: tolerance too small -> no merge ------------------------------
set tgt3 [newNode 3 3 3]
set src3 [newNode 3.5 3 3]
*createmark nodes 1 $tgt3
*createmark nodes 2 $src3
T "EQ_FAR_NO_MERGE" {*equivalence 1 2 0.1}
catch {*createmark nodes 1 all}
set after3 [hm_getmark nodes 1]
P "EQ_FAR_NO_MERGE_TGT_ALIVE" [expr {$tgt3 in $after3}]
P "EQ_FAR_NO_MERGE_SRC_ALIVE" [expr {$src3 in $after3}]

# --- Case 4: merge then delete the absorbed node reference ----------------
# After merging, the absorbed node id must no longer exist.
set tgt4 [newNode 4 4 4]
set src4 [newNode 4 4 4]
*createmark nodes 1 $tgt4
*createmark nodes 2 $src4
T "EQ_CASE4" {*equivalence 1 2 0.001}
catch {*createmark nodes 1 $src4}
P "EQ_CASE4_SRC_MARK_LEN" [hm_marklength nodes 1]

close $chan
exit 0
