# ============================================================================
# Mesh Seam Weld
# HyperMesh 2019 Tcl/Tk
#
# Imprints a selected source node path to target mesh components, then creates
# a ruled weld surface between the source path and imprinted target path and
# stores the automesh result as weld shell elements.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::MeshSeamWeld {
    variable VERSION "0.1"

    variable cfg
    array set cfg {
        output_component       MESH_SEAM_WELD
        weld_mesh_size         15
        patch_expand_layers    2
        imprint_remain         3
        imprint_remesh_mode    2
        imprint_angle          30.0
        mesh_face_shape        1
        mesh_elem_type         2
        mesh_smooth_method     1
        mesh_smooth_tol        0.5
        mesh_size_control      1
        mesh_skew_control      1
        mesh_path_param        1
        mesh_cross_param       1
        mesh_cross_size        0
    }

    variable ui
    array set ui {}
}

proc ::MeshSeamWeld::stateKeys {} {
    return {
        output_component weld_mesh_size patch_expand_layers imprint_remain imprint_remesh_mode imprint_angle
        mesh_face_shape mesh_elem_type mesh_smooth_method mesh_smooth_tol
        mesh_size_control mesh_skew_control mesh_path_param
        mesh_cross_param mesh_cross_size
    }
}

proc ::MeshSeamWeld::uniq {items} {
    set out {}
    array set seen {}
    foreach item $items {
        if {$item eq "" || [info exists seen($item)]} {
            continue
        }
        set seen($item) 1
        lappend out $item
    }
    return $out
}

proc ::MeshSeamWeld::msg {text} {
    catch {hm_usermessage $text}
    catch {puts $text}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "MeshSeamWeld: $text"}
    }
    catch {update}
}

proc ::MeshSeamWeld::loadState {} {
    variable cfg
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray mesh_seam_weld ::MeshSeamWeld::cfg
    }
}

proc ::MeshSeamWeld::saveState {} {
    if {[llength [info commands ::HWFlow::saveArrayState]] > 0} {
        ::HWFlow::saveArrayState mesh_seam_weld ::MeshSeamWeld::cfg
    }
}

proc ::MeshSeamWeld::centerWindow {w} {
    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
}

proc ::MeshSeamWeld::showPanel {} {
    variable VERSION
    variable cfg
    variable ui

    ::MeshSeamWeld::loadState
    foreach key [::MeshSeamWeld::stateKeys] {
        set ui($key) $cfg($key)
    }

    catch {destroy .mesh_seam_weld}
    set w .mesh_seam_weld
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.param -text [::HWFlow::txt "参数" "Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    set fields {
        {output_component "未识别厚度时的输出组件" "Fallback output component"}
        {weld_mesh_size "焊缝网格尺寸" "Weld mesh size"}
        {patch_expand_layers "imprint 局部重绘扩展层数" "Imprint remesh layers"}
        {imprint_remain "imprint remain 参数" "Imprint remain option"}
        {imprint_remesh_mode "imprint remesh_mode 参数" "Imprint remesh_mode option"}
        {imprint_angle "imprint angle 参数" "Imprint angle option"}
        {mesh_face_shape "焊缝面 shape_type" "Weld face shape_type"}
        {mesh_elem_type "焊缝面 elem_type，2 为混合" "Weld face elem_type, 2 = mixed"}
        {mesh_cross_size "横向边参数" "Cross edge parameter"}
    }
    set row 0
    foreach item $fields {
        set key [lindex $item 0]
        label $w.main.param.l_$key -text [::HWFlow::txt [lindex $item 1] [lindex $item 2]] -anchor w
        entry $w.main.param.e_$key -textvariable ::MeshSeamWeld::ui($key) -width 24
        grid $w.main.param.l_$key -row $row -column 0 -sticky w -padx {0 8} -pady 2
        grid $w.main.param.e_$key -row $row -column 1 -sticky w -pady 2
        incr row
    }

    message $w.main.note -width 520 -text [::HWFlow::txt \
        "执行时先在 HyperMesh 面板选择焊缝源 node path，再选择目标 component。随后调用 imprint_nodelist 完成目标局部重绘，并用 ruled surface + automesh 生成焊缝网格。" \
        "When running, select the source node path first, then target components. The tool then uses imprint_nodelist for local target remesh and creates the weld mesh with ruled surface + automesh."]
    grid $w.main.note -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.close -text [::HWFlow::txt "关闭" "Close"] -width 10 -command "destroy .mesh_seam_weld"
    button $w.btn.save -text [::HWFlow::txt "保存" "Save"] -width 10 -command "::MeshSeamWeld::acceptPanel"
    pack $w.btn.close -side right -padx 4
    pack $w.btn.save -side right -padx 4

    bind $w <Escape> "destroy .mesh_seam_weld"
    wm protocol $w WM_DELETE_WINDOW "destroy .mesh_seam_weld"
    ::MeshSeamWeld::centerWindow $w
    tkwait window $w
}

proc ::MeshSeamWeld::acceptPanel {} {
    variable cfg
    variable ui

    if {[string trim $ui(output_component)] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "输出组件不能为空。" "Output component cannot be empty."]
        return
    }
    if {![string is double -strict $ui(weld_mesh_size)] || $ui(weld_mesh_size) <= 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "焊缝网格尺寸必须为正数。" "Weld mesh size must be positive."]
        return
    }
    if {![string is integer -strict $ui(patch_expand_layers)] || $ui(patch_expand_layers) < 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "扩展层数必须为非负整数。" "Expansion layers must be a non-negative integer."]
        return
    }
    if {![string is double -strict $ui(imprint_angle)] || $ui(imprint_angle) < 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "imprint angle 必须为非负数值。" "imprint angle must be non-negative."]
        return
    }
    if {![string is double -strict $ui(mesh_smooth_tol)] || $ui(mesh_smooth_tol) <= 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "mesh_smooth_tol 必须为正数。" "mesh_smooth_tol must be positive."]
        return
    }
    foreach key {imprint_remain imprint_remesh_mode mesh_face_shape mesh_elem_type mesh_smooth_method mesh_size_control mesh_skew_control mesh_path_param mesh_cross_param mesh_cross_size} {
        if {![string is integer -strict $ui($key)] || $ui($key) < 0} {
            tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "$key 必须为非负整数。" "$key must be a non-negative integer."]
            return
        }
    }

    foreach key [::MeshSeamWeld::stateKeys] {
        set cfg($key) $ui($key)
    }
    ::MeshSeamWeld::saveState
    catch {destroy .mesh_seam_weld}
}

proc ::MeshSeamWeld::runSettings {} {
    ::MeshSeamWeld::showPanel
}

proc ::MeshSeamWeld::pickNodes {} {
    catch {*clearmark nodes 1}
    set prompt [::HWFlow::txt "选择焊缝源 node path" "Select weld source node path"]
    set opened 0
    foreach cmd [list \
        [list *createlistpanel nodes 1 $prompt "node path"] \
        [list *createlistpanel nodes 1 $prompt] \
        [list *createmarkpanel nodes 1 $prompt "node path"] \
        [list *createmarkpanel nodes 1 $prompt "by path"] \
        [list *createmarkpanel nodes 1 $prompt]] {
        if {![catch {uplevel #0 $cmd}]} {
            set opened 1
            break
        }
    }
    if {!$opened} {
        error [::HWFlow::txt "无法打开 node path 选择面板。" "Could not open the node path selection panel."]
    }
    set nodes {}
    catch {set nodes [hm_getlist nodes 1]}
    if {[llength $nodes] == 0} {
        catch {set nodes [hm_getmark nodes 1]}
    }
    catch {*clearmark nodes 1}
    return [::MeshSeamWeld::uniq $nodes]
}

proc ::MeshSeamWeld::pickComponents {} {
    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "选择要投影到的目标网格组件" "Select target mesh components for projection"]
    set comps {}
    catch {set comps [hm_getmark comps 1]}
    catch {*clearmark comps 1}
    catch {*clearmark components 1}
    return [::MeshSeamWeld::uniq $comps]
}

proc ::MeshSeamWeld::nodeXYZ {nodeId} {
    if {![catch {hm_getvalue nodes id=$nodeId dataname=x} x] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=y} y] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=z} z]} {
        return [list $x $y $z]
    }
    if {![catch {hm_nodevalue $nodeId} val] && [llength $val] >= 3} {
        return [lrange $val 0 2]
    }
    error [::HWFlow::txt "无法读取节点 $nodeId 坐标。" "Cannot read coordinates for node $nodeId."]
}

proc ::MeshSeamWeld::elemNodes {elemId} {
    if {![catch {hm_getvalue elems id=$elemId dataname=nodes} nodes] && [llength $nodes] > 0} {
        return [::MeshSeamWeld::uniq $nodes]
    }
    if {![catch {hm_nodelist $elemId} nodes] && [llength $nodes] > 0} {
        return [::MeshSeamWeld::uniq $nodes]
    }
    return {}
}

proc ::MeshSeamWeld::elemsByComponents {compIds} {
    set out {}
    foreach compId $compIds {
        if {[llength [info commands ::HWFlow::getCompEntityIds]] > 0} {
            set elems [::HWFlow::getCompEntityIds $compId elems elems]
        } else {
            set elems {}
            catch {*clearmark elems 2}
            if {![catch {*createmark elems 2 "by comp id" $compId}]} {
                catch {set elems [hm_getmark elems 2]}
            }
            catch {*clearmark elems 2}
        }
        foreach elemId $elems {
            set nodes [::MeshSeamWeld::elemNodes $elemId]
            if {[llength $nodes] >= 3} {
                lappend out $elemId
            }
        }
    }
    return [::MeshSeamWeld::uniq $out]
}

proc ::MeshSeamWeld::elemComponentId {elemId} {
    foreach dn {component.id collector.id comp.id component collector} {
        if {![catch {set value [hm_getvalue elems id=$elemId dataname=$dn]}] && $value ne "" && $value != 0} {
            if {[string is integer -strict $value]} {
                return $value
            }
            set compId [::HWFlow::componentIdByName $value]
            if {$compId ne ""} {
                return $compId
            }
        }
    }
    return ""
}

proc ::MeshSeamWeld::nodeElementIds {nodeId} {
    foreach dn {elems elements} {
        if {![catch {set elems [hm_getvalue nodes id=$nodeId dataname=$dn]}] && [llength $elems] > 0} {
            return [::MeshSeamWeld::uniq $elems]
        }
    }

    set out {}
    foreach selector [list \
        [list "by node id" $nodeId] \
        [list "by node" $nodeId] \
        [list "by nodes" $nodeId]] {
        catch {*clearmark elems 2}
        if {![catch {eval *createmark elems 2 $selector}]} {
            catch {set out [hm_getmark elems 2]}
            if {[llength $out] > 0} {
                catch {*clearmark elems 2}
                return [::MeshSeamWeld::uniq $out]
            }
        }
        catch {*clearmark elems 2}
    }
    return {}
}

proc ::MeshSeamWeld::componentIdsFromNodes {nodeIds} {
    set out {}
    foreach nodeId $nodeIds {
        foreach elemId [::MeshSeamWeld::nodeElementIds $nodeId] {
            set compId [::MeshSeamWeld::elemComponentId $elemId]
            if {$compId ne ""} {
                lappend out $compId
            }
        }
    }
    return [::MeshSeamWeld::uniq $out]
}

proc ::MeshSeamWeld::componentNames {compIds} {
    set names {}
    foreach compId [::MeshSeamWeld::uniq $compIds] {
        if {$compId eq ""} {
            continue
        }
        lappend names [::HWFlow::componentName $compId]
    }
    return [::MeshSeamWeld::uniq $names]
}

proc ::MeshSeamWeld::thicknessFromComponentName {name} {
    if {[regexp -nocase {(^|_)T([0-9]+(\.[0-9]+)?)(_|$)} $name -> _ thicknessText]} {
        if {[string is double -strict $thicknessText] && $thicknessText > 0} {
            return [expr {double($thicknessText)}]
        }
    }
    return ""
}

proc ::MeshSeamWeld::formatThickness {thickness} {
    set text [format "%.6g" $thickness]
    regsub {\.0+$} $text "" text
    regsub {(\.[0-9]*?)0+$} $text {\1} text
    return $text
}

proc ::MeshSeamWeld::seamComponentForRelatedComps {relatedCompIds} {
    variable cfg

    set minThickness ""
    foreach name [::MeshSeamWeld::componentNames $relatedCompIds] {
        set thickness [::MeshSeamWeld::thicknessFromComponentName $name]
        if {$thickness eq ""} {
            continue
        }
        if {$minThickness eq "" || $thickness < $minThickness} {
            set minThickness $thickness
        }
    }

    if {$minThickness eq ""} {
        return [string trim $cfg(output_component)]
    }
    return "SEAM_T[::MeshSeamWeld::formatThickness $minThickness]"
}

proc ::MeshSeamWeld::moveElemsToComponent {elemIds compName} {
    set elemIds [::MeshSeamWeld::uniq $elemIds]
    if {[llength $elemIds] == 0 || [string trim $compName] eq ""} {
        return 0
    }
    ::HWFlow::createComponent $compName 11
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elemIds}]} {
        return 0
    }
    set ok [expr {![catch {*movemark elems 1 $compName}]}]
    catch {*clearmark elems 1}
    return $ok
}

proc ::MeshSeamWeld::vsub {a b} {
    return [list [expr {[lindex $a 0] - [lindex $b 0]}] [expr {[lindex $a 1] - [lindex $b 1]}] [expr {[lindex $a 2] - [lindex $b 2]}]]
}

proc ::MeshSeamWeld::vadd {a b} {
    return [list [expr {[lindex $a 0] + [lindex $b 0]}] [expr {[lindex $a 1] + [lindex $b 1]}] [expr {[lindex $a 2] + [lindex $b 2]}]]
}

proc ::MeshSeamWeld::vscale {a s} {
    return [list [expr {[lindex $a 0] * $s}] [expr {[lindex $a 1] * $s}] [expr {[lindex $a 2] * $s}]]
}

proc ::MeshSeamWeld::dot {a b} {
    expr {[lindex $a 0]*[lindex $b 0] + [lindex $a 1]*[lindex $b 1] + [lindex $a 2]*[lindex $b 2]}
}

proc ::MeshSeamWeld::dist2 {a b} {
    set d [::MeshSeamWeld::vsub $a $b]
    return [::MeshSeamWeld::dot $d $d]
}

proc ::MeshSeamWeld::entityIdsCreatedAfter {entityType beforeId} {
    if {$beforeId eq ""} {
        error [::HWFlow::txt \
            "无法读取操作前的实体 ID，不能可靠识别新建实体。" \
            "Could not read the pre-operation entity ID; new entities cannot be identified reliably."]
    }
    set afterId ""
    catch {set afterId [hm_latestentityid $entityType]}
    if {$afterId eq "" || $afterId == 0} {
        return {}
    }

    set out {}
    for {set id [expr {$beforeId + 1}]} {$id <= $afterId} {incr id} {
        if {$entityType eq "nodes"} {
            if {![catch {::MeshSeamWeld::nodeXYZ $id}]} {
                lappend out $id
            }
        } elseif {$entityType eq "elems"} {
            if {[llength [::MeshSeamWeld::elemNodes $id]] > 0} {
                lappend out $id
            }
        }
    }
    return $out
}

proc ::MeshSeamWeld::markComponents {compIds markId} {
    catch {*clearmark comps $markId}
    catch {*clearmark components $markId}
    if {[llength $compIds] == 0} {
        return 0
    }
    if {![catch {eval *createmark components $markId $compIds}]} {
        return 1
    }
    if {![catch {eval *createmark comps $markId $compIds}]} {
        return 1
    }
    return 0
}

proc ::MeshSeamWeld::runImprintNodeList {sourceNodes targetComps} {
    variable cfg

    if {![::MeshSeamWeld::markComponents $targetComps 2]} {
        error [::HWFlow::txt "无法标记目标组件。" "Could not mark target components."]
    }
    if {[catch {eval *createlist nodes 1 $sourceNodes} err]} {
        error [::HWFlow::txt "无法创建源节点列表：$err" "Could not create source node list: $err"]
    }

    set options [format "remain %s to_dest_component 0 remesh_layers %s remesh_mode %s angle %.6f create_joint_elems 0" \
        $cfg(imprint_remain) $cfg(patch_expand_layers) $cfg(imprint_remesh_mode) $cfg(imprint_angle)]

    set lastErr ""
    foreach entityType {components comps} {
        if {![catch {*imprint_nodelist 1 $entityType 2 $options} err]} {
            return 1
        }
        set lastErr $err
    }
    error [::HWFlow::txt "imprint_nodelist 执行失败：$lastErr" "imprint_nodelist failed: $lastErr"]
}

proc ::MeshSeamWeld::nodesList2FromImprint {sourceNodes newNodes} {
    set list2 {}
    catch {set list2 [hm_getlist nodes 2]}
    if {[llength $list2] != [llength $sourceNodes]} {
        return {}
    }

    array set isNew {}
    foreach nodeId $newNodes {
        set isNew($nodeId) 1
    }
    foreach nodeId $list2 {
        if {![info exists isNew($nodeId)]} {
            return {}
        }
    }
    return [::MeshSeamWeld::uniq $list2]
}

proc ::MeshSeamWeld::matchTargetPathNodes {sourceNodes candidateNodes} {
    set candidateNodes [::MeshSeamWeld::uniq $candidateNodes]
    if {[llength $candidateNodes] < [llength $sourceNodes]} {
        error [::HWFlow::txt \
            "imprint 后新增节点数量不足，无法形成目标 node path。" \
            "Not enough nodes were created by imprint to form the target node path."]
    }

    set targetNodes {}
    array set used {}
    foreach sourceNode $sourceNodes {
        set sourcePoint [::MeshSeamWeld::nodeXYZ $sourceNode]
        set bestNode ""
        set bestD2 ""
        foreach candidate $candidateNodes {
            if {[info exists used($candidate)]} {
                continue
            }
            set d2 [::MeshSeamWeld::dist2 $sourcePoint [::MeshSeamWeld::nodeXYZ $candidate]]
            if {$bestNode eq "" || $d2 < $bestD2} {
                set bestNode $candidate
                set bestD2 $d2
            }
        }
        if {$bestNode eq ""} {
            error [::HWFlow::txt "无法匹配目标 node path。" "Could not match the target node path."]
        }
        set used($bestNode) 1
        lappend targetNodes $bestNode
    }
    return $targetNodes
}

proc ::MeshSeamWeld::targetPathNodesAfterImprint {sourceNodes imprintNodes} {
    set list2Nodes [::MeshSeamWeld::nodesList2FromImprint $sourceNodes $imprintNodes]
    if {[llength $list2Nodes] > 0} {
        return $list2Nodes
    }
    return [::MeshSeamWeld::matchTargetPathNodes $sourceNodes $imprintNodes]
}

proc ::MeshSeamWeld::createRuledMeshBetweenNodePaths {sourceNodes targetNodes outputCompName} {
    variable cfg

    if {[llength $sourceNodes] != [llength $targetNodes]} {
        error [::HWFlow::txt "源 node path 与目标 node path 数量不一致。" "Source and target node path counts do not match."]
    }

    if {[string trim $outputCompName] eq ""} {
        set outputCompName $cfg(output_component)
    }
    ::HWFlow::createComponent $outputCompName 11
    catch {*currentcollector component $outputCompName}
    catch {*currentcollector components $outputCompName}

    set beforeElem ""
    catch {set beforeElem [hm_latestentityid elems]}
    set historyStarted 0
    set code [catch {
        catch {*surfacemode 1}
        *startnotehistorystate {Create ruled surface and mesh}
        set historyStarted 1

        eval *createlist nodes 1 $sourceNodes
        eval *createlist nodes 2 $targetNodes
        *linearsurfacebetweennodes 1 2 1

        *set_meshfaceparams 0 $cfg(mesh_face_shape) $cfg(mesh_elem_type) 0 0 $cfg(mesh_smooth_method) $cfg(mesh_smooth_tol) $cfg(mesh_size_control) $cfg(mesh_skew_control)
        *set_meshedgeparams 0 $cfg(mesh_path_param) $cfg(weld_mesh_size) 0 0 0 0 0 0 0
        *set_meshedgeparams 1 $cfg(mesh_cross_param) $cfg(mesh_cross_size) 0 0 0 0 0 0 0
        *set_meshedgeparams 2 $cfg(mesh_path_param) $cfg(weld_mesh_size) 0 0 0 0 0 0 0
        *set_meshedgeparams 3 $cfg(mesh_cross_param) $cfg(mesh_cross_size) 0 0 0 0 0 0 0
        *automesh 0 1 2
        *storemeshtodatabase 0
    } err]

    if {$code} {
        catch {*rejectmesh 0}
        catch {*ameshclearsurface}
        if {$historyStarted} {
            catch {*endnotehistorystate {Create ruled surface and mesh}}
        }
        error [::HWFlow::txt "创建 ruled 焊缝网格失败：$err" "Failed to create ruled weld mesh: $err"]
    }

    catch {*ameshclearsurface}
    if {$historyStarted} {
        catch {*endnotehistorystate {Create ruled surface and mesh}}
    }
    set elemIds [::MeshSeamWeld::entityIdsCreatedAfter elems $beforeElem]
    ::MeshSeamWeld::moveElemsToComponent $elemIds $outputCompName
    return $elemIds
}

proc ::MeshSeamWeld::runAction {} {
    variable cfg
    ::MeshSeamWeld::loadState

    set sourceNodes [::MeshSeamWeld::pickNodes]
    if {[llength $sourceNodes] < 2} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "至少需要选择 2 个源节点。" "Select at least 2 source nodes."]
        return
    }

    set targetComps [::MeshSeamWeld::pickComponents]
    if {[llength $targetComps] == 0} {
        return
    }
    set targetElems [::MeshSeamWeld::elemsByComponents $targetComps]
    if {[llength $targetElems] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "目标组件中没有可用壳网格单元。" "Target components contain no usable shell elements."]
        return
    }

    set code [catch {
        set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]
        set relatedCompIds [::MeshSeamWeld::uniq [concat $sourceCompIds $targetComps]]
        set seamCompName [::MeshSeamWeld::seamComponentForRelatedComps $relatedCompIds]
        set beforeNode ""
        catch {set beforeNode [hm_latestentityid nodes]}
        ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps
        set imprintNodes [::MeshSeamWeld::entityIdsCreatedAfter nodes $beforeNode]
        set targetNodes [::MeshSeamWeld::targetPathNodesAfterImprint $sourceNodes $imprintNodes]
        set weldElems [::MeshSeamWeld::createRuledMeshBetweenNodePaths $sourceNodes $targetNodes $seamCompName]
        if {[llength $weldElems] == 0} {
            error [::HWFlow::txt "automesh 未生成焊缝单元。" "automesh did not create weld elements."]
        }
    } err]

    if {$code} {
        tk_messageBox -icon error -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $err
        return
    }

    catch {::HWFlow::refreshBrowser}
    set msg [::HWFlow::txt \
        "网格焊缝完成。\n源节点：[llength $sourceNodes]\n源组件：[llength $sourceCompIds]\n目标组件：[llength $targetComps]\n焊缝组件：$seamCompName\n焊缝网格尺寸：$cfg(weld_mesh_size)\nimprint 新增节点：[llength $imprintNodes]\n目标路径节点：[llength $targetNodes]\n新建焊缝单元：[llength $weldElems]" \
        "Mesh seam weld finished.\nSource nodes: [llength $sourceNodes]\nSource components: [llength $sourceCompIds]\nTarget components: [llength $targetComps]\nWeld component: $seamCompName\nWeld mesh size: $cfg(weld_mesh_size)\nImprint-created nodes: [llength $imprintNodes]\nTarget path nodes: [llength $targetNodes]\nNew weld elements: [llength $weldElems]"]
    tk_messageBox -icon info -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $msg
}

proc ::MeshSeamWeld::run {} {
    ::MeshSeamWeld::runAction
}
