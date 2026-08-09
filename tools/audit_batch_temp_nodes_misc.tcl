# Misc clarifications: *nodecreate glob false-positive, *deleteidrange arg
# orders, and whether any list/array-based batch node create exists.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_batch_temp_nodes_misc.tcl
#
# Results: runtime/audit_batch_temp_nodes_misc_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_batch_temp_nodes_misc_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
    flush $channel
}
proc RAW {key value} {
    P $key [string map [list "\n" { } "\r" { }] $value]
}

# --- M1: *nodecreate glob matching -----------------------------------------
P "M1_INFO_NODECREATE" [join [info commands *nodecreate] { }]
P "M1_INFO_NODECREATE_STAR" [join [info commands *nodecreate*] { }]
P "M1_STRINGMATCH" [string match *nodecreate *nodecreateatintersection]
set err ""
if {[catch {*nodecreate 1 2 3} e]} { set err $e }
RAW "M1_CALL_ERR" $err

# --- M2: *deleteidrange argument orders ------------------------------------
set n1 [*createnode 10 10 10 0 0 0]
set latest ""
catch {set latest [hm_latestentityid nodes]}
P "M2_NODE_ID" $latest
foreach order {
    {{*deleteidrange nodes $latest $latest}}
    {{*deleteidrange $latest $latest nodes}}
    {{*deleteidrange nodes $latest}}
    {{*deleteidrange 1 $latest $latest nodes}}
} {
    set err ""
    set val ""
    if {[catch {eval $order} v]} { set err $v } else { set val $v }
    P "M2_ORDER_[string map [list { } _] $order]" $val
    P "M2_ORDER_[string map [list { } _] $order]_ERR" $err
}
set exists ""
catch {set exists [hm_getvalue nodes id=$latest dataname=id]}
P "M2_NODE_STILL_EXISTS" $exists

# --- M3: batch node create surface: any command accepting a list of xyz? ---
P "M3_CREATE_NODE_CMDS" [join [lsort [info commands *creat*node*]] { }]
P "M3_NODE_CREATE_CMDS" [join [lsort [info commands *node*creat*]] { }]

# --- M4: verify *createnode 3-arg acceptance and value echo ---------------
set r ""
set err ""
if {[catch {set r [*createnode 7 8 9]} e]} { set err $e }
P "M4_3ARG_RET" $r
P "M4_3ARG_ERR" $err
set latest2 ""
catch {set latest2 [hm_latestentityid nodes]}
P "M4_3ARG_LATEST" $latest2
set coords ""
catch {
    *createmark nodes 1 -1
    set coords [hm_getvalue nodes mark=1 dataname=coordinates]
}
P "M4_3ARG_COORDS" [join $coords { }]

close $channel
exit 0
