# Follow-up probe: which component do imported entities land in?
#
# importRigidDelta (modules/hybrid_core/tcl/incremental_import.tcl) verifies
# that each imported RBE2's collector.id equals the manifest component_id.
# This probe enumerates the components created by the OptiStruct reader for
# two comment conventions ($HMCOMP ID vs $HMMOVE) and exports the result.
#
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_hybrid_core_import_comps.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe"  -nocommand -nouserprofiledialog -tcl tools/audit_hybrid_core_import_comps.tcl

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version ""
catch {set version [string trim [hm_info -appinfo VERSION]]}
if {$version eq ""} { set version "unknown" }
set fileVersion [regsub -all {[^a-zA-Z0-9]} $version _]
set reportPath [file join $outputDir "audit_hybrid_core_import_comps_${fileVersion}.log"]
set ::auditChannel [open $reportPath w]

proc P {key value} {
    variable ::auditChannel
    puts $::auditChannel "${key}=${value}"
    flush $::auditChannel
}
proc R {label script} {
    if {[catch {uplevel 1 $script} value options]} {
        P $label "ERROR:[string map [list \n { } \r {}] $value]"
    } else {
        P $label [string map [list \n { } \r {}] $value]
    }
}
proc wipeModel {label} {
    catch {hm_answernext yes}
    R ${label} {*deletemodel}
    catch {hm_answernext all}
}

P "audit_start" [clock format [clock seconds]]
P "hm_version" $version

# Enumerate every component: id -> name
proc dumpComps {label} {
    catch {*clearmark comps 2}
    R ${label}_comps_mark {*createmark comps 2 all}
    set ids ""
    R ${label}_comps_ids {set ids [hm_getmark comps 2]}
    P "${label}_comp_count" [llength $ids]
    set names {}
    foreach id $ids {
        set name ""
        catch {set name [hm_getvalue comps id=$id dataname=name]}
        lappend names "$id=$name"
    }
    P "${label}_comp_list" [join $names { | }]
}

proc dumpElems {label} {
    catch {*clearmark elems 2}
    R ${label}_elems_mark {*createmark elems 2 all}
    set ids ""
    R ${label}_elems_ids {set ids [hm_getmark elems 2]}
    P "${label}_elem_count" [llength $ids]
    set rows {}
    foreach id $ids {
        set comp ""
        catch {set comp [hm_getvalue elems id=$id dataname=collector.id]}
        set card ""
        catch {set card [hm_getvalue elems id=$id dataname=type]}
        lappend rows "$id=comp$comp,type$card"
    }
    P "${label}_elem_list" [join $rows { | }]
}

proc dumpProps {label} {
    catch {*clearmark props 2}
    R ${label}_props_mark {*createmark props 2 all}
    set ids ""
    R ${label}_props_ids {set ids [hm_getmark props 2]}
    P "${label}_prop_count" [llength $ids]
    set rows {}
    foreach id $ids {
        set name ""
        catch {set name [hm_getvalue props id=$id dataname=name]}
        lappend rows "$id=$name"
    }
    P "${label}_prop_list" [join $rows { | }]
}

# --- Deck A: $HMCOMP ID convention (exactly what fem_delta.py writes) -----
set femA [file join $outputDir audit_import_comps_a.fem]
set channel [open $femA w]
puts $channel "\$ HMWF_INCREMENTAL_RIGID_IMPORT_V1"
puts $channel "BEGIN BULK"
puts $channel "\$HMNAME COMP 900 \"audit_rigid_comp\""
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,901,,10.,10.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,902,,0.,0.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,903,,20.,0.,0."
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,904,,0.,20.,0."
puts $channel "RBE2,910,901,123456,902,903,904"
puts $channel "ENDDATA"
puts $channel ""
close $channel

# --- Deck B: $HMMOVE convention (as HM's own export writes it) ------------
set femB [file join $outputDir audit_import_comps_b.fem]
set channel [open $femB w]
puts $channel "\$ HMWF_INCREMENTAL_RIGID_IMPORT_V1"
puts $channel "BEGIN BULK"
puts $channel "\$HMNAME COMP 900 \"audit_rigid_comp\""
puts $channel "GRID,901,,10.,10.,0."
puts $channel "GRID,902,,0.,0.,0."
puts $channel "GRID,903,,20.,0.,0."
puts $channel "GRID,904,,0.,20.,0."
puts $channel "RBE2,910,901,123456,902,903,904"
puts $channel "\$HMMOVE 900"
puts $channel "\$ 901"
puts $channel "\$ 902"
puts $channel "\$ 903"
puts $channel "\$ 904"
puts $channel "\$ 910"
puts $channel "ENDDATA"
puts $channel ""
close $channel

# --- Deck C: $HMCOMP ID without $HMNAME first ------------------------------
set femC [file join $outputDir audit_import_comps_c.fem]
set channel [open $femC w]
puts $channel "BEGIN BULK"
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,901,,10.,10.,0."
puts $channel "GRID,902,,0.,0.,0."
puts $channel "GRID,903,,20.,0.,0."
puts $channel "GRID,904,,0.,20.,0."
puts $channel "RBE2,910,901,123456,902,903,904"
puts $channel "ENDDATA"
puts $channel ""
close $channel

wipeModel clean_a
R importA {*feinputwithdata2 "#optistruct/optistruct" $femA 0 0 0 0 0 1 2 1 0}
dumpComps deckA
dumpElems deckA
dumpProps deckA

wipeModel clean_b
R importB {*feinputwithdata2 "#optistruct/optistruct" $femB 0 0 0 0 0 1 2 1 0}
dumpComps deckB
dumpElems deckB

wipeModel clean_c
R importC {*feinputwithdata2 "#optistruct/optistruct" $femC 0 0 0 0 0 1 2 1 0}
dumpComps deckC
dumpElems deckC

# Round-trip: reimport HM's own export of deck B model to see HMMOVE honored
set exportPath [file join $outputDir audit_import_comps_export.fem]
if {[file exists [file join [string trim [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]] feoutput optistruct optistruct]]} {
    R export_template {*templatefileset [file join [string trim [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]] feoutput optistruct optistruct]}
    R export_fem {*feoutputwithdata [file join [string trim [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]] feoutput optistruct optistruct] $exportPath 0 0 1 1 0}
    P "export_exists" [expr {[file exists $exportPath] ? 1 : 0}]
    if {[file exists $exportPath]} {
        set channel [open $exportPath r]
        set text [read $channel]
        close $channel
        set lines [split $text "\n"]
        set hmmoveLines {}
        foreach line $lines {
            if {[string match "\$HMMOVE*" $line] || [string match "\$ *" $line]} {
                lappend hmmoveLines [string trim $line]
            }
        }
        P "export_hmmove" [join $hmmoveLines { | }]
        wipeModel clean_reimport
        R reimport {*feinputwithdata2 "#optistruct/optistruct" $exportPath 0 0 0 0 0 1 2 1 0}
        dumpComps reimport
        dumpElems reimport
    }
}

P "audit_done" 1
close $::auditChannel
exit 0
