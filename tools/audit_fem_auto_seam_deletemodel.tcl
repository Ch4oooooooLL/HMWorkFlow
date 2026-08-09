# Tenth audit probe for fem_auto_seam: *deletemodel as the complete model
# clear (probe7 showed *deletemark comps leaves orphan nodes that cannot be
# deleted, shifting node IDs on re-import).  If *deletemodel wipes nodes too,
# then *deletemodel + *feinputwithdata2 is a true replace semantics for .fem.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_deletemodel.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam10_${version}.log"]
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
proc AllIds {type} {
    catch {*clearmark $type 1}
    catch {*createmark $type 1 all}
    return [lsort -integer [hm_getmark $type 1]]
}

# --- Fixture ----------------------------------------------------------------
L "SECTION=fixture"
set compA [FXComp AUDIT10_PLATE_A 1]
set compB [FXComp AUDIT10_PLATE_B 2]
FXSetComp AUDIT10_PLATE_A
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
FXSetComp AUDIT10_PLATE_B
set sliver [FXQuad [list [FXNode 30 0 0] [FXNode 40 0 0] [FXNode 40 0.01 0] [FXNode 30 0.01 0]]]
FXSetComp AUDIT10_PLATE_A
set elemIdsBefore [lsort -integer [concat $elemsA [list $sliver]]]
catch {*clearmark nodes 1}; *createmark nodes 1 all
set nodeIdsBefore [lsort -integer [hm_getmark nodes 1]]
P "FIXTURE_ELEMS" [FXCount elems]
P "FIXTURE_NODES" [FXCount nodes]
P "FIXTURE_COMPS" [FXCount comps]
P "ELEM_IDS" [join $elemIdsBefore ,]
P "NODE_IDS" [join $nodeIdsBefore ,]

# --- Export ----------------------------------------------------------------
L "SECTION=export"
set template [file join [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR] feoutput optistruct optistruct]
set femPath [file join $outputDir audit10_model_${version}.fem]
catch {file delete -force $femPath}
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*feoutput_select $template $femPath 1 0 0} err]
P "EXPORT_ERR" [expr {$code ? $err : "none"}]
P "EXPORT_SIZE" [expr {[file isfile $femPath] ? [file size $femPath] : 0}]

# --- *deletemodel variants --------------------------------------------------
L "SECTION=deletemodel"
P "DELETEMODEL_EXISTS" [expr {[llength [info commands *deletemodel]] > 0}]
catch {hm_answernext yes}
set code [catch {*deletemodel} err]
P "DELETEMODEL_ERR" [expr {$code ? $err : "none"}]
P "AFTER_DEL_ELEMS" [FXCount elems]
P "AFTER_DEL_NODES" [FXCount nodes]
P "AFTER_DEL_COMPS" [FXCount comps]
P "AFTER_DEL_PROPS" [FXCount props]

# --- Re-import --------------------------------------------------------------
L "SECTION=import"
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 2 1 0
} err]
P "IMPORT_ERR" [expr {$code ? $err : "none"}]
P "IMPORT_ELEMS" [FXCount elems]
P "IMPORT_NODES" [FXCount nodes]
catch {*clearmark elems 1}; *createmark elems 1 all
set importedElems [lsort -integer [hm_getmark elems 1]]
P "IMPORT_ELEM_IDS" [join $importedElems ,]
P "ELEM_IDS_PRESERVED" [expr {$importedElems eq $elemIdsBefore}]
catch {*clearmark nodes 1}; *createmark nodes 1 all
set importedNodes [lsort -integer [hm_getmark nodes 1]]
P "IMPORT_NODE_IDS" [join $importedNodes ,]
P "NODE_IDS_PRESERVED" [expr {$importedNodes eq $nodeIdsBefore}]
P "ELEM1_CONN" [join [Conn [lindex $elemIdsBefore 0]] ,]

L "SECTION=done"
P "PROBE10_COMPLETE" 1
close $channel
exit 0
