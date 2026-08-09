# Fix probe 3: *replacentitywithentity(mark) node replacement for
# ::RB2Bolt::replaceOneNode.  *replacenodes fails on both builds and
# *equivalence does not merge coincident free nodes; the only remaining
# documented candidate is *replacentitywithentity / *replacentitywithentitymark.
# Verify: re-point a rod element from src to tgt, and src disappears.
#
# Run once per build:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/fix_probe_bolt_replacentity.tcl
# Results: runtime/fix_probe_bolt_replacentity_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "fix_probe_bolt_replacentity_${version}.log"]
set chan [open $reportPath w]
fconfigure $chan -encoding utf-8 -translation lf

proc P {key value} {
    variable chan
    puts $chan "${key}=${value}"
    flush $chan
}

proc T {key script} {
    set code [catch {uplevel 1 $script} value options]
    if {$code} {
        set msg [string map [list "\n" " " "\r" " " "{" "" "}" ""] $value]
        P "$key" "ERR: $msg"
        return 0
    }
    P "$key" "OK: $value"
    return 1
}

P "AUDIT" "fix_probe_bolt_replacentity"
P "VERSION" $version
P "EXISTS *replacentitywithentity" [expr {[info commands *replacentitywithentity] ne ""}]
P "EXISTS *replacentitywithentitymark" [expr {[info commands *replacentitywithentitymark] ne ""}]

proc newNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}

# --- 1. *replacentitywithentity nodes src tgt ------------------------------
# Rod built with the audit-probe pattern (*createlist + *createelement 1 1 1);
# other mark patterns hard-crash HM2019 hmbatch.
set na [newNode 30 30 30]
set nb [newNode 31 30 30]
*createlist nodes 1 $na $nb
*createelement 1 1 1
*createmark elems 1 -1
set rod [lindex [hm_getmark elems 1] 0]
P "ROD1_ID" $rod
P "ROD1_NODES_BEFORE" [hm_getvalue elems id=$rod dataname=nodes]
set nc [newNode 32 30 30]
T "RE_ENTITY_SRC_TGT" {*replacentitywithentity nodes $nb $nc}
catch {*createmark elems 1 $rod}
P "ROD1_NODES_AFTER" [hm_getvalue elems id=$rod dataname=nodes]
catch {*createmark nodes 1 $nb}
P "ROD1_SRC_ALIVE" [hm_marklength nodes 1]
catch {*createmark nodes 1 $nc}
P "ROD1_TGT_ALIVE" [hm_marklength nodes 1]

# --- 2. *replacentitywithentitymark nodes mark tgt -------------------------
set na2 [newNode 40 40 40]
set nb2 [newNode 41 40 40]
*createlist nodes 1 $na2 $nb2
*createelement 1 1 1
*createmark elems 1 -1
set rod2 [lindex [hm_getmark elems 1] 0]
P "ROD2_ID" $rod2
set nc2 [newNode 42 40 40]
catch {*clearmark nodes 2}
*createmark nodes 2 $nb2
T "RE_MARK_TGT" {*replacentitywithentitymark nodes 2 $nc2}
catch {*createmark elems 1 $rod2}
P "ROD2_NODES_AFTER" [hm_getvalue elems id=$rod2 dataname=nodes]
catch {*createmark nodes 1 $nb2}
P "ROD2_SRC_ALIVE" [hm_marklength nodes 1]

# --- 3. *replacentitywithentitymark with both-node mark --------------------
set na3 [newNode 50 50 50]
set nb3 [newNode 51 50 50]
*createlist nodes 1 $na3 $nb3
*createelement 1 1 1
*createmark elems 1 -1
set rod3 [lindex [hm_getmark elems 1] 0]
set nc3 [newNode 52 50 50]
catch {*clearmark nodes 2}
*createmark nodes 2 $nb3 $nc3
T "RE_MARK_MIXED" {*replacentitywithentitymark nodes 2 $nc3}
catch {*createmark elems 1 $rod3}
P "ROD3_NODES_AFTER" [hm_getvalue elems id=$rod3 dataname=nodes]

close $chan
exit 0
