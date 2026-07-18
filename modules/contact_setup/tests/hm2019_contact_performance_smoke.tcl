# HyperMesh 2019 batch performance smoke test for a moderately large contact.
# By default it creates two 50 x 20 shell grids (1000 elements per side), runs
# the same geometry/index/matching path as the UI, and creates solver-backed
# SURF and CONTACT entities. CONTACT_PERF_NX and CONTACT_PERF_NY can override
# the grid dimensions for larger CLI benchmarks.

set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
set outputDir [file join $root runtime tasks contact_setup cli_performance]
file mkdir $outputDir
set gridNx 50
set gridNy 20
if {[info exists ::env(CONTACT_PERF_NX)] && [string is integer -strict $::env(CONTACT_PERF_NX)]} {
    set gridNx $::env(CONTACT_PERF_NX)
}
if {[info exists ::env(CONTACT_PERF_NY)] && [string is integer -strict $::env(CONTACT_PERF_NY)]} {
    set gridNy $::env(CONTACT_PERF_NY)
}
set expectedElements [expr {$gridNx * $gridNy}]
set reportPath [file join $outputDir "hm2019_contact_performance_${expectedElements}.txt"]

proc perfNode {x y z} {
    *createnode $x $y $z 0 0 0
    return [hm_latestentityid nodes]
}

proc perfQuad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    return [hm_latestentityid elems]
}

proc createGridSide {nx ny z reverse} {
    array set nodeAt {}
    for {set j 0} {$j <= $ny} {incr j} {
        for {set i 0} {$i <= $nx} {incr i} {
            set nodeAt($i,$j) [perfNode [expr {double($i)}] [expr {double($j)}] $z]
        }
    }
    set elems {}
    for {set j 0} {$j < $ny} {incr j} {
        for {set i 0} {$i < $nx} {incr i} {
            set n1 $nodeAt($i,$j)
            set n2 $nodeAt([expr {$i+1}],$j)
            set n3 $nodeAt([expr {$i+1}],[expr {$j+1}])
            set n4 $nodeAt($i,[expr {$j+1}])
            if {$reverse} {
                lappend elems [perfQuad [list $n1 $n4 $n3 $n2]]
            } else {
                lappend elems [perfQuad [list $n1 $n2 $n3 $n4]]
            }
        }
    }
    return $elems
}

proc runPerformanceSmoke {root nx ny expectedElements} {
    set executableDir [hm_info -appinfo EXECUTABLEDIR]
    set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
    *templatefileset $templatePath
    source [file join $root modules contact_setup.tcl]

    *collectorcreateonly components CONTACT_PERF_SHELL "" 11
    *currentcollector component CONTACT_PERF_SHELL
    set elemsA [createGridSide $nx $ny 0.0 0]
    set elemsB [createGridSide $nx $ny 1.0 1]

    set totalStarted [clock milliseconds]
    set started $totalStarted
    ::ContactSetup::primeGeometryCache [concat $elemsA $elemsB]
    set cacheMs [expr {[clock milliseconds] - $started}]

    set contactFaces [::ContactSetup::selectNearestContactFaces $elemsA $elemsB]
    set matchedA [dict get $contactFaces elemsA]
    set matchedB [dict get $contactFaces elemsB]
    if {[llength $matchedA] != $expectedElements || [llength $matchedB] != $expectedElements} {
        error "Expected $expectedElements matched elements per side, got A=[llength $matchedA] B=[llength $matchedB]"
    }

    set orientations [::ContactSetup::referenceOrientations $matchedA $matchedB]
    set started [clock milliseconds]
    set surfAId [::ContactSetup::createContactSurf PERF_MAIN $matchedA 13 [lindex $orientations 0] [lindex $orientations 1]]
    set surfaceAMs [expr {[clock milliseconds] - $started}]
    set started [clock milliseconds]
    set surfBId [::ContactSetup::createContactSurf PERF_SECONDARY $matchedB 14 [lindex $orientations 2] [lindex $orientations 3]]
    set surfaceBMs [expr {[clock milliseconds] - $started}]
    set ::ContactSetup::ui(try_group) 1
    set ::ContactSetup::ui(contact_type) STICK
    set started [clock milliseconds]
    set groupId [::ContactSetup::createGroup PERF_CONTACT $surfAId $surfBId]
    set groupMs [expr {[clock milliseconds] - $started}]
    set totalMs [expr {[clock milliseconds] - $totalStarted}]
    ::ContactSetup::clearGeometryCache

    set perf [dict get $contactFaces perf]
    return [join [list \
        status=PASS \
        elements_per_side=$expectedElements \
        cache_ms=$cacheMs \
        geometry_ms=[dict get $perf geometry_ms] \
        grid_ms=[dict get $perf grid_ms] \
        match_ms=[dict get $perf match_ms] \
        surface_a_ms=$surfaceAMs \
        surface_b_ms=$surfaceBMs \
        group_ms=$groupMs \
        total_ms=$totalMs \
        main_surface_id=$surfAId \
        secondary_surface_id=$surfBId \
        group_id=$groupId] "\n"]
}

set code [catch {runPerformanceSmoke $root $gridNx $gridNy $expectedElements} details options]
set channel [open $reportPath w]
if {$code} {
    puts $channel "status=FAIL"
    puts $channel $details
} else {
    puts $channel $details
}
close $channel
if {$code} {
    return -options $options $details
}
