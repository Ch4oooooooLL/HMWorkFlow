# HyperMesh 2019 bridge self-test. This file does not modify the model.
set selfTestDir [file dirname [file normalize [info script]]]
source -encoding utf-8 [file join $selfTestDir init.tcl]

set workspace [::HybridCore::createTaskWorkspace hybrid_core_self_test]
set taskDir [dict get $workspace task_dir]
set runId [dict get $workspace run_id]
set entry [file join $::HybridCore::MODULE_DIR python runtime_self_test.py]

set code [catch {
    ::HybridCore::runPythonEntry $entry [list --output-dir $taskDir] $taskDir
    # The offline self-test uses a fixed payload run ID. Verify the common
    # loader itself here; per-module entries will use the workspace run ID.
    set payload [::HybridCore::loadResultSidecar \
        [file join $taskDir result.tcl] \
        ::HybridCore::selfTestResult \
        hybrid_core_self_test SELF_TEST]
    ::HybridCore::log INFO "HyperMesh bridge self-test passed python_status=[dict get $payload status] workspace_run_id=$runId"
} err opts]

::HybridCore::closeLog
if {$code} {
    set message "Hybrid bridge self-test failed:\n$err\n\nTask directory:\n$taskDir"
    if {[llength [info commands tk_messageBox]] > 0} {
        tk_messageBox -icon error -title "Hybrid Bridge Self-Test" -message $message
    } else {
        catch {puts stderr $message}
    }
    return -options $opts $err
}

set message "Hybrid bridge self-test passed.\n\nTask directory:\n$taskDir"
if {[llength [info commands tk_messageBox]] > 0} {
    tk_messageBox -icon info -title "Hybrid Bridge Self-Test" -message $message
} else {
    catch {puts $message}
}
