# Run in a new hmbatch process; never imports into the user's working model.
set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
file mkdir [file join $root temp solid_seam_refactor]
set channel [open [file join $root temp solid_seam_refactor open_edge_native.log] w]
fconfigure $channel -encoding utf-8 -buffering line
set rc [catch {
    source -encoding utf-8 [file join $root modules workflow_common.tcl]
    source -encoding utf-8 [file join $root modules solid_seam_connector.tcl]
    proc ::SolidSeam::message {icon text} { puts $::channel "$icon $text" }
    set executableDir [hm_info -appinfo EXECUTABLEDIR]
    *templatefileset [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
    set femPath [file join $root examples AutoShellSeamBackend test_fem combined_all_cases.fem]
    set input [open $femPath r]
    set deck [read $input]; close $input
    # Attach a quad at only the upper-right corner of the source plate.
    # The lower, open weld edge is unchanged; the remote corner has degree 4.
    set deck [string map [list "GRID,48,,20,0,3" "GRID,48,,20,0,9" \
        "GRID,49,,30,0,3" "GRID,49,,30,0,9" "GRID,50,,40,0,3" "GRID,50,,40,0,9"] $deck]
    set extra {GRID,900001,,70,0,23
GRID,900002,,70,0,33
GRID,900003,,60,0,33
$HMCOMP ID 2
CQUAD4,900001,2,66,900001,900002,900003
ENDDATA}
    set femPath [file join $root temp solid_seam_refactor open_edge_fixture.fem]
    set output [open $femPath w]
    puts $output [string map [list ENDDATA $extra] $deck]; close $output
    *feinputpreserveincludefiles
    *createstringarray 10 "OptiStruct " " " "ANSA " "PATRAN " "EXPAND_IDS_FOR_FORMULA_SETS " "ASSIGNPROP_BYHMCOMMENTS" "LOADCOLS_DISPLAY_SKIP " "VECTORCOLS_DISPLAY_SKIP " "SYSTCOLS_DISPLAY_SKIP " "CONTACTSURF_DISPLAY_SKIP "
    *feinputwithdata2 "#optistruct\\optistruct" $femPath 0 0 0 0 0 1 10 1 0
    set source [hm_getvalue comps name="F01_CASE_01_STRAIGHT_T__WEB_T1" dataname=id]
    set target [hm_getvalue comps name="F01_CASE_01_STRAIGHT_T__BASE_T2" dataname=id]
    set ::SolidSeam::ui(input_type) AUTO
    set edge {46 47 48 49 50 51 52}
    set branched 0
    dict for {n neighbors} [::SolidSeam::freeBoundaryGraph $source] {
        if {[llength $neighbors] > 2} { set branched 1 }
    }
    if {!$branched} { error "Fixture did not create branched boundary" }
    puts $channel "OPEN_EDGE=$edge BRANCHED=$branched"
    foreach mode {AUTO AUTO_GROUP} {
        set ::SolidSeam::ui(input_type) $mode
        set ::SolidSeam::ui(shadow_face_distance) [expr {$mode eq "AUTO_GROUP"}]
        if {$mode eq "AUTO"} {
            set rows [::SolidSeam::autoDetectAndCreate [list $source $target] 1]
        } else {
            set plans [::SolidSeam::prepareAutoGroup [list $source $target]]
            if {[llength $plans] != 1} { error "AutoGroup lost pair" }
            set rows [dict get [lindex $plans 0] candidates]
        }
        if {![llength $rows]} { error "No open seam" }
        foreach row $rows {
            if {[dict get $row is_closed]} { error "Open edge falsely closed" }
            if {$mode eq "AUTO_GROUP" && ![dict exists $row shadow_face_summary]} { error "Missing shadow face-distance summary" }
            if {$mode eq "AUTO_GROUP"} { puts $channel "SHADOW [dict get $row shadow_face_summary]" }
            foreach n [dict get $row node_ids] { if {$n ni $edge} { error "Unrelated boundary included" } }
        }
        set found {}
        foreach row $rows { set found [concat $found [dict get $row node_ids]] }
        if {[lsort -integer -unique $found] ne $edge} { error "Middle of open edge missing: $found; expected $edge" }
        puts $channel "$mode open_paths=[llength $rows] all_nodes=$found"
    }
    ::SolidSeam::newRun
    set ::SolidSeam::candidateRows $rows
    set beforeElements [hm_entitylist elems id all]
    ::SolidSeam::createAcceptedCandidates
    set middlePentas 0
    foreach element [::SolidSeamCommandProfile::newIds $beforeElements [hm_entitylist elems id all]] {
        if {[::SolidSeam::elementConfig $element] != 206} { continue }
        set x 0.0; set nodes [::SolidSeam::elementNodes $element]
        foreach n $nodes { set x [expr {$x+[lindex [::SolidSeam::nodeXYZ $n] 0]}] }
        set x [expr {$x/[llength $nodes]}]
        if {$x > 20 && $x < 40} { incr middlePentas }
    }
    if {!$middlePentas} { error "Realization still omitted the middle of the seam" }
    puts $channel "MIDDLE_PENTAS=$middlePentas"
    puts $channel "REALIZED $::SolidSeam::lastResultSummary"
    puts $channel PASS
} err opts]
if {$rc} { puts $channel "FAIL $err\n[dict get $opts -errorinfo]" }
close $channel
exit $rc
