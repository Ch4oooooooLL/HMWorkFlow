# HybridCore command audit probe (HM2019 / HM2022 hmbatch).
#
# Verifies every HyperMesh native command used by modules/hybrid_core/tcl/ on
# the real build, checks the *feinputwithdata2 option-array contract used by
# the incremental RIGID import, and benchmarks bulk vs per-id hm_getvalue.
#
# Run (one launch per installed HyperMesh):
#   "C:\Program Files\Altair\2019\hm\bin\win64\hmbatch.exe" -nocommand -nouserprofiledialog -tcl tools/audit_hybrid_core_commands.tcl
#   "D:\Program Files\Altair\hwdesktop\hm\bin\win64\hmbatch.exe"  -nocommand -nouserprofiledialog -tcl tools/audit_hybrid_core_commands.tcl
#
# hmbatch exposes no stdout channel; all results go to
# runtime/audit_hybrid_core_commands_<version>.log as KEY=VALUE (ASCII only).
# Script always exits 0; failures are recorded as ERROR=... lines.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version ""
catch {set version [string trim [hm_info -appinfo VERSION]]}
if {$version eq ""} { set version "unknown" }
set fileVersion [regsub -all {[^a-zA-Z0-9]} $version _]
set reportPath [file join $outputDir "audit_hybrid_core_commands_${fileVersion}.log"]
set ::auditChannel [open $reportPath w]

proc P {key value} {
    variable ::auditChannel
    puts $::auditChannel "${key}=${value}"
    flush $::auditChannel
}

# Run a script, log label=result or label=ERROR:<message> (single line).
proc R {label script} {
    if {[catch {uplevel 1 $script} value options]} {
        set message [string map [list \n { } \r {}] $value]
        P $label "ERROR:$message"
    } else {
        P $label [string map [list \n { } \r {}] $value]
    }
}

proc exists {name} {
    set pat [string map {* {\*} ? {\?} [ {\[} ] {\]} \\ {\\\\}} $name]
    return [expr {[llength [info commands $pat]] > 0}]
}

# *deletemodel prompts "Do you wish to delete the current model?" even in
# batch mode; answer it first (batch_mesher background workers do the same).
proc wipeModel {label} {
    catch {hm_answernext yes}
    R ${label} {*deletemodel}
    catch {hm_answernext all}
}

P "audit_start" [clock format [clock seconds]]
P "hm_version" $version
P "tcl_patchlevel" [info patchlevel]
P "script" [file normalize [info script]]

# ---------------------------------------------------------------------------
# 1. Command existence (hybrid_core surface + candidate alternatives)
# ---------------------------------------------------------------------------
foreach name {
    *clearmark *clearmarkall *createmark *deletemark *movemark
    *createstringarray *createarray *createlist
    *feinputwithdata2 *feoutputwithdata *feinputpreserveincludefiles
    *templatefileset *readfile *deletemodel *displayimporterrors
    *createentity *renameentity *currentcollector *entitypreviewempty
    *collectorcreateonly *createnode *createelement
    hm_getvalue hm_getmark hm_marklength hm_getarrayvalue
    hm_entitymaxid hm_latestentityid hm_entityincollector
    hm_info hm_answernext hm_version hm_blockerrormessages
} {
    P "exists_$name" [expr {[exists $name] ? 1 : 0}]
}

# ---------------------------------------------------------------------------
# 2. Build a small model: 2 components, 9 nodes, 4 quads in comp A
# ---------------------------------------------------------------------------
wipeModel deletemodel_initial
R collectorcreate_a {*collectorcreateonly components audit_comp_a "" 1}
R comp_a_id {hm_getvalue comps name=audit_comp_a dataname=id}
R collectorcreate_b {*collectorcreateonly components audit_comp_b "" 2}
R comp_b_id {hm_getvalue comps name=audit_comp_b dataname=id}
R currentcollector_a {*currentcollector component audit_comp_a}

set nodeIds {}
for {set iy 0} {$iy < 3} {incr iy} {
    for {set ix 0} {$ix < 3} {incr ix} {
        set x [expr {10.0 * $ix}]
        set y [expr {10.0 * $iy}]
        R node_create_${ix}_${iy} {*createnode $x $y 0 0 0 0}
        lappend nodeIds [hm_latestentityid nodes]
    }
}
P "model_node_count" [llength $nodeIds]

set quadIds {}
for {set iy 0} {$iy < 2} {incr iy} {
    for {set ix 0} {$ix < 2} {incr ix} {
        set n0 [lindex $nodeIds [expr {$iy*3+$ix}]]
        set n1 [lindex $nodeIds [expr {$iy*3+$ix+1}]]
        set n2 [lindex $nodeIds [expr {($iy+1)*3+$ix+1}]]
        set n3 [lindex $nodeIds [expr {($iy+1)*3+$ix}]]
        R quad_create_${ix}_${iy} {eval *createlist nodes 1 [list $n0 $n1 $n2 $n3]}
        R quad_elem_${ix}_${iy} {*createelement 104 1 1 1}
        lappend quadIds [hm_latestentityid elems]
    }
}
P "model_elem_count" [llength $quadIds]

# ---------------------------------------------------------------------------
# 3. Mark + getvalue semantics (hm_bulk_reader.tcl / incremental_import.tcl)
# ---------------------------------------------------------------------------
R mark_clearmark_comps {*clearmark comps 2}
R mark_createmark_comps_all {*createmark comps 2 all}
R mark_getmark_comps {hm_getmark comps 2}
R mark_marklength_comps {hm_marklength comps 2}
R mark_clearmark_nodes {*clearmark nodes 2}
R mark_createmark_nodes_ids {eval *createmark nodes 2 $nodeIds}
R mark_getmark_nodes {hm_getmark nodes 2}
R mark_marklength_nodes {hm_marklength nodes 2}

# Bulk coordinate read shape (hm_bulk_reader.tcl core path)
set bulkCoords ""
R bulk_coords_raw {set bulkCoords [hm_getvalue nodes mark=2 dataname=coordinates]}
R bulk_coords_length {llength $bulkCoords}
R bulk_coords_first {lindex $bulkCoords 0}
R bulk_coords_first_is_triple {llength [lindex $bulkCoords 0]}

# Per-id coordinate reads (fallback path)
R coords_by_id {hm_getvalue nodes id=[lindex $nodeIds 0] dataname=coordinates}
R x_by_id {hm_getvalue nodes id=[lindex $nodeIds 0] dataname=x}
R y_by_id {hm_getvalue nodes id=[lindex $nodeIds 0] dataname=y}
R z_by_id {hm_getvalue nodes id=[lindex $nodeIds 0] dataname=z}
R id_by_id {hm_getvalue nodes id=[lindex $nodeIds 0] dataname=id}

# ids= bulk syntax (candidate alternative to mark=)
R bulk_coords_ids_syntax {hm_getvalue nodes ids="$nodeIds" dataname=coordinates}
R bulk_coords_ids_length {llength [hm_getvalue nodes ids="$nodeIds" dataname=coordinates]}

# Element reads used by verifyRigidManifest / organizeRigidManifest
R elem_collector_id {hm_getvalue elems id=[lindex $quadIds 0] dataname=collector.id}
R elem_type {hm_getvalue elems id=[lindex $quadIds 0] dataname=type}
R elem_cardimage {hm_getvalue elems id=[lindex $quadIds 0] dataname=cardimage}
R elem_nodes {hm_getvalue elems id=[lindex $quadIds 0] dataname=nodes}
R elem_bulk_collector_id {hm_getvalue elems mark=2 dataname=collector.id}

# Component reads used by incremental_import.tcl
R comp_name_by_id {hm_getvalue comps id=[hm_getvalue comps name=audit_comp_a dataname=id] dataname=name}
R comp_id_by_name {hm_getvalue comps name=audit_comp_a dataname=id}

# Fallback entity-type names used by existingEntityIds loops must fail cleanly
R invalid_type_elements {hm_getvalue elements id=1 dataname=id}
R invalid_type_components {hm_getvalue components id=1 dataname=name}
R invalid_type_mark {hm_getmark elements 2}

# Empty mark behavior
R empty_mark_clearmark {*clearmark nodes 2}
R empty_mark_getmark {hm_getmark nodes 2}
R empty_mark_getvalue {hm_getvalue nodes mark=2 dataname=coordinates}

# ---------------------------------------------------------------------------
# 4. *movemark (incremental_import.tcl organizeRigidManifest path)
# ---------------------------------------------------------------------------
R movemark_clearmark {*clearmark elems 1}
R movemark_createmark {*createmark elems 1 [lindex $quadIds 2]}
R movemark_call {*movemark elems 1 audit_comp_b}
R movemark_verify {hm_getvalue elems id=[lindex $quadIds 2] dataname=collector.id}
R movemark_bad_name {*movemark elems 1 audit_no_such_comp}

# ---------------------------------------------------------------------------
# 5. ID functions (model_state.tcl maxEntityId / componentEntityCount)
# ---------------------------------------------------------------------------
R entitymaxid_nodes {hm_entitymaxid nodes}
R latestentityid_nodes {hm_latestentityid nodes}
R entitymaxid_elems {hm_entitymaxid elems}
R entitymaxid_comps {hm_entitymaxid comps}
R entityincollector_elems {hm_entityincollector comps [hm_getvalue comps name=audit_comp_a dataname=id] elems 0 0 -byid}
R entityincollector_nodes {hm_entityincollector comps [hm_getvalue comps name=audit_comp_a dataname=id] nodes 0 0 -byid}
R entityincollector_elems_nobyid {hm_entityincollector comps [hm_getvalue comps name=audit_comp_a dataname=id] elems 0 0}

# ---------------------------------------------------------------------------
# 6. *deletemark (cleanupIncrementalEntities / deleteEmptyNewComponents)
# ---------------------------------------------------------------------------
R throwaway_create {*collectorcreateonly components audit_throwaway "" 3}
R throwaway_id {hm_getvalue comps name=audit_throwaway dataname=id}
R deletemark_clearmark {*clearmark comps 2}
R deletemark_createmark {*createmark comps 2 [hm_getvalue comps name=audit_throwaway dataname=id]}
R deletemark_call {*deletemark comps 2}
R deletemark_verify {hm_getvalue comps id=[hm_getvalue comps name=audit_throwaway dataname=id] dataname=id}

# ---------------------------------------------------------------------------
# 7. *createstringarray return value (incremental_import.tcl line 217)
# ---------------------------------------------------------------------------
R createstringarray_call {*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "}
set arrId [*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "]
P "createstringarray_returned_id" $arrId

# ---------------------------------------------------------------------------
# 8. Incremental RIGID FEM import (*feinputwithdata2, the production path)
#    Deck mimics modules/hybrid_core/python/fem_delta.py output exactly.
# ---------------------------------------------------------------------------
set ::auditFemPath [file join $outputDir audit_hybrid_core_incremental.fem]
set channel [open $::auditFemPath w]
puts $channel "\$ HMWF_INCREMENTAL_RIGID_IMPORT_V1"
puts $channel "BEGIN BULK"
puts $channel "\$HMNAME COMP 900 \"audit_rigid_comp\""
puts $channel "\$HMCOMP ID 900"
puts $channel "GRID,901,,10.,10.,0."
puts $channel "GRID,902,,0.,0.,0."
puts $channel "GRID,903,,20.,0.,0."
puts $channel "GRID,904,,0.,20.,0."
puts $channel "RBE2,910,901,123456,902,903,904"
puts $channel "ENDDATA"
puts $channel ""
close $channel
P "fem_incremental_written" [file exists $::auditFemPath]

proc importVerify {label args} {
    # args = the trailing feinputwithdata2 parameters after reader+filename
    R ${label}_import {*feinputwithdata2 "#optistruct/optistruct" $::auditFemPath {*}$args}
    R ${label}_elem_exists {hm_getvalue elems id=910 dataname=id}
    R ${label}_elem_comp {hm_getvalue elems id=910 dataname=collector.id}
    R ${label}_comp_name {hm_getvalue comps id=900 dataname=name}
    R ${label}_node_exists {hm_getvalue nodes id=901 dataname=id}
    R ${label}_node_comp_of_node {hm_getvalue nodes id=901 dataname=collector.id}
    R ${label}_marklength_nodes {hm_marklength nodes 2}
    catch {*clearmark nodes 2}
    R ${label}_total_nodes {*createmark nodes 2 all}
    R ${label}_node_count {hm_marklength nodes 2}
}

wipeModel import_clean_1
# Variant A: hybrid_core's exact call  (0 0 0 0 0 1 2 1 0)
importVerify importA 0 0 0 0 0 1 2 1 0
# Variant B: no option array (numoptions=0)
wipeModel import_clean_2
importVerify importB 0 0 0 0 0 1 0 1 0
# Variant C: explicit array id returned by *createstringarray
wipeModel import_clean_3
importVerify importC 0 0 0 0 0 1 2 1 $arrId
# Variant D: template set first (batch_mesher style) + hybrid_core args
wipeModel import_clean_4
R importD_template {*templatefileset [file join [string trim [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]] feoutput optistruct optistruct]}
importVerify importD 0 0 0 0 0 1 2 1 0

# ---------------------------------------------------------------------------
# 9. ASSIGNPROP option strings: padded vs unpadded vs none (property deck)
# ---------------------------------------------------------------------------
set ::auditPropFem [file join $outputDir audit_hybrid_core_prop.fem]
set channel [open $::auditPropFem w]
puts $channel "BEGIN BULK"
puts $channel "\$HMNAME COMP 700 \"audit_prop_comp\""
puts $channel "\$HMCOMP ID 700"
puts $channel "GRID,701,,0.,0.,0."
puts $channel "GRID,702,,10.,0.,0."
puts $channel "GRID,703,,10.,10.,0."
puts $channel "GRID,704,,0.,10.,0."
puts $channel "PSHELL,710,1,1."
puts $channel "\$HMNAME PROP 710 \"audit_prop\""
puts $channel "CQUAD4,720,0,701,702,703,704"
puts $channel "ENDDATA"
puts $channel ""
close $channel

proc propVerify {label args} {
    R ${label}_import {*feinputwithdata2 "#optistruct/optistruct" $::auditPropFem {*}$args}
    R ${label}_elem_exists {hm_getvalue elems id=720 dataname=id}
    R ${label}_elem_prop {hm_getvalue elems id=720 dataname=prop.id}
    R ${label}_elem_comp {hm_getvalue elems id=720 dataname=collector.id}
    R ${label}_prop_exists {hm_getvalue props id=710 dataname=id}
    catch {*clearmark props 2}
    R ${label}_prop_count {*createmark props 2 all}
    R ${label}_prop_count2 {hm_marklength props 2}
}

wipeModel prop_clean_1
*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
propVerify propPadded 0 0 0 0 0 1 2 1 0
wipeModel prop_clean_2
*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS" "ASSIGNPROP_ONELEMS"
propVerify propUnpadded 0 0 0 0 0 1 2 1 0
wipeModel prop_clean_3
propVerify propNoOptions 0 0 0 0 0 1 0 1 0

# ---------------------------------------------------------------------------
# 10. Bulk read benchmark: 3000 GRIDs, bulk mark read vs per-id loop
# ---------------------------------------------------------------------------
set bulkFem [file join $outputDir audit_hybrid_core_bulk.fem]
set channel [open $bulkFem w]
puts $channel "BEGIN BULK"
for {set i 1001} {$i <= 4000} {incr i} {
    puts $channel "GRID,$i,,[expr {($i-1000)%100}],[expr {($i-1000)/100}],0."
}
puts $channel "ENDDATA"
puts $channel ""
close $channel
wipeModel bulk_clean
R bulk_import {*feinputwithdata2 "#optistruct/optistruct" $bulkFem 0 0 0 0 0 1 0 1 0}
catch {*clearmark nodes 2}
R bulk_mark_all {*createmark nodes 2 all}
R bulk_mark_count {hm_marklength nodes 2}
set markIds ""
R bulk_getmark_ids {set markIds [hm_getmark nodes 2]}
P "bulk_getmark_count" [llength $markIds]
set t0 [clock milliseconds]
R bulk_bulk_read {set bc [hm_getvalue nodes mark=2 dataname=coordinates]}
set t1 [clock milliseconds]
set perIdCount 0
foreach id $markIds {
    set c [hm_getvalue nodes id=$id dataname=coordinates]
    incr perIdCount
}
set t2 [clock milliseconds]
P "bench_bulk_ms" [expr {$t1 - $t0}]
P "bench_perid_ms" [expr {$t2 - $t1}]
P "bench_perid_count" $perIdCount
P "bench_bulk_shape" [llength $bc]

# ---------------------------------------------------------------------------
# 11. Export round trip (*templatefileset + *feoutputwithdata), the suggested
#     alternative for full-model writes
# ---------------------------------------------------------------------------
set templatesDir ""
catch {set templatesDir [string trim [hm_info -appinfo SPECIFIEDPATH TEMPLATES_DIR]]}
set template [file join $templatesDir feoutput optistruct optistruct]
P "template_path" $template
P "template_exists" [expr {[file exists $template] ? 1 : 0}]
if {[file exists $template]} {
    wipeModel export_clean
    R export_build_comp {*collectorcreateonly components audit_export "" 4}
    R export_current {*currentcollector component audit_export}
    for {set i 1} {$i <= 4} {incr i} {
        R export_node_$i {*createnode [expr {10*($i%2)}] [expr {10*($i/2)}] 0 0 0 0}
    }
    set en [hm_latestentityid nodes]
    set enodes [list [expr {$en-3}] [expr {$en-2}] [expr {$en-1}] $en]
    R export_list {eval *createlist nodes 1 $enodes}
    R export_elem {*createelement 104 1 1 1}
    R export_template {*templatefileset $template}
    set exportPath [file join $outputDir audit_hybrid_core_export.fem]
    R export_fem {*feoutputwithdata $template $exportPath 0 0 1 1 0}
    P "export_file_exists" [expr {[file exists $exportPath] ? 1 : 0}]
    P "export_file_size" [expr {[file exists $exportPath] ? [file size $exportPath] : 0}]
}

# ---------------------------------------------------------------------------
# 12. *createentity / *renameentity quick functional checks (candidates)
# ---------------------------------------------------------------------------
R createentity_named {*createentity comps name=audit_created_comp}
R createentity_named_id {hm_getvalue comps name=audit_created_comp dataname=id}
R createentity_cardimage {*createentity comps cardimage=components name=audit_created_comp2}
R renameentity_try {*renameentity comps [hm_getvalue comps name=audit_created_comp dataname=id] audit_renamed_comp}
R renameentity_verify {hm_getvalue comps name=audit_renamed_comp dataname=id}

P "audit_done" 1
close $::auditChannel
catch {close $channel}
exit 0
