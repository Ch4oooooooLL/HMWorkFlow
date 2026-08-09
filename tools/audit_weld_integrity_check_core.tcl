# Audit probe v2 for weld_integrity_check native HyperMesh commands.
# Round 1 findings: *collectorcreateonly switches the current collector, so
# plate A must be re-selected explicitly; display toggling via
# *displaycollectorsbymark appeared ineffective in hmbatch and needs variant
# probing with two independent queries (displayed selector + hm_collectordisplayed);
# hm_viewfit does not exist on 2019.
#
# Run (repo root):
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_weld_integrity_check_core.tcl
# Results: runtime/audit_weld_integrity_check_<VERSION>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_weld_integrity_check_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    set value [string map {"\n" "\\n"} $value]
    puts $channel "${key}=${value}"
}
proc exists {name} { expr {[info commands $name] ne ""} }

P "VERSION" $version
P "RUNNER" [file tail [info nameofexecutable]]

# --- 1. Command existence -------------------------------------------------
foreach name {
    *clearmark *createmark *createmarkpanel *editmarkpanel
    *displaycollector *displaycollectorsbymark *displaycollectorsallbymark
    *numbersclear *numbersmark *graphuserwindow_byXYZandR *graphuserwindow_to_XYZ
    *feoutput_select *feoutput *feoutputwithdata *feoutputwithtemplate
    hm_getmark hm_getvalue hm_info hm_redraw hm_viewfit hm_answernext
    *displayimporterrors hm_setdisplay *colormark *windowfit hm_fit *viewfit
    *currentcollector *collectorcreateonly *createnode *createlist *createelement
    hm_getdatalist
} {
    P "EXISTS $name" [exists $name]
}
P "FIT_COMMANDS" [join [lsort [info commands *fit*]] { }]
P "VIEW_COMMANDS" [join [lsort [info commands hm_view*]] { }]
P "HM_COLLECTOR_COMMANDS" [join [lsort [info commands hm_collector*]] { }]

# --- 2. Four-comp fixture --------------------------------------------------
# Plates A (z=0) and B (z=10) hold 4 quads each; C and D are empty comps used
# to detect "hide everything not in the mark" semantics.
namespace eval ::Audit {}
proc ::Audit::component {name color} {
    *collectorcreateonly components $name "" $color
    set id [hm_getvalue comps name=$name dataname=id]
    return $id
}
proc ::Audit::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::Audit::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

set compA [::Audit::component PROBE_WIC_A 1]
set compB [::Audit::component PROBE_WIC_B 2]
set compC [::Audit::component PROBE_WIC_C 5]
set compD [::Audit::component PROBE_WIC_D 6]
set matIdA ""; set matIdB ""; set propIdA ""
catch {*collectorcreateonly materials PROBE_MAT_A "" 3}
catch {set matIdA [hm_getvalue mats name=PROBE_MAT_A dataname=id]}
catch {*collectorcreateonly materials PROBE_MAT_B "" 4}
catch {set matIdB [hm_getvalue mats name=PROBE_MAT_B dataname=id]}
catch {*collectorcreateonly properties PROBE_PROP_A "" 3}
catch {set propIdA [hm_getvalue props name=PROBE_PROP_A dataname=id]}
P "FIXTURE_COMP_A" $compA
P "FIXTURE_COMP_B" $compB
P "FIXTURE_COMP_C" $compC
P "FIXTURE_COMP_D" $compD
P "FIXTURE_MAT_A" $matIdA
P "FIXTURE_MAT_B" $matIdB
P "FIXTURE_PROP_A" $propIdA

# plate A: switch back explicitly; *collectorcreateonly moves the current collector
*currentcollector component PROBE_WIC_A
array set na {}
foreach x {0 10 20} { foreach y {0 10 20} { set na($x,$y) [::Audit::node $x $y 0] } }
foreach x0 {0 10} x1 {10 20} { foreach y0 {0 10} y1 {10 20} { ::Audit::quad [list $na($x0,$y0) $na($x1,$y0) $na($x1,$y1) $na($x0,$y1)] } }

*currentcollector component PROBE_WIC_B
array set nb {}
foreach x {0 10 20} { foreach y {0 10 20} { set nb($x,$y) [::Audit::node $x $y 10] } }
foreach x0 {0 10} x1 {10 20} { foreach y0 {0 10} y1 {10 20} { ::Audit::quad [list $nb($x0,$y0) $nb($x1,$y0) $nb($x1,$y1) $nb($x0,$y1)] } }

catch {*clearmark elems 2}
if {![catch {*createmark elems 2 "by comp id" $compA}]} { set elemsA [hm_getmark elems 2] } else { set elemsA {} }
catch {*clearmark elems 2}
if {![catch {*createmark elems 2 "by comp id" $compB}]} { set elemsB [hm_getmark elems 2] } else { set elemsB {} }
P "FIXTURE_ELEMS_A" [llength $elemsA]
P "FIXTURE_ELEMS_B" [llength $elemsB]

# --- 3. *createmark selector spellings ------------------------------------
catch {*clearmark elems 1}
if {[catch {*createmark elems 1 "by component id" $compA} err]} { P "CREATEMARK_ELEMS_BY_COMPONENT_ID" "ERROR $err" } else { P "CREATEMARK_ELEMS_BY_COMPONENT_ID" [llength [hm_getmark elems 1]] }
catch {*clearmark elems 1}
if {[catch {*createmark elems 1 "by comp id" $compA} err]} { P "CREATEMARK_ELEMS_BY_COMP_ID" "ERROR $err" } else { P "CREATEMARK_ELEMS_BY_COMP_ID" [llength [hm_getmark elems 1]] }
catch {*clearmark nodes 1}
if {[catch {*createmark nodes 1 "by component id" $compA} err]} { P "CREATEMARK_NODES_BY_COMPONENT_ID" "ERROR $err" } else { P "CREATEMARK_NODES_BY_COMPONENT_ID" [llength [hm_getmark nodes 1]] }
catch {*clearmark nodes 1}
if {[catch {*createmark nodes 1 "by comp id" $compA} err]} { P "CREATEMARK_NODES_BY_COMP_ID" "ERROR $err" } else { P "CREATEMARK_NODES_BY_COMP_ID" [llength [hm_getmark nodes 1]] }
catch {*clearmark elems 1}
if {[catch {eval *createmark elems 1 [list "by component id"] $compA $compB} err]} { P "CREATEMARK_ELEMS_BY_COMPONENT_ID_MULTI" "ERROR $err" } else { P "CREATEMARK_ELEMS_BY_COMPONENT_ID_MULTI" [llength [hm_getmark elems 1]] }
catch {*clearmark nodes 1}
if {[catch {eval *createmark nodes 1 [list "by component id"] $compA $compB} err]} { P "CREATEMARK_NODES_BY_COMPONENT_ID_MULTI" "ERROR $err" } else { P "CREATEMARK_NODES_BY_COMPONENT_ID_MULTI" [llength [hm_getmark nodes 1]] }
catch {*clearmark comps 2}
if {[catch {*createmark comps 2 displayed} err]} { P "CREATEMARK_COMPS_DISPLAYED" "ERROR $err" } else { P "CREATEMARK_COMPS_DISPLAYED" [llength [hm_getmark comps 2]] }
catch {*clearmark comps 2}
if {[catch {*createmark components 2 displayed} err]} { P "CREATEMARK_COMPONENTS_DISPLAYED" "ERROR $err" } else { P "CREATEMARK_COMPONENTS_DISPLAYED" [llength [hm_getmark comps 2]] }
catch {*clearmark comps 1}
if {[catch {*createmark comps 1 all} err]} { P "CREATEMARK_COMPS_ALL" "ERROR $err" } else { P "CREATEMARK_COMPS_ALL" [llength [hm_getmark comps 1]] }
catch {*clearmark comps 1}
if {[catch {eval *createmark comps 1 [list $compA $compB]} err]} { P "CREATEMARK_COMPS_BAREIDS" "ERROR $err" } else { P "CREATEMARK_COMPS_BAREIDS" [llength [hm_getmark comps 1]] }

# --- 4. Display state queries (two independent methods) ---------------------
proc ::Audit::visibleComps {} {
    catch {*clearmark comps 2}
    set v {}
    if {![catch {*createmark comps 2 displayed}]} { catch {set v [hm_getmark comps 2]} }
    catch {*clearmark comps 2}
    return [lsort -integer $v]
}
proc ::Audit::collectorDisplay {etype id} {
    set d UNKNOWN
    catch {set d [hm_getvalue $etype id=$id dataname=display]}
    return $d
}
proc ::Audit::hmCollectorDisplay {etype id} {
    set d UNKNOWN
    catch {set d [hm_collectordisplayed $etype $id]}
    return $d
}
proc ::Audit::visibleMats {} {
    catch {*clearmark mats 2}
    set v {}
    if {![catch {*createmark mats 2 displayed}]} { catch {set v [hm_getmark mats 2]} }
    catch {*clearmark mats 2}
    return $v
}

P "DISPLAY_INITIAL_COMPS" [join [::Audit::visibleComps] { }]
P "DISPLAY_INITIAL_MATS" [join [lsort -integer [::Audit::visibleMats]] { }]
P "DISPLAY_INITIAL_COMP_A_DISPLAY_DATANAME" [::Audit::collectorDisplay comps $compA]
P "DISPLAY_INITIAL_MAT_A_DISPLAY_DATANAME" [::Audit::collectorDisplay mats $matIdA]
P "DISPLAY_INITIAL_COLLECTORQUERY_COMP_A" [::Audit::hmCollectorDisplay comps $compA]
P "DISPLAY_INITIAL_COLLECTORQUERY_COMP_B" [::Audit::hmCollectorDisplay comps $compB]
P "DISPLAY_INITIAL_COLLECTORQUERY_COMP_C" [::Audit::hmCollectorDisplay comps $compC]
P "DISPLAY_INITIAL_COLLECTORQUERY_MAT_A" [::Audit::hmCollectorDisplay mats $matIdA]
P "DISPLAY_INITIAL_COLLECTORQUERY_PROP_A" [::Audit::hmCollectorDisplay props $propIdA]

# --- 4a. *displaycollectorsbymark variants (mark = {A}) --------------------
proc ::Audit::toggleByMark {args} {
    catch {*clearmark comps 1}
    eval *createmark comps 1 [list $::Audit::compA]
    if {[catch {uplevel 1 [concat *displaycollectorsbymark $args]} err]} { return "ERROR $err" }
    return OK
}
set ::Audit::compA $compA
foreach variant {
    {comps 1 off 1 1}
    {comps 1 0 1 1}
    {comps 1 off}
    {comps 1 0}
} {
    set label [join $variant _]
    P "BYMARK_VARIANT $label" [::Audit::toggleByMark {*}$variant]
    P "BYMARK_AFTER $label COMPS" [join [::Audit::visibleComps] { }]
    P "BYMARK_AFTER $label COLLECTORQ_A" [::Audit::hmCollectorDisplay comps $compA]
    P "BYMARK_AFTER $label COLLECTORQ_B" [::Audit::hmCollectorDisplay comps $compB]
    # restore all on before next variant
    catch {*clearmark comps 1}
    *createmark comps 1 all
    catch {*displaycollectorsbymark comps 1 on 1 1}
    P "BYMARK_RESTORED $label COMPS" [join [::Audit::visibleComps] { }]
}

# --- 4b. *displaycollectorsallbymark variants (mark = {A}) -----------------
proc ::Audit::toggleAllByMark {args} {
    catch {*clearmark comps 1}
    eval *createmark comps 1 [list $::Audit::compA]
    if {[catch {uplevel 1 [concat *displaycollectorsallbymark $args]} err]} { return "ERROR $err" }
    return OK
}
foreach variant {
    {1 off 1 1}
    {1 0 1 1}
    {1 off}
    {1 0}
} {
    set label [join $variant _]
    P "ALLBYMARK_VARIANT $label" [::Audit::toggleAllByMark {*}$variant]
    P "ALLBYMARK_AFTER $label COMPS" [join [::Audit::visibleComps] { }]
    P "ALLBYMARK_AFTER $label COLLECTORQ_A" [::Audit::hmCollectorDisplay comps $compA]
    P "ALLBYMARK_AFTER $label COLLECTORQ_B" [::Audit::hmCollectorDisplay comps $compB]
    P "ALLBYMARK_AFTER $label COLLECTORQ_C" [::Audit::hmCollectorDisplay comps $compC]
    P "ALLBYMARK_AFTER $label COLLECTORQ_MAT_A" [::Audit::hmCollectorDisplay mats $matIdA]
    P "ALLBYMARK_AFTER $label COLLECTORQ_PROP_A" [::Audit::hmCollectorDisplay props $propIdA]
    # restore all on before next variant
    catch {*clearmark comps 1}
    *createmark comps 1 all
    catch {*displaycollectorsallbymark 1 on 1 1}
    P "ALLBYMARK_RESTORED $label COMPS" [join [::Audit::visibleComps] { }]
}

# --- 4c. alternative: *displaycollector by name (workflow_common pattern) --
if {[catch {*displaycollector component off PROBE_WIC_A 1 1} err]} { P "DISPLAYCOLLECTOR_OFF" "ERROR $err" } else { P "DISPLAYCOLLECTOR_OFF" OK }
P "DISPLAYCOLLECTOR_OFF_AFTER_COMPS" [join [::Audit::visibleComps] { }]
P "DISPLAYCOLLECTOR_OFF_AFTER_COLLECTORQ_A" [::Audit::hmCollectorDisplay comps $compA]
if {[catch {*displaycollector component on PROBE_WIC_A 1 1} err]} { P "DISPLAYCOLLECTOR_ON" "ERROR $err" } else { P "DISPLAYCOLLECTOR_ON" OK }
P "DISPLAYCOLLECTOR_ON_AFTER_COMPS" [join [::Audit::visibleComps] { }]

# --- 4d. mats/props display observability and allbymark side effects -------
catch {*clearmark mats 2}
if {[catch {*createmark mats 2 displayed} err]} { P "MATS_DISPLAYED_SELECTOR_INITIAL" "ERROR $err" } else { P "MATS_DISPLAYED_SELECTOR_INITIAL" [join [hm_getmark mats 2] { }] }
catch {*clearmark mats 1}
if {[catch {*createmark mats 1 all} err]} { P "MATS_ALL" "ERROR $err" } else { P "MATS_ALL" [llength [hm_getmark mats 1]] }
catch {*clearmark props 1}
if {[catch {*createmark props 1 all} err]} { P "PROPS_ALL" "ERROR $err" } else { P "PROPS_ALL" [llength [hm_getmark props 1]] }
if {[catch {set dl [hm_getdatalist mats 1]}]} { P "GETDATALIST_MATS" "ERROR" } else { P "GETDATALIST_MATS" [join $dl { }] }
catch {*clearmark mats 1}
if {[catch {*createmark mats 1 all}]} { set matsAll {} } else { set matsAll [hm_getmark mats 1] }
if {[llength $matsAll]} {
    if {[catch {*displaycollectorsbymark mats 1 on 1 1} err]} { P "MATS_BYMARK_ON" "ERROR $err" } else { P "MATS_BYMARK_ON" OK }
    catch {*clearmark mats 2}
    if {[catch {*createmark mats 2 displayed} err]} { P "MATS_DISPLAYED_SELECTOR_AFTER_ON" "ERROR $err" } else { P "MATS_DISPLAYED_SELECTOR_AFTER_ON" [join [hm_getmark mats 2] { }] }
}
# allbymark off with a comps-only mark: do mats get hidden?
catch {*clearmark comps 1}
eval *createmark comps 1 [list $compA]
catch {*displaycollectorsallbymark 1 off 1 1}
catch {*clearmark mats 2}
if {[catch {*createmark mats 2 displayed} err]} { P "MATS_DISPLAYED_AFTER_ALLBYMARK_OFF" "ERROR $err" } else { P "MATS_DISPLAYED_AFTER_ALLBYMARK_OFF" [join [hm_getmark mats 2] { }] }
catch {*clearmark props 2}
if {[catch {*createmark props 2 displayed} err]} { P "PROPS_DISPLAYED_AFTER_ALLBYMARK_OFF" "ERROR $err" } else { P "PROPS_DISPLAYED_AFTER_ALLBYMARK_OFF" [join [hm_getmark props 2] { }] }
# restore: comps all on
catch {*clearmark comps 1}
*createmark comps 1 all
catch {*displaycollectorsallbymark 1 on 1 1}
P "DISPLAY_AFTER_ALLBYMARK_FINAL_RESTORE_COMPS" [join [::Audit::visibleComps] { }]

# --- 4e. hm_collectordisplayed with mark-id argument -----------------------
catch {*clearmark comps 1}
eval *createmark comps 1 [list $compA $compB]
if {[catch {set hmd [hm_collectordisplayed comps 1]} err]} { P "HM_COLLECTORDISPLAYED_MARK" "ERROR $err" } else { P "HM_COLLECTORDISPLAYED_MARK" [join $hmd { }] }

# --- 5. Number labels on valid elements ------------------------------------
catch {*clearmark nodes 1}
eval *createmark nodes 1 [list $na(0,0) $na(20,20)]
if {[catch {*numbersmark nodes 1 1} err]} { P "NUMBERSMARK_NODES_1_1" "ERROR $err" } else { P "NUMBERSMARK_NODES_1_1" OK }
catch {*clearmark elems 1}
eval *createmark elems 1 [list [lindex $elemsA 0] [lindex $elemsA 1]]
if {[catch {*numbersmark elems 1 1} err]} { P "NUMBERSMARK_ELEMS_1_1" "ERROR $err" } else { P "NUMBERSMARK_ELEMS_1_1" OK }
if {[catch {*numbersmark elems 1 0} err]} { P "NUMBERSMARK_ELEMS_1_0" "ERROR $err" } else { P "NUMBERSMARK_ELEMS_1_0" OK }
if {[catch {*numbersclear} err]} { P "NUMBERS_CLEAR" "ERROR $err" } else { P "NUMBERS_CLEAR" OK }

# --- 6. Graphics window / view ---------------------------------------------
if {[catch {*graphuserwindow_byXYZandR 10 10 5 40} err]} { P "GRAPHUSERWINDOW_BYXYZANDR" "ERROR $err" } else { P "GRAPHUSERWINDOW_BYXYZANDR" OK }
if {[catch {hm_viewfit} err]} { P "HM_VIEWFIT" "ERROR $err" } else { P "HM_VIEWFIT" OK }
if {[exists *viewfit]} {
    if {[catch {*viewfit} err]} { P "STAR_VIEWFIT" "ERROR $err" } else { P "STAR_VIEWFIT" OK }
} else { P "STAR_VIEWFIT" "NOT-EXISTS" }
if {[catch {hm_redraw} err]} { P "HM_REDRAW" "ERROR $err" } else { P "HM_REDRAW" OK }
if {[catch {hm_answernext yes} err]} { P "HM_ANSWER_NEXT" "ERROR $err" } else { P "HM_ANSWER_NEXT" OK }

# --- 7. hm_getvalue / hm_info ----------------------------------------------
if {[catch {set nm [hm_getvalue comps id=$compA dataname=name]}]} { P "GETVALUE_COMP_NAME" "ERROR" } else { P "GETVALUE_COMP_NAME" $nm }
if {[catch {set nx [hm_getvalue nodes id=$na(0,0) dataname=x]}]} { P "GETVALUE_NODE_X" "ERROR" } else { P "GETVALUE_NODE_X" $nx }
set tplDir ""
catch {set tplDir [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]}
set exeDir ""
catch {set exeDir [hm_info -appinfo EXECUTABLEDIR]}
P "HM_INFO_TEMPLATES_DIR" $tplDir
P "HM_INFO_EXECUTABLEDIR" $exeDir
set tpl1 [file join $tplDir feoutput optistruct optistruct]
set tpl2 [file join $exeDir .. .. .. templates feoutput optistruct optistruct]
P "TEMPLATE_EXISTS_DIR1" [file exists $tpl1]
P "TEMPLATE_EXISTS_DIR2" [file exists $tpl2]
set templatePath ""
if {[file isfile $tpl1]} { set templatePath $tpl1 } elseif {[file isfile $tpl2]} { set templatePath $tpl2 }

# --- 8. Full export pipeline (mirrors exporter.tcl) ------------------------
set outPath [file join $outputDir "audit_wic_export_${version}.fem"]
catch {*clearmark elems 1}; catch {*clearmark nodes 1}
if {$templatePath eq ""} {
    P "FEOUTPUT_SELECT" "ERROR no-template-found"
} elseif {[catch {
    eval *createmark elems 1 [list "by component id"] $compA $compB
    eval *createmark nodes 1 [list "by component id"] $compA $compB
    hm_answernext yes
    *feoutput_select $templatePath $outPath 1 0 0
} err]} {
    P "FEOUTPUT_SELECT" "ERROR $err"
} else {
    P "FEOUTPUT_SELECT" OK
    P "FEOUTPUT_FILE_EXISTS" [file exists $outPath]
    if {[file isfile $outPath]} {
        P "FEOUTPUT_FILE_SIZE" [file size $outPath]
        set fh [open $outPath r]
        set content [read $fh]
        close $fh
        set grid 0; set quad 0; set tria 0
        foreach line [split $content "\n"] {
            if {[string match "GRID*" $line]} { incr grid }
            if {[string match "CQUAD4*" $line]} { incr quad }
            if {[string match "CTRIA3*" $line]} { incr tria }
        }
        P "FEOUTPUT_GRID_COUNT" $grid
        P "FEOUTPUT_CQUAD4_COUNT" $quad
        P "FEOUTPUT_CTRIA3_COUNT" $tria
    }
}

close $channel
exit 0
