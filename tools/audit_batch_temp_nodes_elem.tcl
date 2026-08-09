# Supplementary probe: *deletemark on a node attached to a quad element,
# using real node ids (via the -1 last-created trick) since *createnode's
# return value is unreliable under hmbatch. Also checks hm_entityincollector
# as a way to read a node's component.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_elem.tcl
#
# Results: runtime/audit_batch_temp_nodes_elem_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_elem_${version}.log"]
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
proc markByIdOnly {markId ids} {
    catch {*clearmark nodes $markId}
    eval [linsert $ids 0 *createmark nodes $markId "by id only"]
}

# --- E1: build a quad with real node ids, then delete one attached node ----
set a [newNode 10 0 0]
set b [newNode 10 10 0]
set c [newNode 0 10 0]
set d [newNode 0 0 0]
P "E1_IDS" "$a $b $c $d"
catch {*clearlist nodes 1}
eval *createlist nodes 1 [list $a $b $c $d]
set e1e ""
if {[catch {*createelement 104 1 1 1} e]} { set e1e $e }
P "E1_ELEM_CREATE_ERR" $e1e
set elemIds ""
catch {set elemIds [hm_getvalue elems mark=1 dataname=id]}
P "E1_ELEM_IDS" [join $elemIds { }]
P "E1_COUNT_BEFORE" [nodeCount]
markByIdOnly 2 [list $a]
set e1 ""
if {[catch {*deletemark nodes 2} e]} { set e1 $e }
P "E1_DELETE_ATTACHED_ERR" $e1
P "E1_NODE_A_EXISTS" [nodeExists $a]
P "E1_COUNT_AFTER" [nodeCount]
catch {*clearmark elems 1}
*createmark elems 1 all
P "E1_ELEMS_REMAINING" [join [hm_getmark elems 1] { }]

# --- E2: deletemark on the element itself (sanity: elems deletable) --------
catch {*clearmark elems 2}
*createmark elems 2 all
set e2 ""
if {[catch {*deletemark elems 2} e]} { set e2 $e }
P "E2_DELETE_ELEMS_ERR" $e2
catch {*clearmark elems 1}
*createmark elems 1 all
P "E2_ELEMS_REMAINING" [join [hm_getmark elems 1] { }]

# --- E3: read a node's component via hm_entityincollector ------------------
if {[catch {*collectorcreateonly components AUDIT_COMP_D "" 4} e]} {
    P "E3_COMPCREATE_ERR" $e
}
if {[catch {*currentcollector component AUDIT_COMP_D} e]} {
    P "E3_CURCOLL_ERR" $e
}
set n [newNode 50 50 50]
P "E3_NODE_ID" $n
set idx 0
foreach form {
    {hm_entityincollector nodes $n comps}
    {hm_entityincollector nodes $n components}
    {hm_entityincollector nodes id=$n comps}
    {hm_entityincollector nodes $n component}
} {
    incr idx
    set val ""
    set err ""
    if {[catch {eval $form} v]} { set err $v } else { set val $v }
    P "E3_FORM_${idx}_VAL" $val
    P "E3_FORM_${idx}_ERR" $err
}

close $channel
exit 0
