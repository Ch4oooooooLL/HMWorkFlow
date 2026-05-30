# ======================================================================
# HyperMesh RBE2 Toolkit - Main Entry
# HyperMesh 2019 Tcl/Tk
#
# Main launcher with Tk GUI, sources module files from modules/ folder.
# ======================================================================

namespace eval ::HWToolkit {
    variable MODULES
    variable SCRIPT_DIR [file dirname [file normalize [info script]]]

    set MODULES {
        auto_hole_rbe2 {
            label    "贯通孔 RBE2"
            desc     "3D 实体网格贯通孔自动创建 RBE2"
            proc     "::AutoHoleRBE2::run"
        }
        rbe2_bolt_connector {
            label    "RBE2 螺栓连接"
            desc     "RBE2 分组并创建 CBEAM 螺栓段"
            proc     "::RB2Bolt::run"
        }
        shell_washer_hole_rbe2 {
            label    "Shell 垫圈孔 RBE2"
            desc     "Shell 垫圈孔自动创建 RBE2"
            proc     "::RB2W::main"
        }
        midsurf {
            label    "钣金抽中面"
            desc     "钣金件抽中面并重命名为 原名_T厚度"
            proc     "::MidSurf::run"
        }
    }
}

proc ::HWToolkit::sourceModules {} {
    variable SCRIPT_DIR
    variable MODULES

    foreach {key info} $MODULES {
        set src [dict get $MODULES $key]
        set f [file join $SCRIPT_DIR "modules" "${key}.tcl"]
        if {[file exists $f]} {
            if {[catch {uplevel \#0 [list source $f]} err]} {
                tk_messageBox -icon error -title "HWToolkit" \
                    -message "Failed to load module $key:\n$err"
                return 0
            }
        } else {
            tk_messageBox -icon error -title "HWToolkit" \
                -message "Module file not found:\n$f"
            return 0
        }
    }
    return 1
}

proc ::HWToolkit::showPanel {} {
    variable MODULES

    catch {destroy .hwtoolkit}

    set w .hwtoolkit
    toplevel $w
    wm title $w "HyperMesh RBE2 Toolkit"
    wm resizable $w 0 0

    frame $w.header -padx 12 -pady 8
    pack $w.header -fill x

    label $w.header.title -text "HyperMesh RBE2 Toolkit" -font {Arial 14 bold}
    label $w.header.subtitle -text "请选择需要执行的功能模块" -font {Arial 9}
    pack $w.header.title -anchor w
    pack $w.header.subtitle -anchor w

    set body $w.body
    frame $body -padx 12 -pady 4
    pack $body -fill both -expand 1

    set row 0
    foreach {key info} $MODULES {
        set lbl [dict get $info label]
        set desc [dict get $info desc]

        labelframe $body.f_$key -text $lbl -padx 8 -pady 6
        grid $body.f_$key -row $row -column 0 -sticky ew -padx 0 -pady 4

        message $body.f_$key.desc -text $desc -width 360 -anchor w -font {Arial 9}
        grid $body.f_$key.desc -row 0 -column 0 -sticky w -padx {0 8}

        button $body.f_$key.run -text "运行" -width 8 \
            -command [list ::HWToolkit::runModule $key]
        grid $body.f_$key.run -row 0 -column 1 -sticky e

        incr row
    }

    grid columnconfigure $body 0 -weight 1

    frame $w.foot -padx 12 -pady 8
    pack $w.foot -fill x

    button $w.foot.close -text "关闭" -width 10 -command "destroy .hwtoolkit"
    pack $w.foot.close -side right -padx 4

    bind $w <Escape> "destroy .hwtoolkit"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]

    tkwait window $w
}

proc ::HWToolkit::runModule {key} {
    variable MODULES

    catch {destroy .hwtoolkit}

    set info [dict get $MODULES $key]
    set procName [dict get $info proc]

    if {[catch {uplevel \#0 [list $procName]} err]} {
        tk_messageBox -icon error -title "HWToolkit" \
            -message "Module $key error:\n$err"
    }
}

proc ::HWToolkit::run {} {
    if {![::HWToolkit::sourceModules]} {
        return
    }
    if {[catch {::HWToolkit::showPanel} err]} {
        tk_messageBox -icon error -title "HWToolkit" \
            -message "Panel error:\n$err"
    }
}

::HWToolkit::run