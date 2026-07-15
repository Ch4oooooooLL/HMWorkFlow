set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
source [file join $root modules hybrid_core tcl init.tcl]
set entry [file join $root modules hybrid_core python runtime_self_test.py]

proc ::HybridCore::benchmarkWorkerMode {enabled iterations entry} {
    variable persistentWorkerEnabled
    set persistentWorkerEnabled $enabled
    if {!$enabled} { ::HybridCore::stopPersistentWorker }
    set started [clock milliseconds]
    for {set i 0} {$i < $iterations} {incr i} {
        set ws [::HybridCore::createTaskWorkspace worker_benchmark]
        set dir [dict get $ws task_dir]
        ::HybridCore::setProgressRange 0 100 "Worker benchmark" "iteration [expr {$i+1}]/$iterations"
        ::HybridCore::runPythonEntry $entry [list --output-dir $dir] $dir
        ::HybridCore::closeLog
    }
    return [expr {([clock milliseconds]-$started)/double($iterations)}]
}

# Warm up once so the persistent measurement excludes its intentional first start.
set ::HybridCore::persistentWorkerEnabled 1
set warm [::HybridCore::createTaskWorkspace worker_benchmark]
::HybridCore::runPythonEntry $entry [list --output-dir [dict get $warm task_dir]] [dict get $warm task_dir]
::HybridCore::closeLog
set persistentMs [::HybridCore::benchmarkWorkerMode 1 5 $entry]
set oneShotMs [::HybridCore::benchmarkWorkerMode 0 5 $entry]
set ::HybridCore::persistentWorkerEnabled 1

set report [open [file join $root runtime hm_worker_benchmark.txt] w]
puts $report [format "persistent_average_ms=%.3f" $persistentMs]
puts $report [format "one_shot_average_ms=%.3f" $oneShotMs]
if {$persistentMs>0} { puts $report [format "speedup=%.2fx" [expr {$oneShotMs/$persistentMs}]] }
close $report
