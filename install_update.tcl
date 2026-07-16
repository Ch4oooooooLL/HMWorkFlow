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

    source $hybridCoreInit
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

proc ::HWInstaller::run {} {
    variable ROOT
    set coreFile [file join $ROOT hw_toolkit_core.tcl]
    if {![file exists $coreFile]} {
        error "HMWorkFlow core file not found: $coreFile"
    }
    source $coreFile
    if {![::HWToolkit::ensureCoreLoaded]} {
        error "HMWorkFlow common modules could not be loaded."
    }
    if {[llength [info commands ::HWShortcut::initialize]] == 0} {
        error "HMWorkFlow shortcut manager could not be loaded."
    }

    ::HWShortcut::initialize
    ::HWShortcut::installAutoLoader

    ::HWInstaller::reloadHybridCore
    if {![::HWShortcut::mainShortcutConfigured]} {
        ::HWShortcut::showInitialSetup
    }

    catch {puts "HMWorkFlow install/update completed. Native key library: [::HWShortcut::nativeLibraryStatus]"}
    ::HWToolkit::run
}

if {[catch {::HWInstaller::run} hwInstallerError]} {
    catch {puts "HMWorkFlow install/update failed: $hwInstallerError"}
    if {[llength [info commands tk_messageBox]] > 0} {
        catch {tk_messageBox -icon error -title "HMWorkFlow" -message "HMWorkFlow install/update failed:\n$hwInstallerError"}
    } else {
        catch {hm_usermessage "HMWorkFlow install/update failed."}
    }
}
