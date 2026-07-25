# ============================================================================
# HyperMesh Toolkit - Main Entry
# HyperMesh 2019 Tcl/Tk
#
# Compatibility launcher. install_update.tcl is the supported entry point for
# both first installation and later tool-library updates.
# ============================================================================

set scriptDir [file dirname [file normalize [info script]]]
set installerFile [file join $scriptDir "install_update.tcl"]

if {[catch {
    if {![file exists $installerFile]} {
        error "Install/update file not found: $installerFile"
    }
    source -encoding utf-8 $installerFile
} hwToolkitErr]} {
    catch {puts "HMWorkFlow startup failed: $hwToolkitErr"}
    if {[llength [info commands tk_messageBox]] > 0} {
        tk_messageBox -icon error -title "HM WorkFlow" -message "HMWorkFlow startup failed:\n$hwToolkitErr"
    } else {
        catch {hm_usermessage "HMWorkFlow startup failed."}
    }
}
