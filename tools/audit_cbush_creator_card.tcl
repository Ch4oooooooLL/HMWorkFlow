# Audit probe C: does the OptiStruct template make CID/STATUS valid datanames
# on spring config 21 type 6 (CBUSH) elements, and does the module's
# *setvalue elems id=.. CID=0 STATUS=1 chain work then? ASCII export via
# *feoutput_select to verify the written CBUSH card.
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_cbush_creator_card.tcl
# Results: runtime/audit_cbush_card_<version>.log, runtime/audit_cbush_deck_<version>.fem

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir

set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_cbush_card_${version}.log"]
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
proc cardProbe {label eid} {
    foreach dn {CID CIDSYS system.id system STATUS K1 C1 GE S S1 S2 OCID} {
        set code [catch {set v [hm_getvalue elems id=$eid dataname=$dn]} err]
        if {$code} { P "$label GET $dn" "ERROR: $err" } else { P "$label GET $dn" "OK: $v" }
    }
}

P "VERSION" $version

# --- 1. Create spring type 6 element BEFORE loading the template -------------
catch {*createentity comps includeid=0 name=PROBE_CARD_COMP}
catch {*currentcollector component PROBE_CARD_COMP}
catch {*currentcollector components PROBE_CARD_COMP}
set srcNode [makeNode 1 2 3]
set offNode [makeNode 1 2 8]
tryResult "ELEMENTTYPE_21_6" {*elementtype 21 6}
set springCode [catch {*springos $srcNode $offNode "" 0 0 0 0 0 0 0} springRet]
P "SPRINGOS" [expr {$springCode ? "ERROR: $springRet" : "OK ret=$springRet"}]
set elemId [hm_latestentityid elems]
P "ELEM_ID" $elemId
P "ELEM_CFG" [hm_getvalue elems id=$elemId dataname=config]
P "ELEM_TYPE" [hm_getvalue elems id=$elemId dataname=type]

# --- 2. Card datanames BEFORE template load ----------------------------------
cardProbe "BEFORE_TPL" $elemId

# --- 3. Load OptiStruct template ---------------------------------------------
set tpl2019 "C:/Program Files/Altair/2019/templates/feoutput/optistruct/optistruct"
set tpl2022 "D:/Program Files/Altair/hwdesktop/templates/feoutput/optistruct/optistruct"
set tpl [expr {[file exists $tpl2019] ? $tpl2019 : ([file exists $tpl2022] ? $tpl2022 : "")}]
P "TEMPLATE" $tpl
if {$tpl ne ""} {
    tryResult "TEMPLATEFILESET" {*templatefileset $tpl}
}

# --- 4. Card datanames AFTER template load -----------------------------------
cardProbe "AFTER_TPL" $elemId

# --- 5. Module chain: *setvalue elems id=.. CID=0 STATUS=1 -------------------
tryResult "SETVALUE_CID0_STATUS1" {*setvalue elems id=$elemId CID=0 STATUS=1}
tryResult "SETVALUE_CID7_STATUS1" {*setvalue elems id=$elemId CID=7 STATUS=1}
tryResult "SETVALUE_CID0_ONLY" {*setvalue elems id=$elemId CID=0}
set code [catch {set v [hm_getvalue elems id=$elemId dataname=CID]} err]
P "GET_CID_AFTER_SETVALUE" [expr {$code ? "ERROR: $err" : "OK: $v"}]

# --- 6. ASCII export via *feoutput_select (mark_id=1) ------------------------
if {$tpl ne ""} {
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    *createmark elems 1 all
    *createmark nodes 1 all
    set asciiPath [file join $outputDir "audit_cbush_deck_${version}.fem"]
    set code [catch {
        hm_answernext yes
        *feoutput_select $tpl $asciiPath 1 0 0
    } err]
    P "FEOUTPUT_SELECT" [expr {$code ? "ERROR: $err" : "OK"}]
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    if {[file exists $asciiPath]} {
        set fh [open $asciiPath r]
        set content [read $fh]
        close $fh
        P "DECK_BYTES" [string length $content]
        P "DECK_HAS_CBUSH" [string match -nocase *CBUSH* $content]
        set cbushLines {}
        foreach line [split $content \n] {
            if {[string match -nocase *CBUSH* $line]} { lappend cbushLines [string trim $line] }
        }
        P "DECK_CBUSH_LINES" [join $cbushLines { | }]
        set gridLines {}
        foreach line [split $content \n] {
            if {[string match -nocase "GRID*" $line]} { lappend gridLines [string trim $line] }
        }
        P "DECK_GRID_LINES" [join $gridLines { | }]
    } else {
        P "DECK_EXPORT" "NO FILE"
    }
}

# --- 7. Node deletion after template load (is *deletemark nodes template-dependent?) ----
set loneNode [makeNode 51 2 8]
catch {*clearmark nodes 2}
catch {*createmark nodes 2 "by id only" $loneNode}
tryResult "DELETEMARK_NODE_WITH_TPL" {*deletemark nodes 2}
catch {*clearmark nodes 2}
catch {*clearmark nodes 1 all}
catch {*createmark nodes 1 all}
set loneGone [expr {[lsearch -exact [hm_getmark nodes 1] $loneNode] < 0}]
P "LONE_NODE_GONE_WITH_TPL" $loneGone
catch {*clearmark nodes 1}

close $channel
exit 0
