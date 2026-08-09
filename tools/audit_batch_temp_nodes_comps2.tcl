# Corrected component-deletion test: mark the component by id first, then
# *deletemark comps. Does deleting a component delete its contained nodes?
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_comps2.tcl
#
# Results: runtime/audit_batch_temp_nodes_comps2_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_comps2_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
    flush $channel
}
proc RAW {key value} {
    P $key [string map [list "\n" { } "\r" { }] $value]
}
proc newNode {x y z} {
    catch {*createnode $x $y $z 0 0 0}
    set id ""
    catch {set id [hm_latestentityid nodes]}
    return $id
}
proc nodeExists {id} {
    set v ""
    catch {set v [hm_getvalue nodes id=$id dataname=id]}
    return $v
}
proc nodeCount {} {
    catch {*clearmark nodes 3}
    *createmark nodes 3 all
    return [llength [hm_getmark nodes 3]]
}
proc compId {name} {
    set id ""
    catch {set id [hm_entityinfo id comps $name -byname]}
    return $id
}
proc markComps {markId ids} {
    catch {*clearmark comps $markId}
    eval [linsert $ids 0 *createmark comps $markId]
}

# --- D1: comp with 2 free nodes --------------------------------------------
set d1e ""
if {[catch {*collectorcreateonly components AUDIT_BATCH_D1 "" 5} e]} { set d1e $e }
P "D1_COMPCREATE_ERR" $d1e
if {[catch {*currentcollector component AUDIT_BATCH_D1} e]} {
    P "D1_CURCOLL_ERR" $e
}
set n1 [newNode 1 1 1]
set n2 [newNode 2 2 2]
P "D1_IDS" "$n1 $n2"
P "D1_COUNT_BEFORE" [nodeCount]
set cid [compId AUDIT_BATCH_D1]
P "D1_COMP_ID" $cid
markComps 1 [list $cid]
set d1 ""
if {[catch {*deletemark comps 1} e]} { set d1 $e }
P "D1_DELETE_COMPS_ERR" $d1
P "D1_COUNT_AFTER" [nodeCount]
P "D1_NODE_N1_EXISTS" [nodeExists $n1]
P "D1_NODE_N2_EXISTS" [nodeExists $n2]
catch {*clearmark comps 1}
*createmark comps 1 all
P "D1_COMPS_REMAINING" [join [hm_getmark comps 1] { }]

# --- D2: comp with nodes + element -----------------------------------------
if {[catch {*collectorcreateonly components AUDIT_BATCH_D2 "" 6} e]} {
    P "D2_COMPCREATE_ERR" $e
}
if {[catch {*currentcollector component AUDIT_BATCH_D2} e]} {
    P "D2_CURCOLL_ERR" $e
}
set a [newNode 10 0 0]
set b [newNode 10 10 0]
set c [newNode 0 10 0]
set d [newNode 0 0 0]
catch {*clearlist nodes 1}
eval *createlist nodes 1 [list $a $b $c $d]
set d2e ""
if {[catch {*createelement 104 1 1 1} e]} { set d2e $e }
P "D2_ELEM_CREATE_ERR" $d2e
catch {*clearmark elems 1}
*createmark elems 1 all
P "D2_ELEMS_BEFORE" [join [hm_getmark elems 1] { }]
set cid2 [compId AUDIT_BATCH_D2]
P "D2_COMP_ID" $cid2
markComps 1 [list $cid2]
set d2 ""
if {[catch {*deletemark comps 1} e]} { set d2 $e }
P "D2_DELETE_COMPS_ERR" $d2
P "D2_COUNT_AFTER" [nodeCount]
P "D2_NODE_A_EXISTS" [nodeExists $a]
catch {*clearmark elems 1}
*createmark elems 1 all
P "D2_ELEMS_AFTER" [join [hm_getmark elems 1] { }]

close $channel
exit 0
