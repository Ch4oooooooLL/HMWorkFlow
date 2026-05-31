# ======================================================================
# HyperMesh Preprocess Workflow Toolkit - Main Entry
# HyperMesh 2019 Tcl/Tk
#
# Main launcher with a workflow-oriented Tk GUI.
# ======================================================================

namespace eval ::HWToolkit {
    variable SCRIPT_DIR [file dirname [file normalize [info script]]]
    variable COMMON_MODULES {workflow_common}
    variable MODULES
    variable SOURCED_FILES {}

    set MODULES {
        component_category {
            group    "01. Organize"
            file     "component_workflow"
            label    "Component Type Classification"
            desc     "Classify components into SHELL, SOLID or CASTING and rename them with the category prefix."
            proc     "::CompWorkflow::runCategory"
        }
        material_assignment {
            group    "01. Organize"
            file     "component_workflow"
            label    "Material Assignment"
            desc     "Assign material keys from the TXT library, rename components and organize material assemblies."
            proc     "::CompWorkflow::runMaterial"
        }
        midsurf {
            group    "02. Geometry"
            label    "Midsurface Extraction"
            desc     "Extract sheet-metal midsurfaces and name outputs as CATEGORY_NAME_Tx_MATERIAL."
            proc     "::MidSurf::run"
        }
        seam_surface {
            group    "03. Seam"
            label    "Seam Surface Creation"
            desc     "Create SEAM_Tx geometry surfaces with Line-Surface or Line-Line workflows."
            proc     "::SeamSurf::run"
        }
        shell_washer_hole_rbe2 {
            group    "04. RBE2"
            label    "Shell Washer-Hole RBE2"
            desc     "Create RBE2 elements for shell washer holes."
            proc     "::RB2W::run"
        }
        auto_hole_rbe2 {
            group    "04. RBE2"
            label    "Solid Through-Hole RBE2"
            desc     "Create RBE2 elements for cylindrical through-holes in solid meshes."
            proc     "::AutoHoleRBE2::run"
        }
        rbe2_bolt_connector {
            group    "05. Bolt"
            label    "RBE2 Bolt Connector"
            desc     "Group RBE2 elements and create CBEAM/CBAR bolt segments."
            proc     "::RB2Bolt::run"
        }
    }
}

proc ::HWToolkit::moduleFile {key {info ""}} {
    variable SCRIPT_DIR
    set fileKey $key
    if {$info ne "" && [dict exists $info file]} {
        set fileKey [dict get $info file]
    }
    return [file join $SCRIPT_DIR "modules" "${fileKey}.tcl"]
}

proc ::HWToolkit::sourceOneModule {key {info ""}} {
    variable SOURCED_FILES
    set f [::HWToolkit::moduleFile $key $info]
    set norm [file normalize $f]
    if {[lsearch -exact $SOURCED_FILES $norm] >= 0} {
        return 1
    }
    if {![file exists $f]} {
        tk_messageBox -icon error -title "HWToolkit" -message "Module file not found:\n$f"
        return 0
    }
    if {[catch {uplevel #0 [list source $f]} err]} {
        tk_messageBox -icon error -title "HWToolkit" -message "Failed to load module $key:\n$err"
        return 0
    }
    lappend SOURCED_FILES $norm
    return 1
}

proc ::HWToolkit::sourceModules {} {
    variable COMMON_MODULES
    variable MODULES
    variable SOURCED_FILES
    set SOURCED_FILES {}

    foreach key $COMMON_MODULES {
        if {![::HWToolkit::sourceOneModule $key]} {
            return 0
        }
    }
    foreach {key info} $MODULES {
        if {![::HWToolkit::sourceOneModule $key $info]} {
            return 0
        }
    }
    return 1
}

proc ::HWToolkit::moduleGroups {} {
    variable MODULES
    set groups {}
    foreach {key info} $MODULES {
        set group [dict get $info group]
        if {[lsearch -exact $groups $group] < 0} {
            lappend groups $group
        }
    }
    return $groups
}

proc ::HWToolkit::clearExistingWindows {} {
    catch {::CompWorkflow::saveState}
    catch {::MidSurf::savePanelState}
    catch {::AutoHoleRBE2::savePanelState}
    catch {::RB2Bolt::saveState}
    catch {::SeamSurf::savePanelState}

    catch {set ::MidSurf::ui(ok) 0}
    catch {set ::MidSurf::ui(promptOk) -1}
    catch {set ::AutoHoleRBE2::ui(ok) 0}
    catch {set ::RB2Bolt::done -1}
    catch {set ::SeamSurf::ui(ok) 0}
    catch {set ::SeamSurf::ui(promptOk) -1}
    catch {set ::SeamSurf::ui(pickOk) -1}

    foreach w {
        .hwtoolkit
        .comp_category
        .material_assign
        .material_editor
        .midsurf_dlg
        .midsurf_thick
        .autoHoleRBE2
        .rb2bolt_dlg
        .seam_surface
        .seam_thickness
        .seam_pick
    } {
        if {[winfo exists $w]} {
            catch {destroy $w}
        }
    }
    catch {update idletasks}
}

proc ::HWToolkit::showPanel {} {
    variable MODULES

    catch {destroy .hwtoolkit}
    set w .hwtoolkit
    toplevel $w
    wm title $w "HyperMesh Preprocess Workflow Toolkit"
    wm resizable $w 0 0

    frame $w.header -padx 12 -pady 10
    pack $w.header -fill x
    label $w.header.title -text "HyperMesh Preprocess Workflow Toolkit" -font {Arial 14 bold}
    label $w.header.subtitle -text "Workflow modules for HyperMesh 2019 preprocessing" -font {Arial 9}
    pack $w.header.title -anchor w
    pack $w.header.subtitle -anchor w

    frame $w.body -padx 12 -pady 4
    pack $w.body -fill both -expand 1

    set row 0
    foreach group [::HWToolkit::moduleGroups] {
        labelframe $w.body.g$row -text $group -padx 8 -pady 8
        grid $w.body.g$row -row $row -column 0 -sticky ew -pady 4
        grid columnconfigure $w.body.g$row 0 -weight 1

        set innerRow 0
        foreach {key info} $MODULES {
            if {[dict get $info group] ne $group} {
                continue
            }
            set labelText [dict get $info label]
            set descText [dict get $info desc]
            label $w.body.g$row.l_$key -text $labelText -font {Arial 9 bold} -anchor w
            message $w.body.g$row.d_$key -text $descText -width 430 -anchor w -font {Arial 9}
            button $w.body.g$row.b_$key -text "Run" -width 10 -command [list ::HWToolkit::runModule $key]
            grid $w.body.g$row.l_$key -row $innerRow -column 0 -sticky w -padx {0 8} -pady {2 0}
            grid $w.body.g$row.b_$key -row $innerRow -column 1 -sticky e -pady {2 0}
            incr innerRow
            grid $w.body.g$row.d_$key -row $innerRow -column 0 -columnspan 2 -sticky w -padx {12 0} -pady {0 6}
            incr innerRow
        }
        incr row
    }
    grid columnconfigure $w.body 0 -weight 1

    frame $w.foot -padx 12 -pady 10
    pack $w.foot -fill x
    button $w.foot.close -text "Exit" -width 10 -command "destroy .hwtoolkit"
    pack $w.foot.close -side right
    bind $w <Escape> "destroy .hwtoolkit"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
    catch {wm deiconify $w}
    catch {raise $w}
    catch {focus -force $w}
    catch {wm attributes $w -topmost 1}
    catch {after 250 [list catch [list wm attributes $w -topmost 0]]}
    tkwait window $w
}

proc ::HWToolkit::showHome {} {
    if {[winfo exists .hwtoolkit]} {
        raise .hwtoolkit
        return
    }
    ::HWToolkit::showPanel
}

proc ::HWToolkit::runModule {key} {
    variable MODULES
    catch {destroy .hwtoolkit}

    set info [dict get $MODULES $key]
    set procName [dict get $info proc]
    if {[catch {uplevel #0 [list $procName]} err]} {
        tk_messageBox -icon error -title "HWToolkit" -message "Module $key error:\n$err"
    }
}

proc ::HWToolkit::run {} {
    if {![::HWToolkit::sourceModules]} {
        return
    }
    ::HWToolkit::clearExistingWindows
    if {[catch {::HWToolkit::showPanel} err]} {
        tk_messageBox -icon error -title "HWToolkit" -message "Panel error:\n$err"
    }
}

::HWToolkit::run
