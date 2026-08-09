# Ninth audit probe for fem_auto_seam: does *feinputwithdata2 OVERWRITE
# entities with identical IDs on a non-empty model, or append renumbered
# copies?  Decisive for the "reopen edited .fem" replacement strategy
# (probe7 showed a cleared model keeps orphan nodes so IDs shift).
# Also checks component/property preservation through export->import.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_fem_auto_seam_merge_overwrite.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_fem_auto_seam9_${version}.log"]
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
proc CompNames {} {
    catch {*clearmark comps 1}
    catch {*createmark comps 1 all}
    set names {}
    foreach id [hm_getmark comps 1] {
        set n ""; catch {set n [hm_getvalue comps id=$id dataname=name]}
        lappend names "$id:$n"
    }
    return [join [lsort $names] {;} ]
}

# --- Fixture: comp A 4 quads + property, sliver in comp B ----------------------
L "SECTION=fixture"
set compA [FXComp AUDIT9_PLATE_A 1]
set compB [FXComp AUDIT9_PLATE_B 2]
FXSetComp AUDIT9_PLATE_A
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
FXSetComp AUDIT9_PLATE_B
set sliver [FXQuad [list [FXNode 30 0 0] [FXNode 40 0 0] [FXNode 40 0.01 0] [FXNode 30 0.01 0]]]
FXSetComp AUDIT9_PLATE_A
# property on comp A (card image guess 1; failure tolerated)
catch {*collectorcreateonly properties AUDIT9_PROP_A "" 1}
catch {*clearmark comps 1}
catch {*createmark comps 1 "by name" AUDIT9_PLATE_A}
catch {*propertyupdate components 1 AUDIT9_PROP_A}
P "FIXTURE_ELEMS" [FXCount elems]
P "FIXTURE_NODES" [FXCount nodes]
P "ELEM_IDS" [join [AllIds elems] ,]
P "NODE_IDS" [join [AllIds nodes] ,]
P "COMPS" [CompNames]
P "ELEM1_CONN" [join [Conn [lindex $elemsA 0]] ,]

# --- Export ----------------------------------------------------------------
L "SECTION=export"
set template [file join [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR] feoutput optistruct optistruct]
set femPath [file join $outputDir audit9_model_${version}.fem]
catch {file delete -force $femPath}
catch {*clearmark elems 1}; *createmark elems 1 all
catch {*clearmark nodes 1}; *createmark nodes 1 all
set code [catch {*feoutput_select $template $femPath 1 0 0} err]
P "EXPORT_ERR" [expr {$code ? $err : "none"}]
P "EXPORT_SIZE" [expr {[file isfile $femPath] ? [file size $femPath] : 0}]

# --- Merge import #1 on the non-empty model ---------------------------------
L "SECTION=merge1"
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 2 1 0
} err]
P "IMPORT1_ERR" [expr {$code ? $err : "none"}]
P "IMPORT1_ELEMS" [FXCount elems]
P "IMPORT1_NODES" [FXCount nodes]
P "IMPORT1_ELEM_IDS" [join [AllIds elems] ,]
P "IMPORT1_NODE_IDS" [join [AllIds nodes] ,]
P "IMPORT1_COMPS" [CompNames]
P "IMPORT1_ELEM1_CONN" [join [Conn [lindex $elemsA 0]] ,]

# --- Merge import #2 (second identical import) -------------------------------
L "SECTION=merge2"
set code [catch {
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 2 1 0
} err]
P "IMPORT2_ERR" [expr {$code ? $err : "none"}]
P "IMPORT2_ELEMS" [FXCount elems]
P "IMPORT2_NODES" [FXCount nodes]
P "IMPORT2_ELEM_IDS" [join [AllIds elems] ,]
P "IMPORT2_NODE_IDS" [join [AllIds nodes] ,]

L "SECTION=done"
P "PROBE9_COMPLETE" 1
close $channel
exit 0
