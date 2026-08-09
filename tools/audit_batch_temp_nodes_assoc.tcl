# Does hm_getdeleteassociatedentitiesbycompmark include nodes? If yes, the
# GUI-style "delete comp + associated entities" is a viable undo path.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_assoc.tcl
#
# Results: runtime/audit_batch_temp_nodes_assoc_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_assoc_${version}.log"]
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

# Build: comp AUDIT_ASSOC with 4 nodes + 1 quad
if {[catch {*collectorcreateonly components AUDIT_ASSOC "" 8} e]} {
    P "A_COMPCREATE_ERR" $e
}
if {[catch {*currentcollector component AUDIT_ASSOC} e]} {
    P "A_CURCOLL_ERR" $e
}
set a [newNode 20 0 0]
set b [newNode 20 20 0]
set c [newNode 0 20 0]
set d [newNode 0 0 0]
P "A_IDS" "$a $b $c $d"
catch {*clearlist nodes 1}
eval *createlist nodes 1 [list $a $b $c $d]
set ae ""
if {[catch {*createelement 104 1 1 1} e]} { set ae $e }
P "A_ELEM_CREATE_ERR" $ae
set cid ""
catch {set cid [hm_entityinfo id comps AUDIT_ASSOC -byname]}
P "A_COMP_ID" $cid

# A1: associated entities for this comp mark
catch {*clearmark comps 1}
eval *createmark comps 1 $cid
set a1 ""
if {[catch {hm_getdeleteassociatedentitiesbycompmark 1 2} e]} { set a1 $e }
P "A1_ASSOC_ERR" $a1
foreach et {elems nodes comps loads} {
    set ids ""
    catch {*clearmark $et 2}
    catch {set ids [hm_getmark $et 2]}
    P "A1_MARK2_${et}" [join $ids { }]
}

# A2: delete comp + the associated mark 2 content
set a2 ""
if {[catch {*deletemark comps 1} e]} { set a2 $e }
P "A2_DELETE_COMPS_ERR" $a2
set a2b ""
if {[catch {*deletemark nodes 2} e]} { set a2b $e }
P "A2_DELETE_NODES_ERR" $a2b
P "A2_NODE_A_EXISTS" [nodeExists $a]
P "A2_NODE_B_EXISTS" [nodeExists $b]
catch {*clearmark elems 1}
*createmark elems 1 all
P "A2_ELEMS_REMAINING" [join [hm_getmark elems 1] { }]

close $channel
exit 0
