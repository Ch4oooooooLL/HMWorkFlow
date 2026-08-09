# Seventh audit probe for fem_auto_seam: verify a working "File > Open"
# replacement for .fem files (*readfile silently loads an empty model).
# Sequence under test:
#   export fem (module's own optistruct template) -> delete all comps+nodes
#   -> *feinputwithdata2 import -> compare entity IDs with pre-clear state.
# Also probes *storemeshtodatabase 0 vs 1 and *elementupdate directly.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_replace_fem.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam7_${version}.log"]
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
proc Alive {type elementId} {
    catch {*clearmark $type 1}
    eval *createmark $type 1 [list $elementId]
    return [llength [hm_getmark $type 1]]
}

# --- Fixture: comp A 4 quads (5x5), sliver in comp B ---------------------------
L "SECTION=fixture"
set compA [FXComp AUDIT7_PLATE_A 1]
set compB [FXComp AUDIT7_PLATE_B 2]
FXSetComp AUDIT7_PLATE_A
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
FXSetComp AUDIT7_PLATE_B
set sliver [FXQuad [list [FXNode 30 0 0] [FXNode 40 0 0] [FXNode 40 0.01 0] [FXNode 30 0.01 0]]]
FXSetComp AUDIT7_PLATE_A
set elemIdsBefore [lsort -integer [concat $elemsA [list $sliver]]]
catch {*clearmark nodes 1}; *createmark nodes 1 all
set nodeIdsBefore [lsort -integer [hm_getmark nodes 1]]
P "FIXTURE_ELEMS" [FXCount elems]
P "FIXTURE_NODES" [FXCount nodes]
P "ELEM_IDS_BEFORE" [join $elemIdsBefore ,]
P "NODE_IDS_BEFORE" [join $nodeIdsBefore ,]

# --- 1. Export fem with the module's own template ------------------------------
L "SECTION=export"
set template [file join [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR] feoutput optistruct optistruct]
set femPath [file join $outputDir audit7_model_${version}.fem]
catch {file delete -force $femPath}
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*feoutput_select $template $femPath 1 0 0} err]
P "EXPORT_ERR" [expr {$code ? $err : "none"}]
P "EXPORT_SIZE" [expr {[file isfile $femPath] ? [file size $femPath] : 0}]

# --- 2. Clear the model (File>Open semantics for non-hm files) -----------------
L "SECTION=clear"
catch {*clearmark comps 1}; *createmark comps 1 all
catch {*deletemark comps 1}
P "AFTER_DEL_COMP_ELEMS" [FXCount elems]
P "AFTER_DEL_COMP_NODES" [FXCount nodes]
P "AFTER_DEL_COMP_COMPS" [FXCount comps]
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*deletemark nodes 1} err]
P "DELETE_NODES_ERR" [expr {$code ? $err : "none"}]
P "AFTER_DEL_NODES" [FXCount nodes]
P "AFTER_DEL_NODES_COMPS" [FXCount comps]

# --- 3. Re-import the exported fem ----------------------------------------------
L "SECTION=import"
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 2 1 0
} err]
P "IMPORT_ERR" [expr {$code ? $err : "none"}]
P "IMPORT_ELEMS" [FXCount elems]
P "IMPORT_COMPS" [FXCount comps]
catch {*clearmark elems 1}; *createmark elems 1 all
set importedElems [lsort -integer [hm_getmark elems 1]]
P "IMPORT_ELEM_IDS" [join $importedElems ,]
P "ELEM_IDS_PRESERVED" [expr {$importedElems eq $elemIdsBefore}]
catch {*clearmark nodes 1}; *createmark nodes 1 all
set importedNodes [lsort -integer [hm_getmark nodes 1]]
P "IMPORT_NODE_IDS" [join $importedNodes ,]
P "NODE_IDS_PRESERVED" [expr {$importedNodes eq $nodeIdsBefore}]
P "ELEM1_CONN_AFTER" [join [Conn [lindex $elemIdsBefore 0]] ,]
P "SLIVER_ALIVE" [Alive elems $sliver]
set compAExists [catch {*createmark comps 1 "by name" AUDIT7_PLATE_A}]
P "COMP_A_EXISTS_ERR" $compAExists
P "COMP_A_COUNT" [llength [hm_getmark comps 1]]

# --- 4. storemeshtodatabase flag 0 vs 1 on the imported model -------------------
L "SECTION=storeflag"
set patch [lrange $elemIdsBefore 0 1]
catch {*clearmark elements 1}
eval *createmark elements 1 $patch
catch {*featureangleset 30}
catch {*setusefeatures 3}
catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30}
catch {*set_meshfaceparams 0 2 2 0 0 1 0.5 1 1}
catch {*automesh 0 2 2}
set before0 [FXCount elems]
set code [catch {*storemeshtodatabase 0} err]
P "STORE0_ERR" [expr {$code ? $err : "none"}]
P "STORE0_TOTAL" "$before0->[FXCount elems]"
catch {*ameshclearsurface}
catch {*setusefeatures 0}
# flag 1 on the same patch again
catch {*clearmark elements 1}
eval *createmark elements 1 $patch
catch {*featureangleset 30}
catch {*setusefeatures 3}
catch {*interactiveremeshelems 1 4.0 2 2 1 1 2 30}
catch {*set_meshfaceparams 0 2 2 0 0 1 0.5 1 1}
catch {*automesh 0 2 2}
set before1 [FXCount elems]
set code [catch {*storemeshtodatabase 1} err]
P "STORE1_ERR" [expr {$code ? $err : "none"}]
P "STORE1_TOTAL" "$before1->[FXCount elems]"
catch {*ameshclearsurface}
catch {*setusefeatures 0}

# --- 5. *elementupdate direct call ----------------------------------------------
L "SECTION=elementupdate"
catch {*clearmark elems 1}; *createmark elems 1 all
set code [catch {*elementupdate 1} err]
P "ELEMENTUPDATE_ERR" [expr {$code ? $err : "none"}]
P "ELEMENTUPDATE_TOTAL" [FXCount elems]

L "SECTION=done"
P "PROBE7_COMPLETE" 1
close $channel
exit 0
