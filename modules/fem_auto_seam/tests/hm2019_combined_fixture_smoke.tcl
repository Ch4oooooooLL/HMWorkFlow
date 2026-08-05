proc writeCombinedFixtureReport {path lines} {
    file mkdir [file dirname $path]
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel [join $lines "\n"]
    close $channel
}

set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
set reportPath [file join $root runtime tasks fem_auto_seam combined_fixture_hm2019_report.txt]
set lines {}
set code [catch {
    if {![file isfile $femPath] || [file size $femPath] == 0} { error "combined fixture is missing or empty: $femPath" }
    set template [file normalize [file join [file dirname [info nameofexecutable]] .. .. .. templates feoutput optistruct optistruct]]
    *templatefileset [file nativename $template]
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 2 1 0
    *createmark nodes 1 all; set nodeIds [hm_getmark nodes 1]
    *createmark elems 1 all; set elementIds [hm_getmark elems 1]
    *createmark comps 1 all; set componentIds [hm_getmark comps 1]
    set casePrefixes [dict create]
    foreach componentId $componentIds {
        set name [hm_getvalue comps id=$componentId dataname=name]
        if {[regexp {^(F(?:0[1-9]|10))_} $name -> prefix]} { dict set casePrefixes $prefix 1 }
    }
    if {[dict size $casePrefixes] != 10} { error "expected 10 scenario prefixes, found [dict keys $casePrefixes]" }
    if {![llength $nodeIds] || ![llength $elementIds] || ![llength $componentIds]} { error "combined fixture import is empty" }
    lappend lines "status=PASS"
    lappend lines "fem=$femPath"
    lappend lines "nodes=[llength $nodeIds]"
    lappend lines "elements=[llength $elementIds]"
    lappend lines "components=[llength $componentIds]"
    lappend lines "scenario_prefixes=[join [lsort [dict keys $casePrefixes]] ,]"
} errorMessage errorOptions]

if {$code} {
    lappend lines "status=FAIL"
    lappend lines "error=$errorMessage"
    writeCombinedFixtureReport $reportPath $lines
    return -options $errorOptions $errorMessage
}
writeCombinedFixtureReport $reportPath $lines
