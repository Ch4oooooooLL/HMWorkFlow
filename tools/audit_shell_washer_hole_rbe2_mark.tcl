# Audit probe: mark selectors and mark utilities used by the
# shell_washer_hole_rbe2 module.  Headless run:
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_shell_washer_hole_rbe2_mark.tcl
#
# Results: runtime/audit_washer_mark_<version>.log  (KEY=VALUE, ASCII only)
# Probe restraint: single hmbatch launch, minimal model, no panels.

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_washer_mark_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

# ---- Build a minimal fixture: 1 comp, 9 nodes, 8 quads, 1 RBE2 ------------
proc mknode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}

catch {*clearmark comps 1}
*collectorcreateonly components AUDIT_SRC "" 1
*currentcollector component AUDIT_SRC

set center [mknode 0 0 0]
set ring {}
for {set i 0} {$i < 8} {incr i} {
    set a [expr {$i * 45.0 * 3.141592653589793 / 180.0}]
    lappend ring [mknode [expr {5.0 * cos($a)}] [expr {5.0 * sin($a)}] 0]
}
# 8 quads: center + 2 adjacent ring nodes -> tria ring via quads (c4-c1 pattern)
# Use consecutive ring nodes only (proper quads between ring nodes):
#   quad(i) = ring(i), ring(i+1), ring(i+2), ring(i+3) -> overlapping; instead
#   build 4 quads from ring pairs and 4 trias; simpler: 8 tria3 from center.
foreach pair {{0 1} {1 2} {2 3} {3 4} {4 5} {5 6} {6 7} {7 0}} {
    set i [lindex $pair 0]
    set j [lindex $pair 1]
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 [list $center [lindex $ring $i] [lindex $ring $j]]
    *createelement 103 1 1 1
}
catch {*clearmark nodes 1}
*createmark nodes 1 all
set allNodes [hm_getmark nodes 1]
catch {*clearmark elems 1}
*createmark elems 1 all
set allElems [hm_getmark elems 1]
set shells [llength $allElems]
P "VERSION" $version
P "NODES_TOTAL" [llength $allNodes]
P "SHELL_ELEMS_TOTAL" $shells
P "LATEST_COMP" [hm_latestentityid comps]
P "LATEST_ELEM" [hm_latestentityid elems]
P "LATEST_NODE" [hm_latestentityid nodes]

# RBE2 via *rigidlink (module createRigidLink path)
catch {*clearmark nodes 2}
eval *createmark nodes 2 $ring
set rigidCode [catch {*rigidlink $center 2 123456} rigidErr]
P "RIGIDLINK_ERROR" $rigidCode
if {$rigidCode} { P "RIGIDLINK_ERRMSG" $rigidErr }
catch {*clearmark nodes 2}
*createmark elems 1 all
set rbe2Count 0
set rbe2Id 0
foreach eid [hm_getmark elems 1] {
    if {![catch {set cfg [hm_getvalue elems id=$eid dataname=config]}] && [string trim $cfg] eq "55"} {
        incr rbe2Count
        set rbe2Id $eid
    }
}
P "RBE2_CREATED_BY_RIGIDLINK" $rbe2Count
if {$rbe2Id == 0} {
    # If config is not 55, report what the latest element config is
    catch {set latestCfg [hm_getvalue elems id=[hm_latestentityid elems] dataname=config]}
    P "LATEST_ELEM_CONFIG" [string trim $latestCfg]
}
catch {*clearmark elems 1}

# ---- Mark selector matrix --------------------------------------------------
# each: selectors {label args...}; run in mark 2; report OK/ERR + count
proc tryMark {label entity args} {
    catch {*clearmark $entity 2}
    set code [catch {eval *createmark $entity 2 $args} err]
    if {$code} {
        P "MARK $label" "ERROR: [string map {\n { } \r { }} $err]"
    } else {
        set ids {}
        catch {set ids [hm_getmark $entity 2]}
        P "MARK $label" "OK COUNT=[llength $ids] IDS=[join [lrange $ids 0 4] {,}]"
    }
    catch {*clearmark $entity 2}
}

# element config selectors (module markRigidLinkCandidates order)
tryMark "ELEMS_BY_CONFIG_55" elems {"by config" 55}
tryMark "ELEMS_BY_ELEMENT_CONFIG_55" elems {"by element config" 55}
tryMark "ELEMS_BY_ELEM_CONFIG_55" elems {"by elem config" 55}
tryMark "ELEMS_BY_CONFIGURATION_55" elems {"by configuration" 55}
tryMark "ELEMS_BY_CARD_IMAGE_RBE2" elems {"by card image" RBE2}
tryMark "ELEMS_BY_CARDIMAGE_RBE2" elems {"by cardimage" RBE2}
tryMark "ELEMS_BY_TYPE_RBE2" elems {"by type" RBE2}

# id forms
tryMark "ELEMS_BY_ID_ONLY_VALID" elems {"by id only" [lindex $allElems 0] [lindex $allElems 1]}
tryMark "ELEMS_BY_ID_ONLY_WITH_MISSING" elems {"by id only" [lindex $allElems 0] 9999991 9999992}
tryMark "ELEMS_PLAIN_IDS" elems [lrange $allElems 0 2]
tryMark "ELEMS_MINUS_ONE" elems -1
tryMark "ELEMS_ALL" elems all
tryMark "ELEMS_BY_NODE_ID" elems {"by node id" $center}
tryMark "ELEMS_BY_NODE" elems {"by node" $center}
tryMark "ELEMS_BY_NODES" elems {"by nodes" $center}
tryMark "ELEMS_BY_COMP_ID" elems {"by comp id" [hm_latestentityid comps]}
tryMark "ELEMS_BY_COLLECTOR_ID" elems {"by collector id" [hm_latestentityid comps]}
tryMark "ELEMS_BY_COMP_NAME" elems {"by comp name" AUDIT_SRC}
tryMark "ELEMS_BY_COMPONENT_ID" elems {"by component id" [hm_latestentityid comps]}

# node selectors (module exporter uses "by component id" for nodes)
tryMark "NODES_BY_COMP_ID" nodes {"by comp id" [hm_latestentityid comps]}
tryMark "NODES_BY_COMPONENT_ID" nodes {"by component id" [hm_latestentityid comps]}
tryMark "NODES_ALL" nodes all

# component selectors
tryMark "COMPS_BY_NAME_ONLY" comps {"by name only" AUDIT_SRC}
tryMark "COMPS_BY_NAME" comps {"by name" AUDIT_SRC}
tryMark "COMPS_ALL" comps all

# ---- Mark utilities ---------------------------------------------------------
catch {*clearmark elems 2}
eval *createmark elems 2 [lrange $allElems 0 1]
P "UTIL_CLEARMARK" [catch {*clearmark elems 2}]
P "UTIL_GETMARK_AFTER_CLEAR" [llength [hm_getmark elems 2]]

catch {*clearmark elems 1}
eval *createmark elems 1 [lrange $allElems 0 1]
P "UTIL_MARKTOUSERMARK" [catch {*marktousermark elems 1}]
catch {*clearmark elems 1}
P "UTIL_HM_MARKCLEAR" [catch {hm_markclear elems 1}]

catch {*clearmark elems 2}
eval *createmark elems 2 [lrange $allElems 0 1]
set deletedBefore [llength [hm_getmark elems 2]]
P "UTIL_DELETEMARK" [catch {*deletemark elems 2}]
P "UTIL_DELETEMARK_COUNT" $deletedBefore

close $channel
exit 0
