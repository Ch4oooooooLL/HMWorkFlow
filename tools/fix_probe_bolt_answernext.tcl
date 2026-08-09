# Fix probe 4: do *equivalence / *replacentitywithentity merge nodes when a
# confirmation answer (hm_answernext) is provided?  The earlier probes ran
# without any answer and every merge silently did nothing.
#
# Run once per build:
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/fix_probe_bolt_answernext.tcl
# Results: runtime/fix_probe_bolt_answernext_<version>.log (KEY=VALUE, ASCII).

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "fix_probe_bolt_answernext_${version}.log"]
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

P "AUDIT" "fix_probe_bolt_answernext"
P "VERSION" $version

proc newNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}

proc alive {id} {
    catch {*clearmark nodes 1}
    catch {*createmark nodes 1 $id}
    expr {[hm_marklength nodes 1] > 0}
}

# --- 1. *equivalence with hm_answernext yes --------------------------------
set tgt [newNode 60 60 60]
set src [newNode 60 60 60]
*createmark nodes 1 $tgt
*createmark nodes 2 $src
catch {hm_answernext yes}
T "EQ_AN_2MARK" {*equivalence 1 2 0.001}
P "EQ_AN_2MARK_SRC_ALIVE" [alive $src]
P "EQ_AN_2MARK_TGT_ALIVE" [alive $tgt]

set tgt [newNode 61 61 61]
set src [newNode 61 61 61]
*createmark nodes 1 $tgt
*createmark nodes 2 $src
catch {hm_answernext yes}
T "EQ_AN_NODEKW" {*equivalence nodes 1 2 0.001}
P "EQ_AN_NODEKW_SRC_ALIVE" [alive $src]
P "EQ_AN_NODEKW_TGT_ALIVE" [alive $tgt]

# --- 2. *replacentitywithentity with hm_answernext --------------------------
set na [newNode 70 70 70]
set nb [newNode 71 70 70]
*createlist nodes 1 $na $nb
*createelement 1 1 1
*createmark elems 1 -1
set rod [lindex [hm_getmark elems 1] 0]
set nc [newNode 72 70 70]
catch {hm_answernext yes}
T "RE_AN_SRC_TGT" {*replacentitywithentity nodes $nb $nc}
P "RE_AN_SRC_ALIVE" [alive $nb]
P "RE_AN_TGT_ALIVE" [alive $nc]
catch {*clearmark elems 1}
catch {*createmark elems 1 $rod}
P "RE_AN_ROD_NODES" [hm_getvalue elems id=$rod dataname=nodes]

# --- 3. node ids after merge: which id survives ----------------------------
set tgt [newNode 80 80 80]
set src [newNode 80 80 80]
*createmark nodes 1 $tgt
*createmark nodes 2 $src
catch {hm_answernext yes}
T "EQ_AN_KEEP1" {*equivalence 1 2 0.001}
P "EQ_AN_KEEP1_TOTAL" [llength [hm_getmark nodes 1]]

close $chan
exit 0
