# Audit probe: the incremental FEM import path used by
# HybridCore::importRigidDelta (*createstringarray + *feinputwithdata2 with
# ASSIGNPROP options) and the solver-id lookup chain used by
# RB2W::resolveUnusedRBE2InternalIds.  Starts from an EMPTY model and imports
# the comma-format OptiStruct deck (solver ids 901..910 != internal ids) that
# the module pipeline produces.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_shell_washer_hole_rbe2_import.tcl
# Result: runtime/audit_washer_import_<version>.log
set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_washer_import_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
proc T {key script} {
    if {[catch {uplevel 1 $script} value options]} {
        P $key "ERROR: [string map {\n { } \r { }} $value]"
    } else {
        P $key [string trim $value]
    }
}

set femPath [file join $root runtime audit_hybrid_core_incremental.fem]
if {![file isfile $femPath]} {
    set deck {
BEGIN BULK
GRID,901,,10.,10.,0.
GRID,902,,0.,0.,0.
GRID,903,,20.,0.,0.
GRID,904,,0.,20.,0.
RBE2,910,901,123456,902,903,904
ENDDATA
}
    set fh [open $femPath w]
    puts $fh $deck
    close $fh
}

P "VERSION" $version
P "DECK_EXISTS" [file isfile $femPath]
T "CREATESTRINGARRAY_ASSIGNPROP" {*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "}
T "FEINPUTWITHDATA2" {*feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 2 1 0}

catch {*clearmark elems 1}
*createmark elems 1 all
set importedElems [hm_getmark elems 1]
catch {*clearmark nodes 1}
*createmark nodes 1 all
set importedNodes [hm_getmark nodes 1]
P "IMPORTED_ELEMS" [join [lsort -integer $importedElems] {,}]
P "IMPORTED_NODES" [join [lsort -integer $importedNodes] {,}]

set rbe2Count 0; set rbe2Id 0
foreach eid $importedElems {
    if {![catch {set cfg [hm_getvalue elems id=$eid dataname=config]}] && [string trim $cfg] eq "55"} { incr rbe2Count; set rbe2Id $eid }
}
P "IMPORTED_RBE2_COUNT" $rbe2Count
P "IMPORTED_RBE2_ID" $rbe2Id

# ---- solver-id lookup chain on the imported (non-contiguous) model ---------
T "GETIDPOOLS_ELEMS" {hm_getidpools elems name}
T "GETIDPOOLS_ELEMENTS" {hm_getidpools elements name}
set pools {}
catch {set pools [hm_getidpools elems name]}
if {[llength $pools] == 0} { catch {set pools [hm_getidpools elements name]} }
P "POOL_COUNT" [llength $pools]
foreach pool $pools {
    T "GETINTERNALID $pool 910" {hm_getinternalid $pool 910 -bypoolname}
}
T "GETSOLVERID_RBE2_BYID" {hm_getsolverid elems $rbe2Id -byid}
if {[llength $importedElems] > 0} {
    T "GETSOLVERID_SHELL_BYID" {hm_getsolverid elems [lindex $importedElems 0] -byid}
}

# ---- datanames on the imported RBE2 ----------------------------------------
if {$rbe2Id != 0} {
    T "IMPORTED_RBE2_COLLECTOR" {hm_getvalue elems id=$rbe2Id dataname=collector.id}
    T "IMPORTED_RBE2_CONFIG" {hm_getvalue elems id=$rbe2Id dataname=config}
    T "IMPORTED_RBE2_INDEP" {hm_getvalue elems id=$rbe2Id dataname=independentnode.id}
    T "IMPORTED_RBE2_DEPS" {hm_getvalue elems id=$rbe2Id dataname=dependentnodes}
    T "IMPORTED_RBE2_CARDIMAGE" {hm_getvalue elems id=$rbe2Id dataname=cardimage}
    T "IMPORTED_RBE2_DEPMAX" {hm_getvalue elems id=$rbe2Id dataname=dependentnodesmax}
}
catch {*clearmark comps 1}
*createmark comps 1 all
P "IMPORTED_COMPS" [join [hm_getmark comps 1] {,}]
catch {*clearmark comps 1}

close $channel
exit 0
