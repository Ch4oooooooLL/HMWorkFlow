# Audit probe: isolated *createelement with rigid config 55, plus
# hm_getvalue mark-based batch reads (continue from alt probe).
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_shell_washer_hole_rbe2_alt2.tcl
set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_washer_alt2_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
proc T {key script} {
    if {[catch {uplevel 1 $script} value options]} {
        P $key "ERROR: [string map {\n { } \r { }} $value]"
    } else {
        P $key [string trim $value]
    }
}
proc mknode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
catch {*clearmark comps 1}
*collectorcreateonly components AUDIT_ALT2 "" 1
*currentcollector component AUDIT_ALT2
set n1 [mknode 0 0 0]; set n2 [mknode 10 0 0]; set n3 [mknode 10 10 0]; set n4 [mknode 0 10 0]
catch {*clearmark nodes 1}
eval *createlist nodes 1 [list $n1 $n2 $n3 $n4]
*createelement 104 1 1 1
catch {*clearmark elems 1}
*createmark elems 1 -1
set quad [lindex [hm_getmark elems 1] 0]
P "QUAD_ID" $quad

# ---- batch reads ------------------------------------------------------------
catch {*clearmark nodes 1}
eval *createmark nodes 1 [list $n1 $n2 $n3 $n4]
T "GETVALUE_NODES_MARK_COORDINATES" {hm_getvalue nodes mark=1 dataname=coordinates}
T "GETVALUE_NODES_MARK_X" {hm_getvalue nodes mark=1 dataname=x}
T "GETVALUE_NODES_MARK_ID" {hm_getvalue nodes mark=1 dataname=id}
catch {*clearmark elems 1}
eval *createmark elems 1 [list $quad]
T "GETVALUE_ELEMS_MARK_NODES" {hm_getvalue elems mark=1 dataname=nodes}
T "GETVALUE_ELEMS_MARK_CONFIG" {hm_getvalue elems mark=1 dataname=config}
catch {*clearmark nodes 1}
catch {*clearmark elems 1}
P "BATCH_READS_DONE" 1
flush $channel

# ---- *createelement 55 (rigid) from node mark - LAST (may kill hmbatch) -----
catch {*clearmark nodes 2}
eval *createmark nodes 2 [list $n1 $n2 $n3 $n4]
set ceCode [catch {*createelement 55 2 1 1} ceErr]
P "CREATELEMENT_55_CODE" $ceCode
P "CREATELEMENT_55_ERR" [string map {\n { } \r { }} $ceErr]
catch {*clearmark nodes 2}
catch {*clearmark elems 1}
*createmark elems 1 all
set counts {}
foreach eid [hm_getmark elems 1] {
    catch {set c [hm_getvalue elems id=$eid dataname=config]}
    dict incr counts [string trim $c]
}
P "CONFIGS_AFTER" [join $counts { }]
catch {*clearmark elems 1}

close $channel
exit 0
