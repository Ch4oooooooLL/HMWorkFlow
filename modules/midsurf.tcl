# ============================================================================
# MidSurf v0.1
# HyperMesh 2019 Tcl/Tk
#
# Batch midsurface extraction for sheet-metal geometry components.
# Output component names are generated as:
#   <source component name>_T<thickness>
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::MidSurf {
    variable VERSION "0.1"

    variable cfg
    array set cfg {
        middleSurfaceName     "Middle Surface"
        alignSteps            1
        midPosition           0.5
        extractByComp         1
        rerunType             9
        stitchTolMode         0
        maxRTtRatio           2.0
        maxThicknessRatio     10.0
        surfaceNormals        -1
        fallbackThickness     0.0
        thicknessFormat       "%.3g"
        variableThicknessTol  0.05
        requireCleanMiddle    1
        keepTransparency      0
        hideSourceComponent   1
    }

    variable ui
    array set ui {
        ok 0
        selectedComps ""
        selectedText "No components selected"
        promptOk 0
        promptValue ""
    }

    variable stat
    array set stat {}
}

proc ::MidSurf::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::MidSurf::savePanelState {} {
    variable cfg
    variable ui
    foreach k [array names cfg] {
        if {[info exists ui($k)]} {
            set cfg($k) $ui($k)
        }
    }
    if {[llength [info commands ::HWFlow::saveArrayState]] > 0} {
        ::HWFlow::saveArrayState midsurf ::MidSurf::cfg
    }
}

# ----------------------------------------------------------------------
# UI
# ----------------------------------------------------------------------

proc ::MidSurf::showPanel {} {
    variable cfg
    variable ui
    variable VERSION

    catch {destroy .midsurf_dlg}
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray midsurf ::MidSurf::cfg
    }

    foreach k [array names cfg] {
        set ui($k) $cfg($k)
    }
    set ui(ok) 0
    set ui(selectedComps) ""
    set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]

    set w .midsurf_dlg
    toplevel $w
    wm title $w "[::HWFlow::txt "钣金中面抽取" "MidSurf"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "钣金中面抽取" "Midsurface Extraction"] -font {Arial 10 bold}
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 组件选择" "1. Component Selection"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    button $w.main.sel.pick -text [::HWFlow::txt "选择/重选组件" "Pick / Repick Components"] -width 24 -command "::MidSurf::pickComponents"
    label $w.main.sel.info -textvariable ::MidSurf::ui(selectedText) -width 64 -anchor w
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.param -text [::HWFlow::txt "2. 中面抽取参数" "2. Midsurface Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    set r 0
    label $w.main.param.l_method -text [::HWFlow::txt "抽取方法" "Extraction Method"] -anchor w
    tk_optionMenu $w.main.param.m_method ::MidSurf::ui(rerunType) 0 3 6 9
    label $w.main.param.tip_method -text [::HWFlow::txt "0=偏置，3=偏置+平面，6=蒙皮偏置，9=偏置+平面+扫掠" "0=offset, 3=offset+planes, 6=skin offset, 9=offset+planes+sweeps"] -anchor w
    grid $w.main.param.l_method -row $r -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.param.m_method -row $r -column 1 -sticky w -padx {0 10} -pady 2
    grid $w.main.param.tip_method -row $r -column 2 -columnspan 2 -sticky w -pady 2
    incr r

    set fields {
        {alignSteps            "阶梯对齐步数" "Step alignment"}
        {midPosition           "中面位置" "Mid position"}
        {maxRTtRatio           "最大 R/T 比" "Max R/T"}
        {maxThicknessRatio     "最大厚度比" "Max thickness ratio"}
        {surfaceNormals        "曲面法向" "Surface normals"}
        {variableThicknessTol  "变厚容差" "Variable thickness tolerance"}
        {fallbackThickness     "备用厚度" "Fallback thickness"}
        {thicknessFormat       "厚度格式" "Thickness format"}
    }

    set i 0
    foreach item $fields {
        set key [lindex $item 0]
        set name [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        set row [expr {$r + ($i / 2)}]
        set col [expr {($i % 2) * 2}]

        label $w.main.param.l_$key -text $name -anchor w
        entry $w.main.param.e_$key -textvariable ::MidSurf::ui($key) -width 16
        grid $w.main.param.l_$key -row $row -column $col -sticky w -padx {0 6} -pady 2
        grid $w.main.param.e_$key -row $row -column [expr {$col + 1}] -sticky w -padx {0 18} -pady 2
        incr i
    }
    set r [expr {$r + 4}]

    labelframe $w.main.opt -text [::HWFlow::txt "3. 选项" "3. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    checkbutton $w.main.opt.clean -text [::HWFlow::txt "运行前要求不存在 Middle Surface 临时组件" "Require no existing Middle Surface component before running"] \
        -variable ::MidSurf::ui(requireCleanMiddle)
    checkbutton $w.main.opt.trans -text [::HWFlow::txt "保留输入几何透明状态" "Keep input geometry transparency"] \
        -variable ::MidSurf::ui(keepTransparency)
    checkbutton $w.main.opt.hide -text [::HWFlow::txt "抽取后隐藏源几何组件" "Hide source geometry component after extraction"] \
        -variable ::MidSurf::ui(hideSourceComponent)
    grid $w.main.opt.clean -row 0 -column 0 -sticky w -pady 2
    grid $w.main.opt.trans -row 1 -column 0 -sticky w -pady 2
    grid $w.main.opt.hide -row 2 -column 0 -sticky w -pady 2

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x

    button $w.btn.cancel -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "::MidSurf::savePanelState; set ::MidSurf::ui(ok) 0; ::MidSurf::backToHome .midsurf_dlg"
    button $w.btn.start -text [::HWFlow::txt "开始抽取" "Start Extraction"] -width 16 -command "::MidSurf::acceptPanel"
    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.start -side right -padx 4

    bind $w <Escape> "::MidSurf::savePanelState; set ::MidSurf::ui(ok) 0; destroy .midsurf_dlg"
    wm protocol $w WM_DELETE_WINDOW "::MidSurf::savePanelState; set ::MidSurf::ui(ok) 0; destroy .midsurf_dlg"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]

    tkwait window $w
    return $ui(ok)
}

proc ::MidSurf::pickComponents {} {
    variable ui

    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "选择需要抽取中面的几何组件" "Select geometry components for midsurface extraction"]
    set comps [hm_getmark comps 1]
    catch {*clearmark comps 1}

    if {[llength $comps] == 0} {
        set ui(selectedComps) ""
        set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]
    } else {
        set ui(selectedComps) [::MidSurf::uniq $comps]
        set ui(selectedText) [::HWFlow::txt "已选择 [llength $ui(selectedComps)] 个组件" "Selected [llength $ui(selectedComps)] component(s)"]
    }

    catch {raise .midsurf_dlg}
    catch {focus .midsurf_dlg}
}

proc ::MidSurf::acceptPanel {} {
    variable cfg
    variable ui

    if {[llength $ui(selectedComps)] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }

    foreach k {alignSteps extractByComp rerunType stitchTolMode surfaceNormals requireCleanMiddle keepTransparency hideSourceComponent} {
        if {![string is integer -strict $ui($k)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "$k 必须为整数。" "$k must be an integer."]
            return
        }
    }

    foreach k {midPosition maxRTtRatio maxThicknessRatio fallbackThickness variableThicknessTol} {
        if {![string is double -strict $ui($k)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "$k 必须为数值。" "$k must be a number."]
            return
        }
    }

    if {$ui(alignSteps) < 0 || $ui(alignSteps) > 5} {
        tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "alignSteps 必须在 0 到 5 之间。" "alignSteps must be between 0 and 5."]
        return
    }
    if {$ui(midPosition) < 0.0 || $ui(midPosition) > 1.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "midPosition 必须在 0 到 1 之间。" "midPosition must be between 0 and 1."]
        return
    }
    if {$ui(maxRTtRatio) <= 0.0 || $ui(maxThicknessRatio) <= 1.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "maxRTtRatio 必须大于 0，maxThicknessRatio 必须大于 1。" "maxRTtRatio must be > 0 and maxThicknessRatio must be > 1."]
        return
    }
    if {$ui(variableThicknessTol) < 0.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "variableThicknessTol 不能为负值。" "variableThicknessTol cannot be negative."]
        return
    }
    if {[string trim $ui(thicknessFormat)] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "thicknessFormat 不能为空。" "thicknessFormat cannot be empty."]
        return
    }

    foreach k [array names cfg] {
        set cfg($k) $ui($k)
    }
    ::MidSurf::savePanelState

    set ui(ok) 1
    destroy .midsurf_dlg
}

proc ::MidSurf::askThickness {compName defaultValue reason} {
    variable ui

    catch {destroy .midsurf_thick}

    set ui(promptOk) 0
    if {$defaultValue ne "" && $defaultValue > 0.0} {
        set ui(promptValue) $defaultValue
    } else {
        set ui(promptValue) ""
    }

    set w .midsurf_thick
    toplevel $w
    wm title $w [::HWFlow::txt "输入厚度" "Input Thickness"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "无法可靠读取厚度：" "Thickness could not be read reliably:"] -font {Arial 10 bold}
    label $w.main.comp -text $compName -anchor w
    message $w.main.reason -text $reason -width 420 -anchor w
    label $w.main.lbl -text [::HWFlow::txt "输入用于命名的厚度 T：" "Enter thickness T for naming:"] -anchor w
    entry $w.main.entry -textvariable ::MidSurf::ui(promptValue) -width 20

    grid $w.main.title -row 0 -column 0 -columnspan 2 -sticky w -pady {0 4}
    grid $w.main.comp -row 1 -column 0 -columnspan 2 -sticky w -pady {0 4}
    grid $w.main.reason -row 2 -column 0 -columnspan 2 -sticky w -pady {0 8}
    grid $w.main.lbl -row 3 -column 0 -sticky w -padx {0 8}
    grid $w.main.entry -row 3 -column 1 -sticky w

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.cancel -text [::HWFlow::txt "使用 UNKNOWN" "Use UNKNOWN"] -width 14 -command "set ::MidSurf::ui(promptOk) -1; destroy .midsurf_thick"
    button $w.btn.ok -text [::HWFlow::txt "确定" "OK"] -width 10 -command "::MidSurf::acceptThicknessPrompt"
    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.ok -side right -padx 4

    bind $w <Return> "::MidSurf::acceptThicknessPrompt"
    bind $w <Escape> "set ::MidSurf::ui(promptOk) -1; destroy .midsurf_thick"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]

    tkwait window $w
    if {$ui(promptOk) == 1} {
        return $ui(promptValue)
    }
    return ""
}

proc ::MidSurf::acceptThicknessPrompt {} {
    variable ui

    set v [string trim $ui(promptValue)]
    if {![string is double -strict $v] || $v <= 0.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "中面抽取" "MidSurf"] -message [::HWFlow::txt "厚度必须为大于 0 的数值。" "Thickness must be a number greater than 0."]
        return
    }

    set ui(promptValue) $v
    set ui(promptOk) 1
    destroy .midsurf_thick
}

# ----------------------------------------------------------------------
# Utilities
# ----------------------------------------------------------------------

proc ::MidSurf::msg {txt} {
    catch {hm_usermessage $txt}
    catch {puts $txt}
    catch {update}
}

proc ::MidSurf::uniq {lst} {
    array set seen {}
    set out {}
    foreach v $lst {
        if {$v eq ""} {
            continue
        }
        if {![info exists seen($v)]} {
            set seen($v) 1
            lappend out $v
        }
    }
    return $out
}

proc ::MidSurf::median {vals} {
    set vals2 {}
    foreach v $vals {
        if {[string is double -strict $v] && $v > 0.0} {
            lappend vals2 $v
        }
    }
    set n [llength $vals2]
    if {$n == 0} {
        return ""
    }
    set sorted [lsort -real $vals2]
    set mid [expr {$n / 2}]
    if {[expr {$n % 2}] == 1} {
        return [lindex $sorted $mid]
    }
    return [expr {([lindex $sorted [expr {$mid - 1}]] + [lindex $sorted $mid]) / 2.0}]
}

proc ::MidSurf::valueSpreadRatio {vals center} {
    if {$center eq "" || $center <= 0.0} {
        return 0.0
    }
    set minv 1.0e99
    set maxv -1.0
    set count 0
    foreach v $vals {
        if {![string is double -strict $v] || $v <= 0.0} {
            continue
        }
        if {$v < $minv} { set minv $v }
        if {$v > $maxv} { set maxv $v }
        incr count
    }
    if {$count < 2} {
        return 0.0
    }
    return [expr {($maxv - $minv) / double($center)}]
}

proc ::MidSurf::formatThickness {value} {
    variable cfg

    if {$value eq "" || ![string is double -strict $value] || $value <= 0.0} {
        return "UNKNOWN"
    }

    if {[catch {set out [format $cfg(thicknessFormat) $value]}]} {
        set out [format %.3g $value]
    }

    set out [string trim $out]
    regsub -all {[^0-9A-Za-z_.+-]+} $out {_} out
    if {$out eq ""} {
        return "UNKNOWN"
    }
    return $out
}

proc ::MidSurf::getComponentName {compId} {
    foreach etype {comps components component} {
        if {![catch {set n [hm_getcollectorname $etype $compId]}] && $n ne ""} {
            return $n
        }
    }
    foreach etype {comps components component} {
        if {![catch {set n [hm_entityinfo name $etype $compId -byid]}] && $n ne ""} {
            return $n
        }
    }
    if {![catch {set n [hm_getvalue comps id=$compId dataname=name]}] && $n ne ""} {
        return $n
    }
    return "comp_$compId"
}

proc ::MidSurf::componentExistsByName {compName} {
    if {![catch {set exists [hm_entityinfo exist components $compName -byname]}]} {
        return $exists
    }
    if {![catch {set cid [hm_entityinfo id components $compName -byname]}] && $cid ne "" && $cid != 0} {
        return 1
    }
    return 0
}

proc ::MidSurf::componentIdByName {compName} {
    foreach etype {components comps component} {
        if {![catch {set cid [hm_entityinfo id $etype $compName -byname]}] && $cid ne "" && $cid != 0} {
            return $cid
        }
    }

    foreach etype {components comps} {
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 "by name only" $compName}]} {
            if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                catch {*clearmark $etype 2}
                return [lindex $ids 0]
            }
        }
        catch {*clearmark $etype 2}
    }

    return ""
}

proc ::MidSurf::markComponentByName {compName markId} {
    foreach etype {components comps} {
        catch {*clearmark $etype $markId}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $etype $markId $selector $compName}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                    return $etype
                }
            }
        }
    }
    return ""
}

proc ::MidSurf::enableInteractiveBrowserUpdates {} {
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {*setoption block_redraw=0}
    catch {*setoption block_messages=0}
    catch {hm_blockredraw 0}
    catch {hm_blockmessages 0}
    catch {hm_blockerrormessages 0}
    catch {hm_commandfilestate 1}
    catch {update idletasks}
}

proc ::MidSurf::refreshComponentBrowser {compName} {
    set markType [::MidSurf::markComponentByName $compName 2]
    if {$markType ne ""} {
        catch {*marksuppressactive $markType 2 0}
        catch {*marksuppressoutput $markType 2 0}
        catch {*displaycollectorsbymark $markType 2 on 1 1}
        catch {*displaycollectorsallbymark 2 on 1 1}
        catch {*clearmark $markType 2}
    }
    catch {*displaycollector component on $compName 1 1}
    catch {*displaycollector components on $compName 1 1}
    catch {*displaycollectorwithfilter component on $compName 1 1}
    catch {*displaycollectorwithfilter components on $compName 1 1}
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {hm_redraw}
    catch {update idletasks}
    catch {update}
}

proc ::MidSurf::getCompEntityIds {compId dataname markEntityType} {
    set ids {}
    if {![catch {set ids [hm_getvalue comps id=$compId dataname=$dataname]}] && [llength $ids] > 0} {
        return [::MidSurf::uniq $ids]
    }

    catch {*clearmark $markEntityType 2}
    if {![catch {*createmark $markEntityType 2 "by comp id" $compId}]} {
        catch {set ids [hm_getmark $markEntityType 2]}
    }
    catch {*clearmark $markEntityType 2}
    return [::MidSurf::uniq $ids]
}

proc ::MidSurf::markInputGeometry {compId} {
    set solids [::MidSurf::getCompEntityIds $compId solids solids]
    if {[llength $solids] > 0} {
        catch {*clearmark solids 1}
        eval *createmark solids 1 $solids
        return [list solids $solids]
    }

    set surfs [::MidSurf::getCompEntityIds $compId surfaces surfs]
    if {[llength $surfs] > 0} {
        catch {*clearmark surfs 1}
        eval *createmark surfs 1 $surfs
        return [list surfaces $surfs]
    }

    return [list "" {}]
}

proc ::MidSurf::uniqueComponentName {baseName} {
    set base [string trim $baseName]
    if {$base eq ""} {
        set base "Midsurface_TUNKNOWN"
    }

    if {![::MidSurf::componentExistsByName $base]} {
        return $base
    }

    for {set i 1} {$i <= 999} {incr i} {
        set cand [format "%s_%02d" $base $i]
        if {![::MidSurf::componentExistsByName $cand]} {
            return $cand
        }
    }

    return [format "%s_%s" $base [clock seconds]]
}

proc ::MidSurf::deleteComponentByName {compName} {
    foreach etype {components comps} {
        catch {*clearmark $etype 2}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $etype 2 $selector $compName}]} {
                if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                    catch {*deletemark $etype 2}
                    catch {*clearmark $etype 2}
                    return 1
                }
            }
        }
        catch {*clearmark $etype 2}
    }
    return 0
}

proc ::MidSurf::clearMarks {} {
    foreach etype {comps components solids surfs surfaces elems nodes points lines} {
        catch {*clearmark $etype 1}
        catch {*clearmark $etype 2}
    }
}

# ----------------------------------------------------------------------
# Thickness helpers
# ----------------------------------------------------------------------

proc ::MidSurf::readComponentThickness {compId} {
    set vals {}

    if {![catch {set t [hm_getthickness comps $compId]}] && $t ne "" && [string is double -strict $t] && $t > 0.0} {
        lappend vals $t
    }

    if {![catch {set t [hm_getvalue comps id=$compId dataname=thickness]}] && $t ne "" && [string is double -strict $t] && $t > 0.0} {
        lappend vals $t
    }

    return $vals
}

proc ::MidSurf::readThicknessFromSurface {surfId} {
    set vals {}

    foreach etype {surfs surfaces} {
        if {![catch {set t [hm_getvalue $etype id=$surfId dataname=thickness]}] &&
            $t ne "" && [string is double -strict $t] && $t > 0.0} {
            lappend vals $t
        }
    }

    foreach etype {surfs surfaces} {
        if {![catch {set raw [hm_getsurfacethicknessvalues $etype $surfId]}] && [llength $raw] > 0} {
            foreach item $raw {
                if {[llength $item] >= 2} {
                    set t [lindex $item 1]
                } else {
                    set t $item
                }
                if {[string is double -strict $t] && $t > 0.0} {
                    lappend vals $t
                }
            }
        }
    }

    return $vals
}

proc ::MidSurf::readThicknessFromPoints {compId} {
    set vals {}
    set pts [::MidSurf::getCompEntityIds $compId points points]

    foreach pt $pts {
        if {[catch {set raw [hm_getsurfacethicknessvalues points $pt]}]} {
            continue
        }

        foreach item $raw {
            if {[llength $item] >= 2} {
                set t [lindex $item 1]
            } else {
                set t $item
            }
            if {[string is double -strict $t] && $t > 0.0} {
                lappend vals $t
            }
        }
    }

    return $vals
}

proc ::MidSurf::readMiddleSurfaceThickness {midCompId} {
    set vals {}

    foreach surf [::MidSurf::getCompEntityIds $midCompId surfaces surfs] {
        set vals [concat $vals [::MidSurf::readThicknessFromSurface $surf]]
    }

    set vals [concat $vals [::MidSurf::readThicknessFromPoints $midCompId]]
    return $vals
}

proc ::MidSurf::chooseThickness {sourceCompId sourceName midCompId} {
    variable cfg

    set vals [::MidSurf::readMiddleSurfaceThickness $midCompId]
    if {[llength $vals] == 0} {
        set vals [::MidSurf::readComponentThickness $sourceCompId]
    }
    if {[llength $vals] == 0 && $cfg(fallbackThickness) > 0.0} {
        return $cfg(fallbackThickness)
    }

    set t [::MidSurf::median $vals]
    if {$t eq ""} {
        return [::MidSurf::askThickness $sourceName $cfg(fallbackThickness) "No readable thickness data was found in the midsurface result."]
    }

    set spread [::MidSurf::valueSpreadRatio $vals $t]
    if {$spread > $cfg(variableThicknessTol)} {
        set reason [format "Variable thickness appears high. Median thickness is %.6g and relative spread is about %.3f." $t $spread]
        set userT [::MidSurf::askThickness $sourceName $t $reason]
        if {$userT ne ""} {
            return $userT
        }
    }

    return $t
}

proc ::MidSurf::sourceThicknessCandidate {sourceCompId} {
    variable cfg

    set vals [::MidSurf::readComponentThickness $sourceCompId]
    foreach surf [::MidSurf::getCompEntityIds $sourceCompId surfaces surfs] {
        set vals [concat $vals [::MidSurf::readThicknessFromSurface $surf]]
    }
    set vals [concat $vals [::MidSurf::readThicknessFromPoints $sourceCompId]]

    set t [::MidSurf::median $vals]
    if {$t eq "" && $cfg(fallbackThickness) > 0.0} {
        return $cfg(fallbackThickness)
    }
    return $t
}

proc ::MidSurf::outputNameForSource {sourceName thickness} {
    set tText [::MidSurf::formatThickness $thickness]
    if {[namespace exists ::HWFlow]} {
        return [::HWFlow::formatMidsurfName $sourceName $tText]
    }
    return "${sourceName}_T${tText}"
}

proc ::MidSurf::existingOutputForSource {sourceCompId sourceName {thickness ""}} {
    if {$thickness eq ""} {
        set thickness [::MidSurf::sourceThicknessCandidate $sourceCompId]
    }
    if {$thickness eq ""} {
        return {}
    }

    set base [::MidSurf::outputNameForSource $sourceName $thickness]
    set candidates [list $base]
    for {set i 1} {$i <= 999} {incr i} {
        lappend candidates [format "%s_%02d" $base $i]
    }

    foreach name $candidates {
        set cid [::MidSurf::componentIdByName $name]
        if {$cid eq ""} {
            if {$name eq $base} {
                continue
            }
            break
        }
        set surfs [::MidSurf::getCompEntityIds $cid surfaces surfs]
        if {[llength $surfs] > 0} {
            return [list $name [llength $surfs] $thickness]
        }
    }
    return {}
}

# ----------------------------------------------------------------------
# HyperMesh operations
# ----------------------------------------------------------------------

proc ::MidSurf::extractMidsurface {entityType} {
    variable cfg

    if {$entityType eq "solids"} {
        set normals 3
    } else {
        set normals $cfg(surfaceNormals)
    }

    set extractByComp $cfg(extractByComp)
    if {$cfg(keepTransparency)} {
        set extractByComp [expr {$extractByComp + 10}]
    }

    set cmd19 [list *midsurface_extract_10 \
        $entityType 1 \
        $normals \
        0 \
        $cfg(alignSteps) \
        $extractByComp \
        $cfg(rerunType) \
        $cfg(stitchTolMode) \
        $cfg(maxRTtRatio) \
        0 \
        0 \
        $cfg(maxThicknessRatio) \
        0 \
        0 \
        $cfg(midPosition) \
        undefined \
        0 \
        0 \
        1]

    set err19 ""
    if {![catch {eval $cmd19} err19]} {
        return
    }

    set cmd17 [list *midsurface_extract_10 \
        $entityType 1 \
        $normals \
        0 \
        $cfg(alignSteps) \
        $extractByComp \
        $cfg(rerunType) \
        $cfg(stitchTolMode) \
        $cfg(maxRTtRatio) \
        $cfg(maxThicknessRatio) \
        0 \
        0 \
        $cfg(midPosition) \
        undefined \
        0 \
        0 \
        1]

    set err17 ""
    if {![catch {eval $cmd17} err17]} {
        return
    }

    error [::HWFlow::txt "midsurface_extract_10 执行失败。19 参数错误：$err19；17 参数错误：$err17" "midsurface_extract_10 failed. 19-arg error: $err19; 17-arg error: $err17"]
}

proc ::MidSurf::renameMiddleSurface {sourceName thickness midCompId} {
    variable cfg

    set outName [::MidSurf::outputNameForSource $sourceName $thickness]
    set existingId [::MidSurf::componentIdByName $outName]
    if {$existingId ne "" && $existingId ne $midCompId} {
        error [::HWFlow::txt "目标中面组件 $outName 已存在，本次创建已跳过。" "Target midsurface component $outName already exists; this creation was skipped."]
    }

    if {$outName ne $cfg(middleSurfaceName)} {
        ::MidSurf::enableInteractiveBrowserUpdates
        set histName "Renamed Component $cfg(middleSurfaceName) to $outName"
        catch {*startnotehistorystate $histName}
        if {[catch {*renamecollector component $cfg(middleSurfaceName) $outName} err]} {
            if {[catch {*renamecollector components $cfg(middleSurfaceName) $outName} err2]} {
                catch {*endnotehistorystate $histName}
                error [::HWFlow::txt "无法将 $cfg(middleSurfaceName) 重命名为 $outName：$err / $err2" "Cannot rename $cfg(middleSurfaceName) to $outName: $err / $err2"]
            }
        }
        catch {*endnotehistorystate $histName}
    }

    catch {*currentcollector component $outName}
    catch {*currentcollector components $outName}
    ::MidSurf::refreshComponentBrowser $outName

    return $outName
}

proc ::MidSurf::hideSourceComponent {sourceName} {
    variable cfg
    if {!$cfg(hideSourceComponent)} {
        return
    }
    if {[namespace exists ::HWFlow]} {
        ::HWFlow::displayComponent $sourceName off
    } else {
        catch {*displaycollector component off $sourceName 1 1}
        catch {*displaycollector components off $sourceName 1 1}
        catch {hm_redraw}
    }
}

proc ::MidSurf::processComponent {compId} {
    variable cfg

    set sourceName [::MidSurf::getComponentName $compId]
    ::MidSurf::msg [::HWFlow::txt "中面抽取：正在处理 $sourceName" "MidSurf: processing $sourceName"]

    set existing [::MidSurf::existingOutputForSource $compId $sourceName]
    if {[llength $existing] > 0} {
        set outName [lindex $existing 0]
        set surfCount [lindex $existing 1]
        ::MidSurf::msg [::HWFlow::txt "中面抽取：$sourceName 对应的 $outName 已存在，跳过创建。" "MidSurf: $sourceName already has $outName, skipped creation."]
        return [list $outName $surfCount [lindex $existing 2] existing]
    }

    if {$cfg(requireCleanMiddle) && [::MidSurf::componentExistsByName $cfg(middleSurfaceName)]} {
        error [::HWFlow::txt "组件 \"$cfg(middleSurfaceName)\" 已存在。请在运行前重命名/删除该组件，或关闭 Middle Surface 清洁检查。" "Component \"$cfg(middleSurfaceName)\" already exists. Rename/delete it before running, or disable the clean Middle Surface check."]
    }

    set markInfo [::MidSurf::markInputGeometry $compId]
    set entityType [lindex $markInfo 0]
    set entities [lindex $markInfo 1]

    if {$entityType eq "" || [llength $entities] == 0} {
        error [::HWFlow::txt "组件 $sourceName 中没有可抽取的实体或曲面。" "Component $sourceName contains no solids or surfaces."]
    }

    ::MidSurf::extractMidsurface $entityType

    set midCompId [::MidSurf::componentIdByName $cfg(middleSurfaceName)]
    if {$midCompId eq ""} {
        error [::HWFlow::txt "中面抽取已结束，但未找到 \"$cfg(middleSurfaceName)\" 组件。" "Extraction finished, but \"$cfg(middleSurfaceName)\" component was not found."]
    }

    set newSurfs [::MidSurf::getCompEntityIds $midCompId surfaces surfs]
    if {[llength $newSurfs] == 0} {
        error [::HWFlow::txt "中面抽取已结束，但 \"$cfg(middleSurfaceName)\" 组件中没有曲面。" "Extraction finished, but \"$cfg(middleSurfaceName)\" contains no surfaces."]
    }

    set thickness [::MidSurf::chooseThickness $compId $sourceName $midCompId]
    set existing [::MidSurf::existingOutputForSource $compId $sourceName $thickness]
    if {[llength $existing] > 0} {
        ::MidSurf::deleteComponentByName $cfg(middleSurfaceName)
        set outName [lindex $existing 0]
        set surfCount [lindex $existing 1]
        ::MidSurf::msg [::HWFlow::txt "中面抽取：$sourceName 对应的 $outName 已存在，已清理本轮临时中面并跳过创建。" "MidSurf: $sourceName already has $outName; cleaned this run's temporary midsurface and skipped creation."]
        return [list $outName $surfCount [lindex $existing 2] existing]
    }

    set outName [::MidSurf::renameMiddleSurface $sourceName $thickness $midCompId]
    ::MidSurf::hideSourceComponent $sourceName

    ::MidSurf::msg [::HWFlow::txt "中面抽取：$sourceName -> $outName，曲面数=[llength $newSurfs]" "MidSurf: $sourceName -> $outName, surfaces=[llength $newSurfs]"]
    return [list $outName [llength $newSurfs] $thickness]
}

# ----------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------

proc ::MidSurf::run {} {
    variable ui
    variable stat
    variable VERSION

    if {![::MidSurf::showPanel]} {
        catch {hm_usermessage [::HWFlow::txt "中面抽取已取消。" "MidSurf cancelled."]}
        return
    }

    array set stat {
        selected 0
        created 0
        existing 0
        skipped 0
        surfaces 0
    }

    set comps [::MidSurf::uniq $ui(selectedComps)]
    set stat(selected) [llength $comps]
    set failures {}
    set createdNames {}
    set existingNames {}

    ::MidSurf::msg [::HWFlow::txt "中面抽取 v$VERSION 开始，组件数=[llength $comps]" "MidSurf v$VERSION started. Components=[llength $comps]"]

    foreach compId $comps {
        set sourceName [::MidSurf::getComponentName $compId]

        if {[catch {set result [::MidSurf::processComponent $compId]} err]} {
            incr stat(skipped)
            lappend failures "$sourceName: $err"
            ::MidSurf::msg [::HWFlow::txt "中面抽取警告：$sourceName 已跳过。$err" "MidSurf warning: $sourceName skipped. $err"]
            continue
        }

        if {[llength $result] >= 4 && [lindex $result 3] eq "existing"} {
            incr stat(existing)
            lappend existingNames [lindex $result 0]
        } else {
            incr stat(created)
            set stat(surfaces) [expr {$stat(surfaces) + [lindex $result 1]}]
            lappend createdNames [lindex $result 0]
        }
        catch {update}
    }

    ::MidSurf::clearMarks

    set msg [::HWFlow::txt "中面抽取 v$VERSION 已完成。\n\n已选择组件：$stat(selected)\n已创建中面组件：$stat(created)\n已创建曲面：$stat(surfaces)\n已跳过既有中面：$stat(existing)\n跳过/失败：$stat(skipped)" "MidSurf v$VERSION finished.\n\nSelected components: $stat(selected)\nCreated midsurface components: $stat(created)\nCreated surfaces: $stat(surfaces)\nSkipped existing midsurfaces: $stat(existing)\nSkipped/failed: $stat(skipped)"]

    if {[llength $createdNames] > 0} {
        append msg [::HWFlow::txt "\n\n已创建：\n" "\n\nCreated:\n"]
        append msg [join [lrange $createdNames 0 9] "\n"]
        if {[llength $createdNames] > 10} {
            append msg "\n..."
        }
    }
    if {[llength $existingNames] > 0} {
        append msg [::HWFlow::txt "\n\n已存在并跳过：\n" "\n\nAlready existed and skipped:\n"]
        append msg [join [lrange $existingNames 0 9] "\n"]
        if {[llength $existingNames] > 10} {
            append msg "\n..."
        }
    }

    if {[llength $failures] > 0} {
        append msg [::HWFlow::txt "\n\n失败项：\n" "\n\nFailures:\n"]
        append msg [join [lrange $failures 0 4] "\n"]
        if {[llength $failures] > 5} {
            append msg "\n..."
        }
    }

    catch {tk_messageBox -icon info -title "[::HWFlow::txt "钣金中面抽取" "MidSurf"] v$VERSION" -message $msg}
    ::MidSurf::msg $msg
}
