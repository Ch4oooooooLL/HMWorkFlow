# ============================================================================
# Audit probe 5: *createmark arg-passing styles - definitive isolation.
# Results -> runtime/audit_lmo_markstyle_<VERSION>.log
# ============================================================================

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_lmo_markstyle_${version}.log"]
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
# Run a mark with the given style and report what actually got parsed
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

P "AUDIT_VERSION" $version
*collectorcreateonly components AUDIT_MS "" 1
*currentcollector component AUDIT_MS
set n1 [node 40 0 0]
set n2 [node 41 0 0]
set n3 [node 42 0 0]
set n4 [node 41 10 0]
set n5 [node 40 10 0]
set n6 [node 42 10 0]
quad [list $n1 $n2 $n4 $n5]
quad [list $n2 $n3 $n6 $n4]
set ids [list $n2 $n4]
P "MS_IDS" [join $ids { }]
P "MS_EXPECT" "elements 1 2 hold nodes 2 4"

# --- A: direct call, quoted selector, separate id args (module L1624 style)
markStyle A_DIRECT_QUOTED_SEPARATE {*createmark elems 2 "by node id" $n2 $n4}
# --- B: direct call, quoted selector, list id arg
markStyle B_DIRECT_QUOTED_LIST {*createmark elems 2 "by node id" $ids}
# --- C: eval, list selector, separate ids (module L691 style)
markStyle C_EVAL_LISTSEP {eval *createmark elems 2 [list "by node id"] $n2 $n4}
# --- D: eval, quoted selector, list arg (module L1704 style)
markStyle D_EVAL_QUOTED_LIST {eval *createmark elems 2 "by node id" $ids}
# --- E: eval, quoted selector, separate ids (probe 2 dumpOwners style)
markStyle E_EVAL_QUOTED_SEPARATE {eval *createmark elems 2 "by node id" $n2 $n4}
# --- F: eval, braced selector, list arg (module L1704 exact)
markStyle F_EVAL_BRACED_LIST {eval *createmark elems 2 {"by node id"} $ids}
# --- G: direct, unquoted selector words, separate ids
markStyle G_DIRECT_WORDS {*createmark elems 2 by node id $n2 $n4}
# --- H: eval all-in-one string
markStyle H_EVAL_STRING {eval {*createmark elems 2 by node id} $n2 $n4}
# --- I: eval, selector as variable
set sel "by node id"
markStyle I_EVAL_VAR_SEL {eval *createmark elems 2 $sel $n2 $n4}

close $channel
exit 0
