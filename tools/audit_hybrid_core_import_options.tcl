# Decisive probe: which *feinputwithdata2 option array makes the OptiStruct
# reader assign imported entities to the $HMCOMP ID component?
#
# Variants compared (all with the fem_delta.py-style deck):
#   A. no options                        -> *createstringarray 0 + num_options=0
#   B. production strings (padded)       -> "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
#   C. unpadded production strings       -> "ASSIGNPROP_BYHMCOMMENTS" "ASSIGNPROP_ONELEMS"
#   D. Altair LoadExistingModel list     -> "OptiStruct " " " "ASSIGNPROP_BYHMCOMMENTS"
#   E. Altair HyperXtrude list           -> "HyperXtrude " "Metal_Extrusion " "ANSA " "PATRAN "
#                                           "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP "
#                                           "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "
#                                           "IDRULES_SKIP"
#   F. ASSIGNPROP_BYHMCOMMENTS alone      -> unpadded, single option
#   G. "OptiStruct " alone (source name)  -> padded single option
#
# Also checks GRID placement via export (nodes have no collector query).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version ""
catch {set version [string trim [hm_info -appinfo VERSION]]}
if {$version eq ""} { set version "unknown" }
set fileVersion [regsub -all {[^a-zA-Z0-9]} $version _]
set reportPath [file join $outputDir "audit_hybrid_core_import_options_${fileVersion}.log"]
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
proc exists {name} {
    set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    return [expr {[llength [info commands $pat]] > 0}]
}

P "audit_start" [clock format [clock seconds]]
P "hm_version" $version

set ::auditFem [file join $outputDir audit_import_options_deck.fem]
set channel [open $::auditFem w]
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

proc verifyImport {label} {
    R ${label}_import {*feinputwithdata2 "#optistruct/optistruct" $::auditFem 0 0 0 0 0 1 $::auditNumOptions 1 0}
    catch {*clearmark comps 2}
    R ${label}_comps_mark {*createmark comps 2 all}
    set ids ""
    R ${label}_comps_ids {set ids [hm_getmark comps 2]}
    set names {}
    foreach id $ids {
        set name ""
        catch {set name [hm_getvalue comps id=$id dataname=name]}
        lappend names "$id=$name"
    }
    P "${label}_comp_list" [join $names { | }]
    R ${label}_elem_comp {hm_getvalue elems id=910 dataname=collector.id}
}

# A: no options
wipeModel clean_a
set ::auditNumOptions 0
*createstringarray 0
verifyImport variantA

# B: production padded strings
wipeModel clean_b
set ::auditNumOptions 2
*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
verifyImport variantB

# C: unpadded production strings
wipeModel clean_c
set ::auditNumOptions 2
*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS" "ASSIGNPROP_ONELEMS"
verifyImport variantC

# D: Altair LoadExistingModel list
wipeModel clean_d
set ::auditNumOptions 3
*createstringarray 3 "OptiStruct " " " "ASSIGNPROP_BYHMCOMMENTS"
verifyImport variantD

# E: Altair HyperXtrude list
wipeModel clean_e
set ::auditNumOptions 9
*createstringarray 9 "HyperXtrude " "Metal_Extrusion " "ANSA " "PATRAN " \
    "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " \
    "CONTACTSURF_DISPLAY_SKIP " "IDRULES_SKIP"
verifyImport variantE

# F: unpadded single
wipeModel clean_f
set ::auditNumOptions 1
*createstringarray 1 "ASSIGNPROP_BYHMCOMMENTS"
verifyImport variantF

# G: "OptiStruct " single (source solver name)
wipeModel clean_g
set ::auditNumOptions 1
*createstringarray 1 "OptiStruct "
verifyImport variantG

# H: production padded + unpadded assignment name combined
wipeModel clean_h
set ::auditNumOptions 3
*createstringarray 3 "ASSIGNPROP_BYHMCOMMENTS" "ASSIGNPROP_ONELEMS" "ASSIGNPROP_BYHMCOMMENTS "
verifyImport variantH

P "audit_done" 1
close $::auditChannel
exit 0
