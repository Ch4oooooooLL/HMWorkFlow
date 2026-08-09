# ============================================================================
# Audit probe 6: *createmark spy - capture the exact argv the command sees.
# Results -> runtime/audit_lmo_markstyle2_<VERSION>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_lmo_markstyle2_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -encoding ascii -translation lf

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}

P "AUDIT_VERSION" $version
*collectorcreateonly components AUDIT_MS2 "" 1
*currentcollector component AUDIT_MS2
set n1 [node 40 0 0]
set n2 [node 41 0 0]
set n3 [node 42 0 0]
set n4 [node 41 10 0]
set n5 [node 40 10 0]
set n6 [node 42 10 0]
quad [list $n1 $n2 $n4 $n5]
quad [list $n2 $n3 $n6 $n4]

# Spy: replace *createmark with a wrapper that logs argv then calls original.
set cmOriginal *createmark
rename *createmark __hm_createmark_real
proc *createmark {args} {
    variable channel
    puts $channel "SPY_CM_ARGC=[llength $args]"
    set i 0
    foreach a $args { puts $channel "SPY_CM_ARG$i=<${a}>"; incr i }
    set code [catch {uplevel 1 [list __hm_createmark_real {*}$args]} err]
    puts $channel "SPY_CM_CODE=$code"
    if {$code} { puts $channel "SPY_CM_ERR=$err" }
    if {$code} { return -code error $err }
    return
}

proc markStyle {key script} {
    catch {*clearmark elems 2}
    set code [catch {uplevel 1 $script} err]
    P "${key}_CODE" $code
    if {$code} {
        P "${key}_ERR" $err
    } else {
        P "${key}_MARK" [join [hm_getmark elems 2] { }]
    }
}

set ids [list $n2 $n4]
set sel "by node id"
P "SPY_IDS_STR" "<$ids>"
P "SPY_SEL_STR" "<$sel>"
P "SPY_LIST_SEL_STR" "<[list $sel]>"

# A: direct quoted - known good
markStyle A_DIRECT_QUOTED {*createmark elems 2 "by node id" $n2 $n4}
# C: eval list selector + separate ids - worked before
markStyle C_EVAL_LISTSEP {eval *createmark elems 2 [list $sel] $n2 $n4}
# D: eval quoted selector + list arg - failed before
markStyle D_EVAL_QUOTED_LIST {eval *createmark elems 2 $sel $ids}
# G: direct unquoted words - failed before
markStyle G_DIRECT_WORDS {*createmark elems 2 by node id $n2 $n4}
# J: eval with single-quoted-string command
markStyle J_EVAL_CMDSTR {eval "*createmark elems 2 $sel $n2 $n4"}
# K: direct with braces around selector
markStyle K_DIRECT_BRACED {*createmark elems 2 {by node id} $n2 $n4}

close $channel
exit 0
