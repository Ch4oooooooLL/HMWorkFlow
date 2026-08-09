# Audit probe v2: alternative/batch commands for the shell_washer_hole_rbe2
# module - *findedges (official signature *findedges <entity> <markid> [mode]),
# *createelement for rigid config, hm_getvalue mark-based batch reads.
# Every step is caught so a single failure cannot kill the run.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_shell_washer_hole_rbe2_alt.tcl
# Result: runtime/audit_washer_alt_<version>.log
set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_washer_alt_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
proc T {key script} {
    if {[catch {uplevel 1 $script} value options]} {
        P $key "ERROR: [string map {\n { } \r { }} $value]"
    } else {
        P $key [string trim $value]
    }
}

foreach cmd {*findedges *rbe2 *rigids *rigidlink *createelement *equivalence *replace} {
    P "EXISTS $cmd" [expr {[llength [info commands $cmd]] > 0}]
}

proc mknode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
catch {*clearmark comps 1}
*collectorcreateonly components AUDIT_ALT "" 1
*currentcollector component AUDIT_ALT
set n1 [mknode 0 0 0]; set n2 [mknode 10 0 0]; set n3 [mknode 10 10 0]; set n4 [mknode 0 10 0]
catch {*clearmark nodes 1}
eval *createlist nodes 1 [list $n1 $n2 $n3 $n4]
*createelement 104 1 1 1
catch {*clearmark elems 1}
*createmark elems 1 -1
set quad [lindex [hm_getmark elems 1] 0]
P "QUAD_ID" $quad

catch {*clearmark nodes 2}
eval *createmark nodes 2 [list $n1 $n2 $n3]
*rigidlink $n4 2 123456
catch {*clearmark nodes 2}
P "RBE2_ID" [hm_latestentityid elems]

# ---- *findedges with official signature: *findedges elems <mark> <mode> ----
catch {*clearmark elems 1}
*createmark elems 1 all
set elemsBefore [hm_getmark elems 1]
P "FINDEDGES_MODE0" [catch {*findedges elems 1 0}]
catch {*clearmark elems 1}
catch {*clearmark comps 1}
*createmark comps 1 all
P "FINDEDGES_COMP_IDS" [join [hm_getmark comps 1] {,}]
set compNames {}
foreach cid [hm_getmark comps 1] {
    catch {lappend compNames [hm_getcollectorname comps $cid]}
}
P "FINDEDGES_COMP_NAMES" [join $compNames {,}]
catch {*clearmark comps 1}
catch {*clearmark elems 1}
*createmark elems 1 all
set elemsAfter [hm_getmark elems 1]
P "FINDEDGES_NEW_ELEMS" [expr {[llength $elemsAfter] - [llength $elemsBefore]}]
set edgeElems {}
set cfgs {}
foreach eid $elemsAfter {
    if {$eid in $elemsBefore} { continue }
    lappend edgeElems $eid
    catch {set c [hm_getvalue elems id=$eid dataname=config]}
    lappend cfgs [string trim $c]
}
P "FINDEDGES_EDGE_ELEMS" [join $edgeElems {,}]
P "FINDEDGES_EDGE_CONFIGS" [join [lsort -unique $cfgs] {,}]
catch {*clearmark elems 1}

# ---- *createelement with config 55 (RBE2) ----------------------------------
catch {*clearmark nodes 2}
eval *createmark nodes 2 [list $n1 $n2 $n3 $n4]
T "CREATELEMENT_55" {*createelement 55 2 1 1}
catch {*clearmark nodes 2}
catch {*clearmark elems 1}
*createmark elems 1 all
set cfg55 0
foreach eid [hm_getmark elems 1] {
    catch {set c [hm_getvalue elems id=$eid dataname=config]}
    if {[string trim $c] eq "55"} { incr cfg55 }
}
P "CREATELEMENT_55_RBE2_COUNT" $cfg55
catch {*clearmark elems 1}

# ---- hm_getvalue mark-based batch reads ------------------------------------
catch {*clearmark nodes 1}
eval *createmark nodes 1 [list $n1 $n2 $n3 $n4]
T "GETVALUE_NODES_MARK_COORDINATES" {hm_getvalue nodes mark=1 dataname=coordinates}
T "GETVALUE_NODES_MARK_X" {hm_getvalue nodes mark=1 dataname=x}
T "GETVALUE_NODES_MARK_ID" {hm_getvalue nodes mark=1 dataname=id}
catch {*clearmark elems 1}
eval *createmark elems 1 [list $quad]
T "GETVALUE_ELEMS_MARK_NODES" {hm_getvalue elems mark=1 dataname=nodes}
T "GETVALUE_ELEMS_MARK_CONFIG" {hm_getvalue elems mark=1 dataname=config}
catch {*clearmark nodes 1}
catch {*clearmark elems 1}

close $channel
exit 0
