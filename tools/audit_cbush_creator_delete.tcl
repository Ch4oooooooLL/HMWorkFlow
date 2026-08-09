# Audit probe D: node deletion variants (is *deletemark nodes ever allowed?)
# and whether STATUS=1 forces the CID field into the exported CBUSH card.
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_cbush_creator_delete.tcl
# Results: runtime/audit_cbush_delete_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_cbush_delete_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc tryResult {label script} {
    set code [catch {uplevel 1 $script} result]
    if {$code} {
        P $label "ERROR: $result"
    } else {
        P $label "OK: $result"
    }
    return $code
}
proc makeNode {x y z} {
    *createnode $x $y $z 0 0 0
    return [hm_latestentityid nodes]
}
proc nodeCount {} {
    catch {*clearmark nodes 1 all}
    catch {*createmark nodes 1 all}
    set n [llength [hm_getmark nodes 1]]
    catch {*clearmark nodes 1 all}
    return $n
}

P "VERSION" $version

# --- 1. Node deletion variants -----------------------------------------------
set tpl2019 "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
set tpl2022 "D:/Program Files/Altair/hwdesktop/templates/feoutput/optistruct/optistruct"
set tpl [expr {[file exists $tpl2019] ? $tpl2019 : ([file exists $tpl2022] ? $tpl2022 : "")}]
catch {*templatefileset $tpl}

set n1 [makeNode 61 2 8]
set n2 [makeNode 62 2 8]
set n3 [makeNode 63 2 8]
P "NODES_CREATED" [nodeCount]

# a) default selector (no option)
catch {*clearmark nodes 2}
tryResult "MARK_NODES_DEFAULT" {*createmark nodes 2 $n1}
tryResult "DELETEMARK_NODES_DEFAULT" {*deletemark nodes 2}
catch {*clearmark nodes 2}
P "NODES_AFTER_DEFAULT" [nodeCount]

# b) mark 1 with "by id only"
catch {*clearmark nodes 1}
tryResult "MARK_NODES_MARK1" {*createmark nodes 1 "by id only" $n2}
tryResult "DELETEMARK_NODES_MARK1" {*deletemark nodes 1}
catch {*clearmark nodes 1}
P "NODES_AFTER_MARK1" [nodeCount]

# c) all nodes
catch {*clearmark nodes 2}
tryResult "MARK_NODES_ALL" {*createmark nodes 2 all}
tryResult "DELETEMARK_NODES_ALL" {*deletemark nodes 2}
catch {*clearmark nodes 2}
P "NODES_AFTER_ALL" [nodeCount]

# d) delete via *deletemark elems after creating a temp element? element-only path
#    already proven working in probe B. Node path stays.

# --- 2. CID=7 STATUS=1 -> does the deck show the CID field? -------------------
catch {*createentity comps includeid=0 name=PROBE_DEL_COMP}
catch {*currentcollector component PROBE_DEL_COMP}
catch {*currentcollector components PROBE_DEL_COMP}
set srcNode [makeNode 1 2 3]
set offNode [makeNode 1 2 8]
tryResult "ELEMENTTYPE_21_6" {*elementtype 21 6}
tryResult "SPRINGOS" {*springos $srcNode $offNode "" 0 0 0 0 0 0 0}
set elemId [hm_latestentityid elems]
P "ELEM_CFG_TYPE" "[hm_getvalue elems id=$elemId dataname=config]/[hm_getvalue elems id=$elemId dataname=type]"
tryResult "SETVALUE_CID7_STATUS1" {*setvalue elems id=$elemId CID=7 STATUS=1}
set code [catch {set v [hm_getvalue elems id=$elemId dataname=CID]} err]
P "GET_CID_AFTER_7" [expr {$code ? "ERROR: $err" : "OK: $v"}]
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 all
*createmark nodes 1 all
set asciiPath [file join $outputDir "audit_cbush_deck7_${version}.fem"]
tryResult "FEOUTPUT_SELECT" {*feoutput_select $tpl $asciiPath 1 0 0}
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
if {[file exists $asciiPath]} {
    set fh [open $asciiPath r]
    set content [read $fh]
    close $fh
    set cbushLines {}
    foreach line [split $content \n] {
        if {[string match -nocase *CBUSH* $line]} { lappend cbushLines [string trim $line] }
    }
    P "DECK_CBUSH_LINES_CID7" [join $cbushLines { | }]
}

close $channel
exit 0
