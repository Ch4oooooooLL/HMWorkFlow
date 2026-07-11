# ============================================================================
# HMWorkFlow Shortcut Bootstrap
# HyperMesh 2019 Tcl/Tk
#
# Silent startup entry. This file must not open HMWorkFlow windows.
# ============================================================================

if {[catch {
    set hmworkflowRoot [file dirname [file normalize [info script]]]
    set hmworkflowCore [file join $hmworkflowRoot "hw_toolkit_core.tcl"]
    if {![file exists $hmworkflowCore]} {
        error "Core file not found: $hmworkflowCore"
    }
    source $hmworkflowCore
    set ::HWToolkit::QUIET_ERRORS 1

    if {![::HWToolkit::ensureCoreLoaded]} {
        error "Could not load HMWorkFlow common modules."
    }
    if {[llength [info commands ::HWShortcut::initialize]] == 0} {
        set shortcutFile [file join $hmworkflowRoot "modules" "shortcut_manager.tcl"]
        if {![file exists $shortcutFile]} {
            error "Shortcut manager not found: $shortcutFile"
        }
        source $shortcutFile
    }
    ::HWShortcut::initialize
} hmworkflowShortcutError]} {
    catch {puts "HMWorkFlow shortcut initialization failed:"}
    catch {puts $hmworkflowShortcutError}
}
