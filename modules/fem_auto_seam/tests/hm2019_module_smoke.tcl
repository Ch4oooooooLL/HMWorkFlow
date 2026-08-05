if {[info exists ::env(HMWF_REPO_ROOT)] && $::env(HMWF_REPO_ROOT) ne ""} {
    set root [file normalize $::env(HMWF_REPO_ROOT)]
} else {
    set root [file normalize [file join [file dirname [info script]] .. .. ..]]
}
source -encoding utf-8 [file join $root modules fem_auto_seam.tcl]

foreach command {
    ::FemAutoSeam::showPendingReview
    ::FemAutoSeam::autoReviewIsolate
    ::FemAutoSeam::browseFile
    ::FemAutoSeam::runWorkflow
    ::FemAutoSeam::applyAutoPlanDelta
    ::FemAutoSeam::workflowProgressOpen
    ::FemAutoSeam::autoReviewFitIsolated
    ::FemAutoSeam::pendingReviewOpenMeshSeamWeld
    ::FemAutoSeam::cleanupTaskWorkspace
} {
    if {[llength [info commands $command]] != 1} { error "missing command: $command" }
}
foreach key {
    near_edge_distance criteria_path param_path
    optimize_neighborhood optimization_layers optimization_iterations
} {
    if {![info exists ::FemAutoSeam::cfg($key)]} { error "missing configuration key: $key" }
}
set ::FemAutoSeam::cfg(optimize_neighborhood) 0
set ::FemAutoSeam::cfg(criteria_path) ""
set ::FemAutoSeam::cfg(param_path) ""
set defaultCriteria [::FemAutoSeam::effectiveSpecificationPath criteria_path]
set defaultParam [::FemAutoSeam::effectiveSpecificationPath param_path]
foreach path [list $defaultCriteria $defaultParam] {
    if {![file isfile $path] || [file size $path] == 0} { error "missing built-in specification: $path" }
}
*readqualitycriteria $defaultCriteria
set settings [::FemAutoSeam::jsonSettings]
foreach token {optimize_neighborhood criteria_path param_path near_edge_distance} {
    if {[string first $token $settings] < 0} { error "auto JSON is missing: $token" }
}
if {[string first {"optimize_neighborhood": true} $settings] < 0} {
    error "Python optimization must remain enabled regardless of stale UI state"
}
foreach path [list $defaultCriteria $defaultParam] {
    if {[string first [string map {\\ \\\\} $path] $settings] < 0 && [string first $path $settings] < 0} {
        error "resolved built-in specification is missing from JSON: $path"
    }
}
set cleanupDir [file join $root runtime tasks fem_auto_seam hm2019_cleanup_contract]
catch {file delete -force $cleanupDir}
file mkdir [file join $cleanupDir input]
foreach path [list [file join $cleanupDir before.hm] [file join $cleanupDir result.fem] [file join $cleanupDir task.meta] [file join $cleanupDir input transient.json]] {
    ::HWFlow::writeTextFile $path test
}
::HybridCore::openLog [file join $cleanupDir operation.log]
::HybridCore::log INFO "cleanup contract keeps this file open before cleanup"
set retained [::FemAutoSeam::cleanupTaskWorkspace $cleanupDir]
if {$retained ne [list before.hm result.fem]} { error "cleanup contract failed: $retained" }
catch {file delete -force $cleanupDir}
set reportPath [file join $root runtime tasks fem_auto_seam hm2019_module_smoke.txt]
if {[info exists ::env(HMWF_STAGE2_REPORT)] && $::env(HMWF_STAGE2_REPORT) ne ""} {
    set reportPath [file normalize $::env(HMWF_STAGE2_REPORT)]
}
file mkdir [file dirname $reportPath]
set channel [open $reportPath w]
puts $channel "FEM_AUTO_SEAM_TCL_SMOKE PASS version=$::FemAutoSeam::VERSION default_criteria=$defaultCriteria default_param=$defaultParam cleanup=before.hm,result.fem"
close $channel
