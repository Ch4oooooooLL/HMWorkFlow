# Quick check: is there a "delete associated nodes with component" option?
# *deletemark comps deletes the comp and its elements but leaves nodes
# orphaned (verified on 2019). hm_getdeleteassociatedentitiesbycompmark may
# reveal the governing option.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_opt.tcl
#
# Results: runtime/audit_batch_temp_nodes_opt_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_opt_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
    flush $channel
}
proc RAW {key value} {
    P $key [string map [list "\n" { } "\r" { }] $value]
}

# --- O1: usage string of the delete-associated helper ----------------------
set err ""
set val ""
if {[catch {hm_getdeleteassociatedentitiesbycompmark} v]} { set err $v } else { set val $v }
RAW "O1_ASSOC_NOARG_ERR" $err
P "O1_ASSOC_NOARG_VAL" $val

# --- O2: *setoption probe on plausible delete option names -----------------
foreach opt {delete_associated delete_associated_entities delete_elems_attached delete_nodes_attached} {
    set err ""
    set val ""
    if {[catch {*setoption $opt 1} v]} { set err $v } else { set val $v }
    P "O2_SETOPTION_${opt}_ERR" $err
    P "O2_SETOPTION_${opt}_VAL" $val
}

# --- O3: comp delete with the option set (if any accepted) -----------------
# Reuse the D1 scenario to see whether any option made nodes go away.
if {[catch {*collectorcreateonly components AUDIT_BATCH_O3 "" 7} e]} {
    P "O3_COMPCREATE_ERR" $e
}
if {[catch {*currentcollector component AUDIT_BATCH_O3} e]} {
    P "O3_CURCOLL_ERR" $e
}
set n1 ""
catch {*createnode 11 11 11 0 0 0}
set n1 ""
catch {set n1 [hm_latestentityid nodes]}
set n2 ""
catch {*createnode 12 12 12 0 0 0}
set n2 ""
catch {set n2 [hm_latestentityid nodes]}
set cid ""
catch {set cid [hm_entityinfo id comps AUDIT_BATCH_O3 -byname]}
P "O3_COMP_ID" $cid
P "O3_IDS" "$n1 $n2"
catch {*clearmark comps 1}
eval *createmark comps 1 $cid
set o3 ""
if {[catch {*deletemark comps 1} e]} { set o3 $e }
P "O3_DELETE_COMPS_ERR" $o3
set e1 ""
catch {set e1 [hm_getvalue nodes id=$n1 dataname=id]}
set e2 ""
catch {set e2 [hm_getvalue nodes id=$n2 dataname=id]}
P "O3_NODE_N1_EXISTS" $e1
P "O3_NODE_N2_EXISTS" $e2

close $channel
exit 0
