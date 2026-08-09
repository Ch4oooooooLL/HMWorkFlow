# Audit probe for modules/mesh_seam_weld native HyperMesh commands (part 3):
# FEM export/import used by the FAST_AUTO path (*feoutput_select,
# *feinputwithdata2) and the snapshot save/restore commands.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_feio.tcl
#
# Results: runtime/audit_mesh_seam_weld_feio_<version>.log (ASCII KEY=VALUE)

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_feio_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

P "status" "STARTED"
P "version" $version

namespace eval ::MSWA3 {}
proc ::MSWA3::comp {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    return [hm_getvalue comps name=$name dataname=id]
}
proc ::MSWA3::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc ::MSWA3::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
proc ::MSWA3::nodeCount {} {
    if {[catch {*createmark nodes 1 all} e]} { return "MARK_ERR" }
    set s {}
    catch {set s [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    return [llength $s]
}
proc ::MSWA3::elemCount {} {
    if {[catch {*createmark elems 1 all} e]} { return "MARK_ERR" }
    set s {}
    catch {set s [hm_getmark elems 1]}
    catch {*clearmark elems 1}
    return [llength $s]
}

set compA [::MSWA3::comp MSWA3_A 11]
array set n {}
foreach x {0 10 20} {
    foreach y {0 10 20} {
        set n($x,$y) [::MSWA3::node $x $y 0]
    }
}
foreach x0 {0 10} x1 {10 20} {
    foreach y0 {0 10} y1 {10 20} {
        ::MSWA3::quad [list $n($x0,$y0) $n($x1,$y0) $n($x1,$y1) $n($x0,$y1)]
    }
}
P "FIXTURE_NODES" [::MSWA3::nodeCount]
P "FIXTURE_ELEMS" [::MSWA3::elemCount]

# --- 1. Locate the OptiStruct FEM export template ---------------------------
set templatePath ""
catch {set templatePath [file normalize [file join \
    [hm_info -appinfo EXECUTABLEDIR] .. .. .. templates feoutput optistruct optistruct]]}
P "TEMPLATE_CANDIDATE" $templatePath
P "TEMPLATE_ISFILE" [expr {$templatePath ne "" && [file isfile $templatePath]}]

# --- 2. *writefile / *readfile snapshot roundtrip (clean model, FIRST) ------
set snapPath [file join $outputDir "audit_mesh_seam_weld_snapshot_${version}.hm"]
catch {file delete -force $snapPath}
catch {hm_answernext yes}
if {[catch {*writefile $snapPath 1} wfErr]} {
    P "WRITEFILE_ERROR" $wfErr
} else {
    P "WRITEFILE_OK" 1
    P "WRITEFILE_EXISTS" [file isfile $snapPath]
    P "WRITEFILE_SIZE" [file size $snapPath]
    set marker [::MSWA3::node 77 77 77]
    P "RESTORE_PRE_READ_NODES" [::MSWA3::nodeCount]
    catch {hm_answernext yes}
    if {[catch {*readfile $snapPath 0} rfErr]} {
        P "READFILE_ERROR" $rfErr
    } else {
        P "READFILE_OK" 1
        P "RESTORE_POST_READ_NODES" [::MSWA3::nodeCount]
        set allNodes {}
        catch {*clearmark nodes 1}
        *createmark nodes 1 all
        catch {set allNodes [hm_getmark nodes 1]}
        P "RESTORE_MARKER_GONE" [expr {[lsearch -exact $allNodes $marker] < 0}]
    }
}

# --- 3. *feoutput_select (module's export command) ---------------------------
set outFem [file join $outputDir "audit_mesh_seam_weld_export_${version}.fem"]
catch {file delete -force $outFem}
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
eval *createmark elems 1 [list "by component id"] $compA
eval *createmark nodes 1 [list "by component id"] $compA
P "EXPORT_MARK_ELEMS" [llength [hm_getmark elems 1]]
P "EXPORT_MARK_NODES" [llength [hm_getmark nodes 1]]
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
# elements are in the default component; mark by id instead
set allElemIds {}
catch {*clearmark elems 1}
*createmark elems 1 all
catch {set allElemIds [hm_getmark elems 1]}
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
eval *createmark elems 1 $allElemIds
eval *createmark nodes 1 [list "by elems"] $allElemIds
P "EXPORT_MARK2_ELEMS" [llength [hm_getmark elems 1]]
if {$templatePath eq ""} {
    P "FEOUTPUT_SELECT_SKIPPED" "no template"
} elseif {[catch {*feoutput_select $templatePath $outFem 1 0 0} feErr]} {
    P "FEOUTPUT_SELECT_ERROR" $feErr
} else {
    P "FEOUTPUT_SELECT_OK" 1
    P "FEOUTPUT_FILE_EXISTS" [file isfile $outFem]
    if {[file isfile $outFem]} {
        P "FEOUTPUT_FILE_SIZE" [file size $outFem]
        set gridCount 0
        set quadCount 0
        set chan [open $outFem r]
        while {[gets $chan line] >= 0} {
            if {[string match "GRID*" $line]} { incr gridCount }
            if {[string match "CQUAD4*" $line]} { incr quadCount }
        }
        close $chan
        P "FEOUTPUT_GRID_COUNT" $gridCount
        P "FEOUTPUT_CQUAD4_COUNT" $quadCount
    }
}
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# --- 4. *feoutputwithdata (alternative command) -----------------------------
P "EXISTS feoutputwithdata" [expr {[info commands *feoutputwithdata] ne ""}]
set outFem2 [file join $outputDir "audit_mesh_seam_weld_export2_${version}.fem"]
catch {file delete -force $outFem2}
if {$templatePath ne "" && [info commands *feoutputwithdata] ne ""} {
    catch {*clearmark elems 1}
    eval *createmark elems 1 $allElemIds
    if {[catch {*feoutputwithdata $templatePath $outFem2 1 0 0 0 0 0 0 0 0 0 0} feErr]} {
        P "FEOUTPUTWITHDATA_ERROR" $feErr
    } else {
        P "FEOUTPUTWITHDATA_OK" 1
        P "FEOUTPUTWITHDATA_FILE_EXISTS" [file isfile $outFem2]
        P "FEOUTPUTWITHDATA_SIZE" [file size $outFem2]
    }
    catch {*clearmark elems 1}
}

# --- 5. *feinputwithdata2 with a proper OptiStruct-format delta FEM ---------
# Module exact call: *feinputwithdata2 "#optistruct/optistruct" path 0 0 0 0 0 1 2 1 0
set deltaPath [file join $outputDir "audit_mesh_seam_weld_delta_${version}.fem"]
set chan [open $deltaPath w]
puts $chan "BEGIN BULK"
puts $chan "GRID 9101 0.0 0.0 0.0"
puts $chan "GRID 9102 10.0 0.0 0.0"
puts $chan "GRID 9103 10.0 10.0 0.0"
puts $chan "GRID 9104 0.0 10.0 0.0"
puts $chan "CQUAD4 9201 0 9101 9102 9103 9104"
puts $chan "ENDDATA"
close $chan
P "DELTA_FILE_EXISTS" [file isfile $deltaPath]
P "NODES_BEFORE_IMPORT" [::MSWA3::nodeCount]
P "ELEMS_BEFORE_IMPORT" [::MSWA3::elemCount]
catch {*clearmark nodes 1}
catch {*clearmark elems 1}
if {[catch {*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "} saErr]} {
    P "CREATESTRINGARRAY_ERROR" $saErr
} else {
    P "CREATESTRINGARRAY_OK" 1
}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" $deltaPath 0 0 0 0 0 1 2 1 0} fiErr opts]} {
    P "FEINPUTWITHOUTDATA2_ERROR" $fiErr
    catch {P "FEINPUTWITHOUTDATA2_ERRORINFO" [string range [dict get $opts -errorinfo] 0 500]}
} else {
    P "FEINPUTWITHOUTDATA2_OK" 1
    P "NODES_AFTER_IMPORT" [::MSWA3::nodeCount]
    P "ELEMS_AFTER_IMPORT" [::MSWA3::elemCount]
    set n9101 0
    catch {*clearmark nodes 1}
    if {[catch {*createmark nodes 1 "by id" 9101} mErr]} {
        P "DELTA_MARK_NODE_ERROR" $mErr
    } else {
        set m {}
        catch {set m [hm_getmark nodes 1]}
        P "DELTA_GRID_9101_PRESENT" [expr {[llength $m] > 0}]
    }
    catch {*clearmark elems 1}
    if {[catch {*createmark elems 1 "by id" 9201} mErr]} {
        P "DELTA_MARK_ELEM_ERROR" $mErr
    } else {
        set m {}
        catch {set m [hm_getmark elems 1]}
        P "DELTA_CQUAD4_9201_PRESENT" [expr {[llength $m] > 0}]
    }
}
catch {*clearmark nodes 1}
catch {*clearmark elems 1}

P "status" "DONE"
close $channel
exit 0
