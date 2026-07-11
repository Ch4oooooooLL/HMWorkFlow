# ============================================================================
# HyperMesh Toolkit - Main Entry
# HyperMesh 2019 Tcl/Tk
#
# Manual launcher. The core file can be sourced silently by startup scripts.
# ============================================================================

set scriptDir [file dirname [file normalize [info script]]]
set coreFile [file join $scriptDir "hw_toolkit_core.tcl"]

if {[catch {
    if {![file exists $coreFile]} {
        error "Core file not found: $coreFile"
    }
    source $coreFile
    ::HWToolkit::run
} hwToolkitErr]} {
    catch {puts "HMWorkFlow startup failed: $hwToolkitErr"}
    if {[llength [info commands tk_messageBox]] > 0} {
        tk_messageBox -icon error -title "HM WorkFlow" -message "HMWorkFlow startup failed:\n$hwToolkitErr"
    } else {
        catch {hm_usermessage "HMWorkFlow startup failed."}
    }
}
