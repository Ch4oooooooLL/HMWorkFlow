# Diagnostic: isolate *createmark selector behavior on the installed build.
# Direct calls only (no proc indirection).  Result: runtime/audit_washer_mark2_<ver>.log
set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [string trim [hm_info -appinfo VERSION]]
set reportPath [file join $outputDir "audit_washer_mark2_${version}.log"]
set channel [open $reportPath w]
proc P {key value} { variable channel; puts $channel "${key}=${value}" }

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
foreach pair {{0 1} {1 2} {2 3} {3 4} {4 5} {5 6} {6 7} {7 0}} {
    set i [lindex $pair 0]; set j [lindex $pair 1]
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 [list $center [lindex $ring $i] [lindex $ring $j]]
    *createelement 103 1 1 1
}
catch {*clearmark nodes 2}
eval *createmark nodes 2 $ring
set rc [catch {*rigidlink $center 2 123456} rerr]
catch {*clearmark nodes 2}
*createmark elems 1 all
set allElems [hm_getmark elems 1]
catch {*clearmark elems 1}
P "RIGIDLINK" $rc
P "ALL_ELEMS" [join $allElems {,}]
set srcComp [hm_latestentityid comps]
P "SRC_COMP" $srcComp

proc test {label code} {
    set codeStr $code
    catch {*clearmark elems 2}
    set c [catch {uplevel 1 $code} err]
    if {$c} {
        P "T $label" "ERR $err"
    } else {
        set ids {}
        catch {set ids [hm_getmark elems 2]}
        P "T $label" "OK COUNT=[llength $ids] IDS=[join [lrange $ids 0 8] {,}]"
    }
    catch {*clearmark elems 2}
}

# --- ID forms: single list arg vs separate args -----------------------------
test "PLAIN_LIST_ONE_ARG" {*createmark elems 2 [list 1 2 3]}
test "PLAIN_SEPARATE_ARGS" {*createmark elems 2 1 2 3}
test "BYIDONLY_LIST_ARG" {*createmark elems 2 "by id only" [list 1 2 3]}
test "BYIDONLY_SEPARATE" {*createmark elems 2 "by id only" 1 2 3}
test "BYID_LIST_ARG" {*createmark elems 2 "by id" [list 1 2 3]}
test "BYID_SEPARATE" {*createmark elems 2 "by id" 1 2 3}
test "BYIDONLY_WITH_MISSING" {*createmark elems 2 "by id only" [list 1 9999991 2]}

# --- config forms: number vs name, mark 2 vs mark 1 -------------------------
test "CONFIG_55" {*createmark elems 2 "by config" 55}
test "CONFIG_55_NAME" {*createmark elems 2 "by config" "55"}
test "CONFIG_RBE2" {*createmark elems 2 "by config" RBE2}
test "CONFIG_104" {*createmark elems 2 "by config" 104}
test "CONFIG_QUAD4" {*createmark elems 2 "by config" quad4}
test "CONFIG_TRIA3" {*createmark elems 2 "by config" 103}
test "ELEMENT_CONFIG_55" {*createmark elems 2 "by element config" 55}
test "ELEM_CONFIG_55" {*createmark elems 2 "by elem config" 55}
test "CONFIGURATION_55" {*createmark elems 2 "by configuration" 55}
test "CARD_IMAGE_RBE2" {*createmark elems 2 "by card image" RBE2}
test "CARDIMAGE_RBE2" {*createmark elems 2 "by cardimage" RBE2}
test "TYPE_RBE2" {*createmark elems 2 "by type" RBE2}

# --- node attachment forms ---------------------------------------------------
test "BY_NODE_ID" {*createmark elems 2 "by node id" [list $center]}
test "BY_NODE" {*createmark elems 2 "by node" [list $center]}
test "BY_NODES" {*createmark elems 2 "by nodes" [list $center]}

# --- component forms ---------------------------------------------------------
test "BY_COMP_ID" {*createmark elems 2 "by comp id" [list $srcComp]}
test "BY_COLLECTOR_ID" {*createmark elems 2 "by collector id" [list $srcComp]}
test "BY_COMP_NAME" {*createmark elems 2 "by comp name" [list AUDIT_SRC]}
test "BY_COMPONENT_ID" {*createmark elems 2 "by component id" [list $srcComp]}
test "BY_COMP" {*createmark elems 2 "by comp" [list $srcComp]}

# --- mark 1 vs mark 2 for config selector ------------------------------------
catch {*clearmark elems 1}
set c [catch {*createmark elems 1 "by config" 55} err]
set ids {}
catch {set ids [hm_getmark elems 1]}
P "T MARK1 CONFIG_55" "code=$c COUNT=[llength $ids] IDS=[join $ids {,}]"
catch {*clearmark elems 1}

# --- rigids entity family ----------------------------------------------------
catch {*clearmark rigids 2}
set c [catch {*createmark rigids 2 all} err]
if {$c} { P "RIGIDS_MARK" "ERR $err" } else {
    set ids {}
    catch {set ids [hm_getmark rigids 2]}
    P "RIGIDS_MARK" "OK COUNT=[llength $ids] IDS=[join $ids {,}]"
}
catch {*clearmark rigids 2}
catch {*clearmark elements 2}
set c [catch {*createmark elements 2 "by config" 55} err]
set ids {}
catch {set ids [hm_getmark elements 2]}
P "ELEMENTS_ENTITY CONFIG_55" "code=$c COUNT=[llength $ids]"
catch {*clearmark elements 2}

close $channel
exit 0
