# ============================================================================
# RBE2_BoltConnector_v0_5.tcl
# HyperMesh 2019 oriented Tcl/Tk script
#
# Function:
#   Select RBE2 elements or components containing RBE2 elements, group their
#   independent nodes along X/Y/Z by tolerance, and create CBEAM bolt segments
#   between adjacent RBE2 center nodes only after sorting along the detected axis. Created beam elements are organized into
#   components named by nominal even hole diameter: BOLT_Dxx_CBEAM.
#
# v0.5 grouping logic fix:
#   - Planar RBE2 records only participate in grouping along their detected
#     normal axis. They are no longer searched/connected in their own plane.
#   - Groups containing spatial RBE2 records only are previewed/skipped and do
#     not create CBEAM elements.
#   - CBEAM creation still uses the HyperMesh 2019 compatible
#     *barelementcreatewithoffsets workflow from v0.4.
#
# Notes:
#   - Radius/diameter estimation uses the inner ring of dependent nodes:
#       diameter = 2 * minimum meaningful center-to-dependent-node radius,
#       then floor to an even integer.
#   - Planar RBE2 records only search along their detected normal axis.
#   - If a group contains planar RBE2 and spatial RBE2, diameter is taken from
#     planar RBE2 records first; spatial RBE2 records are still connected.
#   - Spatial-only RBE2 groups are skipped and do not create CBEAM elements.
#   - No nodes are moved to components. Only CBEAM elements are organized.
#   - When no explicit 1D property is supplied, the tool creates/reuses a
#     diameter-specific PBAR/PBEAM property and a default MAT1 material, so the
#     generated CBAR/CBEAM elements have solver stiffness instead of only
#     graphical connectivity.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::RB2Bolt {
    variable VERSION "0.5"

    variable P
    array set P {
        selectMode       elements
        axisMode         AUTO
        gapTol           100.0
        offsetTol        5.0
        minGroupSize     2
        minBeamLength    0.001
        planeAbsTol      0.5
        planeFlatRatio   0.12
        radialAbsTol     0.5
        radialRelTol     0.08
        elemType         CBEAM
        compPrefix       BOLT
        propName         {}
        dryRun           0
    }
    variable done 0
    variable _sortAxis 2
    variable beamSegmentIndex
    variable compIdCache
    variable propIdCache
    variable matIdCache
    variable currentOutputComp ""
    variable bulkCreateMode 0
    variable bulkTouchedOutputComps {}
}

# ------------------------- small utilities ---------------------------------
proc ::RB2Bolt::msg {txt} {
    variable bulkCreateMode
    catch {hm_usermessage $txt}
    catch {puts $txt}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "RB2Bolt: $txt"}
    }
    if {!$bulkCreateMode} {
        catch {update}
    }
}

proc ::RB2Bolt::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::RB2Bolt::loadState {} {
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray rbe2_bolt_connector ::RB2Bolt::P
    }
}

proc ::RB2Bolt::saveState {} {
    if {[llength [info commands ::HWFlow::saveArrayState]] > 0} {
        ::HWFlow::saveArrayState rbe2_bolt_connector ::RB2Bolt::P
    }
}

proc ::RB2Bolt::abs {v} {
    expr {$v < 0 ? -$v : $v}
}

proc ::RB2Bolt::dist3 {x1 y1 z1 x2 y2 z2} {
    expr {sqrt(($x1-$x2)*($x1-$x2) + ($y1-$y2)*($y1-$y2) + ($z1-$z2)*($z1-$z2))}
}

proc ::RB2Bolt::safeName {name} {
    set out $name
    regsub -all {[^A-Za-z0-9_]+} $out {_} out
    regsub -all {_+} $out {_} out
    return [string trim $out _]
}

proc ::RB2Bolt::coordIndex {axis} {
    switch -- $axis {
        X {return 2}
        Y {return 3}
        Z {return 4}
    }
    return 4
}

proc ::RB2Bolt::crossIndices {axis} {
    switch -- $axis {
        X {return {3 4}}
        Y {return {2 4}}
        Z {return {2 3}}
    }
    return {2 3}
}

proc ::RB2Bolt::rangeNormalAxis {rx ry rz} {
    set pairs [lsort -real -index 1 [list [list X $rx] [list Y $ry] [list Z $rz]]]
    return [lindex [lindex $pairs 0] 0]
}

proc ::RB2Bolt::recIsPlanar {rec} {
    expr {[llength $rec] > 6 && [lindex $rec 6]}
}

proc ::RB2Bolt::recNormalAxis {rec} {
    if {[llength $rec] > 7} {return [lindex $rec 7]}
    return ""
}

proc ::RB2Bolt::groupHasPlanar {g} {
    foreach rec $g {
        if {[recIsPlanar $rec]} {return 1}
    }
    return 0
}

proc ::RB2Bolt::nodeXYZ {nid} {
    set x [hm_getvalue nodes id=$nid dataname=x]
    set y [hm_getvalue nodes id=$nid dataname=y]
    set z [hm_getvalue nodes id=$nid dataname=z]
    return [list $x $y $z]
}

proc ::RB2Bolt::evenFloorDiameter {dia} {
    if {$dia <= 0} {return 0}
    set d [expr {int(floor($dia))}]
    if {$d < 1} {return 0}
    if {[expr {$d % 2}] != 0} {incr d -1}
    if {$d < 1} {return 0}
    return $d
}

proc ::RB2Bolt::median {vals} {
    set n [llength $vals]
    if {$n == 0} {return 0.0}
    set s [lsort -real $vals]
    set mid [expr {$n / 2}]
    if {[expr {$n % 2}] == 1} {
        return [lindex $s $mid]
    }
    return [expr {([lindex $s [expr {$mid-1}]] + [lindex $s $mid]) / 2.0}]
}

proc ::RB2Bolt::chooseModeDiameter {ds} {
    array unset cnt
    array set cnt {}
    foreach d $ds {
        if {$d <= 0} {continue}
        if {![info exists cnt($d)]} {set cnt($d) 0}
        incr cnt($d)
    }
    set best 0
    set bestc -1
    foreach d [array names cnt] {
        if {$cnt($d) > $bestc || ($cnt($d) == $bestc && ($best == 0 || $d < $best))} {
            set best $d
            set bestc $cnt($d)
        }
    }
    return $best
}

# ------------------------- GUI ---------------------------------------------
proc ::RB2Bolt::showDialog {{settingsOnly 0}} {
    variable P
    variable done
    variable VERSION
    ::RB2Bolt::loadState
    set done 0

    catch {destroy .rb2bolt_dlg}
    set w .rb2bolt_dlg
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 选择范围" "1. Selection Scope"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    if {$settingsOnly} {
        label $w.main.sel.note -text [::HWFlow::txt \
            "执行时在 HyperMesh 选择面板中切换 elems / comps；这里不再保存选择类型。" \
            "Switch elems / comps in the HyperMesh selection panel when running; selection type is no longer saved here."] -anchor w
        grid $w.main.sel.note -row 0 -column 0 -columnspan 2 -sticky w
    } else {
        label $w.main.sel.l_mode -text [::HWFlow::txt "选择方式" "Select by"] -anchor w
        tk_optionMenu $w.main.sel.m_mode ::RB2Bolt::P(selectMode) elements components
        grid $w.main.sel.l_mode -row 0 -column 0 -sticky w -padx {0 8}
        grid $w.main.sel.m_mode -row 0 -column 1 -sticky w
    }

    labelframe $w.main.param -text [::HWFlow::txt "2. 分组与建模参数" "2. Grouping and Modeling Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    label $w.main.param.l_axis -text [::HWFlow::txt "搜索轴向" "Search axis"] -anchor w
    tk_optionMenu $w.main.param.m_axis ::RB2Bolt::P(axisMode) AUTO X Y Z
    label $w.main.param.l_type -text [::HWFlow::txt "单元类型" "Element type"] -anchor w
    tk_optionMenu $w.main.param.m_type ::RB2Bolt::P(elemType) CBEAM CBAR
    grid $w.main.param.l_axis -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.param.m_axis -row 0 -column 1 -sticky w -padx {0 18} -pady 2
    grid $w.main.param.l_type -row 0 -column 2 -sticky w -padx {0 6} -pady 2
    grid $w.main.param.m_type -row 0 -column 3 -sticky w -pady 2

    set fields {
        {gapTol        "最大轴向连接距离" "Max axial connection distance"}
        {offsetTol     "横向中心偏移容差" "Transverse center offset tolerance"}
        {minGroupSize  "每组最少 RBE2 数量" "Minimum RBE2 count per group"}
        {minBeamLength "最小梁单元长度" "Minimum CBEAM length"}
        {planeAbsTol   "平面 RBE2 厚度判据" "Planar RBE2 thickness criterion"}
        {compPrefix    "输出组件前缀" "Output component prefix"}
        {propName      "1D 属性名称（可选）" "1D property name (optional)"}
    }

    set i 0
    foreach item $fields {
        set key [lindex $item 0]
        set name [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        set row [expr {1 + ($i / 2)}]
        set col [expr {($i % 2) * 2}]

        label $w.main.param.l_$key -text $name -anchor w
        entry $w.main.param.e_$key -textvariable ::RB2Bolt::P($key) -width 16
        grid $w.main.param.l_$key -row $row -column $col -sticky w -padx {0 6} -pady 2
        grid $w.main.param.e_$key -row $row -column [expr {$col + 1}] -sticky w -padx {0 18} -pady 2
        incr i
    }

    labelframe $w.main.opt -text [::HWFlow::txt "3. 选项" "3. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    checkbutton $w.main.opt.dry -text [::HWFlow::txt "仅预览分组，不创建 CBEAM/CBAR" "Preview groups only; do not create CBEAM/CBAR"] -variable ::RB2Bolt::P(dryRun)
    grid $w.main.opt.dry -row 0 -column 0 -sticky w -pady 2

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x

    button $w.btn.cancel -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command {set ::RB2Bolt::done -2}
    if {!$settingsOnly} {
        button $w.btn.unused -text [::HWFlow::txt "检测未用 Shell RBE2" "Find Unused Shell RBE2"] -width 22 -command {set ::RB2Bolt::done 2}
        button $w.btn.ok -text [::HWFlow::txt "确定" "OK"] -width 10 -command {set ::RB2Bolt::done 1}
    } else {
        button $w.btn.ok -text [::HWFlow::txt "保存设置" "Save Settings"] -width 12 -command {set ::RB2Bolt::done 1}
    }
    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.ok -side right -padx 4
    if {!$settingsOnly} {
        pack $w.btn.unused -side right -padx 4
    }

    bind $w <Return> {set ::RB2Bolt::done 1}
    bind $w <Escape> {set ::RB2Bolt::done -1}
    wm protocol $w WM_DELETE_WINDOW {set ::RB2Bolt::done -1}

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]

    tkwait variable ::RB2Bolt::done
    set goHome [expr {$done == -2}]
    ::RB2Bolt::saveState
    catch {destroy $w}
    if {$goHome} {
        ::RB2Bolt::backToHome ""
        return ""
    }
    if {$done == 1} {return "create"}
    if {$done == 2} {return "findUnusedShellRBE2"}
    return ""
}

proc ::RB2Bolt::validateParams {} {
    variable P
    foreach key {gapTol offsetTol minBeamLength planeAbsTol planeFlatRatio radialAbsTol radialRelTol} {
        if {[catch {expr {double($P($key))}} v]} {
            tk_messageBox -icon error -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "参数 $key 不是有效数值。" "Parameter $key is not a valid number."]
            return 0
        }
        set P($key) $v
    }
    if {[catch {expr {int($P(minGroupSize))}} v]} {
        tk_messageBox -icon error -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "每组最少 RBE2 数量必须为有效整数。" "Minimum RBE2 count per group is not a valid integer."]
        return 0
    }
    set P(minGroupSize) $v
    if {$P(gapTol) <= 0 || $P(offsetTol) <= 0 || $P(minGroupSize) < 2} {
        tk_messageBox -icon error -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "轴向距离和横向容差必须大于 0；每组最少 RBE2 数量必须不小于 2。" "Axial distance and transverse tolerance must be > 0; minimum RBE2 count must be >= 2."]
        return 0
    }
    set P(compPrefix) [safeName $P(compPrefix)]
    if {$P(compPrefix) eq ""} {set P(compPrefix) BOLT}
    set P(propName) [string trim $P(propName)]
    return 1
}

# ------------------------- selection and RBE2 parsing -----------------------
proc ::RB2Bolt::clearSelectionMarks {} {
    foreach etype {elems elements comps components} {
        foreach markId {1 2} {
            catch {*clearmark $etype $markId}
            catch {hm_markclear $etype $markId}
        }
    }
    catch {hm_redraw}
    catch {update idletasks}
}

proc ::RB2Bolt::uniqueIntegerIds {ids} {
    set out {}
    foreach id $ids {
        if {$id eq ""} {continue}
        lappend out $id
    }
    if {[llength $out] == 0} {return {}}
    return [lsort -integer -unique $out]
}

proc ::RB2Bolt::intersectIntegerIds {a b} {
    array unset keep
    array set keep {}
    foreach id $b {
        if {$id eq ""} {continue}
        set keep($id) 1
    }

    set out {}
    foreach id $a {
        if {[info exists keep($id)]} {
            lappend out $id
        }
    }
    return [::RB2Bolt::uniqueIntegerIds $out]
}

proc ::RB2Bolt::markElementCandidates {markId selectors} {
    set sawSuccess 0
    set firstSuccessfulSelector ""
    foreach selector $selectors {
        catch {*clearmark elems $markId}
        catch {*clearmark elements $markId}
        set cmd [concat [list *createmark elems $markId] $selector]
        if {![catch {eval $cmd}]} {
            set sawSuccess 1
            if {$firstSuccessfulSelector eq ""} {
                set firstSuccessfulSelector [join $selector " "]
            }
            set ids {}
            catch {set ids [hm_getmark elems $markId]}
            catch {*clearmark elems $markId}
            catch {*clearmark elements $markId}
            set ids [::RB2Bolt::uniqueIntegerIds $ids]
            if {[llength $ids] > 0} {
                return [list 1 $ids [join $selector " "]]
            }
        }
    }
    catch {*clearmark elems $markId}
    catch {*clearmark elements $markId}
    if {$sawSuccess} {
        return [list 1 {} $firstSuccessfulSelector]
    }
    return [list 0 {} ""]
}

proc ::RB2Bolt::markRigidLinkCandidates {markId} {
    return [::RB2Bolt::markElementCandidates $markId {
        {"by config" 55}
        {"by element config" 55}
        {"by elem config" 55}
        {"by configuration" 55}
        {"by card image" RBE2}
        {"by cardimage" RBE2}
        {"by type" RBE2}
    }]
}

proc ::RB2Bolt::markOneDElementCandidates {markId} {
    return [::RB2Bolt::markElementCandidates $markId {
        {"by dimension" 1}
        {"by element dimension" 1}
        {"by elem dimension" 1}
    }]
}

proc ::RB2Bolt::rbe2CandidatesFromSelectedElements {selected} {
    set selected [::RB2Bolt::uniqueIntegerIds $selected]
    if {[llength $selected] == 0} {return {}}

    set exact [::RB2Bolt::markRigidLinkCandidates 2]
    if {[lindex $exact 0]} {
        set out [::RB2Bolt::intersectIntegerIds $selected [lindex $exact 1]]
        msg [::HWFlow::txt \
            "RBE2 快速筛选：选中 [llength $selected] 个单元，按 [lindex $exact 2] 得到候选 [llength $out] 个。" \
            "RBE2 fast filter: [llength $selected] selected elements, [llength $out] candidates by [lindex $exact 2]."]
        return $out
    }

    set oneD [::RB2Bolt::markOneDElementCandidates 2]
    if {[lindex $oneD 0]} {
        set out [::RB2Bolt::intersectIntegerIds $selected [lindex $oneD 1]]
        msg [::HWFlow::txt \
            "RBE2 快速筛选：选中 [llength $selected] 个单元，按 [lindex $oneD 2] 缩小为 1D 候选 [llength $out] 个。" \
            "RBE2 fast filter: [llength $selected] selected elements, narrowed to [llength $out] 1D candidates by [lindex $oneD 2]."]
        return $out
    }

    msg [::HWFlow::txt \
        "当前 HyperMesh 未接受 RBE2/1D mark 快速筛选，回退为扫描选中单元。" \
        "HyperMesh did not accept the RBE2/1D mark fast filter; falling back to scanning selected elements."]
    return $selected
}

proc ::RB2Bolt::elemComponentId {eid} {
    foreach dn {component.id collector.id comp.id} {
        if {![catch {set cid [hm_getvalue elems id=$eid dataname=$dn]}] && $cid ne "" && $cid != 0} {
            return $cid
        }
    }
    return ""
}

proc ::RB2Bolt::componentElementIdsSlow {compIds} {
    set out {}
    foreach cid $compIds {
        catch {*clearmark elems 2}
        catch {*clearmark elements 2}
        if {![catch {*createmark elems 2 "by comp id" $cid}]} {
            foreach e [hm_getmark elems 2] {lappend out $e}
        }
    }
    catch {*clearmark elems 2}
    catch {*clearmark elements 2}
    return [::RB2Bolt::uniqueIntegerIds $out]
}

proc ::RB2Bolt::filterCandidatesByComponents {candidates compIds} {
    array unset want
    array set want {}
    foreach cid $compIds {
        if {$cid eq ""} {continue}
        set want($cid) 1
    }

    set out {}
    set known 0
    foreach eid $candidates {
        set cid [::RB2Bolt::elemComponentId $eid]
        if {$cid eq ""} {continue}
        set known 1
        if {[info exists want($cid)]} {
            lappend out $eid
        }
    }
    return [list $known [::RB2Bolt::uniqueIntegerIds $out]]
}

proc ::RB2Bolt::rbe2CandidatesFromComponents {compIds} {
    set compIds [::RB2Bolt::uniqueIntegerIds $compIds]
    if {[llength $compIds] == 0} {return {}}

    set exact [::RB2Bolt::markRigidLinkCandidates 2]
    if {[lindex $exact 0]} {
        set filtered [::RB2Bolt::filterCandidatesByComponents [lindex $exact 1] $compIds]
        if {[lindex $filtered 0] || [llength [lindex $exact 1]] == 0} {
            set out [lindex $filtered 1]
            msg [::HWFlow::txt \
                "RBE2 快速筛选：选中 [llength $compIds] 个组件，按 [lindex $exact 2] 得到候选 [llength $out] 个。" \
                "RBE2 fast filter: [llength $compIds] selected components, [llength $out] candidates by [lindex $exact 2]."]
            return $out
        }
    }

    set oneD [::RB2Bolt::markOneDElementCandidates 2]
    if {[lindex $oneD 0]} {
        set filtered [::RB2Bolt::filterCandidatesByComponents [lindex $oneD 1] $compIds]
        if {[lindex $filtered 0] || [llength [lindex $oneD 1]] == 0} {
            set out [lindex $filtered 1]
            msg [::HWFlow::txt \
                "RBE2 快速筛选：选中 [llength $compIds] 个组件，按 [lindex $oneD 2] 缩小为 1D 候选 [llength $out] 个。" \
                "RBE2 fast filter: [llength $compIds] selected components, narrowed to [llength $out] 1D candidates by [lindex $oneD 2]."]
            return $out
        }
    }

    set allElems [::RB2Bolt::componentElementIdsSlow $compIds]
    msg [::HWFlow::txt \
        "当前 HyperMesh 未接受 RBE2/1D mark 快速筛选，回退为扫描组件内单元：[llength $allElems] 个。" \
        "HyperMesh did not accept the RBE2/1D mark fast filter; falling back to scanning component elements: [llength $allElems]."]
    return $allElems
}

proc ::RB2Bolt::selectedElementIds {} {
    variable P
    set out {}
    ::RB2Bolt::clearSelectionMarks

    if {$P(selectMode) eq "components"} {
        *createmarkpanel comps 1 [::HWFlow::txt "选择包含 RBE2 单元的组件" "Select components containing RBE2 elements"]
        set comps [hm_getmark comps 1]
        catch {*clearmark comps 1}
        catch {*clearmark components 1}
        if {[llength $comps] == 0} {
            ::RB2Bolt::clearSelectionMarks
            return {}
        }
        set out [::RB2Bolt::rbe2CandidatesFromComponents $comps]
    } else {
        *createmarkpanel elems 1 [::HWFlow::txt "选择 RBE2 单元" "Select RBE2 elements"]
        set selected [hm_getmark elems 1]
        set out [::RB2Bolt::rbe2CandidatesFromSelectedElements $selected]
    }
    ::RB2Bolt::clearSelectionMarks
    return [::RB2Bolt::uniqueIntegerIds $out]
}

proc ::RB2Bolt::markIds {entityTypes markId} {
    foreach entityType $entityTypes {
        if {![catch {set ids [hm_getmark $entityType $markId]}] && [llength $ids] > 0} {
            return [list $entityType $ids]
        }
    }
    return [list "" {}]
}

proc ::RB2Bolt::selectedElementIdsInteractive {} {
    set out {}
    ::RB2Bolt::clearSelectionMarks

    set prompt [::HWFlow::txt \
        "选择 RBE2 单元或包含 RBE2 的组件；在选择面板中切换 elems/comps。" \
        "Select RBE2 elements or components containing RBE2; switch elems/comps in the selection panel."]

    set opened 0
    foreach entityType {entities entity} {
        if {![catch {*createmarkpanel $entityType 1 $prompt}]} {
            set opened 1
            break
        }
    }
    if {!$opened} {
        tk_messageBox -icon error -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt \
            "当前 HyperMesh 未能打开可切换实体类型的选择面板。" \
            "HyperMesh could not open the entity-switching selection panel."]
        return {}
    }

    set compMark [::RB2Bolt::markIds {comps components} 1]
    set elemMark [::RB2Bolt::markIds {elems elements} 1]
    set comps [lindex $compMark 1]
    set elems [lindex $elemMark 1]

    if {[llength $comps] > 0} {
        set out [::RB2Bolt::rbe2CandidatesFromComponents $comps]
    } elseif {[llength $elems] > 0} {
        set out [::RB2Bolt::rbe2CandidatesFromSelectedElements $elems]
    }

    ::RB2Bolt::clearSelectionMarks
    return [::RB2Bolt::uniqueIntegerIds $out]
}

proc ::RB2Bolt::isRigidLink {eid} {
    set cfg ""
    if {[catch {hm_getvalue elems id=$eid dataname=config} cfg]} {return 0}
    if {$cfg == 55} {return 1}
    set typ ""
    catch {set typ [hm_getvalue elems id=$eid dataname=typename]}
    if {[string match -nocase *RBE2* $typ] || [string match -nocase *rigid* $typ]} {return 1}
    return 0
}

proc ::RB2Bolt::rbe2Record {eid} {
    variable P

    if {![isRigidLink $eid]} {return ""}

    set inode ""
    if {[catch {hm_getvalue elems id=$eid dataname=independentnode.id} inode] || $inode eq "" || $inode == 0} {
        return ""
    }

    set allnodes {}
    if {[catch {hm_getvalue elems id=$eid dataname=nodes} allnodes]} {
        return ""
    }

    set xyz [nodeXYZ $inode]
    set cx [lindex $xyz 0]
    set cy [lindex $xyz 1]
    set cz [lindex $xyz 2]

    set depnodes {}
    foreach n $allnodes {
        if {$n != $inode} {lappend depnodes $n}
    }
    if {[llength $depnodes] < 2} {return ""}

    set xs {}; set ys {}; set zs {}; set dists {}
    foreach n $depnodes {
        if {[catch {set nxyz [nodeXYZ $n]}]} {continue}
        set x [lindex $nxyz 0]
        set y [lindex $nxyz 1]
        set z [lindex $nxyz 2]
        lappend xs $x; lappend ys $y; lappend zs $z
        set d [dist3 $cx $cy $cz $x $y $z]
        if {$d > $P(minBeamLength)} {lappend dists $d}
    }
    if {[llength $dists] == 0} {return ""}

    set sx [lsort -real $xs]
    set sy [lsort -real $ys]
    set sz [lsort -real $zs]
    set rx [expr {[lindex $sx end] - [lindex $sx 0]}]
    set ry [expr {[lindex $sy end] - [lindex $sy 0]}]
    set rz [expr {[lindex $sz end] - [lindex $sz 0]}]
    set rangePairs [lsort -real -index 1 [list [list X $rx] [list Y $ry] [list Z $rz]]]
    set minr [lindex [lindex $rangePairs 0] 1]
    set maxr [lindex [lindex $rangePairs end] 1]
    set normalAxis [lindex [lindex $rangePairs 0] 0]

    set planar 0
    if {$maxr > 0} {
        if {$minr <= $P(planeAbsTol) || ($minr / $maxr) <= $P(planeFlatRatio)} {
            set planar 1
        }
    }
    if {!$planar} {set normalAxis ""}

    # Estimate inner free-edge radius from the first radial cluster.
    set sd [lsort -real $dists]
    set r0 [lindex $sd 0]
    set rtol [expr {$P(radialAbsTol) > ($P(radialRelTol) * $r0) ? $P(radialAbsTol) : ($P(radialRelTol) * $r0)}]
    set inner {}
    foreach d $sd {
        if {$d <= $r0 + $rtol} {lappend inner $d}
    }
    set radius [median $inner]
    set dia [evenFloorDiameter [expr {2.0 * $radius}]]

    # record = eid inode x y z dia planar normalAxis
    # normalAxis is only valid for planar RBE2 records and is one of X/Y/Z.
    return [list $eid $inode $cx $cy $cz $dia $planar $normalAxis]
}

proc ::RB2Bolt::collectRBE2Records {elemIds} {
    set records {}
    set total [llength $elemIds]
    set i 0
    foreach eid $elemIds {
        incr i
        if {[llength [info commands ::HWFlow::progressUpdate]] > 0 && ($i == 1 || $i == $total || [expr {$i % 200}] == 0)} {
            set pct [expr {10.0 + 25.0 * ($i / double($total))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "RBE2 Bolt Connector 正在执行" "RBE2 Bolt Connector running"] \
                [::HWFlow::txt "正在读取 RBE2：$i / $total" "Reading RBE2: $i / $total"] \
                [expr {$i == $total}]}
        }
        if {[expr {$i % 200}] == 0} {
            msg [::HWFlow::txt "正在读取 RBE2：$i / $total" "Reading RBE2: $i / $total"]
        }
        set rec [rbe2Record $eid]
        if {$rec ne ""} {lappend records $rec}
    }
    return $records
}

# ------------------------- grouping ----------------------------------------
proc ::RB2Bolt::ufFind {i parentName} {
    upvar 1 $parentName parent
    set p $parent($i)
    if {$p != $i} {
        set parent($i) [ufFind $p parent]
    }
    return $parent($i)
}

proc ::RB2Bolt::ufUnion {a b parentName} {
    upvar 1 $parentName parent
    set ra [ufFind $a parent]
    set rb [ufFind $b parent]
    if {$ra != $rb} {set parent($rb) $ra}
}

proc ::RB2Bolt::pairAxisAllowedByPlanarity {ra rb axis} {
    foreach rec [list $ra $rb] {
        if {[recIsPlanar $rec]} {
            set na [recNormalAxis $rec]
            if {$na ne "" && $axis ne $na} {return 0}
        }
    }
    return 1
}

proc ::RB2Bolt::pairMatchAxis {ra rb axis} {
    variable P
    if {![pairAxisAllowedByPlanarity $ra $rb $axis]} {return 0}
    set ai [coordIndex $axis]
    set cis [crossIndices $axis]
    set c1 [lindex $cis 0]
    set c2 [lindex $cis 1]

    set da [abs [expr {[lindex $ra $ai] - [lindex $rb $ai]}]]
    if {$da <= $P(minBeamLength) || $da > $P(gapTol)} {return 0}

    set dc1 [abs [expr {[lindex $ra $c1] - [lindex $rb $c1]}]]
    set dc2 [abs [expr {[lindex $ra $c2] - [lindex $rb $c2]}]]
    if {$dc1 <= $P(offsetTol) && $dc2 <= $P(offsetTol)} {return 1}
    return 0
}

proc ::RB2Bolt::intFloor {v} {
    expr {int(floor(double($v)))}
}

proc ::RB2Bolt::buildGroupsForAxis {records axis} {
    variable P
    set n [llength $records]
    if {$n < $P(minGroupSize)} {return {}}

    array unset parent
    array set parent {}
    for {set i 0} {$i < $n} {incr i} {set parent($i) $i}

    set cis [crossIndices $axis]
    set c1 [lindex $cis 0]
    set c2 [lindex $cis 1]
    set bin $P(offsetTol)

    array unset bucket
    array set bucket {}
    for {set i 0} {$i < $n} {incr i} {
        set rec [lindex $records $i]
        set b1 [intFloor [expr {[lindex $rec $c1] / $bin}]]
        set b2 [intFloor [expr {[lindex $rec $c2] / $bin}]]
        lappend bucket($b1,$b2) $i
    }

    for {set i 0} {$i < $n} {incr i} {
        set rec [lindex $records $i]
        set b1 [intFloor [expr {[lindex $rec $c1] / $bin}]]
        set b2 [intFloor [expr {[lindex $rec $c2] / $bin}]]
        for {set di -1} {$di <= 1} {incr di} {
            for {set dj -1} {$dj <= 1} {incr dj} {
                set key [expr {$b1+$di}],[expr {$b2+$dj}]
                if {![info exists bucket($key)]} {continue}
                foreach j $bucket($key) {
                    if {$j <= $i} {continue}
                    if {[pairMatchAxis $rec [lindex $records $j] $axis]} {
                        ufUnion $i $j parent
                    }
                }
            }
        }
    }

    array unset groups
    array set groups {}
    for {set i 0} {$i < $n} {incr i} {
        set r [ufFind $i parent]
        lappend groups($r) [lindex $records $i]
    }

    set out {}
    foreach k [array names groups] {
        set g $groups($k)
        if {[llength $g] >= $P(minGroupSize)} {
            lappend out [list $axis [sortGroupByAxis $g $axis]]
        }
    }
    return $out
}

proc ::RB2Bolt::recCompareAxis {a b} {
    variable _sortAxis
    set va [lindex $a $_sortAxis]
    set vb [lindex $b $_sortAxis]
    if {$va < $vb} {return -1}
    if {$va > $vb} {return 1}
    return 0
}

proc ::RB2Bolt::sortGroupByAxis {g axis} {
    variable _sortAxis
    set _sortAxis [coordIndex $axis]
    return [lsort -command ::RB2Bolt::recCompareAxis $g]
}

proc ::RB2Bolt::groupKey {g} {
    set nodes {}
    foreach rec $g {lappend nodes [lindex $rec 1]}
    return [join [lsort -integer $nodes] _]
}

proc ::RB2Bolt::groupSpread {g axis} {
    set ci [coordIndex $axis]
    set vals {}
    foreach rec $g {lappend vals [lindex $rec $ci]}
    set s [lsort -real $vals]
    expr {[lindex $s end] - [lindex $s 0]}
}

proc ::RB2Bolt::buildGroups {records} {
    variable P
    if {$P(axisMode) eq "AUTO"} {
        set axes {X Y Z}
    } else {
        set axes [list $P(axisMode)]
    }

    array unset bestG
    array set bestG {}
    array unset bestS
    array set bestS {}
    array unset bestA
    array set bestA {}

    foreach axis $axes {
        set gs [buildGroupsForAxis $records $axis]
        foreach item $gs {
            set a [lindex $item 0]
            set g [lindex $item 1]
            set key [groupKey $g]
            set sp [groupSpread $g $a]
            if {![info exists bestG($key)] || $sp > $bestS($key)} {
                set bestG($key) $g
                set bestS($key) $sp
                set bestA($key) $a
            }
        }
    }

    set out {}
    foreach key [array names bestG] {
        lappend out [list $bestA($key) $bestG($key)]
    }
    return $out
}

proc ::RB2Bolt::groupDiameter {g} {
    set planarDs {}
    set allDs {}
    foreach rec $g {
        set d [lindex $rec 5]
        if {$d > 0} {
            lappend allDs $d
            if {[lindex $rec 6]} {lappend planarDs $d}
        }
    }
    if {[llength $planarDs] > 0} {
        return [chooseModeDiameter $planarDs]
    }
    return [chooseModeDiameter $allDs]
}

# ------------------------- creation ----------------------------------------
proc ::RB2Bolt::entityIdByName {entityTypes name} {
    foreach etype $entityTypes {
        if {![catch {set id [hm_getvalue $etype name=$name dataname=id]}] && $id ne "" && $id != 0} {
            return $id
        }
        if {![catch {set id [hm_entityinfo id $etype $name -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::RB2Bolt::trySetValue {entityTypes selector field value} {
    foreach etype $entityTypes {
        set cmd [list *setvalue $etype $selector STATUS=1 "$field=$value"]
        if {![catch {eval $cmd}]} {
            return 1
        }
    }
    return 0
}

proc ::RB2Bolt::trySetEntityRef {entityTypes selector fields refType refId} {
    set refValue [format "{%s %s}" $refType $refId]
    foreach field $fields {
        foreach value [list $refValue $refId] {
            if {[::RB2Bolt::trySetValue $entityTypes $selector $field $value]} {
                return 1
            }
        }
    }
    return 0
}

proc ::RB2Bolt::ensureBoltMaterial {} {
    variable P
    variable matIdCache

    set matName [safeName "${P(compPrefix)}_BOLT_STEEL_MAT1"]
    if {$matName eq ""} {set matName BOLT_STEEL_MAT1}
    if {[info exists matIdCache($matName)] && $matIdCache($matName) ne ""} {
        return [list $matName $matIdCache($matName)]
    }

    set id [::RB2Bolt::entityIdByName {mats materials} $matName]
    if {$id eq ""} {
        set err1 ""
        set err2 ""
        if {[catch {*createentity mats cardimage=MAT1 includeid=0 name=$matName} err1]} {
            if {[catch {*createentity materials cardimage=MAT1 includeid=0 name=$matName} err2]} {
                error [::HWFlow::txt "无法创建默认螺栓材料 $matName：$err1 / $err2" "Cannot create default bolt material $matName: $err1 / $err2"]
            }
        }
        set id [::RB2Bolt::entityIdByName {mats materials} $matName]
    }
    if {$id eq "" || $id == 0} {
        error [::HWFlow::txt "无法读取默认螺栓材料 $matName 的 ID。" "Cannot read default bolt material id for $matName."]
    }

    foreach selector [list "id=$id" "name=$matName"] {
        catch {*setvalue mats $selector cardimage=MAT1}
        catch {*setvalue materials $selector cardimage=MAT1}
        ::RB2Bolt::trySetValue {mats materials} $selector E 210000.0
        ::RB2Bolt::trySetValue {mats materials} $selector 1 210000.0
        ::RB2Bolt::trySetValue {mats materials} $selector Nu 0.30
        ::RB2Bolt::trySetValue {mats materials} $selector 3 0.30
        ::RB2Bolt::trySetValue {mats materials} $selector Rho 7.85e-9
        ::RB2Bolt::trySetValue {mats materials} $selector 4 7.85e-9
    }

    set matIdCache($matName) $id
    return [list $matName $id]
}

proc ::RB2Bolt::propertyCardForElementType {elemType} {
    set u [string toupper $elemType]
    if {$u eq "CBAR"} {return PBAR}
    return PBEAM
}

proc ::RB2Bolt::autoPropertyName {elemType dia} {
    variable P
    set card [::RB2Bolt::propertyCardForElementType $elemType]
    if {[string is double -strict $dia] && $dia > 0} {
        set d [format "%.12g" $dia]
    } else {
        set d UNKNOWN
    }
    return [safeName [format "%s_D%s_%s" $P(compPrefix) $d $card]]
}

proc ::RB2Bolt::effectivePropertyName {elemType dia} {
    variable P
    if {$P(propName) ne ""} {
        return $P(propName)
    }
    return [::RB2Bolt::autoPropertyName $elemType $dia]
}

proc ::RB2Bolt::circleSection {dia} {
    if {![string is double -strict $dia] || $dia <= 0} {
        set dia 1.0
    }
    set pi [expr {acos(-1.0)}]
    set area [expr {$pi * $dia * $dia / 4.0}]
    set inertia [expr {$pi * pow($dia, 4) / 64.0}]
    set torsion [expr {$pi * pow($dia, 4) / 32.0}]
    return [list $area $inertia $inertia 0.0 $torsion 0.0]
}

proc ::RB2Bolt::ensureBoltProperty {elemType dia} {
    variable P
    variable propIdCache

    set propName [::RB2Bolt::effectivePropertyName $elemType $dia]
    if {$P(propName) ne ""} {
        return $propName
    }

    set card [::RB2Bolt::propertyCardForElementType $elemType]
    if {[info exists propIdCache($propName)] && $propIdCache($propName) ne ""} {
        return $propName
    }

    set matInfo [::RB2Bolt::ensureBoltMaterial]
    set matId [lindex $matInfo 1]

    set id [::RB2Bolt::entityIdByName {props properties} $propName]
    if {$id eq ""} {
        set err1 ""
        set err2 ""
        if {[catch {*createentity props cardimage=$card includeid=0 name=$propName} err1]} {
            if {[catch {*createentity properties cardimage=$card includeid=0 name=$propName} err2]} {
                error [::HWFlow::txt "无法创建螺栓属性 $propName：$err1 / $err2" "Cannot create bolt property $propName: $err1 / $err2"]
            }
        }
        set id [::RB2Bolt::entityIdByName {props properties} $propName]
    }
    if {$id eq "" || $id == 0} {
        error [::HWFlow::txt "无法读取螺栓属性 $propName 的 ID。" "Cannot read bolt property id for $propName."]
    }

    foreach selector [list "id=$id" "name=$propName"] {
        catch {*setvalue props $selector cardimage=$card}
        catch {*setvalue properties $selector cardimage=$card}
        ::RB2Bolt::trySetEntityRef {props properties} $selector {materialid material.id material MID Mid mid} mats $matId

        set sec [::RB2Bolt::circleSection $dia]
        set area [lindex $sec 0]
        set i1 [lindex $sec 1]
        set i2 [lindex $sec 2]
        set i12 [lindex $sec 3]
        set j [lindex $sec 4]
        set nsm [lindex $sec 5]

        foreach f {A A(A) Area area} {::RB2Bolt::trySetValue {props properties} $selector $f $area}
        foreach f {I1 I1(A) I1A} {::RB2Bolt::trySetValue {props properties} $selector $f $i1}
        foreach f {I2 I2(A) I2A} {::RB2Bolt::trySetValue {props properties} $selector $f $i2}
        foreach f {I12 I12(A) I12A} {::RB2Bolt::trySetValue {props properties} $selector $f $i12}
        foreach f {J J(A) JA} {::RB2Bolt::trySetValue {props properties} $selector $f $j}
        foreach f {NSM NSM(A) NSMA} {::RB2Bolt::trySetValue {props properties} $selector $f $nsm}
        foreach f {K1 K1(A) K1A} {::RB2Bolt::trySetValue {props properties} $selector $f 1.0}
        foreach f {K2 K2(A) K2A} {::RB2Bolt::trySetValue {props properties} $selector $f 1.0}
    }

    set propIdCache($propName) $id
    return $propName
}

proc ::RB2Bolt::enableInteractiveBrowserUpdates {} {
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

proc ::RB2Bolt::rememberBulkTouchedComp {compName} {
    variable bulkTouchedOutputComps
    if {$compName eq ""} {return}
    if {[lsearch -exact $bulkTouchedOutputComps $compName] < 0} {
        lappend bulkTouchedOutputComps $compName
    }
}

proc ::RB2Bolt::beginBulkCreate {} {
    variable currentOutputComp
    variable bulkCreateMode
    variable bulkTouchedOutputComps

    set bulkCreateMode 1
    set currentOutputComp ""
    set bulkTouchedOutputComps {}

    catch {hm_blockbrowserupdate 1}
    catch {*setoption block_browser_update=1}
    catch {*setoption block_redraw=1}
    catch {*setoption block_messages=1}
    catch {hm_blockredraw 1}
    catch {hm_blockmessages 1}
    catch {hm_blockerrormessages 1}
    catch {hm_commandfilestate 0}
}

proc ::RB2Bolt::endBulkCreate {} {
    variable bulkCreateMode
    variable currentOutputComp
    variable bulkTouchedOutputComps

    catch {hm_commandfilestate 1}
    catch {hm_blockerrormessages 0}
    catch {hm_blockmessages 0}
    catch {hm_blockredraw 0}
    catch {*setoption block_messages=0}
    catch {*setoption block_redraw=0}
    catch {*setoption block_browser_update=0}
    catch {hm_blockbrowserupdate 0}

    set touched [::RB2Bolt::uniqList $bulkTouchedOutputComps]
    if {[llength $touched] > 0} {
        if {[llength [info commands ::HWFlow::activateAndShowComponent]] > 0} {
            foreach compName $touched {
                catch {::HWFlow::activateAndShowComponent $compName 0}
            }
            if {[llength [info commands ::HWFlow::refreshBrowser]] > 0} {
                catch {::HWFlow::refreshBrowser}
            }
        } else {
            foreach compName $touched {
                catch {::RB2Bolt::refreshComponentBrowser $compName}
            }
        }
    }

    catch {hm_redraw}
    catch {update idletasks}
    catch {update}

    set currentOutputComp ""
    set bulkTouchedOutputComps {}
    set bulkCreateMode 0
}

proc ::RB2Bolt::ensureComponentFast {name} {
    variable compIdCache

    if {![array exists compIdCache]} {
        catch {unset compIdCache}
        array set compIdCache {}
    }
    ::RB2Bolt::rememberBulkTouchedComp $name

    if {[info exists compIdCache($name)] && $compIdCache($name) ne "" && $compIdCache($name) != 0} {
        return $compIdCache($name)
    }

    set id ""
    if {![catch {hm_getvalue comps name=$name dataname=id} id] && $id ne "" && $id != 0} {
        set compIdCache($name) $id
        return $id
    }

    set err1 ""
    set err2 ""
    set color [expr {1 + int(rand() * 63)}]
    if {$color >= 11} {incr color}
    if {[llength [info commands ::HWFlow::randomComponentColor]] > 0} {
        set color [::HWFlow::randomComponentColor]
    }
    set createCode [catch {*createentity comps includeid=0 name=$name} err1]
    if {$createCode} {
        set createCode [catch {*createentity components includeid=0 name=$name} err1]
    }
    if {$createCode} {
        set createCode [catch {*collectorcreateonly comps $name "" $color} err2]
    }
    if {$createCode} {
        set createCode [catch {*collectorcreateonly components $name "" $color} err2]
    }
    if {$createCode} {
        error [::HWFlow::txt "无法创建组件 $name：$err1 / $err2" "Cannot create component $name: $err1 / $err2"]
    }

    set id 0
    catch {set id [hm_getvalue comps name=$name dataname=id]}
    if {$id ne "" && $id != 0} {
        foreach etype {comps components} {
            catch {*setvalue $etype id=$id color=$color}
        }
    }
    set compIdCache($name) $id
    return $id
}

proc ::RB2Bolt::setCurrentOutputComponentFast {compName} {
    variable currentOutputComp

    if {$currentOutputComp eq $compName} {return}
    ::RB2Bolt::ensureComponentFast $compName
    catch {*currentcollector component $compName}
    catch {*currentcollector components $compName}
    set currentOutputComp $compName
}

proc ::RB2Bolt::ensureComponent {name} {
    set id ""
    if {![catch {hm_getvalue comps name=$name dataname=id} id] && $id ne "" && $id != 0} {
        catch {*currentcollector component $name}
        catch {::HWFlow::activateAndShowComponent $name 0}
        ::RB2Bolt::refreshComponentBrowser $name
        return $id
    }

    if {[llength [info commands ::HWFlow::createComponent]] > 0} {
        set id [::HWFlow::createComponent $name]
    } else {
        set color [expr {1 + int(rand() * 63)}]
        if {$color >= 11} {incr color}
        if {[llength [info commands ::HWFlow::randomComponentColor]] > 0} {
            set color [::HWFlow::randomComponentColor]
        }
        ::RB2Bolt::enableInteractiveBrowserUpdates
        set histName "Created Component $name"
        catch {*startnotehistorystate $histName}
        set createCode [catch {*createentity comps includeid=0 name=$name} err1]
        if {$createCode} {
            set createCode [catch {*createentity components includeid=0 name=$name} err1]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly comps $name "" $color} err2]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly components $name "" $color} err2]
        }
        if {$createCode} {
            catch {*endnotehistorystate $histName}
            error [::HWFlow::txt "无法创建组件 $name：$err1 / $err2" "Cannot create component $name: $err1 / $err2"]
        }
        catch {*endnotehistorystate $histName}
        set id 0
        catch {set id [hm_getvalue comps name=$name dataname=id]}
        if {$id ne "" && $id != 0} {
            foreach etype {comps components} {
                catch {*setvalue $etype id=$id color=$color}
            }
        }
    }
    catch {*currentcollector component $name}
    ::RB2Bolt::refreshComponentBrowser $name
    return $id
}

proc ::RB2Bolt::uniqList {lst} {
    set out {}
    array set seen {}
    foreach v $lst {
        if {$v eq ""} {continue}
        if {![info exists seen($v)]} {
            set seen($v) 1
            lappend out $v
        }
    }
    return $out
}

proc ::RB2Bolt::markComponentByName {compName markId} {
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

proc ::RB2Bolt::refreshComponentBrowser {compName} {
    if {[llength [info commands ::HWFlow::activateAndShowComponent]] > 0} {
        catch {::HWFlow::activateAndShowComponent $compName 0}
        catch {::HWFlow::refreshBrowser}
        return
    }
    set markType [::RB2Bolt::markComponentByName $compName 2]
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

proc ::RB2Bolt::componentIdByName {name} {
    if {[llength [info commands ::HWFlow::componentIdByName]] > 0} {
        return [::HWFlow::componentIdByName $name]
    }
    foreach etype {components comps component} {
        if {![catch {set id [hm_entityinfo id $etype $name -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::RB2Bolt::getElemsByComp {compId} {
    if {[llength [info commands ::HWFlow::getCompEntityIds]] > 0} {
        return [::HWFlow::getCompEntityIds $compId elems elems]
    }
    set elems {}
    catch {*clearmark elems 2}
    if {![catch {*createmark elems 2 "by comp id" $compId}]} {
        catch {set elems [hm_getmark elems 2]}
    }
    catch {*clearmark elems 2}
    return [lsort -integer -unique $elems]
}

proc ::RB2Bolt::beamSegmentKey {n1 n2 elemType propName} {
    return [::HWFlow::nodePairKey $n1 $n2 "[string toupper $elemType]|$propName"]
}

proc ::RB2Bolt::elemLooksLike1DConnector {eid elemType} {
    set target [string toupper $elemType]
    foreach dn {typename solverkeyword solvername cardimage config} {
        if {![catch {set v [hm_getvalue elems id=$eid dataname=$dn]}] && $v ne ""} {
            set u [string toupper "$v"]
            if {[string first $target $u] >= 0 || [string first "BEAM" $u] >= 0 || [string first "BAR" $u] >= 0} {
                return 1
            }
        }
    }
    return 0
}

proc ::RB2Bolt::indexExistingBeamSegments {compName elemType propName} {
    variable beamSegmentIndex
    set indexKey "$compName|$elemType|$propName"
    if {[info exists beamSegmentIndex(__indexed,$indexKey)]} {
        return 0
    }
    set beamSegmentIndex(__indexed,$indexKey) 1

    set compId [::RB2Bolt::componentIdByName $compName]
    if {$compId eq ""} {
        return 0
    }

    set count 0
    foreach eid [::RB2Bolt::getElemsByComp $compId] {
        if {[catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}] || [llength $nodes] < 2} {
            continue
        }
        if {![::RB2Bolt::elemLooksLike1DConnector $eid $elemType] && [llength $nodes] != 2} {
            continue
        }
        set key [::RB2Bolt::beamSegmentKey [lindex $nodes 0] [lindex $nodes 1] $elemType $propName]
        set beamSegmentIndex($key) $eid
        incr count
    }
    return $count
}

proc ::RB2Bolt::existingBeamSegment {n1 n2 elemType compName {propName ""}} {
    variable beamSegmentIndex
    ::RB2Bolt::indexExistingBeamSegments $compName $elemType $propName
    set key [::RB2Bolt::beamSegmentKey $n1 $n2 $elemType $propName]
    if {[info exists beamSegmentIndex($key)]} {
        return [list 1 $beamSegmentIndex($key) $key]
    }
    return [list 0 "" $key]
}

proc ::RB2Bolt::rememberBeamSegment {n1 n2 elemType compName elemId {propName ""}} {
    variable beamSegmentIndex
    set key [::RB2Bolt::beamSegmentKey $n1 $n2 $elemType $propName]
    if {$elemId eq ""} {
        set elemId created
    }
    set beamSegmentIndex($key) $elemId
}

proc ::RB2Bolt::orientVecForNodes {n1 n2} {
    set a [nodeXYZ $n1]
    set b [nodeXYZ $n2]
    set dx [expr {[lindex $b 0] - [lindex $a 0]}]
    set dy [expr {[lindex $b 1] - [lindex $a 1]}]
    set dz [expr {[lindex $b 2] - [lindex $a 2]}]
    set len [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
    if {$len <= 0.0} {return {0.0 0.0 1.0}}

    # The orientation vector must not be parallel to the CBEAM axis.
    # Prefer global Z; use global Y when the beam itself is almost Z-directional.
    set uz [expr {abs($dz / $len)}]
    if {$uz < 0.90} {
        return {0.0 0.0 1.0}
    }
    return {0.0 1.0 0.0}
}

proc ::RB2Bolt::createdElementIdAfter {beforeElem} {
    set elemId ""
    catch {set elemId [hm_latestentityid elems]}
    if {$elemId eq $beforeElem} {set elemId ""}
    return $elemId
}

proc ::RB2Bolt::assignBeamProperty {elemId propName} {
    if {$elemId eq "" || $propName eq ""} {return 0}
    set propId [::RB2Bolt::entityIdByName {props properties} $propName]
    catch {*clearmark elems 1}
    catch {*createmark elems 1 $elemId}
    set ok 0
    if {![catch {*propertyupdate elems 1 $propName}]} {set ok 1}
    if {!$ok && ![catch {*propertyupdate elements 1 $propName}]} {set ok 1}
    catch {*clearmark elems 1}
    if {$propId ne ""} {
        foreach selector [list "id=$elemId"] {
            if {[::RB2Bolt::trySetEntityRef {elems elements} $selector {propertyid property.id property PID pid} props $propId]} {
                set ok 1
            }
        }
    }
    return $ok
}

proc ::RB2Bolt::createdBeamHasProperty {elemId propName} {
    if {$elemId eq "" || $propName eq ""} {return 1}
    set propId [::RB2Bolt::entityIdByName {props properties} $propName]
    set readable 0
    foreach dn {property.id propertyid property collector.id prop.id} {
        if {[catch {set v [hm_getvalue elems id=$elemId dataname=$dn]}] || $v eq ""} {
            continue
        }
        if {[string is double -strict $v] && $v == 0} {
            continue
        }
        set readable 1
        if {$propId ne "" && "$v" eq "$propId"} {return 1}
        if {[string equal -nocase "$v" "$propName"] || [string first [string toupper $propName] [string toupper "$v"]] >= 0} {
            return 1
        }
    }
    if {$readable} {return 0}
    return -1
}

proc ::RB2Bolt::createdBeamNodeIds {elemId} {
    if {$elemId eq ""} {return {}}
    set out {}
    foreach dn {node1.id node2.id} {
        if {![catch {set v [hm_getvalue elems id=$elemId dataname=$dn]}] && $v ne "" && !([string is double -strict $v] && $v == 0)} {
            lappend out $v
        }
    }
    if {[llength $out] >= 2} {
        return [lrange $out 0 1]
    }
    if {![catch {set nodes [hm_getvalue elems id=$elemId dataname=nodes]}] && [llength $nodes] >= 2} {
        return [lrange $nodes 0 1]
    }
    return {}
}

proc ::RB2Bolt::replaceOneNode {sourceNode targetNode} {
    if {$sourceNode eq "" || $targetNode eq "" || "$sourceNode" eq "$targetNode"} {
        return 1
    }
    catch {*createlist nodes 1}
    catch {*createlist nodes 2}
    set ok 0
    if {![catch {*replacenodes source_node=$sourceNode target_node=$targetNode equiv=1 midpoint=0 collapse_check=2}]} {
        set ok 1
    }
    if {!$ok} {
        if {![catch {*createlist nodes 1 $sourceNode}]} {
            if {![catch {*createlist nodes 2 $targetNode}]} {
                if {![catch {*replacenodes source_list=1 target_list=2 equiv=1 midpoint=0 collapse_check=2}]} {
                    set ok 1
                }
            }
        }
    }
    catch {*createlist nodes 1}
    catch {*createlist nodes 2}
    return $ok
}

proc ::RB2Bolt::nodeDistanceById {a b} {
    if {$a eq "" || $b eq ""} {return 1.0e99}
    if {[catch {set pa [nodeXYZ $a]}] || [catch {set pb [nodeXYZ $b]}]} {
        return 1.0e99
    }
    return [dist3 [lindex $pa 0] [lindex $pa 1] [lindex $pa 2] [lindex $pb 0] [lindex $pb 1] [lindex $pb 2]]
}

proc ::RB2Bolt::nodesCoincident {a b} {
    variable P
    set tol $P(minBeamLength)
    if {$tol < 1.0e-6} {set tol 1.0e-6}
    return [expr {[::RB2Bolt::nodeDistanceById $a $b] <= $tol}]
}

proc ::RB2Bolt::forceBeamEndpointNodes {elemId n1 n2} {
    if {$elemId eq ""} {return 0}
    set nodes [::RB2Bolt::createdBeamNodeIds $elemId]
    if {[llength $nodes] >= 2 && [lindex $nodes 0] eq "$n1" && [lindex $nodes 1] eq "$n2"} {
        return 1
    }
    if {[llength $nodes] >= 2 && [lindex $nodes 0] eq "$n2" && [lindex $nodes 1] eq "$n1"} {
        return 1
    }

    set ref1 [format "{nodes %s}" $n1]
    set ref2 [format "{nodes %s}" $n2]
    set directOk 0
    foreach etype {elems elements} {
        if {![catch {*setvalue $etype id=$elemId node1=$ref1 node2=$ref2}]} {
            set directOk 1
            break
        }
        if {![catch {*setvalue $etype id=$elemId node1=$n1 node2=$n2}]} {
            set directOk 1
            break
        }
    }
    if {$directOk} {
        set chk [::RB2Bolt::createdBeamNodeIds $elemId]
        if {[llength $chk] >= 2 && (([lindex $chk 0] eq "$n1" && [lindex $chk 1] eq "$n2") || ([lindex $chk 0] eq "$n2" && [lindex $chk 1] eq "$n1"))} {
            return 1
        }
    }

    if {[llength $nodes] < 2} {return 0}
    set old1 [lindex $nodes 0]
    set old2 [lindex $nodes 1]
    set dStraight [expr {[::RB2Bolt::nodeDistanceById $old1 $n1] + [::RB2Bolt::nodeDistanceById $old2 $n2]}]
    set dSwap [expr {[::RB2Bolt::nodeDistanceById $old1 $n2] + [::RB2Bolt::nodeDistanceById $old2 $n1]}]
    if {$dSwap < $dStraight} {
        set target1 $n2
        set target2 $n1
    } else {
        set target1 $n1
        set target2 $n2
    }
    if {![::RB2Bolt::nodesCoincident $old1 $target1] || ![::RB2Bolt::nodesCoincident $old2 $target2]} {
        return 0
    }
    if {![::RB2Bolt::replaceOneNode $old1 $target1]} {return 0}
    if {![::RB2Bolt::replaceOneNode $old2 $target2]} {return 0}

    set chk [::RB2Bolt::createdBeamNodeIds $elemId]
    if {[llength $chk] >= 2 && (([lindex $chk 0] eq "$n1" && [lindex $chk 1] eq "$n2") || ([lindex $chk 0] eq "$n2" && [lindex $chk 1] eq "$n1"))} {
        return 1
    }
    return 0
}

proc ::RB2Bolt::createdBeamUsesNodes {elemId n1 n2} {
    if {$elemId eq ""} {return 1}
    set nodes [::RB2Bolt::createdBeamNodeIds $elemId]
    if {[llength $nodes] == 0} {
        return 1
    }
    return [expr {[lsearch -exact $nodes $n1] >= 0 && [lsearch -exact $nodes $n2] >= 0}]
}

proc ::RB2Bolt::deleteElementIfKnown {elemId} {
    if {$elemId eq ""} {return}
    catch {*clearmark elems 1}
    if {![catch {*createmark elems 1 $elemId}]} {
        catch {*deletemark elems 1}
    }
    catch {*clearmark elems 1}
}

proc ::RB2Bolt::finalizeCreatedBeam {elemId n1 n2 elemType compName propName} {
    if {![::RB2Bolt::forceBeamEndpointNodes $elemId $n1 $n2] || ![::RB2Bolt::createdBeamUsesNodes $elemId $n1 $n2]} {
        msg [::HWFlow::txt "$elemType 创建后节点校验失败：期望 $n1-$n2，单元=$elemId。" "$elemType node check failed after creation: expected $n1-$n2, elem=$elemId."]
        ::RB2Bolt::deleteElementIfKnown $elemId
        return 0
    }
    set assigned [::RB2Bolt::assignBeamProperty $elemId $propName]
    set propOk [::RB2Bolt::createdBeamHasProperty $elemId $propName]
    if {$propOk == 0} {
        msg [::HWFlow::txt "$elemType 创建后属性校验失败：单元=$elemId，属性=$propName。" "$elemType property check failed after creation: elem=$elemId, property=$propName."]
        return 0
    }
    if {$propOk < 0 && !$assigned && $propName ne ""} {
        msg [::HWFlow::txt "$elemType 已创建，但无法确认属性是否已赋给单元=$elemId，属性=$propName。" "$elemType was created, but property assignment could not be verified: elem=$elemId, property=$propName."]
    }
    ::RB2Bolt::rememberBeamSegment $n1 $n2 $elemType $compName $elemId $propName
    return 1
}

proc ::RB2Bolt::createBeamBetween {n1 n2 elemType compName {propName ""}} {
    variable P
    set xyz1 [nodeXYZ $n1]
    set xyz2 [nodeXYZ $n2]
    set len [dist3 [lindex $xyz1 0] [lindex $xyz1 1] [lindex $xyz1 2] [lindex $xyz2 0] [lindex $xyz2 1] [lindex $xyz2 2]]
    if {$len <= $P(minBeamLength)} {return 0}

    set existing [::RB2Bolt::existingBeamSegment $n1 $n2 $elemType $compName $propName]
    if {[lindex $existing 0]} {
        msg [::HWFlow::txt "$elemType 已存在，跳过节点 $n1-$n2。" "$elemType already exists, skipped nodes $n1-$n2."]
        return -1
    }

    ensureComponent $compName

    # HyperMesh 2019 compatible creation path.
    # This command creates a BAR2-type bar/beam according to the current 1D element
    # type setting. In Nastran/OptiStruct profiles, set: 1D > elem types > BAR2 = CBEAM.
    set ov [orientVecForNodes $n1 $n2]
    if {[catch {*createvector 1 [lindex $ov 0] [lindex $ov 1] [lindex $ov 2]} verr]} {
        msg [::HWFlow::txt "节点 $n1-$n2 的方向向量创建失败：$verr" "Create orientation vector failed for nodes $n1-$n2: $verr"]
        return 0
    }

    if {$propName ne ""} {
        set propCandidates [list $propName]
    } elseif {$P(propName) ne ""} {
        set propCandidates [list $P(propName)]
    } else {
        # Different HM/profile versions accept either 0 or an empty property name
        # when creating a bar without assigning a property. Try both.
        set propCandidates [list 0 ""]
    }

    # Full-offset syntax first. If the installed profile accepts the shorter
    # legacy syntax only, try that as fallback.
    set lastErr ""
    foreach prop $propCandidates {
        set err1 ""
        set beforeElem ""
        catch {set beforeElem [hm_latestentityid elems]}
        set rc1 [catch {*barelementcreatewithoffsets $n1 $n2 1 0 1 0 0 $prop 0 0 0 0 0 0 0 0} err1]
        if {$rc1 == 0} {
            set elemId [::RB2Bolt::createdElementIdAfter $beforeElem]
            if {![::RB2Bolt::finalizeCreatedBeam $elemId $n1 $n2 $elemType $compName $prop]} {return 0}
            return 1
        }
        set lastErr "barFull=$err1"

        set err2 ""
        set beforeElem ""
        catch {set beforeElem [hm_latestentityid elems]}
        set rc2 [catch {*barelementcreatewithoffsets $n1 $n2 1 0 1 0 0 $prop} err2]
        if {$rc2 == 0} {
            set elemId [::RB2Bolt::createdElementIdAfter $beforeElem]
            if {![::RB2Bolt::finalizeCreatedBeam $elemId $n1 $n2 $elemType $compName $prop]} {return 0}
            return 1
        }
        append lastErr "; barShort=$err2"
    }

    msg [::HWFlow::txt "$elemType 创建失败：节点 $n1-$n2；$lastErr" "Create $elemType failed: nodes $n1-$n2; $lastErr"]
    return 0
}

proc ::RB2Bolt::createBeamBetweenRecords {r1 r2 elemType compName {propName ""}} {
    variable P

    set n1 [lindex $r1 1]
    set n2 [lindex $r2 1]
    set x1 [lindex $r1 2]
    set y1 [lindex $r1 3]
    set z1 [lindex $r1 4]
    set x2 [lindex $r2 2]
    set y2 [lindex $r2 3]
    set z2 [lindex $r2 4]

    set dx [expr {$x2 - $x1}]
    set dy [expr {$y2 - $y1}]
    set dz [expr {$z2 - $z1}]
    set len [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
    if {$len <= $P(minBeamLength)} {return 0}

    set existing [::RB2Bolt::existingBeamSegment $n1 $n2 $elemType $compName $propName]
    if {[lindex $existing 0]} {
        return -1
    }

    ::RB2Bolt::setCurrentOutputComponentFast $compName

    set uz [expr {abs($dz / $len)}]
    if {$uz < 0.90} {
        set ov {0.0 0.0 1.0}
    } else {
        set ov {0.0 1.0 0.0}
    }
    if {[catch {*createvector 1 [lindex $ov 0] [lindex $ov 1] [lindex $ov 2]}]} {
        return 0
    }

    if {$propName ne ""} {
        set propCandidates [list $propName]
    } elseif {$P(propName) ne ""} {
        set propCandidates [list $P(propName)]
    } else {
        set propCandidates [list 0 ""]
    }

    foreach prop $propCandidates {
        set beforeElem ""
        catch {set beforeElem [hm_latestentityid elems]}
        if {![catch {*barelementcreatewithoffsets $n1 $n2 1 0 1 0 0 $prop 0 0 0 0 0 0 0 0}]} {
            set elemId [::RB2Bolt::createdElementIdAfter $beforeElem]
            if {![::RB2Bolt::finalizeCreatedBeam $elemId $n1 $n2 $elemType $compName $prop]} {return 0}
            return 1
        }

        set beforeElem ""
        catch {set beforeElem [hm_latestentityid elems]}
        if {![catch {*barelementcreatewithoffsets $n1 $n2 1 0 1 0 0 $prop}]} {
            set elemId [::RB2Bolt::createdElementIdAfter $beforeElem]
            if {![::RB2Bolt::finalizeCreatedBeam $elemId $n1 $n2 $elemType $compName $prop]} {return 0}
            return 1
        }
    }

    return 0
}

proc ::RB2Bolt::pairGroupRecords {g axis} {
    # Build adjacent pairs after sorting along the bolt axis.
    # For sorted RBE2 centers 1,2,3,4, this creates 1-2, 2-3, 3-4.
    # It deliberately avoids skipped/span connections such as 1-3 or 1-4.
    set n [llength $g]
    set pairs {}
    if {$n < 2} {return $pairs}

    for {set i 0} {$i < [expr {$n - 1}]} {incr i} {
        set ri [lindex $g $i]
        set rj [lindex $g [expr {$i + 1}]]
        if {[pairMatchAxis $ri $rj $axis]} {
            lappend pairs [list $ri $rj]
        }
    }
    return $pairs
}

proc ::RB2Bolt::createBolts {groups} {
    variable P
    variable propIdCache
    variable matIdCache
    catch {unset propIdCache}
    array set propIdCache {}
    catch {unset matIdCache}
    array set matIdCache {}

    set created 0
    set skipped 0
    set skippedExisting 0
    set pairTotal 0
    set spatialOnlyGroups 0
    set groupCount [llength $groups]
    set gi 0
    set outputComps {}

    foreach item $groups {
        incr gi
        if {[llength [info commands ::HWFlow::progressUpdate]] > 0 && ($gi == 1 || $gi == $groupCount || [expr {$gi % 20}] == 0)} {
            set pct [expr {65.0 + 25.0 * ($gi / double($groupCount))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "RBE2 Bolt Connector 正在执行" "RBE2 Bolt Connector running"] \
                [::HWFlow::txt "正在创建螺栓分组：$gi / $groupCount" "Creating bolt groups: $gi / $groupCount"] \
                [expr {$gi == $groupCount}]}
        }
        set axis [lindex $item 0]
        set g [lindex $item 1]
        set pairs [pairGroupRecords $g $axis]
        incr pairTotal [llength $pairs]
        set unpaired [expr {([llength $g] > 1 ? ([llength $g] - 1) : 0) - [llength $pairs]}]

        if {![groupHasPlanar $g]} {
            incr spatialOnlyGroups
            incr skipped [expr {[llength $pairs] + $unpaired}]
            msg [::HWFlow::txt "螺栓分组 $gi / $groupCount，轴向=$axis，空间型 RBE2-only 分组，RBE2=[llength $g]，已跳过创建=1" "Bolt group $gi / $groupCount, axis=$axis, spatial-only RBE2 group, RBE2=[llength $g], skipped_creation=1"]
            continue
        }

        set dia [groupDiameter $g]
        if {$dia <= 0} {set dia UNKNOWN}
        set compName [safeName [format "%s_D%s_%s" $P(compPrefix) $dia $P(elemType)]]
        set propName [::RB2Bolt::effectivePropertyName $P(elemType) $dia]

        msg [::HWFlow::txt "螺栓分组 $gi / $groupCount，轴向=$axis，D=$dia，RBE2=[llength $g]，相邻连接段=[llength $pairs]，跳过连接段=$unpaired" "Bolt group $gi / $groupCount, axis=$axis, D=$dia, RBE2=[llength $g], adjacent_segments=[llength $pairs], skipped_segments=$unpaired"]

        if {$P(dryRun)} {continue}
        if {[llength $pairs] > 0} {
            lappend outputComps $compName
        }

        foreach pr $pairs {
            set r1 [lindex $pr 0]
            set r2 [lindex $pr 1]
            set n1 [lindex $r1 1]
            set n2 [lindex $r2 1]
            if {$P(propName) eq ""} {
                set propName [::RB2Bolt::ensureBoltProperty $P(elemType) $dia]
            }
            set createResult [createBeamBetween $n1 $n2 $P(elemType) $compName $propName]
            if {$createResult > 0} {
                incr created
            } elseif {$createResult < 0} {
                incr skippedExisting
            } else {
                incr skipped
            }
        }
        incr skipped $unpaired
    }

    foreach compName [::RB2Bolt::uniqList $outputComps] {
        ::RB2Bolt::refreshComponentBrowser $compName
    }

    return [list $created $skipped $pairTotal $spatialOnlyGroups $skippedExisting]
}

proc ::RB2Bolt::buildBoltPairList {groups} {
    variable P
    set boltPairs {}
    set pairTotal 0
    set skipped 0
    set spatialOnlyGroups 0
    set outputComps {}
    set groupCount [llength $groups]
    set gi 0

    foreach item $groups {
        incr gi
        if {[llength [info commands ::HWFlow::progressUpdate]] > 0 && ($gi == 1 || $gi == $groupCount || [expr {$gi % 100}] == 0)} {
            set pct [expr {55.0 + 10.0 * ($gi / double($groupCount))}]
            catch {::HWFlow::progressUpdate $pct \
                [::HWFlow::txt "RBE2 Bolt Connector 正在执行" "RBE2 Bolt Connector running"] \
                [::HWFlow::txt "正在生成螺栓连接段：$gi / $groupCount" "Building bolt pair list: $gi / $groupCount"] \
                [expr {$gi == $groupCount}]}
        }

        set axis [lindex $item 0]
        set g [lindex $item 1]
        set pairs [pairGroupRecords $g $axis]
        incr pairTotal [llength $pairs]
        set unpaired [expr {([llength $g] > 1 ? ([llength $g] - 1) : 0) - [llength $pairs]}]

        if {![groupHasPlanar $g]} {
            incr spatialOnlyGroups
            incr skipped [expr {[llength $pairs] + $unpaired}]
            continue
        }

        set dia [groupDiameter $g]
        if {$dia <= 0} {set dia UNKNOWN}
        set compName [safeName [format "%s_D%s_%s" $P(compPrefix) $dia $P(elemType)]]
        set propName [::RB2Bolt::effectivePropertyName $P(elemType) $dia]

        if {[llength $pairs] > 0} {
            lappend outputComps $compName
        }
        foreach pr $pairs {
            lappend boltPairs [list $compName $propName $dia $axis $gi [lindex $pr 0] [lindex $pr 1]]
        }
        incr skipped $unpaired
    }

    return [dict create \
        boltPairs $boltPairs \
        pairTotal $pairTotal \
        skipped $skipped \
        spatialOnlyGroups $spatialOnlyGroups \
        outputComps [::RB2Bolt::uniqList $outputComps]]
}

proc ::RB2Bolt::createBoltsFast {groups} {
    variable P
    variable compIdCache
    variable propIdCache
    variable matIdCache

    catch {unset compIdCache}
    array set compIdCache {}
    catch {unset propIdCache}
    array set propIdCache {}
    catch {unset matIdCache}
    array set matIdCache {}

    set tPair0 [clock milliseconds]
    set pairInfo [::RB2Bolt::buildBoltPairList $groups]
    set tPair1 [clock milliseconds]
    set boltPairs [dict get $pairInfo boltPairs]
    set pairTotal [dict get $pairInfo pairTotal]
    set skipped [dict get $pairInfo skipped]
    set spatialOnlyGroups [dict get $pairInfo spatialOnlyGroups]
    set outputComps [dict get $pairInfo outputComps]
    set pairMs [expr {$tPair1 - $tPair0}]

    if {$P(dryRun)} {
        msg [::HWFlow::txt "boltPairs 生成耗时：$pairMs ms；dryRun=1，未创建 $P(elemType)。" "Bolt pair generation time: $pairMs ms; dryRun=1, no $P(elemType) created."]
        msg [::HWFlow::txt "创建统计：created=0，skippedExisting=0，skipped=$skipped，pairTotal=$pairTotal" "Creation stats: created=0, skippedExisting=0, skipped=$skipped, pairTotal=$pairTotal"]
        return [list 0 $skipped $pairTotal $spatialOnlyGroups 0]
    }

    set boltPairs [lsort -index 0 $boltPairs]
    foreach compName $outputComps {
        ::RB2Bolt::ensureComponentFast $compName
    }
    if {$P(propName) eq ""} {
        foreach boltPair $boltPairs {
            ::RB2Bolt::ensureBoltProperty $P(elemType) [lindex $boltPair 2]
        }
    }

    set created 0
    set skippedExisting 0
    set pairCount [llength $boltPairs]
    set tCreate0 [clock milliseconds]
    ::RB2Bolt::beginBulkCreate
    set createCode [catch {
        set pi 0
        foreach boltPair $boltPairs {
            incr pi
            if {[llength [info commands ::HWFlow::progressUpdate]] > 0 && ($pi == 1 || $pi == $pairCount || [expr {$pi % 200}] == 0)} {
                set pct [expr {$pairCount > 0 ? 70.0 + 25.0 * ($pi / double($pairCount)) : 95.0}]
                catch {::HWFlow::progressUpdate $pct \
                    [::HWFlow::txt "RBE2 Bolt Connector 正在执行" "RBE2 Bolt Connector running"] \
                    [::HWFlow::txt "正在创建 $P(elemType)：$pi / $pairCount" "Creating $P(elemType): $pi / $pairCount"] \
                    [expr {$pi == $pairCount}]}
            }

            set compName [lindex $boltPair 0]
            set propName [lindex $boltPair 1]
            set r1 [lindex $boltPair 5]
            set r2 [lindex $boltPair 6]
            set createResult [::RB2Bolt::createBeamBetweenRecords $r1 $r2 $P(elemType) $compName $propName]
            if {$createResult > 0} {
                incr created
            } elseif {$createResult < 0} {
                incr skippedExisting
            } else {
                incr skipped
            }
        }
    } createErr createOpts]
    set endCode [catch {::RB2Bolt::endBulkCreate} endErr endOpts]
    set tCreate1 [clock milliseconds]

    if {$createCode} {
        return -options $createOpts $createErr
    }
    if {$endCode} {
        return -options $endOpts $endErr
    }

    set createMs [expr {$tCreate1 - $tCreate0}]
    msg [::HWFlow::txt "boltPairs 生成耗时：$pairMs ms；$P(elemType) 创建耗时：$createMs ms。" "Bolt pair generation time: $pairMs ms; $P(elemType) creation time: $createMs ms."]
    msg [::HWFlow::txt "创建统计：created=$created，skippedExisting=$skippedExisting，skipped=$skipped，pairTotal=$pairTotal" "Creation stats: created=$created, skippedExisting=$skippedExisting, skipped=$skipped, pairTotal=$pairTotal"]

    return [list $created $skipped $pairTotal $spatialOnlyGroups $skippedExisting]
}

# ------------------------- unused shell RBE2 cleanup aid -------------------
proc ::RB2Bolt::usedRBE2ElementIdsFromGroups {groups} {
    array unset used
    array set used {}

    foreach item $groups {
        set axis [lindex $item 0]
        set g [lindex $item 1]
        if {![::RB2Bolt::groupHasPlanar $g]} {
            continue
        }

        foreach pr [::RB2Bolt::pairGroupRecords $g $axis] {
            set r1 [lindex $pr 0]
            set r2 [lindex $pr 1]
            set used([lindex $r1 0]) 1
            set used([lindex $r2 0]) 1
        }
    }

    set out {}
    foreach eid [array names used] {
        lappend out $eid
    }
    return [::RB2Bolt::uniqueIntegerIds $out]
}

proc ::RB2Bolt::unusedShellRBE2Records {records groups} {
    array unset used
    array set used {}
    foreach eid [::RB2Bolt::usedRBE2ElementIdsFromGroups $groups] {
        set used($eid) 1
    }

    set out {}
    foreach rec $records {
        set eid [lindex $rec 0]
        if {![::RB2Bolt::recIsPlanar $rec]} {
            continue
        }
        if {![info exists used($eid)]} {
            lappend out $rec
        }
    }
    return $out
}

proc ::RB2Bolt::rbe2ElementIdsFromRecords {records} {
    set out {}
    foreach rec $records {
        lappend out [lindex $rec 0]
    }
    return [::RB2Bolt::uniqueIntegerIds $out]
}

proc ::RB2Bolt::deleteComponentByName {compName} {
    set markType [::RB2Bolt::markComponentByName $compName 2]
    if {$markType eq ""} {
        return 0
    }
    if {[catch {*deletemark $markType 2}]} {
        catch {*clearmark $markType 2}
        return 0
    }
    catch {*clearmark $markType 2}
    return 1
}

proc ::RB2Bolt::createMarkerPointOrNode {x y z} {
    set beforePoint ""
    catch {set beforePoint [hm_latestentityid points]}
    if {![catch {*createpoint $x $y $z 0}]} {
        set pointId ""
        catch {set pointId [hm_latestentityid points]}
        if {$pointId ne "" && $pointId != 0 && $pointId ne $beforePoint} {
            return [list point $pointId]
        }
        return [list point ""]
    }

    set beforeNode ""
    catch {set beforeNode [hm_latestentityid nodes]}
    if {![catch {*createnode $x $y $z 0 0 0}]} {
        set nodeId ""
        catch {set nodeId [hm_latestentityid nodes]}
        if {$nodeId ne "" && $nodeId != 0 && $nodeId ne $beforeNode} {
            return [list node $nodeId]
        }
        return [list node ""]
    }

    return [list "" ""]
}

proc ::RB2Bolt::createUnusedShellRBE2Markers {records} {
    set compName "UNUSED_SHELL_RBE2_MARKERS"
    ::RB2Bolt::deleteComponentByName $compName
    ::RB2Bolt::ensureComponent $compName
    catch {*currentcollector component $compName}
    catch {*currentcollector components $compName}

    set pointCount 0
    set nodeCount 0
    set failed 0
    foreach rec $records {
        set made [::RB2Bolt::createMarkerPointOrNode [lindex $rec 2] [lindex $rec 3] [lindex $rec 4]]
        switch -- [lindex $made 0] {
            point {incr pointCount}
            node {incr nodeCount}
            default {incr failed}
        }
    }

    catch {*setvalue comps name=$compName color=2}
    catch {*setvalue components name=$compName color=2}
    ::RB2Bolt::refreshComponentBrowser $compName
    return [dict create component $compName points $pointCount nodes $nodeCount failed $failed]
}

proc ::RB2Bolt::markElementsForManualDelete {elemIds} {
    set elemIds [::RB2Bolt::uniqueIntegerIds $elemIds]
    if {[llength $elemIds] == 0} {
        return ""
    }

    foreach etype {elems elements} {
        catch {*clearmark $etype 1}
        catch {*clearmark $etype 2}
    }

    foreach etype {elems elements} {
        if {![catch {eval [concat [list *createmark $etype 1 "by id only"] $elemIds]}]} {
            set got {}
            catch {set got [hm_getmark $etype 1]}
            if {[llength $got] > 0} {
                catch {*marktousermark $etype 1}
                return $etype
            }
        }

        catch {*clearmark $etype 1}
        if {![catch {eval [concat [list *createmark $etype 1] $elemIds]}]} {
            set got {}
            catch {set got [hm_getmark $etype 1]}
            if {[llength $got] > 0} {
                catch {*marktousermark $etype 1}
                return $etype
            }
        }
    }
    return ""
}

proc ::RB2Bolt::enterElementDeleteMode {elemIds} {
    set markType [::RB2Bolt::markElementsForManualDelete $elemIds]
    if {$markType eq ""} {
        return 0
    }

    catch {hm_usermessage [::HWFlow::txt \
        "未用 Shell RBE2 已自动选入 Delete 面板；请手动确认需要删除的单元。" \
        "Unused shell RBE2 elements were preselected for the Delete panel; manually confirm which elements to delete."]}

    foreach panelName {delete Delete} {
        if {![catch {hm_callpanel $panelName}]} {
            return 1
        }
        if {![catch {hm_pushpanel $panelName}]} {
            return 1
        }
        if {![catch {hm_setpanelproc [list hm_callpanel $panelName]}]} {
            return 1
        }
    }
    return 0
}

proc ::RB2Bolt::runFindUnusedShellRBE2 {} {
    variable P

    msg [::HWFlow::txt "开始检测未用 Shell RBE2。" "Started finding unused shell RBE2 elements."]
    set elemIds [selectedElementIdsInteractive]
    if {[llength $elemIds] == 0} {
        ::RB2Bolt::clearSelectionMarks
        tk_messageBox -icon warning -title [::HWFlow::txt "检测未用 Shell RBE2" "Find Unused Shell RBE2"] -message [::HWFlow::txt "选择范围内未找到 RBE2 候选单元。" "No RBE2 candidate elements were found in the selection scope."]
        return
    }

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "检测未用 Shell RBE2" "Find Unused Shell RBE2"] \
            [::HWFlow::txt "准备读取 RBE2 单元..." "Preparing to read RBE2 elements..."] \
            0]
    }

    set records [collectRBE2Records $elemIds]
    if {[llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 55.0 \
            [::HWFlow::txt "检测未用 Shell RBE2 正在执行" "Find Unused Shell RBE2 running"] \
            [::HWFlow::txt "正在建立分组..." "Building groups..."] \
            1}
    }

    set groups {}
    if {[llength $records] >= 2} {
        set groups [buildGroups $records]
    }
    set unused [::RB2Bolt::unusedShellRBE2Records $records $groups]
    set unusedEids [::RB2Bolt::rbe2ElementIdsFromRecords $unused]

    if {[llength $unused] == 0} {
        ::RB2Bolt::clearSelectionMarks
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "未发现未用 Shell RBE2。" "No unused shell RBE2 found."] 100.0}
        }
        tk_messageBox -icon info -title [::HWFlow::txt "检测未用 Shell RBE2" "Find Unused Shell RBE2"] -message [::HWFlow::txt "未发现没有被当前连接规则用上的 Shell RBE2。" "No shell RBE2 elements were left unused by the current connector rules."]
        return
    }

    if {[llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 80.0 \
            [::HWFlow::txt "检测未用 Shell RBE2 正在执行" "Find Unused Shell RBE2 running"] \
            [::HWFlow::txt "正在创建中心标记点..." "Creating center markers..."] \
            1}
    }

    set markerStat [::RB2Bolt::createUnusedShellRBE2Markers $unused]
    set enteredDelete [::RB2Bolt::enterElementDeleteMode $unusedEids]

    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "检测未用 Shell RBE2 已完成。" "Find Unused Shell RBE2 finished."] 100.0}
    }

    set txt [::HWFlow::txt \
        "检测未用 Shell RBE2 完成：候选 RBE2=[llength $elemIds]，有效记录=[llength $records]，未用 Shell RBE2=[llength $unused]，标记组件=[dict get $markerStat component]，点标记=[dict get $markerStat points]，节点标记=[dict get $markerStat nodes]，标记失败=[dict get $markerStat failed]。" \
        "Find unused shell RBE2 finished: candidate RBE2=[llength $elemIds], usable records=[llength $records], unused shell RBE2=[llength $unused], marker component=[dict get $markerStat component], point markers=[dict get $markerStat points], node markers=[dict get $markerStat nodes], marker failures=[dict get $markerStat failed]."]
    msg $txt

    if {!$enteredDelete} {
        tk_messageBox -icon warning -title [::HWFlow::txt "检测未用 Shell RBE2" "Find Unused Shell RBE2"] -message [::HWFlow::txt \
            "$txt\n\n已生成标记点，但当前 HyperMesh 未能自动进入 Delete 面板。未用 RBE2 单元已保留在元素 mark 1 / user mark 中，请手动打开 Delete 面板并取回选择。" \
            "$txt\n\nMarkers were created, but HyperMesh did not enter the Delete panel automatically. The unused RBE2 elements remain on element mark 1 / user mark; open the Delete panel manually and retrieve the selection."]
    }
}

# ------------------------- entry point -------------------------------------
proc ::RB2Bolt::runCreateFromSelection {} {
    variable P
    variable beamSegmentIndex

    msg [::HWFlow::txt "RBE2 Bolt Connector 开始。若需要 CBEAM 输出，请确认 BAR2 单元类型已设置为 CBEAM。" "RBE2 Bolt Connector started. Make sure BAR2 element type is set to CBEAM if CBEAM output is required."]

    set elemIds [selectedElementIdsInteractive]
    if {[llength $elemIds] == 0} {
        ::RB2Bolt::clearSelectionMarks
        tk_messageBox -icon warning -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "选择范围内未找到 RBE2 候选单元。" "No RBE2 candidate elements were found in the selection scope."]
        return
    }

    msg [::HWFlow::txt "RBE2 候选单元数：[llength $elemIds]" "RBE2 candidate elements: [llength $elemIds]"]
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] \
            [::HWFlow::txt "准备读取 RBE2 单元..." "Preparing to read RBE2 elements..."] \
            0]
    }
    set tRecords0 [clock milliseconds]
    set records [collectRBE2Records $elemIds]
    set tRecords1 [clock milliseconds]
    if {[llength $records] < 2} {
        ::RB2Bolt::clearSelectionMarks
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "可用 RBE2 记录不足。" "Not enough usable RBE2 records."] 100.0}
        }
        tk_messageBox -icon warning -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "选择集中可用 RBE2 单元少于 2 个。" "Fewer than 2 usable RBE2 elements were found in the selection."]
        return
    }

    msg [::HWFlow::txt "有效 RBE2 记录数：[llength $records]。正在建立分组..." "Valid RBE2 records: [llength $records]. Building groups..."]
    if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 45.0 \
            [::HWFlow::txt "RBE2 Bolt Connector 正在执行" "RBE2 Bolt Connector running"] \
            [::HWFlow::txt "正在建立分组..." "Building groups..."] \
            1}
    }
    set tGroups0 [clock milliseconds]
    set groups [buildGroups $records]
    set tGroups1 [clock milliseconds]
    if {[llength $groups] == 0} {
        ::RB2Bolt::clearSelectionMarks
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "没有匹配的 RBE2 分组。" "No matching RBE2 groups."] 100.0}
        }
        tk_messageBox -icon warning -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "没有 RBE2 分组满足当前容差。可尝试增大轴向连接距离或横向中心偏移容差。" "No RBE2 groups matched the tolerances. Try increasing the axial connection distance or transverse center offset tolerance."]
        return
    }

    catch {array unset beamSegmentIndex}
    array set beamSegmentIndex {}
    set result [createBoltsFast $groups]
    set created [lindex $result 0]
    set skipped [lindex $result 1]
    set spatialOnlyGroups [lindex $result 3]
    set skippedExisting [lindex $result 4]
    set recordsMs [expr {$tRecords1 - $tRecords0}]
    set groupsMs [expr {$tGroups1 - $tGroups0}]
    msg [::HWFlow::txt "RBE2 records 读取耗时：$recordsMs ms；groups 建立耗时：$groupsMs ms。" "RBE2 records read time: $recordsMs ms; groups build time: $groupsMs ms."]

    set txt [::HWFlow::txt "RBE2 Bolt Connector 已完成。\n\nRBE2 数量：[llength $records]\n分组数量：[llength $groups]\n已跳过的空间型 RBE2-only 分组：$spatialOnlyGroups\n已创建 $P(elemType)：$created\n已跳过既有 $P(elemType)：$skippedExisting\n跳过/失败：$skipped" "RBE2 Bolt Connector finished.\n\nRBE2 count: [llength $records]\nGroup count: [llength $groups]\nSpatial RBE2-only groups skipped: $spatialOnlyGroups\nCreated $P(elemType): $created\nSkipped existing $P(elemType): $skippedExisting\nSkipped/failed: $skipped"]
    ::RB2Bolt::clearSelectionMarks
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "RBE2 Bolt Connector 已完成。" "RBE2 Bolt Connector finished."] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message $txt
    msg $txt
}

proc ::RB2Bolt::runAction {} {
    ::RB2Bolt::loadState
    if {![validateParams]} {return}
    ::RB2Bolt::saveState
    ::RB2Bolt::runCreateFromSelection
}

proc ::RB2Bolt::runSettings {} {
    ::RB2Bolt::showDialog 1
}

proc ::RB2Bolt::run {} {
    variable P
    variable beamSegmentIndex
    set action [showDialog]
    if {$action eq ""} {
        msg [::HWFlow::txt "RBE2 Bolt Connector 已取消。" "RBE2 Bolt Connector cancelled."]
        return
    }
    if {![validateParams]} {return}
    ::RB2Bolt::saveState
    if {$action eq "findUnusedShellRBE2"} {
        ::RB2Bolt::runFindUnusedShellRBE2
        return
    }

    msg [::HWFlow::txt "RBE2 Bolt Connector 开始。若需要 CBEAM 输出，请确认 BAR2 单元类型已设置为 CBEAM。" "RBE2 Bolt Connector started. Make sure BAR2 element type is set to CBEAM if CBEAM output is required."]

    set elemIds [selectedElementIds]
    if {[llength $elemIds] == 0} {
        ::RB2Bolt::clearSelectionMarks
        tk_messageBox -icon warning -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "选择范围内未找到 RBE2 候选单元。" "No RBE2 candidate elements were found in the selection scope."]
        return
    }

    msg [::HWFlow::txt "RBE2 候选单元数：[llength $elemIds]" "RBE2 candidate elements: [llength $elemIds]"]
    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] \
            [::HWFlow::txt "准备读取 RBE2 单元..." "Preparing to read RBE2 elements..."] \
            0]
    }
    set tRecords0 [clock milliseconds]
    set records [collectRBE2Records $elemIds]
    set tRecords1 [clock milliseconds]
    if {[llength $records] < 2} {
        ::RB2Bolt::clearSelectionMarks
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "可用 RBE2 记录不足。" "Not enough usable RBE2 records."] 100.0}
        }
        tk_messageBox -icon warning -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "选择集中可用 RBE2 单元少于 2 个。" "Fewer than 2 usable RBE2 elements were found in the selection."]
        return
    }

    msg [::HWFlow::txt "有效 RBE2 记录数：[llength $records]。正在建立分组..." "Valid RBE2 records: [llength $records]. Building groups..."]
    if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 45.0 \
            [::HWFlow::txt "RBE2 Bolt Connector 正在执行" "RBE2 Bolt Connector running"] \
            [::HWFlow::txt "正在建立分组..." "Building groups..."] \
            1}
    }
    set tGroups0 [clock milliseconds]
    set groups [buildGroups $records]
    set tGroups1 [clock milliseconds]
    if {[llength $groups] == 0} {
        ::RB2Bolt::clearSelectionMarks
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "没有匹配的 RBE2 分组。" "No matching RBE2 groups."] 100.0}
        }
        tk_messageBox -icon warning -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message [::HWFlow::txt "没有 RBE2 分组满足当前容差。可尝试增大轴向连接距离或横向中心偏移容差。" "No RBE2 groups matched the tolerances. Try increasing the axial connection distance or transverse center offset tolerance."]
        return
    }

    catch {array unset beamSegmentIndex}
    array set beamSegmentIndex {}
    set result [createBoltsFast $groups]
    set created [lindex $result 0]
    set skipped [lindex $result 1]
    set spatialOnlyGroups [lindex $result 3]
    set skippedExisting [lindex $result 4]
    set recordsMs [expr {$tRecords1 - $tRecords0}]
    set groupsMs [expr {$tGroups1 - $tGroups0}]
    msg [::HWFlow::txt "RBE2 records 读取耗时：$recordsMs ms；groups 建立耗时：$groupsMs ms。" "RBE2 records read time: $recordsMs ms; groups build time: $groupsMs ms."]

    set txt [::HWFlow::txt "RBE2 Bolt Connector 已完成。\n\nRBE2 数量：[llength $records]\n分组数量：[llength $groups]\n已跳过的空间型 RBE2-only 分组：$spatialOnlyGroups\n已创建 $P(elemType)：$created\n已跳过既有 $P(elemType)：$skippedExisting\n跳过/失败：$skipped" "RBE2 Bolt Connector finished.\n\nRBE2 count: [llength $records]\nGroup count: [llength $groups]\nSpatial RBE2-only groups skipped: $spatialOnlyGroups\nCreated $P(elemType): $created\nSkipped existing $P(elemType): $skippedExisting\nSkipped/failed: $skipped"]
    ::RB2Bolt::clearSelectionMarks
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "RBE2 Bolt Connector 已完成。" "RBE2 Bolt Connector finished."] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "RBE2 Bolt Connector" "RBE2 Bolt Connector"] -message $txt
    msg $txt
}
