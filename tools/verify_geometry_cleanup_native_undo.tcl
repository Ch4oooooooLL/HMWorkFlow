# Real HyperMesh smoke test for geometry_cleanup native Ctrl+Z integration.
# It runs the production transaction entry with a deterministic point edit,
# verifies successful cleanup creates an undoable native action, then verifies
# a failed cleanup is rolled back by that same history mechanism.

set root [file dirname [file dirname [file normalize [info script]]]]
set version [hm_info -appinfo VERSION]
set testCase success
if {[info exists ::env(HMWF_GEOM_UNDO_CASE)] && $::env(HMWF_GEOM_UNDO_CASE) ne ""} {
    set testCase [string tolower $::env(HMWF_GEOM_UNDO_CASE)]
}
set reportPath [file join $root runtime "geometry_cleanup_native_undo_${version}_${testCase}.log"]
set report [open $reportPath w]
fconfigure $report -encoding utf-8 -translation lf

proc reportValue {key value} {
    variable report
    puts $report "$key=$value"
    flush $report
}

source -encoding utf-8 [file join $root modules geometry_cleanup.tcl]
set ::GeomCleanup::ui(MODE) POCKET
set ::GeomCleanup::ui(PERFORMANCE_MODE) 0
set ::GeomCleanup::ui(VERBOSE) 0

# Browser synchronization is irrelevant in batch mode and can differ between
# desktop releases; the production history path itself remains unchanged.
rename ::HWFlow::refreshBrowser ::HWFlow::refreshBrowser_real
proc ::HWFlow::refreshBrowser {args} { return {} }
rename ::GeomCleanup::removePocket ::GeomCleanup::removePocket_real

proc pointExists {id} {
    return [expr {![catch {set value [hm_getvalue points id=$id dataname=id]}] && $value ne "" && $value != 0}]
}

proc ::GeomCleanup::removePocket {seed} {
    variable stat
    *createpoint 11.25 22.5 33.75 0
    set pointId [hm_latestentityid points]
    set stat(mode) POCKET
    set stat(targetSurfs) [list $seed]
    set stat(newSurfs) {}
    set stat(newSolids) {}
    return [dict create mode POCKET test_point $pointId]
}

reportValue VERSION $version
reportValue TEST_CASE $testCase
if {$testCase eq "classification"} {
    # Confirm the production length query measures a closed circle rather than
    # the zero-length endpoint chord that caused the old helper to mis-rank it.
    set circleCode [catch {
        *createnode 0.0 0.0 0.0 0 0 0
        set centerNode [hm_latestentityid nodes]
        *createvector 1 0.0 0.0 1.0
        eval *createlist nodes 1 [list $centerNode]
        *createcirclefromcenterradius 1 1 20.0 360.0 0.0
        set circleLine [hm_latestentityid lines]
        set circleLength [::GeomCleanup::edgeLength $circleLine]
    } circleError]
    reportValue CLOSED_CIRCLE_QUERY_CODE $circleCode
    if {$circleCode} {
        reportValue CLOSED_CIRCLE_QUERY_ERROR $circleError
        reportValue RESULT FAIL
        close $report
        exit 5
    }
    reportValue CLOSED_CIRCLE_LENGTH $circleLength
    if {abs($circleLength - 125.663706) > 0.01} {
        reportValue RESULT FAIL
        close $report
        exit 5
    }
    # Regression for the field failure: the normal through-hole wall is
    # shorter than the pocket wall. The former height-based sort selected the
    # hole as outer_walls and deleted it. Boundary perimeter must win instead.
    proc ::GeomCleanup::wallsFromLoop {loop seed} {
        if {[lindex $loop 0] == 101} { return [list 301] }
        return [list 401]
    }
    proc ::GeomCleanup::topEdgesFromWallFaces {loop walls deletedFaces} {
        if {[lindex $loop 0] == 101} { return [list 501] }
        return [list 601]
    }
    proc ::GeomCleanup::outsideSurfacesFromEdges {edges excludedFaces} {
        if {[lindex $edges 0] == 501} { return [list 701] }
        return [list 801]
    }
    proc ::GeomCleanup::edgesDistanceFromLoop {loop edges} {
        if {[lindex $loop 0] == 101} { return 8.0 }
        return 2.0
    }
    proc ::GeomCleanup::loopWallDistanceScore {loop walls} { return 999.0 }
    proc ::GeomCleanup::loopPerimeter {loop} {
        if {[lindex $loop 0] == 101} { return 251.327 }
        return 125.664
    }
    set classified [::GeomCleanup::classifyPocketLoops [list [list 101] [list 201]] 900000]
    set outerWalls [dict get $classified outer_walls]
    set innerWalls [dict get $classified inner_walls]
    reportValue CLASSIFIED_POCKET_WALLS $outerWalls
    reportValue CLASSIFIED_HOLE_WALLS $innerWalls
    if {$outerWalls ne "301" || $innerWalls ne "401"} {
        reportValue RESULT FAIL
        close $report
        exit 5
    }
    reportValue RESULT PASS
    close $report
    exit 0
}
if {$testCase eq "success"} {
    set undoBefore [::GeomCleanup::nativeUndoActions]
    set successCode [catch {set successResult [::GeomCleanup::processSurface 900001]} successError]
    reportValue SUCCESS_CODE $successCode
    if {$successCode} {
        reportValue SUCCESS_ERROR $successError
        reportValue RESULT FAIL
        close $report
        exit 2
    }
    set successPoint [dict get $successResult test_point]
    set undoAfter [::GeomCleanup::nativeUndoActions]
    reportValue SUCCESS_POINT_CREATED [pointExists $successPoint]
    reportValue UNDO_ACTION_CHANGED [expr {$undoBefore ne $undoAfter}]
    set undoCode [catch {*undohistorystate 1} undoError]
    reportValue CTRL_Z_EQUIVALENT_CODE $undoCode
    reportValue SUCCESS_POINT_AFTER_UNDO [pointExists $successPoint]
    if {$undoCode || [pointExists $successPoint]} {
        reportValue UNDO_ERROR $undoError
        reportValue RESULT FAIL
        close $report
        exit 3
    }
    reportValue RESULT PASS
    close $report
    exit 0
}

rename ::GeomCleanup::removePocket {}
proc ::GeomCleanup::removePocket {seed} {
    *createpoint 44.0 55.0 66.0 0
    set ::failedPoint [hm_latestentityid points]
    error "intentional rollback probe"
}
set failureCode [catch {::GeomCleanup::processSurface 900002} failureError]
reportValue FAILURE_CODE $failureCode
reportValue FAILURE_POINT_AFTER_ROLLBACK [pointExists $::failedPoint]
if {!$failureCode || [pointExists $::failedPoint]} {
    reportValue FAILURE_ERROR $failureError
    reportValue RESULT FAIL
    close $report
    exit 4
}

reportValue RESULT PASS
close $report
exit 0
