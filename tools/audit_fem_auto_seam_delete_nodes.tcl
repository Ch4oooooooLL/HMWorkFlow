# Eighth audit probe for fem_auto_seam: how to delete nodes in hmbatch.
# Probe7 showed *deletemark comps leaves orphan nodes behind and
# *deletemark nodes 1 all silently keeps them.  Candidates: *deletenodes,
# hm_deletenodes, *deleteunusednodes, order of elems/nodes deletion.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_delete_nodes.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam8_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc L {text} {
    variable channel
    puts $channel "$text"
}
proc FXComp {name color} {
    *collectorcreateonly components $name "" $color
    return [hm_getvalue comps name=$name dataname=id]
}
proc FXSetComp {name} { *currentcollector component $name }
proc FXNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc FXQuad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
proc FXCount {type} {
    catch {*createmark $type 1 all}
    return [llength [hm_getmark $type 1]]
}
proc FXBuild {prefix color} {
    set compId [FXComp ${prefix}_C $color]
    FXSetComp ${prefix}_C
    array set na {}
    foreach x {0 5 10} {
        foreach y {0 5 10} {
            set na($x,$y) [FXNode $x $y 0]
        }
    }
    set elems {}
    foreach x0 {0 5} {
        foreach y0 {0 5} {
            lappend elems [FXQuad [list $na($x0,$y0) $na([expr {$x0+5}],$y0) $na([expr {$x0+5}],[expr {$y0+5}]) $na($x0,[expr {$y0+5}])]]
        }
    }
    return [list $compId $elems]
}

# --- 1. *deleteunusednodes after comp deletion ---------------------------------
L "SECTION=unused"
FXBuild AUDIT8A 1
P "A_NODES" [FXCount nodes]
catch {*createmark comps 1 all}; catch {*deletemark comps 1}
P "A_ELEMS_AFTER_COMP" [FXCount elems]
P "A_NODES_AFTER_COMP" [FXCount nodes]
set code [catch {*deleteunusednodes} err]
P "DELETEUNUSED_0ARG_ERR" [expr {$code ? $err : "none"}]
P "A_NODES_AFTER_UNUSED" [FXCount nodes]

# --- 2. *deletenodes variants on orphan nodes -----------------------------------
L "SECTION=deletenodes"
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*deletenodes 1} err]
P "DELETENODES_1_ERR" [expr {$code ? $err : "none"}]
P "A_NODES_AFTER_DELETENODES" [FXCount nodes]
if {[FXCount nodes]} {
    catch {*clearmark nodes 1}; *createmark nodes 1 all
    set code [catch {hm_deletenodes 1} err]
    P "HM_DELETENODES_1_ERR" [expr {$code ? $err : "none"}]
    P "A_NODES_AFTER_HM_DELETENODES" [FXCount nodes]
}

# --- 3. elems first, then nodes --------------------------------------------------
L "SECTION=elemsfirst"
FXBuild AUDIT8B 2
catch {*createmark elems 1 all}; catch {*deletemark elems 1}
P "B_ELEMS_AFTER_DEL" [FXCount elems]
P "B_NODES_AFTER_DEL" [FXCount nodes]
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*deletemark nodes 1} err]
P "B_DELETEMARK_NODES_ERR" [expr {$code ? $err : "none"}]
P "B_NODES_AFTER_DELETEMARK" [FXCount nodes]
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*deletenodes 1} err]
P "B_DELETENODES_ERR" [expr {$code ? $err : "none"}]
P "B_NODES_AFTER_DELETENODES" [FXCount nodes]

# --- 4. delete nodes while elements still reference them --------------------------
L "SECTION=referenced"
FXBuild AUDIT8C 3
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*deletenodes 1} err]
P "C_DELETENODES_REF_ERR" [expr {$code ? $err : "none"}]
P "C_NODES_AFTER" [FXCount nodes]
P "C_ELEMS_AFTER" [FXCount elems]

L "SECTION=done"
P "PROBE8_COMPLETE" 1
close $channel
exit 0
