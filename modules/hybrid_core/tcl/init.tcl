namespace eval ::HybridCore {
    variable SCHEMA_VERSION "1.0"
    variable TCL_DIR [file dirname [file normalize [info script]]]
    variable MODULE_DIR [file dirname $TCL_DIR]
    variable ROOT_DIR [file dirname [file dirname $MODULE_DIR]]
    variable TASK_ROOT [file join $ROOT_DIR runtime tasks]
    variable currentRunId ""
    variable currentTaskDir ""
    variable logChannel ""
    variable logPath ""
    variable persistentWorkerEnabled 1
    variable workerChannel ""
    variable workerPid ""
    variable workerPython ""
    variable workerSequence 0
    variable workerRequestTimeoutMs 1800000
    variable workerWaitDone 0
    variable workerWaitResponse ""
    variable workerWaitError ""
    variable workerProgressAfter ""
    variable cachedPython ""
    variable workerStartScheduled 0
    variable workerStartupError ""
    variable workerFileFingerprints {}
    variable workerCacheHits 0
    variable workerCacheMisses 0
    variable workerCacheEntries 0
    variable instanceId "hm-[pid]"
    variable instanceLogDir [file join $ROOT_DIR runtime instances "hm-[pid]"]
    variable progressRangeStart 0.0
    variable progressRangeEnd 100.0
    variable progressMessage "Python analysis"
    variable progressDetail ""
    variable progressLastUpdateMs 0
}

foreach fileName {
    data_writer.tcl
    binary_codec.tcl
    hm_bulk_reader.tcl
    bridge_logger.tcl
    task_workspace.tcl
    python_runtime.tcl
    progress_bridge.tcl
    process_runner.tcl
    result_loader.tcl
} {
    source [file join $::HybridCore::TCL_DIR $fileName]
}

# Start one warm Python process from each HyperMesh Tcl interpreter.  Because
# HyperMesh opens the stdio pipe itself, python.exe is a direct child process
# of that HyperMesh instance and cannot be shared by another instance.
proc ::HybridCore::initializeInstanceWorker {} {
    variable instanceId
    variable instanceLogDir
    variable workerStartScheduled
    variable workerStartupError

    set workerStartScheduled 0
    set workerStartupError ""
    if {[::HybridCore::workerAlive]} {
        return [::HybridCore::workerStatus]
    }

    if {[catch {
        file mkdir $instanceLogDir
        ::HybridCore::openLog [file join $instanceLogDir startup.log]
        ::HybridCore::log INFO "HyperMesh Python instance start instance_id=$instanceId owner_pid=[pid]"
        ::HybridCore::startPersistentWorker
    } err]} {
        set workerStartupError $err
        catch {::HybridCore::log ERROR "HyperMesh Python instance failed instance_id=$instanceId error=$err"}
        return -code error $err
    }
    return [::HybridCore::workerStatus]
}

proc ::HybridCore::initializeInstanceWorkerSafely {} {
    if {[catch {::HybridCore::initializeInstanceWorker} err]} {
        catch {puts "HMWorkFlow dedicated Python startup failed: $err"}
        return 0
    }
    return 1
}

proc ::HybridCore::scheduleInstanceWorker {} {
    variable workerStartScheduled
    if {[::HybridCore::workerAlive] || $workerStartScheduled} { return }
    set workerStartScheduled 1
    after idle ::HybridCore::initializeInstanceWorkerSafely
}
