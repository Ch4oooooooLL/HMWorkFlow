# Fourth audit probe for fem_auto_seam: candidate in-place remesh commands
# (*remesh, *remeshelems) and display-command crash isolation in hmbatch.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_alt_cmds.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam4_${version}.log"]
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

# --- Fixture ----------------------------------------------------------------
L "SECTION=fixture"
set compA [FXComp AUDIT4_PLATE_A 1]
set compB [FXComp AUDIT4_PLATE_B 2]
FXSetComp AUDIT4_PLATE_A
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
FXSetComp AUDIT4_PLATE_B
set sliver [FXQuad [list [FXNode 30 0 0] [FXNode 40 0 0] [FXNode 40 0.01 0] [FXNode 30 0.01 0]]]
FXSetComp AUDIT4_PLATE_A
P "FIXTURE_ELEMS" [FXCount elems]

# --- 1. *remesh variants on a 2-quad patch ------------------------------------
L "SECTION=remesh"
set patch [lrange $elemsA 0 1]
foreach variant {
    "remesh 1 4.0"
    "remesh elems 1 4.0"
    "remesh 1 4.0 2"
    "remesh 1"
    "remeshelems 1 4.0"
    "remeshelems 1 4.0 2 2 1 1 2 30"
    "remeshelems elems 1 4.0"
} {
    set totalBefore [FXCount elems]
    set connBefore {}
    foreach eid $patch { dict set connBefore $eid [Conn $eid] }
    catch {*clearmark elements 1}
    eval *createmark elements 1 $patch
    set code [catch {uplevel #0 "eval *$variant"} err]
    P "CMD *$variant ERR" [expr {$code ? $err : "none"}]
    set totalAfter [FXCount elems]
    P "CMD *$variant TOTAL" "$totalBefore->$totalAfter"
    set unchanged 0; set dead 0
    foreach eid $patch {
        if {![Alive $eid]} { incr dead; continue }
        if {[Conn $eid] eq [dict get $connBefore $eid]} { incr unchanged }
    }
    P "CMD *$variant ORIGINAL_DEAD" $dead
    P "CMD *$variant ORIGINAL_UNCHANGED" $unchanged
}

# --- 2. Display command crash isolation (each line flushes) -------------------
L "SECTION=display"
set code [catch {*displaycollectorsallbymark 1 off 1 1} err]
P "DISPLAY_OFF_ERR" [expr {$code ? $err : "none"}]
P "DISPLAY_OFF_DONE" 1
set code [catch {*displaycollectorsallbymark 1 on 1 1} err]
P "DISPLAY_ON_ERR" [expr {$code ? $err : "none"}]
P "DISPLAY_ON_DONE" 1
catch {*clearmark nodes 1}
eval *createmark nodes 1 [list [lindex [hm_getmark nodes 1] 0]]
set code [catch {*numbersmark nodes 1 1} err]
P "NUMBERSMARK_ERR" [expr {$code ? $err : "none"}]
P "NUMBERSMARK_DONE" 1
set code [catch {*numbersclear} err]
P "NUMBERS_CLEAR_ERR" [expr {$code ? $err : "none"}]
P "NUMBERS_CLEAR_DONE" 1
set code [catch {hm_redraw} err]
P "HM_REDRAW_ERR" [expr {$code ? $err : "none"}]
P "HM_REDRAW_DONE" 1
P "HM_VIEWFIT_EXISTS" [expr {[info commands hm_viewfit] ne ""}]
set code [catch {hm_viewfit} err]
P "HM_VIEWFIT_ERR" [expr {$code ? $err : "none"}]
P "HM_VIEWFIT_DONE" 1
set code [catch {*createmarkpanel comps 1 "probe title"} err]
P "CREATEMARKPANEL_ERR" [expr {$code ? $err : "none"}]
P "CREATEMARKPANEL_DONE" 1

L "SECTION=done"
P "PROBE4_COMPLETE" 1
close $channel
exit 0
