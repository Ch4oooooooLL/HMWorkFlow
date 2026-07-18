set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
source [file join $root modules workflow_common.tcl]
source [file join $root modules hybrid_core tcl init.tcl]

set workspace [::HybridCore::createTaskWorkspace platform_service_smoke]
set taskDir [dict get $workspace task_dir]
set token [dict get $workspace task_token]
set legacyRuntime [file normalize [file join $root runtime]]
if {[string first "${legacyRuntime}/" "${taskDir}/"] == 0} {
    error "platform task unexpectedly wrote into the installation runtime: $taskDir"
}
set output [file join $taskDir detached_output.txt]
set entry [file join $root modules hybrid_core tests detached_task_smoke.py]
set result [::HybridCore::runDetachedPythonStage $entry [list --output $output] $taskDir smoke $token]
if {![file isfile $output] || [string trim [::HybridCore::readTextFile $output]] ne $token} {
    error "detached task token did not round-trip"
}
if {[dict get $result task_token] ne $token} {error "detached service returned the wrong token"}
::HybridCore::finalizeTaskWorkspace $taskDir SUCCESS
::HybridCore::stopPersistentWorker
