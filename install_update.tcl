# ============================================================================
# HMWorkFlow Install / Update Entry
# HyperMesh 2019 Tcl/Tk
#
# Run this file whenever the tool library is first installed or updated.
# It refreshes the startup loader, initializes the native HyperMesh key library,
# asks for the main-panel shortcut only on first setup, then opens the toolkit.
# ============================================================================

namespace eval ::HWInstaller {
    variable SCRIPT_FILE [file normalize [info script]]
    variable ROOT [file dirname $SCRIPT_FILE]
    variable SESSION_ACTIONS {}
    variable UPDATE_REPORT ""
}

proc ::HWInstaller::recordAction {message} {
    variable SESSION_ACTIONS
    lappend SESSION_ACTIONS $message
    catch {puts "HMWorkFlow update: $message"}
}

proc ::HWInstaller::cancelHmWorkflowCallbacks {} {
    set prefixes {
        ::HWToolkit ::HWFlow ::HWShortcut ::HybridCore ::BatchMesher
        ::LocalMeshOptimizer ::SeamSurf ::MeshSeamWeld ::ContactSetup
        ::AdhesiveConnector ::SolidSeam ::WeldIntegrityCheck
    }
    set cancelled 0
    foreach afterId [after info] {
        if {[catch {set detail [after info $afterId]}]} { continue }
        set script [lindex $detail 0]
        set owned 0
        foreach prefix $prefixes {
            if {[string first $prefix $script] >= 0} { set owned 1; break }
        }
        if {!$owned} { continue }
        if {![catch {after cancel $afterId}]} { incr cancelled }
    }
    ::HWInstaller::recordAction "cancelled_callbacks=$cancelled"
}

proc ::HWInstaller::terminateKnownBatchProcesses {} {
    set processIds {}
    if {[namespace exists ::BatchMesher] && [array exists ::BatchMesher::runtime]} {
        if {[info exists ::BatchMesher::runtime(background_active)] &&
            ![catch {dict size $::BatchMesher::runtime(background_active)}]} {
            dict for {taskId job} $::BatchMesher::runtime(background_active) {
                foreach key {launcher_pid actual_pid pid} {
                    if {[dict exists $job $key]} {
                        set processId [dict get $job $key]
                        if {[string is integer -strict $processId] && $processId > 0} { lappend processIds $processId }
                    }
                }
            }
        }
        foreach key {background_merge_launcher_pid background_merge_pid} {
            if {[info exists ::BatchMesher::runtime($key)]} {
                set processId $::BatchMesher::runtime($key)
                if {[string is integer -strict $processId] && $processId > 0} { lappend processIds $processId }
            }
        }
        if {[info exists ::BatchMesher::runtime(background_after)] &&
            $::BatchMesher::runtime(background_after) ne ""} {
            catch {after cancel $::BatchMesher::runtime(background_after)}
        }
        if {[info exists ::BatchMesher::runtime(running)] &&
            $::BatchMesher::runtime(running) &&
            [llength [info commands ::BatchMesher::terminateBackgroundRun]] > 0} {
            catch {::BatchMesher::terminateBackgroundRun}
        }
    }
    set processIds [lsort -integer -unique $processIds]
    foreach processId $processIds {
        if {$::tcl_platform(platform) eq "windows"} {
            catch {exec taskkill.exe /PID $processId /T /F}
        } else {
            catch {exec kill -TERM $processId}
        }
    }
    ::HWInstaller::recordAction "terminated_batch_processes=$processIds"
}

proc ::HWInstaller::prepareLiveSession {} {
    variable SESSION_ACTIONS
    set SESSION_ACTIONS {}

    # Save user-facing module state while the old procedures are still valid.
    if {[llength [info commands ::HWToolkit::clearExistingWindows]] > 0} {
        catch {::HWToolkit::clearExistingWindows}
    }
    ::HWInstaller::terminateKnownBatchProcesses
    if {[llength [info commands ::HybridCore::stopPersistentWorker]] > 0} {
        if {[catch {::HybridCore::stopPersistentWorker} workerError]} {
            ::HWInstaller::recordAction "persistent_worker_stop_error=$workerError"
        } else {
            ::HWInstaller::recordAction "persistent_worker_stopped=1"
        }
    }
    ::HWInstaller::cancelHmWorkflowCallbacks

    # Sourcing a Tcl file overwrites procedures but leaves removed procedures,
    # namespace variables and nested callbacks alive.  Delete project-owned
    # module namespaces so this session cannot mix two installed generations.
    foreach namespaceName {
        ::AdhesiveConnector ::AutoHoleRBE2 ::BatchMesher
        ::BatchPropertyAssignment ::CastingTetMesh ::CBushCreator
        ::ContactSetup ::GeomCleanup ::LocalMeshOptimizer
        ::MeshSeamWeld ::MidSurf ::RB2Bolt ::RB2W ::SeamSurf
        ::BomMaterialAssignment ::SolidSeam ::SolidSeamCommandProfile ::WeldIntegrityCheck
        ::HWShortcut ::HWFlow ::HWToolkit
    } {
        if {[namespace exists $namespaceName]} { catch {namespace delete $namespaceName} }
    }
    ::HWInstaller::recordAction "stale_module_namespaces_removed=1"
}

proc ::HWInstaller::reloadHybridCore {} {
    variable ROOT
    set hybridCoreInit [file join $ROOT modules hybrid_core tcl init.tcl]
    if {![file isfile $hybridCoreInit]} {
        error "HMWorkFlow hybrid Python core not found: $hybridCoreInit"
    }

    # A HyperMesh process can retain the namespace, cached Python path and
    # persistent worker created from the previous project location.  Updating
    # the loader alone only fixes the next HyperMesh launch, so explicitly
    # dispose of the live session before loading the core from this installer.
    if {[namespace exists ::HybridCore]} {
        catch {after cancel ::HybridCore::initializeInstanceWorkerSafely}
        if {[llength [info commands ::HybridCore::stopPersistentWorker]] > 0} {
            catch {::HybridCore::stopPersistentWorker}
        }
        namespace delete ::HybridCore
    }

    source -encoding utf-8 $hybridCoreInit
    if {[llength [info commands ::HybridCore::scheduleInstanceWorker]] == 0} {
        error "HMWorkFlow hybrid Python core did not initialize: $hybridCoreInit"
    }

    set expectedRoot [file normalize $ROOT]
    set loadedRoot [file normalize $::HybridCore::ROOT_DIR]
    if {![string equal -nocase $expectedRoot $loadedRoot]} {
        error "HMWorkFlow hybrid Python root mismatch: expected $expectedRoot, loaded $loadedRoot"
    }
    ::HybridCore::scheduleInstanceWorker
}

proc ::HWInstaller::readPackageVersion {} {
    variable ROOT
    set path [file join $ROOT VERSION]
    if {![file isfile $path]} { return "unknown" }
    set channel [open $path r]
    set code [catch {string trim [read $channel]} value options]
    catch {close $channel}
    if {$code} { return -options $options $value }
    return $value
}

proc ::HWInstaller::verifyLoadedSession {} {
    variable ROOT
    set expectedRoot [file normalize $ROOT]
    if {![namespace exists ::BatchMesher]} { error "BatchMesher namespace was not loaded from the update." }
    foreach command {
        ::BatchMesher::launchDetachedHmbatch
        ::BatchMesher::writeWorkerManagerFailure
        ::BatchMesher::buildHmbatchCommand
        ::BatchMesher::probeHmbatchExecutable
    } {
        if {[llength [info commands $command]] == 0} { error "Updated command is missing: $command" }
    }
    set expectedModuleDir [file normalize [file join $ROOT modules batch_mesher]]
    set loadedModuleDir [file normalize $::BatchMesher::MODULE_DIR]
    if {![string equal -nocase $expectedModuleDir $loadedModuleDir]} {
        error "BatchMesher root mismatch: expected $expectedModuleDir, loaded $loadedModuleDir"
    }
    if {[package vcompare $::BatchMesher::VERSION 2.6] < 0} {
        error "Stale BatchMesher version is still loaded: $::BatchMesher::VERSION (expected 2.6 or newer)"
    }
    if {![info exists ::BatchMesher::WORKER_STARTUP_TIMEOUT_MS] ||
        $::BatchMesher::WORKER_STARTUP_TIMEOUT_MS < 60000} {
        error "Updated BatchMesher startup-handshake timeout was not loaded."
    }
    set launchBody [info body ::BatchMesher::launchDetachedHmbatch]
    if {[string first "HMWORKFLOW_BATCH_WORKER" $launchBody] < 0 ||
        [string first "workingDirectory" $launchBody] < 0} {
        error "Updated isolated hmbatch launcher was not loaded."
    }
    set commandBody [info body ::BatchMesher::buildHmbatchCommand]
    if {[string first "-nouserprofiledialog" $commandBody] < 0 ||
        [string first "-nocommand" $commandBody] < 0} {
        error "Updated non-interactive HM2022 hmbatch options were not loaded."
    }
    set workerFile [file join $expectedModuleDir background_worker.tcl]
    if {![file isfile $workerFile]} { error "Updated BatchMesher worker file is missing: $workerFile" }
    set workerChannel [open $workerFile r]
    set workerReadCode [catch {read $workerChannel} workerSource workerReadOptions]
    catch {close $workerChannel}
    if {$workerReadCode} { return -options $workerReadOptions $workerSource }
    set profileStart [string first "proc ::BatchMesherWorker::initializeBatchMeshProfile" $workerSource]
    if {$profileStart < 0 ||
        [string first "variable config" [string range $workerSource $profileStart [expr {$profileStart + 1200}]]] < 0} {
        error "Updated HyperMesh 2022 worker profile initializer was not loaded."
    }
    set loadedRoot [file normalize $::HybridCore::ROOT_DIR]
    if {![string equal -nocase $expectedRoot $loadedRoot]} {
        error "HybridCore root mismatch after update: expected $expectedRoot, loaded $loadedRoot"
    }
    return [dict create \
        package_version [::HWInstaller::readPackageVersion] \
        project_root $expectedRoot \
        batch_mesher_version $::BatchMesher::VERSION \
        batch_module_dir $loadedModuleDir \
        startup_timeout_ms $::BatchMesher::WORKER_STARTUP_TIMEOUT_MS \
        hm_pid [pid]]
}

proc ::HWInstaller::updateReportPath {} {
    variable ROOT
    variable UPDATE_REPORT
    if {[info exists ::env(LOCALAPPDATA)] && [string trim $::env(LOCALAPPDATA)] ne ""} {
        set reportDir [file join $::env(LOCALAPPDATA) HMWorkFlow runtime instances "hm-[pid]"]
    } else {
        set reportDir [file join $ROOT runtime instances "hm-[pid]"]
    }
    file mkdir $reportDir
    set UPDATE_REPORT [file join $reportDir install_update.log]
    return $UPDATE_REPORT
}

proc ::HWInstaller::writeUpdateReport {verification} {
    variable SESSION_ACTIONS
    set reportPath [::HWInstaller::updateReportPath]
    set lines [list \
        "status=SUCCESS" \
        "updated_ms=[clock milliseconds]" \
        "package_version=[dict get $verification package_version]" \
        "project_root=[file nativename [dict get $verification project_root]]" \
        "batch_mesher_version=[dict get $verification batch_mesher_version]" \
        "batch_module_dir=[file nativename [dict get $verification batch_module_dir]]" \
        "startup_timeout_ms=[dict get $verification startup_timeout_ms]" \
        "hm_pid=[dict get $verification hm_pid]"]
    foreach action $SESSION_ACTIONS { lappend lines "action=$action" }
    set channel [open $reportPath w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts -nonewline $channel [join $lines "\n"]
    close $channel
    return $reportPath
}

proc ::HWInstaller::writeUpdateFailureReport {message} {
    variable ROOT
    variable SESSION_ACTIONS
    set reportPath [::HWInstaller::updateReportPath]
    set lines [list \
        "status=FAILED" \
        "updated_ms=[clock milliseconds]" \
        "project_root=[file nativename $ROOT]" \
        "hm_pid=[pid]" \
        "error=$message"]
    foreach action $SESSION_ACTIONS { lappend lines "action=$action" }
    set channel [open $reportPath w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts -nonewline $channel [join $lines "\n"]
    close $channel
    return $reportPath
}

proc ::HWInstaller::run {} {
    variable ROOT
    set coreFile [file join $ROOT hw_toolkit_core.tcl]
    if {![file exists $coreFile]} {
        error "HMWorkFlow core file not found: $coreFile"
    }
    ::HWInstaller::prepareLiveSession
    source -encoding utf-8 $coreFile
    if {![::HWToolkit::ensureCoreLoaded]} {
        error "HMWorkFlow common modules could not be loaded."
    }
    ::HWInstaller::reloadHybridCore
    if {![::HWToolkit::sourceModules]} {
        error "HMWorkFlow modules could not be reloaded from the update root."
    }
    if {[llength [info commands ::HWShortcut::initialize]] == 0} {
        error "HMWorkFlow shortcut manager could not be loaded."
    }

    ::HWShortcut::initialize
    ::HWShortcut::installContextKeyHooks
    ::HWShortcut::installAutoLoader

    set verification [::HWInstaller::verifyLoadedSession]
    set updateReport [::HWInstaller::writeUpdateReport $verification]
    if {![::HWShortcut::mainShortcutConfigured]} {
        ::HWShortcut::showInitialSetup
    }

    set successMessage "HMWorkFlow install/update completed and the current HyperMesh session was reloaded.\n\nVersion: [dict get $verification package_version]\nRoot: [file nativename [dict get $verification project_root]]\nBatchMesher: v[dict get $verification batch_mesher_version]\nReport: [file nativename $updateReport]"
    catch {puts "$successMessage\nNative key library: [::HWShortcut::nativeLibraryStatus]"}
    if {[llength [info commands tk_messageBox]] > 0} {
        catch {tk_messageBox -icon info -title "HMWorkFlow Update" -message $successMessage}
    }
    ::HWToolkit::run
}

if {[catch {::HWInstaller::run} hwInstallerError]} {
    set hwInstallerFailureReport ""
    catch {set hwInstallerFailureReport [::HWInstaller::writeUpdateFailureReport $hwInstallerError]}
    set hwInstallerFailureMessage "HMWorkFlow install/update failed: $hwInstallerError"
    if {$hwInstallerFailureReport ne ""} { append hwInstallerFailureMessage "\nReport: [file nativename $hwInstallerFailureReport]" }
    catch {puts $hwInstallerFailureMessage}
    if {[llength [info commands tk_messageBox]] > 0} {
        catch {tk_messageBox -icon error -title "HMWorkFlow" -message $hwInstallerFailureMessage}
    } else {
        catch {hm_usermessage "HMWorkFlow install/update failed."}
    }
    unset hwInstallerFailureReport hwInstallerFailureMessage
}
