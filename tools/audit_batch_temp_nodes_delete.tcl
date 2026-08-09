# Follow-up probe: pin down the *deletemark node-deletion failure, the
# "Invalid mark id found in file." source, node component placement, and the
# *nodecreate command surface. Run once per installed HyperMesh:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_delete.tcl
#
# Results: runtime/audit_batch_temp_nodes_del_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_del_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
    flush $channel
}
proc R {key value} {
    # verbatim (single-line) raw error capture
    P $key [string map [list "\n" { } "\r" { }] $value]
}

# STEP A: *createmark nodes 1 -1 on a model with NO nodes yet
set errA ""
if {[catch {*createmark nodes 1 -1} e]} { set errA $e }
P "STEP_A" "neg1 on empty model"
R "A_NEG1_ERR" $errA
set idsA ""
catch {set idsA [hm_getmark nodes 1]}
P "A_NEG1_IDS" [join $idsA { }]

# STEP B: *numbersmark on an empty mark
set errB ""
if {[catch {*numbersmark nodes 1 1} e]} { set errB $e }
P "STEP_B" "numbersmark on empty mark"
R "B_NUMBERSMARK_EMPTY_ERR" $errB

# STEP C: *createmark "by id only" with a nonexistent id, in isolation
set errC ""
if {[catch {eval *createmark nodes 2 "by id only" 999999} e]} { set errC $e }
P "STEP_C" "by id only 999999"
R "C_BADID_ERR" $errC
set idsC ""
catch {set idsC [hm_getmark nodes 2]}
P "C_BADID_IDS" [join $idsC { }]

# STEP D: create two free nodes, then *deletemark via mark 2 (verbatim error)
set n1 [*createnode 1 1 1 0 0 0]
set n2 [*createnode 2 2 2 0 0 0]
catch {*clearmark nodes 2}
eval *createmark nodes 2 "by id only" $n1 $n2
set errD ""
if {[catch {*deletemark nodes 2} e]} { set errD $e }
P "STEP_D" "deletemark free nodes"
R "D_DELETEMARK_FREE_ERR" $errD
catch {*clearmark nodes 2}
eval *createmark nodes 2 "by id only" $n1 $n2
set remainD ""
catch {set remainD [hm_getmark nodes 2]}
P "D_REMAINING" [join $remainD { }]
# mark 1 variant
catch {*clearmark nodes 1}
*createmark nodes 1 all
set errD1 ""
if {[catch {*deletemark nodes 1} e]} { set errD1 $e }
R "D_DELETEMARK_ALL_ERR" $errD1

# STEP E: delete a node that IS attached to an element
catch {*clearmark nodes 3}
eval *createmark nodes 3 "by id only" $n1 $n2
set errE1 ""
if {[catch {*createelement 1 3 1 1} e]} { set errE1 $e }
P "STEP_E" "rod element create"
R "E_CREATEELEM_ERR" $errE1
if {$errE1 eq ""} {
    set elemId ""
    catch {set elemId [hm_latestentityid elems]}
    P "E_ELEM_ID" $elemId
    catch {*clearmark nodes 2}
    eval *createmark nodes 2 "by id only" $n1
    set errE2 ""
    if {[catch {*deletemark nodes 2} e]} { set errE2 $e }
    R "E_DELETEMARK_ATTACHED_ERR" $errE2
    catch {*clearmark nodes 2}
    eval *createmark nodes 2 "by id only" $n1
    set remainE ""
    catch {set remainE [hm_getmark nodes 2]}
    P "E_ATTACHED_REMAINING" [join $remainE { }]
    catch {*clearmark elems 1}
    *createmark elems 1 all
    P "E_ELEMS_AFTER" [join [hm_getmark elems 1] { }]
}

# STEP F: mixed valid + stale ids in one mark (undo-after-manual-delete case)
catch {*clearmark nodes 2}
set errF ""
if {[catch {eval *createmark nodes 2 "by id only" $n1 999999} e]} { set errF $e }
P "STEP_F" "mixed valid+stale ids"
R "F_MIXED_ERR" $errF
set idsF ""
catch {set idsF [hm_getmark nodes 2]}
P "F_MIXED_IDS" [join $idsF { }]

# STEP G: node component placement - which dataname reads it?
set compErr ""
if {[catch {*collectorcreateonly components AUDIT_COMP_B "" 2} e]} { set compErr $e }
P "STEP_G" "current comp placement"
R "G_COMPCREATE_ERR" $compErr
set curErr ""
if {[catch {*currentcollector component AUDIT_COMP_B} e]} { set curErr $e }
R "G_CURCOLL_ERR" $curErr
set curColl ""
catch {set curColl [hm_getcurrentcollector comps]}
P "G_GETCURCOLL_RAW" $curColl
set n3 ""
catch {set n3 [hm_latestentityid nodes]}
if {[catch {*createnode 3 3 3 0 0 0}]} {}
set n3 ""
catch {set n3 [hm_latestentityid nodes]}
P "G_NODE_ID" $n3
foreach dn {comp collector.id component.id comps.id component comps} {
    set val ""
    catch {set val [hm_getvalue nodes id=$n3 dataname=$dn]}
    P "G_DATANAME_$dn" $val
}
set ccRet ""
catch {set ccRet [*createnode 4 4 4 0 0 0]}
set n4 ""
catch {set n4 [hm_latestentityid nodes]}
# switch current comp to AUDIT_COMP_A and create again
catch {*currentcollector component AUDIT_COMP_A}
catch {set ccRet [*createnode 5 5 5 0 0 0]}
set n5 ""
catch {set n5 [hm_latestentityid nodes]}
foreach dn {comp collector.id component.id} {
    set v5 ""
    catch {set v5 [hm_getvalue nodes id=$n5 dataname=$dn]}
    set v3 ""
    catch {set v3 [hm_getvalue nodes id=$n3 dataname=$dn]}
    P "G_CMP_${dn}_COMP_B" $v3
    P "G_CMP_${dn}_COMP_A" $v5
}

# STEP H: *nodecreate - discover signature via bare call, then plausible forms
set errH ""
if {[catch {*nodecreate} e]} { set errH $e }
P "STEP_H" "nodecreate signature discovery"
R "H_NODECREATE_NOARG_ERR" $errH
set retH1 ""
set errH1 ""
if {[catch {set retH1 [*nodecreate 9 9 9]} e]} { set errH1 $e }
R "H_NODECREATE_XYZ_ERR" $errH1
P "H_NODECREATE_XYZ_RET" $retH1
set retH2 ""
set errH2 ""
if {[catch {set retH2 [*nodecreate 9 9 9 0 0 0]} e]} { set errH2 $e }
R "H_NODECREATE_6ARGS_ERR" $errH2
P "H_NODECREATE_6ARGS_RET" $retH2

# STEP I: *numbersmark variants
catch {*clearmark nodes 1}
eval *createmark nodes 1 "by id only" $n3 $n5
set errI ""
if {[catch {*numbersmark nodes 1 1} e]} { set errI $e }
R "I_NUMBERSMARK_POPULATED_ERR" $errI

# STEP J: hm_markclear (hm_ API mark clearing alternative)
set errJ ""
if {[catch {hm_markclear nodes 1} e]} { set errJ $e }
R "J_HM_MARKCLEAR_ERR" $errJ
set idsJ -1
catch {set idsJ [llength [hm_getmark nodes 1]]}
P "J_MARK1_LEN_AFTER" $idsJ

# STEP K: *nodesandelemsclear exists as all-or-nothing delete (document only)
P "K_NODESANDELEMSCLEAR_EXISTS" [expr {[info commands *nodesandelemsclear] ne ""}]

close $channel
exit 0
