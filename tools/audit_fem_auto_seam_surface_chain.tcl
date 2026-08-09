# Fifth audit probe for fem_auto_seam: validate a REPLACE-semantics remesh
# chain built from official Altair commands:
#   delete patch elements -> *edgestosurface (free edges to surfaces)
#   -> *interactiveremeshsurf (official) -> *set_meshfaceparams + *automesh
#   -> *storemeshtodatabase -> delete temp surfaces
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_surface_chain.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam5_${version}.log"]
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
proc Conn {elementId} {
    set nodes ""
    catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]}
    return [lsort -integer $nodes]
}
proc Alive {elementId} {
    catch {*clearmark elems 1}
    eval *createmark elems 1 [list $elementId]
    return [llength [hm_getmark elems 1]]
}

# --- Fixture: comp A 4 quads (5x5), sliver in comp B --------------------------
L "SECTION=fixture"
set compA [FXComp AUDIT5_PLATE_A 1]
set compB [FXComp AUDIT5_PLATE_B 2]
FXSetComp AUDIT5_PLATE_A
array set na {}
foreach x {0 5 10} {
    foreach y {0 5 10} {
        set na($x,$y) [FXNode $x $y 0]
    }
}
set elemsA {}
foreach x0 {0 5} {
    foreach y0 {0 5} {
        lappend elemsA [FXQuad [list $na($x0,$y0) $na([expr {$x0+5}],$y0) $na([expr {$x0+5}],[expr {$y0+5}]) $na($x0,[expr {$y0+5}])]]
    }
}
FXSetComp AUDIT5_PLATE_B
set sliver [FXQuad [list [FXNode 30 0 0] [FXNode 40 0 0] [FXNode 40 0.01 0] [FXNode 30 0.01 0]]]
FXSetComp AUDIT5_PLATE_A
set connBefore {}
foreach eid $elemsA { dict set connBefore $eid [Conn $eid] }
P "FIXTURE_ELEMS" [FXCount elems]

# --- 1. Delete patch, then surface-from-edges ---------------------------------
L "SECTION=chain"
catch {*clearmark elems 1}
eval *createmark elems 1 $elemsA
set code [catch {*deletemark elems 1} err]
P "DELETE_PATCH_ERR" [expr {$code ? $err : "none"}]
P "AFTER_DELETE_ELEMS" [FXCount elems]
P "PATCH_DEAD" [expr {![Alive [lindex $elemsA 0]]}]
# free edges of the hole -> mark by free edges
catch {*clearmark edges 1}
set code [catch {*createmark edges 1 "by free edges"} err]
P "MARK_FREE_EDGES_ERR" [expr {$code ? $err : "none"}]
P "FREE_EDGES_COUNT" [llength [hm_getmark edges 1]]
# try *edgestosurface signatures
set code [catch {*edgestosurface} err]
P "EDGESTOSURFACE_0ARG_ERR" [expr {$code ? $err : "none"}]
set surfCount [FXCount surfaces]
P "SURFACES_AFTER_0ARG" $surfCount
if {!$surfCount} {
    catch {*clearmark edges 1}
    *createmark edges 1 "by free edges"
    set code [catch {*edgestosurface 1} err]
    P "EDGESTOSURFACE_1ARG_ERR" [expr {$code ? $err : "none"}]
    set surfCount [FXCount surfaces]
    P "SURFACES_AFTER_1ARG" $surfCount
}

# --- 2. Official surface remesh chain ------------------------------------------
L "SECTION=remesh"
set faces 0
if {$surfCount} {
    catch {*clearmark surfaces 1}
    *createmark surfaces 1 all
    set code [catch {*interactiveremeshsurf 1 4.0 2 2 2 1 1} err]
    P "INTERACTIVEREMESHSURF_ERR" [expr {$code ? $err : "none"}]
    for {set faceIndex 0} {$faceIndex < 20} {incr faceIndex} {
        if {[catch {*set_meshfaceparams $faceIndex 2 2 0 0 1 0.5 1 1}]} { if {$faces > 0} { break }; continue }
        if {[catch {*automesh $faceIndex 2 2}]} { if {$faces == 0} { break } } else { incr faces }
    }
    P "SURF_FACES_MESHED" $faces
    set code [catch {*storemeshtodatabase 1} err]
    P "SURF_STORE_ERR" [expr {$code ? $err : "none"}]
    catch {*ameshclearsurface}
    P "TOTAL_AFTER_STORE" [FXCount elems]
    # clean up the temp surfaces
    catch {*clearmark surfaces 1}
    *createmark surfaces 1 all
    set code [catch {*deletemark surfaces 1} err]
    P "DELETE_SURFACES_ERR" [expr {$code ? $err : "none"}]
    P "SURFACES_REMAIN" [FXCount surfaces]
}
P "ORIGINAL_A_DEAD" [expr {![Alive [lindex $elemsA 0]]}]
P "SLIVER_ALIVE" [Alive $sliver]
P "FINAL_ELEMS" [FXCount elems]

L "SECTION=done"
P "PROBE5_COMPLETE" 1
close $channel
exit 0
