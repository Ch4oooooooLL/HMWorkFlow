# Third audit probe for fem_auto_seam: does the batch automesh chain REPLACE
# the selected elements or ADD an overlay mesh?  Decisive test via element
# connectivity before/after.  Also probes chain variants and alternative
# in-place remesh commands.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_remesh.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam3_${version}.log"]
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

# --- Fixture: comp A 4 quads (5x5), comp B 2 quads, sliver in B ---------------
L "SECTION=fixture"
set compA [FXComp AUDIT3_PLATE_A 1]
set compB [FXComp AUDIT3_PLATE_B 2]
FXSetComp AUDIT3_PLATE_A
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
FXSetComp AUDIT3_PLATE_B
array set nb {}
foreach y {0 5 10} {
    foreach z {5 10} {
        set nb($y,$z) [FXNode 20 $y $z]
    }
}
set elemsB {}
foreach y0 {0 5} {
    lappend elemsB [FXQuad [list $nb($y0,5) $nb([expr {$y0+5}],5) $nb([expr {$y0+5}],10) $nb($y0,10)]]
}
set sliver [FXQuad [list [FXNode 30 0 0] [FXNode 40 0 0] [FXNode 40 0.01 0] [FXNode 30 0.01 0]]]
FXSetComp AUDIT3_PLATE_A
set connBefore {}
foreach eid $elemsA { dict set connBefore $eid [Conn $eid] }
P "FIXTURE_ELEMS" [FXCount elems]
P "FIXTURE_A_IDS" [join $elemsA ,]
P "FIXTURE_A_CONN" [join $connBefore {;}]

# --- 1. Module chain on the A patch -------------------------------------------
L "SECTION=modulechain"
catch {*clearmark elements 1}
eval *createmark elements 1 $elemsA
catch {*clearmark nodes 2}
eval *createmark nodes 2 [list $na(10,5) $na(10,10)]
catch {*elementsaddnodesfixed 1 2}
catch {*setedgedensitylinkwithaspectratio -1}
catch {*elementorder 1}
catch {*featureangleset 30}
catch {*setusefeatures 3}
set code [catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30} err]
P "IRM_ERR" [expr {$code ? $err : "none"}]
set faces 0
for {set faceIndex 0} {$faceIndex < 20} {incr faceIndex} {
    if {[catch {*set_meshfaceparams $faceIndex 2 2 0 0 1 0.5 1 1}]} { if {$faces > 0} { break }; continue }
    if {[catch {*automesh $faceIndex 2 2}]} { if {$faces == 0} { break } } else { incr faces }
}
P "FACES_MESHED" $faces
set code [catch {*storemeshtodatabase 1} err]
P "STORE_ERR" [expr {$code ? $err : "none"}]
catch {*ameshclearsurface}
catch {*featureangleset 60}
catch {*setusefeatures 0}
P "TOTAL_AFTER_STORE" [FXCount elems]
set replaced 0; set unchanged 0; set dead 0
foreach eid $elemsA {
    if {![Alive $eid]} { incr dead; continue }
    if {[Conn $eid] eq [dict get $connBefore $eid]} { incr unchanged } else { incr replaced }
}
P "A_ORIGINALS_DEAD" $dead
P "A_ORIGINALS_UNCHANGED_CONN" $unchanged
P "A_ORIGINALS_REPLACED_CONN" $replaced
P "VERDICT_ADD_OR_REPLACE" [expr {$unchanged > 0 ? "ADD_DUPLICATE" : "REPLACE"}]

# --- 2. Chain variant: no manual automesh, store directly ----------------------
L "SECTION=storeonly"
catch {*clearmark elements 1}
eval *createmark elements 1 [lrange $elemsA 0 1]
catch {*setusefeatures 3}
catch {*featureangleset 30}
set code [catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30} err]
P "IRM_ERR" [expr {$code ? $err : "none"}]
set beforeStore [FXCount elems]
set code [catch {*storemeshtodatabase 1} err]
P "STORE_DIRECT_ERR" [expr {$code ? $err : "none"}]
P "TOTAL_BEFORE_STORE_DIRECT" $beforeStore
P "TOTAL_AFTER_STORE_DIRECT" [FXCount elems]
catch {*ameshclearsurface}
catch {*setusefeatures 0}

# --- 3. Arg sensitivity of *interactiveremeshelems -----------------------------
L "SECTION=args"
catch {*clearmark elements 1}
eval *createmark elements 1 [lrange $elemsA 0 0]
set base [FXCount elems]
foreach variant {
    "1 4.0 2 2 1 1 2 30"
    "1 4.0 1 1 1 1 2 30"
    "1 4.0 2 2 2 1 1 30"
    "1 4.0 2 2 2 2 2 30"
} {
    catch {*setusefeatures 3}
    catch {*featureangleset 30}
    set code [catch {eval *interactiveremeshelems $variant} err]
    P "IRM $variant ERR" [expr {$code ? $err : "none"}]
    set faceOk 0
    if {![catch {*set_meshfaceparams 0 2 2 0 0 1 0.5 1 1}]} {
        if {![catch {*automesh 0 2 2}]} { set faceOk 1 }
    }
    P "IRM $variant FACE0_OK" $faceOk
    set code [catch {*storemeshtodatabase 1} err]
    P "IRM $variant STORE_ERR" [expr {$code ? $err : "none"}]
    P "IRM $variant TOTAL" [FXCount elems]
    catch {*ameshclearsurface}
    catch {*setusefeatures 0}
}

# --- 4. Alternative in-place remesh candidates ---------------------------------
L "SECTION=alternatives"
foreach cmd {
    *remsh *remesh *automesh *elementupdate *remeshelems hm_remesh *mesh
} {
    P "EXISTS $cmd" [expr {[info commands $cmd] ne ""}]
}

L "SECTION=done"
P "PROBE3_COMPLETE" 1
close $channel
exit 0
