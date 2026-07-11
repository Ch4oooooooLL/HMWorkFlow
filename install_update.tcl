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
