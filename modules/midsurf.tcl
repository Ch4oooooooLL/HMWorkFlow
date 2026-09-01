# ============================================================================
# MidSurf v0.8
# HyperMesh 2019 Tcl/Tk
#
# Batch midsurface extraction for sheet-metal geometry components.
# Output component names are generated as:
#   V01_<part name>_T<thickness>[_<material>]
# Existing versions advance to V02, V03, ... without being overwritten.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::MidSurf {
    variable VERSION "0.8"
    variable outputAssemblyName "MIDSURFED"

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
        variableThicknessTol  0.05
        requireCleanMiddle    1
        keepTransparency      0
    }

    variable ui
    array set ui {
        ok 0
        selectedComps ""
        selectedText "No components selected"
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
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 组件选择" "1. Component Selection"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    button $w.main.sel.pick -text [::HWFlow::txt "选择/重选组件" "Pick / Repick Components"] -width 24 -command "::MidSurf::pickComponents"
    label $w.main.sel.info -textvariable ::MidSurf::ui(selectedText) -width 64 -anchor w
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.param -text [::HWFlow::txt "2. Midsurface Parameters" "2. Midsurface Parameters"] -padx 8 -pady 8
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
    set r [expr {$r + 3}]

    labelframe $w.main.opt -text [::HWFlow::txt "3. 选项" "3. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    checkbutton $w.main.opt.clean -text [::HWFlow::txt "运行前要求不存在 Middle Surface 临时组件" "Require no existing Middle Surface component before running"] \
        -variable ::MidSurf::ui(requireCleanMiddle)
    checkbutton $w.main.opt.trans -text [::HWFlow::txt "保留输入几何透明状态" "Keep input geometry transparency"] \
        -variable ::MidSurf::ui(keepTransparency)
    grid $w.main.opt.clean -row 0 -column 0 -sticky w -pady 2
    grid $w.main.opt.trans -row 1 -column 0 -sticky w -pady 2

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
    ::HWFlow::centerWindow $w

    tkwait window $w
    return $ui(ok)
}

proc ::MidSurf::pickComponents {} {
    variable ui

    catch {*clearmark comps 1}
    ::HWFlow::nativeMarkPanel comps 1 [::HWFlow::txt "选择需要抽取中面的几何组件" "Select geometry components for midsurface extraction"]
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
        tk_messageBox -icon warning -title [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -message [::HWFlow::txt "请先选择组件。" "Pick components first."]
        return
    }

    foreach k {alignSteps extractByComp rerunType stitchTolMode surfaceNormals requireCleanMiddle keepTransparency} {
        if {![string is integer -strict $ui($k)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -message [::HWFlow::txt "$k 必须为整数。" "$k must be an integer."]
            return
        }
    }

    foreach k {midPosition maxRTtRatio maxThicknessRatio variableThicknessTol} {
        if {![string is double -strict $ui($k)]} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -message [::HWFlow::txt "$k 必须为数值。" "$k must be a number."]
            return
        }
    }

    if {$ui(alignSteps) < 0 || $ui(alignSteps) > 5} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -message [::HWFlow::txt "alignSteps 必须在 0 到 5 之间。" "alignSteps must be between 0 and 5."]
        return
    }
    if {$ui(midPosition) < 0.0 || $ui(midPosition) > 1.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -message [::HWFlow::txt "midPosition 必须在 0 到 1 之间。" "midPosition must be between 0 and 1."]
        return
    }
    if {$ui(maxRTtRatio) <= 0.0 || $ui(maxThicknessRatio) <= 1.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -message [::HWFlow::txt "maxRTtRatio 必须大于 0，maxThicknessRatio 必须大于 1。" "maxRTtRatio must be > 0 and maxThicknessRatio must be > 1."]
        return
    }
    if {$ui(variableThicknessTol) < 0.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] -message [::HWFlow::txt "variableThicknessTol 不能为负值。" "variableThicknessTol cannot be negative."]
        return
    }
    foreach k [array names cfg] {
        set cfg($k) $ui($k)
    }
    ::MidSurf::savePanelState

    set ui(ok) 1
    destroy .midsurf_dlg
}

# ----------------------------------------------------------------------
# Utilities
# ----------------------------------------------------------------------

proc ::MidSurf::msg {txt} {
    catch {hm_usermessage $txt}
    catch {puts $txt}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "MidSurf: $txt"}
    }
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
    if {[llength [info commands ::HWFlow::formatThicknessToken]] > 0} {
        return [::HWFlow::formatThicknessToken $value]
    }
    if {$value eq "" || ![string is double -strict $value] || $value <= 0.0} {
        return "UNKNOWN"
    }
    return [format "%.6g" $value]
}

proc ::MidSurf::getComponentName {compId} {
    if {[llength [info commands ::HWFlow::componentName]] > 0} {
        return [::HWFlow::componentName $compId]
    }
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
    return [expr {[::MidSurf::componentIdByName $compName] ne ""}]
}

proc ::MidSurf::componentIdByName {compName} {
    # Do not use HWFlow::componentIdByName here. Its compatibility fallback
    # intentionally treats HyperMesh .1/.2 duplicate suffixes as equivalent,
    # while midsurface region names use those suffixes as real identities.
    foreach etype {components comps component} {
        if {![catch {set cid [hm_entityinfo id $etype $compName -byname]}] && $cid ne "" && $cid != 0} {
            if {[::MidSurf::getComponentName $cid] eq $compName} {
                return $cid
            }
        }
    }

    foreach etype {components comps} {
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 all}]} {
            if {![catch {set ids [hm_getmark $etype 2]}]} {
                foreach cid $ids {
                    if {[::MidSurf::getComponentName $cid] eq $compName} {
                        catch {*clearmark $etype 2}
                        return $cid
                    }
                }
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
    if {[llength [info commands ::HWFlow::activateAndShowComponent]] > 0} {
        catch {::HWFlow::activateAndShowComponent $compName 0}
        catch {::HWFlow::refreshBrowser}
        return
    }
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
    # A midsurface extraction task is driven by solid bodies. Each solid in a
    # multi-body component becomes an independent task and produces surfaces
    # in its own result component. Surface input is compatibility fallback
    # only for source components that genuinely contain no solids.
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

proc ::MidSurf::listDifference {left right} {
    array set remove {}
    foreach id $right {
        set remove($id) 1
    }
    set out {}
    foreach id $left {
        if {![info exists remove($id)]} {
            lappend out $id
        }
    }
    return $out
}

# Return the topology-connected subset of target surfaces that contains seed.
# HyperMesh 2019 patch levels may expand only one adjacency ring per call, so
# repeat "by attached" until the mark stops growing.
proc ::MidSurf::attachedTargetSurfaces {seed targetIds} {
    catch {*clearmark surfs 1}
    *createmark surfs 1 $seed

    set previousCount -1
    set iterations 0
    while {1} {
        set current [::MidSurf::uniq [hm_getmark surfs 1]]
        set count [llength $current]
        if {$count == $previousCount} {
            break
        }
        set previousCount $count
        incr iterations
        if {$iterations > 100000} {
            catch {*clearmark surfs 1}
            error "by attached did not converge for seed surface $seed"
        }
        if {[catch {*appendmark surfs 1 "by attached"} err]} {
            catch {*clearmark surfs 1}
            error "by attached failed for seed surface $seed: $err"
        }
    }

    set attached [::MidSurf::uniq [hm_getmark surfs 1]]
    catch {*clearmark surfs 1}
    array set allowed {}
    foreach id $targetIds {
        set allowed($id) 1
    }
    set group {}
    foreach id $attached {
        if {[info exists allowed($id)]} {
            lappend group $id
        }
    }
    if {[lsearch -exact $group $seed] < 0} {
        lappend group $seed
    }
    return [::MidSurf::uniq $group]
}

proc ::MidSurf::surfaceBoundaryEdgeIds {surfaceId} {
    set edgeIds {}
    if {[catch {set loops [hm_getsurfaceedges $surfaceId]}]} {
        return {}
    }
    foreach loop $loops {
        foreach edgeId $loop {
            lappend edgeIds $edgeId
        }
    }
    return [::MidSurf::uniq $edgeIds]
}

# Build connectivity strictly from edges shared by surfaces in targetIds.
# Native "by attached" may traverse through geometry owned by other
# components before the result is intersected with targetIds, which can merge
# otherwise independent sheet-metal bodies into one false group.
proc ::MidSurf::surfaceTopologyGroups {targetIds} {
    set targetIds [::MidSurf::uniq $targetIds]
    array set surfaceEdges {}
    array set edgeSurfaces {}
    foreach surfaceId $targetIds {
        set edges [::MidSurf::surfaceBoundaryEdgeIds $surfaceId]
        set surfaceEdges($surfaceId) $edges
        foreach edgeId $edges {
            lappend edgeSurfaces($edgeId) $surfaceId
        }
    }

    array set visited {}
    set groups {}
    foreach seed $targetIds {
        if {[info exists visited($seed)]} {
            continue
        }
        set visited($seed) 1
        set queue [list $seed]
        set group {}
        while {[llength $queue] > 0} {
            set current [lindex $queue 0]
            set queue [lrange $queue 1 end]
            lappend group $current
            foreach edgeId $surfaceEdges($current) {
                foreach neighbor $edgeSurfaces($edgeId) {
                    if {![info exists visited($neighbor)]} {
                        set visited($neighbor) 1
                        lappend queue $neighbor
                    }
                }
            }
        }
        lappend groups [::MidSurf::uniq $group]
    }
    return $groups
}

# A component can contain several independent sheet-metal bodies.  The native
# extractor is not reliable when all of those bodies are submitted in one
# call, so build explicit extraction groups first.
proc ::MidSurf::inputGeometryGroups {entityType entityIds} {
    set entityIds [::MidSurf::uniq $entityIds]
    if {$entityType eq "solids"} {
        set groups {}
        foreach solidId $entityIds {
            lappend groups [list $solidId]
        }
        return $groups
    }

    return [::MidSurf::surfaceTopologyGroups $entityIds]
}

proc ::MidSurf::markGeometryGroup {entityType entityIds} {
    catch {*clearmark $entityType 1}
    if {[llength $entityIds] == 0} {
        error "Cannot mark an empty midsurface extraction group."
    }
    if {[catch {eval *createmark $entityType 1 $entityIds} err]} {
        error "Cannot mark $entityType for midsurface extraction: $err"
    }
}

proc ::MidSurf::renameComponent {oldName newName} {
    if {$oldName eq $newName} {
        return
    }
    if {[catch {*renamecollector component $oldName $newName} err1]} {
        if {[catch {*renamecollector components $oldName $newName} err2]} {
            error "Cannot rename component $oldName to $newName: $err1 / $err2"
        }
    }
}

proc ::MidSurf::moveSurfacesToComponent {surfaceIds compName} {
    set surfaceIds [::MidSurf::uniq $surfaceIds]
    if {[llength $surfaceIds] == 0} {
        return 0
    }
    catch {*clearmark surfs 1}
    if {[catch {eval *createmark surfs 1 $surfaceIds} err]} {
        error "Cannot mark extracted midsurfaces for component $compName: $err"
    }
    if {[catch {*movemark surfs 1 $compName} err]} {
        catch {*clearmark surfs 1}
        error "Cannot move extracted midsurfaces to component $compName: $err"
    }
    catch {*clearmark surfs 1}
    return [llength $surfaceIds]
}

proc ::MidSurf::allSurfaceIds {} {
    set ids {}
    catch {*clearmark surfs 2}
    if {![catch {*createmark surfs 2 all}]} {
        catch {set ids [hm_getmark surfs 2]}
    }
    catch {*clearmark surfs 2}
    return [::MidSurf::uniq $ids]
}

proc ::MidSurf::deleteSurfaces {surfaceIds} {
    set surfaceIds [::MidSurf::uniq $surfaceIds]
    if {[llength $surfaceIds] == 0} {
        return 0
    }
    catch {*clearmark surfs 2}
    if {![catch {eval *createmark surfs 2 $surfaceIds}]} {
        catch {*deletemark surfs 2}
    }
    catch {*clearmark surfs 2}
    return [llength $surfaceIds]
}

proc ::MidSurf::createTemporaryComponent {baseName} {
    set name [::MidSurf::uniqueComponentName $baseName]
    set id ""
    if {[llength [info commands ::HWFlow::createComponent]] > 0} {
        set id [::HWFlow::createComponent $name "" external]
    } else {
        if {[catch {*createentity comps includeid=0 name=$name} err]} {
            if {[catch {*collectorcreateonly components $name "" 1} err2]} {
                error "Cannot create temporary midsurface component $name: $err / $err2"
            }
        }
        set id [::MidSurf::componentIdByName $name]
    }
    if {$id eq ""} {
        error "Cannot resolve temporary midsurface component $name after creation."
    }
    catch {*currentcollector component $name}
    catch {*currentcollector components $name}
    return [list $name $id]
}

proc ::MidSurf::createAccumulatorComponent {compId} {
    return [::MidSurf::createTemporaryComponent "HW_MIDSURF_TMP_${compId}"]
}

proc ::MidSurf::moveGeometryToComponent {entityType entityIds compName} {
    set entityIds [::MidSurf::uniq $entityIds]
    if {[llength $entityIds] == 0} {
        return 0
    }
    catch {*clearmark $entityType 1}
    if {[catch {eval *createmark $entityType 1 $entityIds} markErr]} {
        error "Cannot mark $entityType for component $compName: $markErr"
    }
    if {[catch {*movemark $entityType 1 $compName} moveErr]} {
        catch {*clearmark $entityType 1}
        error "Cannot move $entityType to component $compName: $moveErr"
    }
    catch {*clearmark $entityType 1}
    return [llength $entityIds]
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

proc ::MidSurf::readThicknessFromComponentName {name} {
    if {[llength [info commands ::HWFlow::thicknessFromComponentName]] > 0} {
        return [::HWFlow::thicknessFromComponentName $name]
    }
    return ""
}

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

proc ::MidSurf::thicknessValuesFromRaw {raw {surfaceId ""}} {
    set vals {}
    foreach item $raw {
        if {[llength $item] >= 3} {
            set itemSurface [lindex $item 0]
            set t [lindex $item 1]
            if {$surfaceId ne "" && $itemSurface ne $surfaceId} {
                continue
            }
        } elseif {[llength $item] >= 2} {
            set t [lindex $item 1]
        } else {
            set t $item
        }
        if {[string is double -strict $t] && $t > 0.0} {
            lappend vals $t
        }
    }
    return $vals
}

proc ::MidSurf::readThicknessFromPoint {pointId {surfaceId ""}} {
    if {[catch {set raw [hm_getsurfacethicknessvalues points $pointId]}]} {
        return {}
    }
    return [::MidSurf::thicknessValuesFromRaw $raw $surfaceId]
}

proc ::MidSurf::surfacePointIds {surfId} {
    set points {}
    if {[catch {set loops [hm_getsurfaceedges $surfId]}]} {
        return {}
    }
    foreach loop $loops {
        foreach edgeId $loop {
            if {![catch {set edgePoints [hm_getverticesfromedge $edgeId]}]} {
                set points [concat $points $edgePoints]
            }
        }
    }
    return [::MidSurf::uniq $points]
}

proc ::MidSurf::readThicknessFromSurface {surfId} {
    set vals {}
    foreach pointId [::MidSurf::surfacePointIds $surfId] {
        set vals [concat $vals [::MidSurf::readThicknessFromPoint $pointId $surfId]]
    }
    return $vals
}

proc ::MidSurf::readThicknessFromComponentPoints {compId} {
    set vals {}
    set pts [::MidSurf::getCompEntityIds $compId points points]

    foreach pt $pts {
        set vals [concat $vals [::MidSurf::readThicknessFromPoint $pt]]
    }
    return $vals
}

proc ::MidSurf::readMiddleSurfaceThickness {midCompId} {
    set vals {}

    foreach surf [::MidSurf::getCompEntityIds $midCompId surfaces surfs] {
        set vals [concat $vals [::MidSurf::readThicknessFromSurface $surf]]
    }

    if {[llength $vals] == 0} {
        set vals [concat $vals [::MidSurf::readThicknessFromComponentPoints $midCompId]]
    }
    return $vals
}

proc ::MidSurf::measureThicknessByVolumeArea {sourceCompId midCompId} {
    set totalVolume 0.0
    set volumeCount 0
    foreach solidId [::MidSurf::getCompEntityIds $sourceCompId solids solids] {
        if {![catch {set volume [hm_getvolumeofsolid solids $solidId]}] &&
            [string is double -strict $volume] && $volume > 0.0} {
            set totalVolume [expr {$totalVolume + $volume}]
            incr volumeCount
        }
    }
    if {$volumeCount == 0 || $totalVolume <= 0.0} {
        return ""
    }

    set totalArea 0.0
    set areaCount 0
    foreach surfId [::MidSurf::getCompEntityIds $midCompId surfaces surfs] {
        set area ""
        foreach cmd [list \
            [list hm_getareaofsurface surfs $surfId] \
            [list hm_getvalue surfs id=$surfId dataname=area]] {
            if {![catch {set candidate [uplevel #0 $cmd]}] &&
                [string is double -strict $candidate] && $candidate > 0.0} {
                set area $candidate
                break
            }
        }
        if {$area ne ""} {
            set totalArea [expr {$totalArea + $area}]
            incr areaCount
        }
    }
    if {$areaCount == 0 || $totalArea <= 0.0} {
        return ""
    }
    return [expr {$totalVolume / $totalArea}]
}

proc ::MidSurf::chooseThickness {sourceCompId sourceName midCompId} {
    variable cfg

    set nameThickness [::MidSurf::readThicknessFromComponentName $sourceName]
    if {$nameThickness ne ""} {
        return $nameThickness
    }

    set vals [::MidSurf::readMiddleSurfaceThickness $midCompId]
    if {[llength $vals] == 0} {
        set vals [::MidSurf::sourceThicknessValues $sourceCompId]
    }

    set t [::MidSurf::median $vals]
    if {$t eq ""} {
        set t [::MidSurf::measureThicknessByVolumeArea $sourceCompId $midCompId]
        if {$t ne ""} {
            ::MidSurf::msg [::HWFlow::txt \
                [format "Midsurface Extraction: %s 未读取到厚度属性，已按实体体积/中面面积自动测得厚度 %.6g。" $sourceName $t] \
                [format "MidSurf: no thickness metadata was available for %s; measured thickness %.6g from solid volume / midsurface area." $sourceName $t]]
        }
        return $t
    }

    set spread [::MidSurf::valueSpreadRatio $vals $t]
    if {$spread > $cfg(variableThicknessTol)} {
        ::MidSurf::msg [::HWFlow::txt \
            [format "Midsurface Extraction: %s 自动测得的厚度变化较大，使用中位数 %.6g（相对离散度约 %.3f）。" $sourceName $t $spread] \
            [format "MidSurf: measured thickness varies for %s; using median %.6g (relative spread about %.3f)." $sourceName $t $spread]]
    }

    return $t
}

proc ::MidSurf::sourceThicknessValues {sourceCompId} {
    set vals [::MidSurf::readComponentThickness $sourceCompId]
    foreach surf [::MidSurf::getCompEntityIds $sourceCompId surfaces surfs] {
        set vals [concat $vals [::MidSurf::readThicknessFromSurface $surf]]
    }
    set vals [concat $vals [::MidSurf::readThicknessFromComponentPoints $sourceCompId]]
    return $vals
}

proc ::MidSurf::sourceThicknessCandidate {sourceCompId sourceName} {
    set nameThickness [::MidSurf::readThicknessFromComponentName $sourceName]
    if {$nameThickness ne ""} {
        return $nameThickness
    }
    return [::MidSurf::median [::MidSurf::sourceThicknessValues $sourceCompId]]
}

proc ::MidSurf::outputNameForSource {sourceName thickness {version 1}} {
    set tText [::MidSurf::formatThickness $thickness]
    if {![string is integer -strict $version] || $version < 1} {
        set version 1
    }
    set versionToken [format "V%02d" $version]
    # Imported source geometry may carry a workflow suffix such as
    # V01_PART_TT_Q355-Geometry. TT is not a real thickness token; discard it
    # and everything after it before producing the canonical midsurface name.
    if {[regexp -nocase {^(V[^_]+_)?(.+?)_TT(_.*)?$} $sourceName -> sourceVersion sourcePart sourceSuffix]} {
        set sourceName "${sourceVersion}${sourcePart}"
    }
    if {[namespace exists ::HWFlow]} {
        set formatted [::HWFlow::formatMidsurfName $sourceName $tText]
        if {[regsub -nocase {^V[^_]*_} $formatted "${versionToken}_" versioned]} {
            return $versioned
        }
        return "${versionToken}_${formatted}"
    }
    set partName $sourceName
    regsub -nocase {^V[^_]*_} $partName "" partName
    return "${versionToken}_${partName}_T${tText}"
}

proc ::MidSurf::nextOutputNameForSource {sourceName thickness} {
    for {set version 1} {$version <= 999} {incr version} {
        set candidate [::MidSurf::outputNameForSource $sourceName $thickness $version]
        if {![::MidSurf::componentExistsByName $candidate]} {
            return $candidate
        }
    }
    error [::HWFlow::txt \
        "组件 $sourceName 已存在 V01 到 V999 的中面版本，无法分配新名称。" \
        "Midsurface versions V01 through V999 already exist for $sourceName; a new name cannot be allocated."]
}

proc ::MidSurf::outputNameForRegion {sourceName thickness regionIndex regionCount {version 1}} {
    set name [::MidSurf::outputNameForSource $sourceName $thickness $version]
    if {$regionCount <= 1} {
        return $name
    }
    if {![regexp {^(.*)(_T.*)$} $name -> stem tail]} {
        return "${name}.${regionIndex}"
    }
    return "${stem}.${regionIndex}${tail}"
}

proc ::MidSurf::nextOutputNameForRegion {sourceName thickness regionIndex regionCount} {
    for {set version 1} {$version <= 999} {incr version} {
        set candidate [::MidSurf::outputNameForRegion $sourceName $thickness $regionIndex $regionCount $version]
        if {![::MidSurf::componentExistsByName $candidate]} {
            return $candidate
        }
    }
    error [::HWFlow::txt \
        "组件 $sourceName 的第 $regionIndex 个离散面域已存在 V01 到 V999，无法分配新名称。" \
        "Midsurface versions V01 through V999 already exist for region $regionIndex of $sourceName."]
}

# ----------------------------------------------------------------------
# HyperMesh operations
# ----------------------------------------------------------------------

proc ::MidSurf::extractMidsurface {entityType {extractByCompOverride ""}} {
    variable cfg

    if {$entityType eq "solids"} {
        set normals 3
    } else {
        set normals $cfg(surfaceNormals)
    }

    set extractByComp $cfg(extractByComp)
    if {$extractByCompOverride ne ""} {
        set extractByComp $extractByCompOverride
    }
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
        return 19
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
        return 17
    }

    error [::HWFlow::txt "midsurface_extract_10 执行失败。19 参数错误：$err19；17 参数错误：$err17" "midsurface_extract_10 failed. 19-arg error: $err19; 17-arg error: $err17"]
}

proc ::MidSurf::renameMiddleSurface {sourceName thickness midCompId {currentName ""} {outName ""}} {
    variable cfg

    if {$currentName eq ""} {
        set currentName $cfg(middleSurfaceName)
    }

    if {$outName eq ""} {
        set outName [::MidSurf::nextOutputNameForSource $sourceName $thickness]
    }
    set existingId [::MidSurf::componentIdByName $outName]
    if {$existingId ne "" && $existingId ne $midCompId} {
        error [::HWFlow::txt "目标中面组件 $outName 已存在，本次创建已跳过。" "Target midsurface component $outName already exists; this creation was skipped."]
    }

    if {$outName ne $currentName} {
        ::MidSurf::enableInteractiveBrowserUpdates
        set histName "Renamed Component $currentName to $outName"
        catch {*startnotehistorystate $histName}
        if {[catch {::MidSurf::renameComponent $currentName $outName} err]} {
            catch {*endnotehistorystate $histName}
            error [::HWFlow::txt "无法将 $currentName 重命名为 $outName：$err" "Cannot rename $currentName to $outName: $err"]
        }
        catch {*endnotehistorystate $histName}
    }

    catch {*currentcollector component $outName}
    catch {*currentcollector components $outName}
    catch {::HWFlow::activateAndShowComponent $outName 0}
    ::MidSurf::refreshComponentBrowser $outName

    return $outName
}

proc ::MidSurf::hideSourceComponent {sourceName} {
    if {[namespace exists ::HWFlow]} {
        ::HWFlow::displayComponent $sourceName off
    } else {
        catch {*displaycollector component off $sourceName 1 1}
        catch {*displaycollector components off $sourceName 1 1}
        catch {hm_redraw}
    }
}

proc ::MidSurf::organizeOutputComponent {compName} {
    variable outputAssemblyName

    set compId [::MidSurf::componentIdByName $compName]
    if {$compId eq ""} {
        error [::HWFlow::txt "无法读取中面组件 $compName 的 ID，不能加入 $outputAssemblyName assembly。" "Cannot read the ID of midsurface component $compName; it cannot be added to the $outputAssemblyName assembly."]
    }
    set assemblyId [::HWFlow::addComponentsToAssembly $outputAssemblyName [list $compId]]
    if {$assemblyId eq ""} {
        error [::HWFlow::txt "无法创建或更新 $outputAssemblyName assembly。" "Cannot create or update the $outputAssemblyName assembly."]
    }
    return $assemblyId
}

proc ::MidSurf::processComponent {compId} {
    variable cfg
    variable lastProcessFailures

    set lastProcessFailures 0

    set sourceName [::MidSurf::getComponentName $compId]
    ::MidSurf::msg [::HWFlow::txt "Midsurface Extraction: 正在处理 $sourceName" "MidSurf: processing $sourceName"]

    if {$cfg(requireCleanMiddle) && [::MidSurf::componentExistsByName $cfg(middleSurfaceName)]} {
        error [::HWFlow::txt "组件 \"$cfg(middleSurfaceName)\" 已存在。请在运行前重命名/删除该组件，或关闭 Middle Surface 清洁检查。" "Component \"$cfg(middleSurfaceName)\" already exists. Rename/delete it before running, or disable the clean Middle Surface check."]
    }

    set markInfo [::MidSurf::markInputGeometry $compId]
    set entityType [lindex $markInfo 0]
    set entities [lindex $markInfo 1]

    if {$entityType eq "" || [llength $entities] == 0} {
        error [::HWFlow::txt "组件 $sourceName 中没有可抽取的实体或曲面。" "Component $sourceName contains no solids or surfaces."]
    }

    set groups [::MidSurf::inputGeometryGroups $entityType $entities]
    set groupCount [llength $groups]
    set inputTemporary [expr {$entityType ne "surfaces"}]
    if {$inputTemporary} {
        set inputInfo [::MidSurf::createTemporaryComponent "HW_MIDSURF_INPUT_${compId}"]
        set inputName [lindex $inputInfo 0]
        set inputId [lindex $inputInfo 1]
    } else {
        set inputName $sourceName
        set inputId $compId
    }
    set results {}
    set groupFailures {}
    set inputRestoreFailed 0
    set groupIndex 0

    foreach group $groups {
        incr groupIndex
        set groupLabel "$entityType IDs=[join $group ,]"
        if {$inputTemporary && [catch {::MidSurf::moveGeometryToComponent $entityType $group $inputName} isolateErr]} {
            lappend groupFailures "$groupIndex/$groupCount ($groupLabel): cannot isolate input geometry: $isolateErr"
            continue
        }
        catch {*currentcollector component $inputName}
        catch {*currentcollector components $inputName}
        ::MidSurf::markGeometryGroup $entityType $group
        set beforeSurfs [::MidSurf::allSurfaceIds]
        set middleBeforeId [::MidSurf::componentIdByName $cfg(middleSurfaceName)]
        set extractByCompOverride ""
        if {$entityType eq "surfaces"} {
            set extractByCompOverride 0
        }
        if {[catch {set extractLayout [::MidSurf::extractMidsurface $entityType $extractByCompOverride]} extractErr]} {
            set failedCreated [::MidSurf::listDifference [::MidSurf::allSurfaceIds] $beforeSurfs]
            ::MidSurf::deleteSurfaces $failedCreated
            if {[catch {::MidSurf::moveGeometryToComponent $entityType $group $sourceName} restoreErr]} {
                set inputRestoreFailed 1
                lappend groupFailures "$groupIndex/$groupCount ($groupLabel): source geometry restore failed: $restoreErr"
            }
            if {$middleBeforeId eq ""} {
                catch {::MidSurf::deleteComponentByName $cfg(middleSurfaceName)}
            }
            lappend groupFailures "$groupIndex/$groupCount ($groupLabel): $extractErr"
            continue
        }

        # Do not assume the output collector is named "Middle Surface".  The
        # documented 19-argument layout normally creates that collector, but
        # the HM2019-compatible 17-argument fallback writes into the current
        # component.  Global surface-set differencing works for both layouts.
        set groupSurfs [::MidSurf::listDifference [::MidSurf::allSurfaceIds] $beforeSurfs]
        if {[llength $groupSurfs] == 0} {
            if {[catch {::MidSurf::moveGeometryToComponent $entityType $group $sourceName} restoreErr]} {
                set inputRestoreFailed 1
                lappend groupFailures "$groupIndex/$groupCount ($groupLabel): source geometry restore failed: $restoreErr"
            }
            if {$middleBeforeId eq ""} {
                catch {::MidSurf::deleteComponentByName $cfg(middleSurfaceName)}
            }
            lappend groupFailures "$groupIndex/$groupCount ($groupLabel): native layout $extractLayout returned success but created no new surfaces"
            continue
        }

        set resultInfo [::MidSurf::createTemporaryComponent "HW_MIDSURF_RESULT_${compId}_${groupIndex}"]
        set resultName [lindex $resultInfo 0]
        set resultId [lindex $resultInfo 1]
        if {[catch {::MidSurf::moveSurfacesToComponent $groupSurfs $resultName} moveErr]} {
            ::MidSurf::deleteSurfaces $groupSurfs
            catch {::MidSurf::deleteComponentByName $resultName}
            if {[catch {::MidSurf::moveGeometryToComponent $entityType $group $sourceName} restoreErr]} {
                set inputRestoreFailed 1
                lappend groupFailures "$groupIndex/$groupCount ($groupLabel): source geometry restore failed: $restoreErr"
            }
            if {$middleBeforeId eq ""} {
                catch {::MidSurf::deleteComponentByName $cfg(middleSurfaceName)}
            }
            lappend groupFailures "$groupIndex/$groupCount ($groupLabel): $moveErr"
            continue
        }

        # Measure while the current region is still isolated in inputId so
        # volume/area fallback uses this region rather than the whole source
        # component. Name-tag thickness still comes from the original name.
        set thickness [::MidSurf::chooseThickness $inputId $sourceName $resultId]
        if {[catch {::MidSurf::moveGeometryToComponent $entityType $group $sourceName} restoreErr]} {
            set inputRestoreFailed 1
            lappend groupFailures "$groupIndex/$groupCount ($groupLabel): midsurface created but source geometry restore failed: $restoreErr"
        }
        if {$middleBeforeId eq ""} {
            catch {::MidSurf::deleteComponentByName $cfg(middleSurfaceName)}
        }

        set nextOutName [::MidSurf::nextOutputNameForRegion $sourceName $thickness $groupIndex $groupCount]
        if {[catch {
            set outName [::MidSurf::renameMiddleSurface $sourceName $thickness $resultId $resultName $nextOutName]
            ::MidSurf::organizeOutputComponent $outName
        } finalizeErr]} {
            catch {::MidSurf::deleteComponentByName $resultName}
            lappend groupFailures "$groupIndex/$groupCount ($groupLabel): cannot finalize output component: $finalizeErr"
            continue
        }

        lappend results [list $outName [llength $groupSurfs] $thickness]
        ::MidSurf::msg "Midsurface Extraction: $sourceName region $groupIndex/$groupCount -> $outName; native layout=$extractLayout, surfaces=[llength $groupSurfs]."
    }

    if {$inputTemporary && !$inputRestoreFailed} {
        catch {::MidSurf::deleteComponentByName $inputName}
    } elseif {$inputTemporary} {
        ::MidSurf::msg "Midsurface Extraction warning: retained $inputName because source geometry restoration failed."
    }

    set lastProcessFailures [llength $groupFailures]
    if {[llength $results] == 0} {
        set detail [join $groupFailures "; "]
        error [::HWFlow::txt "组件 $sourceName 的所有几何分区均未能抽取中面。$detail" "All geometry regions in $sourceName failed midsurface extraction. $detail"]
    }

    if {[llength $groupFailures] == 0} {
        ::MidSurf::hideSourceComponent $sourceName
    } else {
        ::MidSurf::msg [::HWFlow::txt \
            "Midsurface Extraction warning: $sourceName 有 [llength $groupFailures]/$groupCount 个几何分区抽取失败，源组件保持显示。详情：[join $groupFailures {；}]" \
            "MidSurf warning: [llength $groupFailures]/$groupCount geometry regions failed for $sourceName; the source component remains visible. Details: [join $groupFailures {; }]" ]
    }

    ::MidSurf::msg [::HWFlow::txt \
        "Midsurface Extraction: $sourceName 完成，离散面域=$groupCount，输出组件=[llength $results]。" \
        "MidSurf: $sourceName finished; regions=$groupCount, output components=[llength $results]."]
    return $results
}

# ----------------------------------------------------------------------
# Entry
# ----------------------------------------------------------------------

proc ::MidSurf::run {} {
    variable outputAssemblyName
    variable ui
    variable stat
    variable VERSION

    if {![::MidSurf::showPanel]} {
        catch {hm_usermessage [::HWFlow::txt "Midsurface Extraction cancelled." "MidSurf cancelled."]}
        return
    }

    array set stat {
        selected 0
        created 0
        skipped 0
        surfaces 0
    }

    set comps [::MidSurf::uniq $ui(selectedComps)]
    set stat(selected) [llength $comps]
    set failures {}
    set createdNames {}
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] \
            [::HWFlow::txt "准备抽取中面..." "Preparing midsurface extraction..."] \
            0]
    }

    ::MidSurf::msg [::HWFlow::txt "Midsurface Extraction v$VERSION started. 组件数=[llength $comps]" "MidSurf v$VERSION started. Components=[llength $comps]"]

    set compIndex 0
    foreach compId $comps {
        incr compIndex
        set sourceName [::MidSurf::getComponentName $compId]
        if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
            set pct [expr {5.0 + 85.0 * (($compIndex - 1) / double($stat(selected)))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "Midsurface Extraction 正在执行" "Midsurface extraction running"] \
                [::HWFlow::txt "组件 $compIndex/$stat(selected)：$sourceName" "Component $compIndex/$stat(selected): $sourceName"] \
                1}
        }

        if {[catch {set componentResults [::MidSurf::processComponent $compId]} err]} {
            incr stat(skipped)
            lappend failures "$sourceName: $err"
            ::MidSurf::msg [::HWFlow::txt "Midsurface Extraction warning: $sourceName 已跳过。$err" "MidSurf warning: $sourceName skipped. $err"]
            continue
        }

        if {[info exists ::MidSurf::lastProcessFailures] && $::MidSurf::lastProcessFailures > 0} {
            incr stat(skipped)
        }
        foreach result $componentResults {
            incr stat(created)
            set stat(surfaces) [expr {$stat(surfaces) + [lindex $result 1]}]
            lappend createdNames [lindex $result 0]
        }
        catch {update}
    }

    ::MidSurf::clearMarks
    if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 95.0 \
            [::HWFlow::txt "Midsurface Extraction 正在收尾" "Midsurface extraction finishing"] \
            [::HWFlow::txt "正在刷新结果并生成汇总..." "Refreshing results and building summary..."] \
            1}
    }

    set msg [::HWFlow::txt "Midsurface Extraction v$VERSION finished.\n\n输出 assembly：$outputAssemblyName\n已选择组件：$stat(selected)\n已创建中面组件：$stat(created)\n已创建曲面：$stat(surfaces)\n跳过/失败：$stat(skipped)" "MidSurf v$VERSION finished.\n\nOutput assembly: $outputAssemblyName\nSelected components: $stat(selected)\nCreated midsurface components: $stat(created)\nCreated surfaces: $stat(surfaces)\nSkipped/failed: $stat(skipped)"]

    if {[llength $createdNames] > 0} {
        append msg [::HWFlow::txt "\n\n已创建：\n" "\n\nCreated:\n"]
        append msg [join [lrange $createdNames 0 9] "\n"]
        if {[llength $createdNames] > 10} {
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

    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "Midsurface extraction finished." "Midsurface extraction finished."] 100.0}
    }
    catch {tk_messageBox -icon info -title "[::HWFlow::txt "Midsurface Extraction" "Midsurface Extraction"] v$VERSION" -message $msg}
    ::MidSurf::msg $msg
}
