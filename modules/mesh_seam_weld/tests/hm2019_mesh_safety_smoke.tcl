# Run in a fresh hmbatch process, never in a user's loaded model.
set root [file normalize [file join [file dirname [info script]] .. .. ..]]
set report [open [file join $root runtime hm_mesh_safety_smoke.log] w]
fconfigure $report -buffering line
puts $report "STARTED [hm_info -appinfo VERSION]"
proc smokeNode {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 -1
    return [lindex [hm_getmark nodes 1] 0]
}
proc smokeQuad {nodes} {
    eval *createlist nodes 1 $nodes
    *createelement 104 1 1 1
    *createmark elems 1 -1
    return [lindex [hm_getmark elems 1] 0]
}
proc smokeSameSnapshot {before after} {
    foreach field {connectivity coordinates} {
        set a [dict get $before $field]; set b [dict get $after $field]
        if {[lsort -integer [dict keys $a]] ne [lsort -integer [dict keys $b]]} {
            error "Rollback changed $field IDs: [dict keys $a] -> [dict keys $b]"
        }
        dict for {id value} $a {
            if {$value ne [dict get $b $id]} { error "Rollback changed $field at $id: $value -> [dict get $b $id]" }
        }
    }
}
if {[catch {
    source -encoding utf-8 [file join $root modules mesh_seam_weld.tcl]
    *collectorcreateonly components BASE_T2 "" 11
    *currentcollector component BASE_T2
    set base [hm_getvalue comps name=BASE_T2 dataname=id]
    set target {}
    for {set x 0} {$x <= 8} {incr x} {
        for {set y 0} {$y <= 4} {incr y} {
            set bn($x,$y) [smokeNode [expr {10*$x-10}] [expr {10*$y-20}] 0]
        }
    }
    for {set x 0} {$x < 8} {incr x} {
        for {set y 0} {$y < 4} {incr y} {
            lappend target [smokeQuad [list $bn($x,$y) $bn([expr {$x+1}],$y) \
                $bn([expr {$x+1}],[expr {$y+1}]) $bn($x,[expr {$y+1}])]]
        }
    }
    *collectorcreateonly components WEB_T1 "" 22
    *currentcollector component WEB_T1
    set web [hm_getvalue comps name=WEB_T1 dataname=id]
    set source {}
    for {set x 0} {$x <= 6} {incr x} {
        set wn($x,0) [smokeNode [expr {10*$x}] 0 3]
        set wn($x,1) [smokeNode [expr {10*$x}] 0 13]
        lappend source $wn($x,0)
    }
    for {set x 0} {$x < 6} {incr x} {
        smokeQuad [list $wn($x,0) $wn([expr {$x+1}],0) $wn([expr {$x+1}],1) $wn($x,1)]
    }
    set ::MeshSeamWeld::cfg(weld_mesh_size) 8
    set prepared [::MeshSeamWeld::prepareCurrentTargetPatch $source [list $base] 0]
    set patch [dict get $prepared target_elements]
    foreach id $patch {
        if {[::MeshSeamWeld::elemComponentId $id] != $base} { error "target halo entered web" }
    }
    puts $report "TARGET_SCOPE_PASS [llength $patch]"
    rename ::MeshSeamWeld::validateStructuralMesh ::MeshSeamWeld::validateStructuralMeshActual
    set injectFailure 1
    proc ::MeshSeamWeld::validateStructuralMesh {before weld source closed} {
        set checked [::MeshSeamWeld::validateStructuralMeshActual $before $weld $source $closed]
        if {$::injectFailure} { error "Injected post-imprint quality failure" }
        return $checked
    }
    set baseline [::MeshSeamWeld::structuralMeshSnapshot $source $patch]
    set failed [::MeshSeamWeld::processWeldPathIsolated $source [list $base] 0 0 1 1 \
        [list $web] SEAM_T1 {30 0 3} $patch 0]
    if {[dict get $failed ok] || ![dict get $failed rollback_ok]} { error "Injected failure was not rolled back" }
    set restored [::MeshSeamWeld::structuralMeshSnapshot $source $patch]
    smokeSameSnapshot $baseline $restored
    puts $report "ROLLBACK_PASS"
    set injectFailure 0
    set outcome [::MeshSeamWeld::processWeldPathIsolated $source [list $base] 0 0 1 1 \
        [list $web] SEAM_T1 {30 0 3} $patch 0]
    puts $report "RESULT $outcome"
    if {![dict get $outcome ok]} { error "Straight T weld did not complete" }
    set prepared [::MeshSeamWeld::prepareCurrentTargetPatch $source [list $base] 0]
    set patch [dict get $prepared target_elements]
    set baseline [::MeshSeamWeld::structuralMeshSnapshot $source $patch]
    set duplicate [::MeshSeamWeld::processWeldPathIsolated $source [list $base] 0 0 1 1 \
        [list $web] SEAM_T1 {30 0 3} $patch 0]
    puts $report "DUPLICATE_RESULT $duplicate"
    if {[dict get $duplicate ok] || ![dict get $duplicate rollback_ok]} { error "Duplicate weld was not rejected safely" }
    set restored [::MeshSeamWeld::structuralMeshSnapshot $source $patch]
    smokeSameSnapshot $baseline $restored
    puts $report "DUPLICATE_PASS"
    puts $report "PASS"
} problem options]} {
    puts $report "FAIL $problem"
    if {[dict exists $options -errorinfo]} { puts $report [dict get $options -errorinfo] }
}
close $report
*quit 1
