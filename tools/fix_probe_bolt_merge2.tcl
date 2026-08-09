# Fix probe 2: find a working node-merge signature for replaceOneNode.
# *equivalence nodes 1 2 <tol> exists but does not merge coincident free
# nodes on either build.  This probe lists every merge/replace/weld command
# and exercises the plausible signatures with real free nodes.
#
# Run once per build:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/fix_probe_bolt_merge2.tcl
# Results: runtime/fix_probe_bolt_merge2_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "fix_probe_bolt_merge2_${version}.log"]
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

P "AUDIT" "fix_probe_bolt_merge2"
P "VERSION" $version

# --- 1. Command surface scan ----------------------------------------------
set mergeish [lsort [info commands *equi*]]
P "CMDS_EQUI" [join $mergeish { }]
set mergeish2 [lsort [info commands *merg*]]
P "CMDS_MERG" [join $mergeish2 { }]
set mergeish3 [lsort [info commands *weld*]]
P "CMDS_WELD" [join $mergeish3 { }]
set mergeish4 [lsort [info commands *replac*]]
P "CMDS_REPLAC" [join $mergeish4 { }]
set mergeish5 [lsort [info commands *nodeupdate*]]
P "CMDS_NODEUPDATE" [join $mergeish5 { }]
set mergeish6 [lsort [info commands *elementupdate*]]
P "CMDS_ELEMUPDATE" [join $mergeish6 { }]
set mergeish7 [lsort [info commands *combine*]]
P "CMDS_COMBINE" [join $mergeish7 { }]

# --- 2. Fixture: coincident free nodes ------------------------------------
proc newNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}

# --- 3. *equivalence extra signatures --------------------------------------
set tgt [newNode 10 10 10]
set src [newNode 10 10 10]
*createmark nodes 1 $tgt
*createmark nodes 2 $src
T "EQ_NO_TOL" {*equivalence nodes 1 2}
catch {*createmark nodes 1 all}
set after [hm_getmark nodes 1]
P "EQ_NO_TOL_SRC_ALIVE" [expr {$src in $after}]
P "EQ_NO_TOL_TOTAL" [llength $after]

set tgt [newNode 11 11 11]
set src [newNode 11 11 11]
*createmark nodes 1 $tgt
*createmark nodes 2 $src
T "EQ_4ARG" {*equivalence nodes 1 2 0.001 1}
catch {*createmark nodes 1 all}
set after [hm_getmark nodes 1]
P "EQ_4ARG_SRC_ALIVE" [expr {$src in $after}]

set tgt [newNode 12 12 12]
set src [newNode 12 12 12]
*createmark nodes 1 $tgt
*createmark nodes 2 $src
T "EQ_SWAPPED" {*equivalence nodes 2 1 0.001}
catch {*createmark nodes 1 all}
set after [hm_getmark nodes 1]
P "EQ_SWAPPED_TGT_ALIVE" [expr {$tgt in $after}]
P "EQ_SWAPPED_SRC_ALIVE" [expr {$src in $after}]

# --- 4. *nodeupdate coordinates (exists both builds) -----------------------
set nu [newNode 13 13 13]
T "NODEUPDATE_XYZ" {*nodeupdate $nu 99 99 99}
catch {*createmark nodes 1 $nu}
set coordErr ""
catch {set nx [hm_getvalue nodes id=$nu dataname=x]}
P "NODEUPDATE_X_AFTER" $nx

# --- 5. *elementupdate node reference (unit test for the real fix) ---------
# Build a rod on (a b), then re-point the rod's node 2 -> c via
# *elementupdate, and delete the freed node.
set na [newNode 20 20 20]
set nb [newNode 21 20 20]
*createmark nodes 1 $na $nb
*createlist nodes 1 $na $nb
*createelement 11 1 1 1
*createmark elems 1 -1
set rod [lindex [hm_getmark elems 1] 0]
P "ROD_ID" $rod
catch {*createmark nodes 1 $na}
P "ROD_NODE_1" [hm_getvalue elems id=$rod dataname=nodes]
set nc [newNode 22 20 20]
catch {*clearmark elems 1}
catch {*createmark elems 1 $rod}
T "ELEMUPDATE_2ARG" {*elementupdate 1 2 $nc}
catch {*createmark elems 1 $rod}
P "ROD_NODES_AFTER" [hm_getvalue elems id=$rod dataname=nodes]

close $chan
exit 0
