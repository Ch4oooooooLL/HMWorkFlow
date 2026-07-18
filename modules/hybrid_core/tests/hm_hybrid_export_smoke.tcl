set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
# hmbatch does not load the interactive profile framework.  Select the
# OptiStruct template directly so solver-specific property APIs are available.
set optiTemplate [file normalize [file join [file dirname [info nameofexecutable]] .. .. .. templates feoutput optistruct optistruct]]
if {![file exists $optiTemplate]} {error "OptiStruct template not found: $optiTemplate"}
*templatefileset $optiTemplate
foreach module {auto_hole_rbe2.tcl shell_washer_hole_rbe2.tcl rbe2_bolt_connector.tcl mesh_seam_weld.tcl} {
    source [file join $root modules $module]
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
set snodes {}
foreach xyz {{0 0 40} {10 0 40} {10 10 40} {0 10 40} {0 0 50} {10 0 50} {10 10 50} {0 10 50}} {
    lappend snodes [::HybridSmoke::node {*}$xyz]
}
::HybridSmoke::solid $snodes
set ::AutoHoleRBE2::ui(selectedComps) [list $solidComp]
set autoRun [::AutoHoleRBE2::runPythonRecognition]
if {[pid $::HybridCore::workerChannel] ne $sharedWorkerPid} { error "persistent worker PID changed between bolt and auto-hole modules" }
set autoStatus [dict get [dict get $autoRun payload] status]
::HybridCore::closeLog
if {$autoStatus ne "SUCCESS"} { error "auto hole smoke did not return SUCCESS" }

set report [open [file join $root runtime hm_hybrid_export_smoke.ok] w]
puts $report "HyperMesh 2019 Tcl export -> Python -> sidecar smoke passed"
puts $report "shared_worker_pid=$sharedWorkerPid requests=4"
puts $report "washer_candidates=$washerCount washer_created=[lindex $washerCreate 0] seam_path_nodes=[llength $seamPath] bolt_pairs=$boltCount bolt_created=[dict get $boltCreate created] auto_status=$autoStatus"
close $report
