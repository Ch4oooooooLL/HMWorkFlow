# ============================================================================
# HMWorkFlow Shortcut Bootstrap
# HyperMesh 2019 Tcl/Tk
#
# Silent startup entry. This file must not open HMWorkFlow windows.
# ============================================================================

set hmworkflowBatchWorkerBootstrap [expr {
    [info exists ::env(HMWORKFLOW_BATCH_WORKER)] &&
    [string trim $::env(HMWORKFLOW_BATCH_WORKER)] eq "1"
}]

if {$hmworkflowBatchWorkerBootstrap} {
    # BatchMesher hmbatch processes source their dedicated launcher Tcl.  They
    # do not need UI shortcuts or the warm Python worker from an interactive
    # HyperMesh session.  Skipping both also prevents an installed older copy
    # of HMWorkFlow from populating the worker interpreter before its explicit
    # launcher is sourced.
    catch {puts "HMWorkFlow interactive bootstrap skipped for BatchMesher worker."}
} elseif {[catch {
    set hmworkflowRoot [file dirname [file normalize [info script]]]
    set hmworkflowCore [file join $hmworkflowRoot "hw_toolkit_core.tcl"]
    if {![file exists $hmworkflowCore]} {
        error "Core file not found: $hmworkflowCore"
    }
    source -encoding utf-8 $hmworkflowCore
    set ::HWToolkit::QUIET_ERRORS 1

    if {![::HWToolkit::ensureCoreLoaded]} {
        error "Could not load HMWorkFlow common modules."
    }
    if {[llength [info commands ::HWShortcut::initialize]] == 0} {
        set shortcutFile [file join $hmworkflowRoot "modules" "shortcut_manager.tcl"]
        if {![file exists $shortcutFile]} {
            error "Shortcut manager not found: $shortcutFile"
        }
        source -encoding utf-8 $shortcutFile
    }
    # HyperWorks 2019 normally has its key API ready here.  HyperWorks 2022
    # sources hmcustom.tcl earlier, so this call retries asynchronously until
    # the modeling context can accept shortcut registrations.
    ::HWShortcut::startStartupInitialization

    set hybridCoreInit [file join $hmworkflowRoot "modules" "hybrid_core" "tcl" "init.tcl"]
    if {![file exists $hybridCoreInit]} {
        error "Hybrid Python core not found: $hybridCoreInit"
    }
    if {[llength [info commands ::HybridCore::scheduleInstanceWorker]] == 0} {
        source -encoding utf-8 $hybridCoreInit
    }
    ::HybridCore::scheduleInstanceWorker
} hmworkflowShortcutError]} {
    catch {puts "HMWorkFlow shortcut initialization failed:"}
    catch {puts $hmworkflowShortcutError}
}

unset hmworkflowBatchWorkerBootstrap
