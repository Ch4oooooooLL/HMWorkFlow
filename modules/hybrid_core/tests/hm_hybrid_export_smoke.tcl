set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
# hmbatch does not load the interactive profile framework.  Select the
# OptiStruct template directly so solver-specific property APIs are available.
set optiTemplate [file normalize [file join [file dirname [info nameofexecutable]] .. .. .. templates feoutput optistruct optistruct]]
if {![file exists $optiTemplate]} {error "OptiStruct template not found: $optiTemplate"}
*templatefileset $optiTemplate
foreach module {auto_hole_rbe2.tcl shell_washer_hole_rbe2.tcl rbe2_bolt_connector.tcl mesh_seam_weld.tcl} {
    source [file join $root modules $module]
}
# mesh_seam_weld.tcl intentionally keeps its Python/FEM bridge out of the
# normal module runtime (see its loader note); this smoke exercises that
# bridge, so opt into it explicitly, exactly as a FAST_AUTO user session does.
if {![llength [info commands ::MeshSeamWeld::runPythonPathStage]]} {
    ::HWFlow::sourceUtf8 [file join $root modules mesh_seam_weld tcl bridge.tcl]
}
if {![llength [info commands ::MeshSeamWeld::exportHybridInputs]]} {
    ::HWFlow::sourceUtf8 [file join $root modules mesh_seam_weld tcl exporter.tcl]
}

namespace eval ::HybridSmoke {}
proc ::HybridSmoke::component {name color} {
    if {[catch {set id [hm_getvalue comps name=$name dataname=id]}] || $id eq "" || $id == 0} {
        *collectorcreateonly components $name "" $color
        set id [hm_getvalue comps name=$name dataname=id]
    }
    *currentcollector component $name
    return $id
}
proc ::HybridSmoke::node {x y z} { *createnode $x $y $z 0 0 0; return [hm_latestentityid nodes] }
proc ::HybridSmoke::quad {nodes} { eval *createlist nodes 1 $nodes; *createelement 104 1 1 1; return [hm_latestentityid elems] }
proc ::HybridSmoke::solid {nodes} { eval *createlist nodes 1 $nodes; *createelement 208 1 1 1; return [hm_latestentityid elems] }

set shellComp [::HybridSmoke::component HYBRID_SMOKE_SHELL 11]
set inner {}; set outer {}
for {set i 0} {$i < 8} {incr i} {
    set a [expr {2.0*acos(-1.0)*$i/8.0}]
    lappend inner [::HybridSmoke::node [expr {5.0*cos($a)}] [expr {5.0*sin($a)}] 0.0]
}
for {set i 0} {$i < 8} {incr i} {
    set a [expr {2.0*acos(-1.0)*$i/8.0}]
    lappend outer [::HybridSmoke::node [expr {7.0*cos($a)}] [expr {7.0*sin($a)}] 0.0]
}
for {set i 0} {$i < 8} {incr i} {
    set j [expr {($i+1)%8}]
    ::HybridSmoke::quad [list [lindex $inner $i] [lindex $inner $j] [lindex $outer $j] [lindex $outer $i]]
}

set ::RB2W::ui(selectedComps) [list $shellComp]
set washerRun [::RB2W::runPythonRecognition $shellComp]
set sharedWorkerPid [pid $::HybridCore::workerChannel]
set washerCount [llength [dict get [dict get $washerRun payload] candidates]]
if {$washerCount != 1} { error "shell washer smoke expected 1 candidate, got $washerCount" }
# Interactive HWFlow component creation uses Model Browser operations.  Make
# it fatal here to prove RB2W takes its silent direct-command path instead.
rename ::HWFlow::createComponent ::HWFlow::createComponent_browser_path
proc ::HWFlow::createComponent {args} { error "interactive component creation path must not be used by RB2W" }
set washerCreate [::RB2W::executePythonCandidates $shellComp [dict get $washerRun payload]]
rename ::HWFlow::createComponent {}
rename ::HWFlow::createComponent_browser_path ::HWFlow::createComponent
::HybridCore::closeLog
if {[lindex $washerCreate 0] != 1} { error "shell washer smoke expected 1 created RBE2, got $washerCreate" }

set seamRun [::MeshSeamWeld::runPythonPathStage source $inner {} 1]
if {[pid $::HybridCore::workerChannel] ne $sharedWorkerPid} { error "persistent worker PID changed between washer and seam modules" }
set seamPath [dict get [lindex [dict get [dict get $seamRun payload] candidates] 0] path_node_ids]
::HybridCore::closeLog
if {[llength $seamPath] != 8} { error "seam source smoke expected 8 path nodes" }

::HybridSmoke::component HYBRID_SMOKE_RBE2 21
set rigidIds {}
foreach z {0.0 20.0} {
    set center [::HybridSmoke::node 30.0 0.0 $z]; set deps {}
    for {set i 0} {$i < 8} {incr i} {
        set a [expr {2.0*acos(-1.0)*$i/8.0}]
        lappend deps [::HybridSmoke::node [expr {30.0+5.0*cos($a)}] [expr {5.0*sin($a)}] $z]
    }
    catch {*clearmark nodes 2}; eval *createmark nodes 2 $deps; *rigidlink $center 2 123456
    lappend rigidIds [hm_latestentityid elems]
}
set boltRun [::RB2Bolt::runPythonPlanning $rigidIds]
if {[pid $::HybridCore::workerChannel] ne $sharedWorkerPid} { error "persistent worker PID changed between seam and bolt modules" }
set boltCount [llength [dict get [dict get $boltRun payload] candidates]]
if {$boltCount != 1} { error "bolt smoke expected 1 pair, got $boltCount" }
set ::RB2Bolt::P(propName) ""
set boltCreate [::RB2Bolt::executePythonPlans [dict get $boltRun payload]]
::HybridCore::closeLog
if {[dict get $boltCreate created] != 1} { error "bolt smoke expected 1 created beam, got $boltCreate" }

set solidComp [::HybridSmoke::component HYBRID_SMOKE_SOLID 31]
# Build a first-order hexa annulus: its inner cylindrical free-face patch is
# a real through-hole candidate, while the outer patch is rejected by the
# geometry/normal checks.  This turns the smoke into export -> recognition ->
# native RBE2 creation coverage instead of merely checking Python status.
set holeInnerBottom {}; set holeOuterBottom {}
set holeInnerTop {}; set holeOuterTop {}
set holeSegments 12
for {set i 0} {$i < $holeSegments} {incr i} {
    set a [expr {2.0*acos(-1.0)*$i/double($holeSegments)}]
    set ca [expr {cos($a)}]; set sa [expr {sin($a)}]
    lappend holeInnerBottom [::HybridSmoke::node [expr {60.0+5.0*$ca}] [expr {5.0*$sa}] 40.0]
    lappend holeOuterBottom [::HybridSmoke::node [expr {60.0+10.0*$ca}] [expr {10.0*$sa}] 40.0]
    lappend holeInnerTop [::HybridSmoke::node [expr {60.0+5.0*$ca}] [expr {5.0*$sa}] 50.0]
    lappend holeOuterTop [::HybridSmoke::node [expr {60.0+10.0*$ca}] [expr {10.0*$sa}] 50.0]
}
for {set i 0} {$i < $holeSegments} {incr i} {
    set j [expr {($i+1)%$holeSegments}]
    ::HybridSmoke::solid [list \
        [lindex $holeInnerBottom $i] [lindex $holeOuterBottom $i] \
        [lindex $holeOuterBottom $j] [lindex $holeInnerBottom $j] \
        [lindex $holeInnerTop $i] [lindex $holeOuterTop $i] \
        [lindex $holeOuterTop $j] [lindex $holeInnerTop $j]]
}
set ::AutoHoleRBE2::ui(selectedComps) [list $solidComp]
set autoRun [::AutoHoleRBE2::runPythonRecognition]
if {[pid $::HybridCore::workerChannel] ne $sharedWorkerPid} { error "persistent worker PID changed between bolt and auto-hole modules" }
set restoredFaceComp ""
catch {set restoredFaceComp [hm_getvalue comps name=^faces dataname=id]}
if {$restoredFaceComp eq "" || $restoredFaceComp == 0} {
    error "auto hole export did not restore the ^faces component name"
}
catch {*createmark comps 2 all}
foreach componentId [hm_getmark comps 2] {
    set componentName [hm_getvalue comps id=$componentId dataname=name]
    if {[string match "HMWF_AUTO_HOLE_FACES_*" $componentName]} {
        error "auto hole export leaked temporary component name $componentName"
    }
}
catch {*clearmark comps 2}
set autoStatus [dict get [dict get $autoRun payload] status]
set autoCount [llength [dict get [dict get $autoRun payload] candidates]]
if {$autoCount != 1} { error "auto hole smoke expected 1 through-hole candidate, got $autoCount" }
set autoCreate [::AutoHoleRBE2::executePythonCandidates [dict get $autoRun payload]]
::HybridCore::closeLog
if {$autoStatus ne "SUCCESS"} { error "auto hole smoke did not return SUCCESS" }
if {[dict get $autoCreate created] != 1 || [dict get $autoCreate failed] != 0} {
    error "auto hole smoke expected 1 created RBE2, got $autoCreate"
}

set report [open [file join $root runtime hm_hybrid_export_smoke.ok] w]
puts $report "HyperMesh 2019 Tcl export -> Python -> sidecar smoke passed"
puts $report "shared_worker_pid=$sharedWorkerPid requests=4"
puts $report "washer_candidates=$washerCount washer_created=[lindex $washerCreate 0] seam_path_nodes=[llength $seamPath] bolt_pairs=$boltCount bolt_created=[dict get $boltCreate created] auto_status=$autoStatus auto_candidates=$autoCount auto_created=[dict get $autoCreate created]"
close $report
