# ============================================================================
# Mesh Seam Weld
# HyperMesh 2019 Tcl/Tk
#
# Imprints a selected source node path to target mesh components, then creates
# a ruled weld region between the source path and imprinted target path and
# stores the automesh result as weld shell elements.  Geometry surface creation
# is optional and disabled by default.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::MeshSeamWeld {
    variable VERSION "0.6"

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
        create_geometry_surf   0
    }

    variable ui
    array set ui {}

    # Per-run caches.  Large node paths previously repeated the same database
    # queries for element connectivity, node adjacency, and coordinates.
    variable elemNodesCache
    variable nodeElemsCache
    variable elemComponentCache
    variable nodeFreeEdgeNeighborsCache
    variable nodeXYZCache
    array set elemNodesCache {}
    array set nodeElemsCache {}
    array set elemComponentCache {}
    array set nodeFreeEdgeNeighborsCache {}
    array set nodeXYZCache {}
}

proc ::MeshSeamWeld::stateKeys {} {
    return {
        output_component weld_mesh_size patch_expand_layers imprint_remain imprint_remesh_mode imprint_angle
        mesh_face_shape mesh_elem_type mesh_smooth_method mesh_smooth_tol
        mesh_size_control mesh_skew_control mesh_path_param
        mesh_cross_param mesh_cross_size create_geometry_surf
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
    button $w.btn.more -text [::HWFlow::txt "更多" "More"] -width 10 -command "::MeshSeamWeld::showMorePanel"
    button $w.btn.save -text [::HWFlow::txt "保存" "Save"] -width 10 -command "::MeshSeamWeld::acceptPanel"
    pack $w.btn.close -side right -padx 4
    pack $w.btn.save -side right -padx 4
    pack $w.btn.more -side right -padx 4

    bind $w <Escape> "destroy .mesh_seam_weld"
    wm protocol $w WM_DELETE_WINDOW "destroy .mesh_seam_weld"
    ::MeshSeamWeld::centerWindow $w
    tkwait window $w
}

proc ::MeshSeamWeld::showMorePanel {} {
    variable ui

    set w .mesh_seam_weld_more
    catch {destroy $w}
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "网格焊缝 - 更多" "Mesh Seam Weld - More"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    checkbutton $w.main.keep_surface \
        -text [::HWFlow::txt \
            "创建并保留焊缝几何 surface（默认关闭）" \
            "Create and keep weld geometry surface (off by default)"] \
        -variable ::MeshSeamWeld::ui(create_geometry_surf) \
        -onvalue 1 -offvalue 0
    pack $w.main.keep_surface -anchor w
    message $w.main.note -width 430 -text [::HWFlow::txt \
        "关闭时使用 Mesh, delete surface：会临时建立网格区域并在网格完成后删除，不向模型保留新的几何 surface。" \
        "When off, Mesh, delete surface uses a temporary mesh region and removes it after meshing, leaving no geometry surface in the model."]
    pack $w.main.note -anchor w -pady {8 0}

    frame $w.btn -padx 12 -pady {0 10}
    pack $w.btn -fill x
    button $w.btn.close -text [::HWFlow::txt "关闭" "Close"] -width 10 -command [list destroy $w]
    pack $w.btn.close -side right

    bind $w <Escape> [list destroy $w]
    wm protocol $w WM_DELETE_WINDOW [list destroy $w]
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
    foreach key {imprint_remain imprint_remesh_mode mesh_face_shape mesh_elem_type mesh_smooth_method mesh_size_control mesh_skew_control mesh_path_param mesh_cross_param mesh_cross_size create_geometry_surf} {
        if {![string is integer -strict $ui($key)] || $ui($key) < 0} {
            tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "$key 必须为非负整数。" "$key must be a non-negative integer."]
            return
        }
    }
    if {$ui(create_geometry_surf) != 0 && $ui(create_geometry_surf) != 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "创建几何 surface 只能为 0（关闭）或 1（开启）。" "Create geometry surface must be 0 (off) or 1 (on)."]
        return
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

proc ::MeshSeamWeld::resetRunCaches {} {
    foreach arrayName {
        elemNodesCache nodeElemsCache elemComponentCache
        nodeFreeEdgeNeighborsCache nodeXYZCache
    } {
        upvar #0 ::MeshSeamWeld::$arrayName cache
        catch {array unset cache}
        array set cache {}
    }
}

proc ::MeshSeamWeld::clearNodeSelection {} {
    # *clearmark does not clear the ordered node list used by the node-path
    # selector.  Clear both so a cancelled prior selection cannot be accepted
    # on the next entry to this module.
    foreach listId {1 2} {
        catch {*clearlist nodes $listId}
    }
    foreach markId {1 2} {
        catch {*clearmark nodes $markId}
    }
}

proc ::MeshSeamWeld::clearComponentSelection {} {
    foreach entityType {comps components} {
        foreach markId {1 2} {
            catch {*clearmark $entityType $markId}
        }
    }
}

proc ::MeshSeamWeld::clearTransientSelections {} {
    ::MeshSeamWeld::clearNodeSelection
    ::MeshSeamWeld::clearComponentSelection
}

proc ::MeshSeamWeld::pickNodes {} {
    ::MeshSeamWeld::clearNodeSelection
    set prompt [::HWFlow::txt "选择焊缝源 node path" "Select weld source node path"]
    # The dedicated panel is documented to open directly in the "by path"
    # collector.  Keep the generic list panel only as a compatibility fallback
    # for an older/custom HyperMesh installation where this command is absent.
    if {[catch {*createlistbypathpanel nodes 1 $prompt} pathErr]} {
        if {[catch {*createlistpanel nodes 1 $prompt} listErr]} {
            error [::HWFlow::txt \
                "无法打开 node path 选择面板：$pathErr；备用面板错误：$listErr" \
                "Could not open the node path selection panel: $pathErr; fallback error: $listErr"]
        }
    }
    set nodes {}
    catch {set nodes [hm_getlist nodes 1]}
    if {[llength $nodes] == 0} {
        catch {set nodes [hm_getmark nodes 1]}
    }
    ::MeshSeamWeld::clearNodeSelection
    return [::MeshSeamWeld::uniq $nodes]
}

proc ::MeshSeamWeld::pickComponents {} {
    ::MeshSeamWeld::clearComponentSelection
    *createmarkpanel comps 1 [::HWFlow::txt "选择要投影到的目标网格组件" "Select target mesh components for projection"]
    set comps {}
    catch {set comps [hm_getmark comps 1]}
    ::MeshSeamWeld::clearComponentSelection
    return [::MeshSeamWeld::uniq $comps]
}

proc ::MeshSeamWeld::nodeXYZ {nodeId} {
    variable nodeXYZCache
    if {[info exists nodeXYZCache($nodeId)]} {
        return $nodeXYZCache($nodeId)
    }
    if {![catch {hm_getvalue nodes id=$nodeId dataname=x} x] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=y} y] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=z} z]} {
        set nodeXYZCache($nodeId) [list $x $y $z]
        return $nodeXYZCache($nodeId)
    }
    if {![catch {hm_nodevalue $nodeId} val] && [llength $val] >= 3} {
        set nodeXYZCache($nodeId) [lrange $val 0 2]
        return $nodeXYZCache($nodeId)
    }
    error [::HWFlow::txt "无法读取节点 $nodeId 坐标。" "Cannot read coordinates for node $nodeId."]
}

proc ::MeshSeamWeld::elemNodes {elemId} {
    variable elemNodesCache
    if {[info exists elemNodesCache($elemId)]} {
        return $elemNodesCache($elemId)
    }
    if {![catch {hm_getvalue elems id=$elemId dataname=nodes} nodes] && [llength $nodes] > 0} {
        set elemNodesCache($elemId) [::MeshSeamWeld::uniq $nodes]
        return $elemNodesCache($elemId)
    }
    if {![catch {hm_nodelist $elemId} nodes] && [llength $nodes] > 0} {
        set elemNodesCache($elemId) [::MeshSeamWeld::uniq $nodes]
        return $elemNodesCache($elemId)
    }
    set elemNodesCache($elemId) {}
    return {}
}

proc ::MeshSeamWeld::componentsHaveElements {compIds} {
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
        if {[llength $elems] > 0} {
            return 1
        }
    }
    return 0
}

proc ::MeshSeamWeld::elemComponentId {elemId} {
    variable elemComponentCache
    if {[info exists elemComponentCache($elemId)]} {
        return $elemComponentCache($elemId)
    }
    foreach dn {component.id collector.id comp.id component collector} {
        if {![catch {set value [hm_getvalue elems id=$elemId dataname=$dn]}] && $value ne "" && $value != 0} {
            if {[string is integer -strict $value]} {
                set elemComponentCache($elemId) $value
                return $elemComponentCache($elemId)
            }
            set compId [::HWFlow::componentIdByName $value]
            if {$compId ne ""} {
                set elemComponentCache($elemId) $compId
                return $elemComponentCache($elemId)
            }
        }
    }
    set elemComponentCache($elemId) ""
    return ""
}

proc ::MeshSeamWeld::nodeElementIds {nodeId} {
    variable nodeElemsCache
    if {[info exists nodeElemsCache($nodeId)]} {
        return $nodeElemsCache($nodeId)
    }
    foreach dn {elems elements} {
        if {![catch {set elems [hm_getvalue nodes id=$nodeId dataname=$dn]}] && [llength $elems] > 0} {
            set nodeElemsCache($nodeId) [::MeshSeamWeld::uniq $elems]
            return $nodeElemsCache($nodeId)
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
                set nodeElemsCache($nodeId) [::MeshSeamWeld::uniq $out]
                return $nodeElemsCache($nodeId)
            }
        }
        catch {*clearmark elems 2}
    }
    set nodeElemsCache($nodeId) {}
    return {}
}

proc ::MeshSeamWeld::elementContainsEdge {elemId a b} {
    set nodes [::MeshSeamWeld::elemNodes $elemId]
    set count [llength $nodes]
    if {$count < 3} {
        return 0
    }
    for {set i 0} {$i < $count} {incr i} {
        set n1 [lindex $nodes $i]
        set n2 [lindex $nodes [expr {($i + 1) % $count}]]
        if {($n1 == $a && $n2 == $b) || ($n1 == $b && $n2 == $a)} {
            return 1
        }
    }
    return 0
}

proc ::MeshSeamWeld::freeEdgeNeighbors {nodeId} {
    variable nodeFreeEdgeNeighborsCache
    if {[info exists nodeFreeEdgeNeighborsCache($nodeId)]} {
        return $nodeFreeEdgeNeighborsCache($nodeId)
    }

    # Inspect only the one-ring of this node.  This avoids constructing a
    # full-model edge graph when the user supplies one seed node.
    array set candidates {}
    set ownerElems [::MeshSeamWeld::nodeElementIds $nodeId]
    foreach elemId $ownerElems {
        set nodes [::MeshSeamWeld::elemNodes $elemId]
        set count [llength $nodes]
        if {$count < 3} {
            continue
        }
        for {set i 0} {$i < $count} {incr i} {
            set n1 [lindex $nodes $i]
            set n2 [lindex $nodes [expr {($i + 1) % $count}]]
            if {$n1 == $nodeId && $n2 != $nodeId} {
                set candidates($n2) 1
            } elseif {$n2 == $nodeId && $n1 != $nodeId} {
                set candidates($n1) 1
            }
        }
    }

    set neighbors {}
    foreach neighbor [array names candidates] {
        set owners {}
        foreach elemId $ownerElems {
            if {[::MeshSeamWeld::elementContainsEdge $elemId $nodeId $neighbor]} {
                lappend owners $elemId
            }
        }
        if {[llength [::MeshSeamWeld::uniq $owners]] == 1} {
            lappend neighbors $neighbor
        }
    }
    set nodeFreeEdgeNeighborsCache($nodeId) [lsort -integer -unique $neighbors]
    return $nodeFreeEdgeNeighborsCache($nodeId)
}

proc ::MeshSeamWeld::closedFreeEdgeLoopFromNode {seedNode} {
    set firstNeighbors [::MeshSeamWeld::freeEdgeNeighbors $seedNode]
    if {[llength $firstNeighbors] != 2} {
        error [::HWFlow::txt \
            "节点 $seedNode 不位于唯一的闭合自由边上（该节点检测到 [llength $firstNeighbors] 条自由边）。请选择同一闭环上的两个或更多节点。" \
            "Node $seedNode is not on one closed free-edge loop ([llength $firstNeighbors] free edges found at the node). Select two or more nodes on the same loop."]
    }

    set loop [list $seedNode]
    array set visited [list $seedNode 1]
    set previous $seedNode
    set current [lindex $firstNeighbors 0]
    set limit 100000
    while {1} {
        if {$current == $seedNode} {
            break
        }
        if {[info exists visited($current)]} {
            error [::HWFlow::txt \
                "自由边路径在回到起始节点前发生自交，不能自动创建焊缝。请选择两个或更多节点。" \
                "The free-edge path self-intersects before returning to its start node; select two or more nodes."]
        }
        if {[llength $loop] >= $limit} {
            error [::HWFlow::txt \
                "自由边路径过长，已停止自动闭环检测。请选择两个或更多节点。" \
                "The free-edge path is too long; select two or more nodes."]
        }
        set visited($current) 1
        lappend loop $current
        set neighbors [::MeshSeamWeld::freeEdgeNeighbors $current]
        if {[llength $neighbors] != 2} {
            error [::HWFlow::txt \
                "自由边在节点 $current 处不是闭合流形路径，不能自动创建焊缝。请选择两个或更多节点。" \
                "The free edge is not a closed manifold path at node $current; select two or more nodes."]
        }
        set next ""
        foreach neighbor $neighbors {
            if {$neighbor != $previous} {
                set next $neighbor
                break
            }
        }
        if {$next eq ""} {
            error [::HWFlow::txt \
                "无法继续追踪节点 $current 处的自由边。请选择两个或更多节点。" \
                "Cannot continue tracing the free edge at node $current; select two or more nodes."]
        }
        set previous $current
        set current $next
    }
    if {[llength $loop] < 3} {
        error [::HWFlow::txt \
            "检测到的自由边闭环节点数不足 3。请选择两个或更多节点。" \
            "The detected free-edge loop has fewer than three nodes; select two or more nodes."]
    }
    return $loop
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
    ::MeshSeamWeld::ensureOutputComponent $compName 11
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elemIds}]} {
        return 0
    }
    set ok [expr {![catch {*movemark elems 1 $compName}]}]
    catch {*clearmark elems 1}
    return $ok
}

proc ::MeshSeamWeld::ensureOutputComponent {compName {color 11}} {
    set compName [string trim $compName]
    if {$compName eq ""} {
        error [::HWFlow::txt "焊缝输出组件名称不能为空。" "The weld output component name cannot be empty."]
    }

    set compId [::HWFlow::componentIdByName $compName]
    if {$compId eq ""} {
        # Do not call ::HWFlow::createComponent here.  Its Browser creation
        # route is useful for interactive tools, but opens the unwanted
        # Create Component dialog for every new weld output component.
        set createCode [catch {*createentity comps includeid=0 name=$compName} err1]
        if {$createCode} {
            set createCode [catch {*createentity components includeid=0 name=$compName} err1]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly comps $compName "" $color} err2]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly components $compName "" $color} err2]
        }
        if {$createCode} {
            error [::HWFlow::txt \
                "无法静默创建焊缝输出组件 $compName：$err1 / $err2" \
                "Cannot create weld output component $compName without UI: $err1 / $err2"]
        }
        set compId [::HWFlow::componentIdByName $compName]
    }

    if {$compId ne "" && $color ne ""} {
        foreach entityType {comps components} {
            catch {*setvalue $entityType id=$compId color=$color}
        }
    }
    catch {*currentcollector component $compName}
    catch {*currentcollector components $compName}
    return $compId
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

proc ::MeshSeamWeld::runImprintNodeList {sourceNodes targetComps {closeNodeList 0}} {
    variable cfg

    # list 2 is the fast path for receiving the imprinted target nodes.  Clear
    # it first so an unsupported runtime cannot accidentally reuse a prior run.
    catch {*clearlist nodes 2}
    if {![::MeshSeamWeld::markComponents $targetComps 2]} {
        error [::HWFlow::txt "无法标记目标组件。" "Could not mark target components."]
    }
    if {[catch {eval *createlist nodes 1 $sourceNodes} err]} {
        error [::HWFlow::txt "无法创建源节点列表：$err" "Could not create source node list: $err"]
    }

    set options [format "remain %s to_dest_component 0 remesh_layers %s remesh_mode %s angle %.6f create_joint_elems 0 close_node_list %d" \
        $cfg(imprint_remain) $cfg(patch_expand_layers) $cfg(imprint_remesh_mode) $cfg(imprint_angle) $closeNodeList]

    set lastErr ""
    foreach entityType {components comps} {
        if {![catch {*imprint_nodelist 1 $entityType 2 $options} err]} {
            return 1
        }
        set lastErr $err
    }
    error [::HWFlow::txt "imprint_nodelist 执行失败：$lastErr" "imprint_nodelist failed: $lastErr"]
}

proc ::MeshSeamWeld::targetNodesFromImprintList {sourceNodes beforeNode} {
    set list2 {}
    catch {set list2 [hm_getlist nodes 2]}
    if {[llength $list2] != [llength $sourceNodes]} {
        return {}
    }
    set list2 [::MeshSeamWeld::uniq $list2]
    if {[llength $list2] != [llength $sourceNodes]} {
        return {}
    }
    # Retain the former safety condition: list 2 is trusted only when it is
    # made of nodes created by this imprint, never nodes left by an earlier UI
    # operation or source nodes reused by an unsupported runtime.
    if {$beforeNode ne ""} {
        foreach nodeId $list2 {
            if {![string is integer -strict $nodeId] || $nodeId <= $beforeNode} {
                return {}
            }
        }
    }
    return $list2
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
    return [::MeshSeamWeld::matchTargetPathNodes $sourceNodes $imprintNodes]
}

proc ::MeshSeamWeld::createRuledMeshBetweenNodePaths {sourceNodes targetNodes outputCompName {closedLoop 0}} {
    variable cfg

    if {[llength $sourceNodes] != [llength $targetNodes]} {
        error [::HWFlow::txt "源 node path 与目标 node path 数量不一致。" "Source and target node path counts do not match."]
    }

    if {[string trim $outputCompName] eq ""} {
        set outputCompName $cfg(output_component)
    }
    ::MeshSeamWeld::ensureOutputComponent $outputCompName 11

    set beforeElem ""
    catch {set beforeElem [hm_latestentityid elems]}
    # HyperMesh 2019 records show that ruled node-list creation followed by
    # *automesh can terminate the session in mode 3 (Mesh without surface).
    # Mode 2 uses a temporary ruled surface, deletes it after meshing, and
    # therefore preserves the default requirement: no geometry surface remains.
    set surfaceMode [expr {$cfg(create_geometry_surf) ? 1 : 2}]
    set historyStarted 0
    set code [catch {
        # 1 = mesh and keep surface; 2 = mesh and delete surface.
        *surfacemode $surfaceMode
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
    if {$closedLoop} {
        # A ruled node-list surface is open at its two list ends.  Closing the
        # imprint alone therefore leaves one weld cell missing.  Create the
        # final quad explicitly after accepting the automesh, using the same
        # ordered source/target end pairs as the rest of the strip.
        set closureNodes [list \
            [lindex $sourceNodes end] [lindex $sourceNodes 0] \
            [lindex $targetNodes 0] [lindex $targetNodes end]]
        if {[catch {
            eval *createlist nodes 1 $closureNodes
            *createelement 104 1 1 1
        } closureErr]} {
            if {$historyStarted} {
                catch {*endnotehistorystate {Create ruled surface and mesh}}
            }
            error [::HWFlow::txt \
                "闭环焊缝封口单元创建失败：$closureErr" \
                "Failed to create the closed-loop weld closure element: $closureErr"]
        }
    }
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
    ::MeshSeamWeld::resetRunCaches
    ::MeshSeamWeld::clearTransientSelections

    set sourceNodes [::MeshSeamWeld::pickNodes]
    if {[llength $sourceNodes] == 0} {
        return
    }
    set sourceSelectionMode "node path"
    set closedSourceLoop 0
    if {[llength $sourceNodes] == 1} {
        set seedNode [lindex $sourceNodes 0]
        set code [catch {
            set sourceNodes [::MeshSeamWeld::closedFreeEdgeLoopFromNode $seedNode]
        } err]
        if {$code} {
            tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $err
            return
        }
        set sourceSelectionMode "single-node closed free-edge loop"
        set closedSourceLoop 1
        ::MeshSeamWeld::msg [::HWFlow::txt \
            "单节点 $seedNode 已扩展为闭合自由边环，节点数：[llength $sourceNodes]。" \
            "Single node $seedNode expanded to a closed free-edge loop with [llength $sourceNodes] nodes."]
    }

    set targetComps [::MeshSeamWeld::pickComponents]
    if {[llength $targetComps] == 0} {
        return
    }
    if {![::MeshSeamWeld::componentsHaveElements $targetComps]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "目标组件中没有可用网格单元。" "Target components contain no usable mesh elements."]
        return
    }

    set code [catch {
        set sourceCompIds [::MeshSeamWeld::componentIdsFromNodes $sourceNodes]
        set relatedCompIds [::MeshSeamWeld::uniq [concat $sourceCompIds $targetComps]]
        set seamCompName [::MeshSeamWeld::seamComponentForRelatedComps $relatedCompIds]
        set beforeNode ""
        catch {set beforeNode [hm_latestentityid nodes]}
        ::MeshSeamWeld::runImprintNodeList $sourceNodes $targetComps $closedSourceLoop

        # In supported HyperMesh versions imprint returns the ordered target
        # path through list 2.  Reading that list bypasses a slow scan of every
        # node ID created since the operation.  Preserve the old ID-scan plus
        # coordinate matching as a safe fallback for installations where list 2
        # is not populated by imprint.
        set targetNodes [::MeshSeamWeld::targetNodesFromImprintList $sourceNodes $beforeNode]
        set imprintNodes $targetNodes
        if {[llength $targetNodes] == 0} {
            set imprintNodes [::MeshSeamWeld::entityIdsCreatedAfter nodes $beforeNode]
            set targetNodes [::MeshSeamWeld::targetPathNodesAfterImprint $sourceNodes $imprintNodes]
        }
        set weldElems [::MeshSeamWeld::createRuledMeshBetweenNodePaths $sourceNodes $targetNodes $seamCompName $closedSourceLoop]
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
        "网格焊缝完成。\n源选择模式：$sourceSelectionMode\n源节点：[llength $sourceNodes]\n源组件：[llength $sourceCompIds]\n目标组件：[llength $targetComps]\n焊缝组件：$seamCompName\n焊缝网格尺寸：$cfg(weld_mesh_size)\nimprint 目标路径节点：[llength $imprintNodes]\n目标路径节点：[llength $targetNodes]\n新建焊缝单元：[llength $weldElems]" \
        "Mesh seam weld finished.\nSource selection mode: $sourceSelectionMode\nSource nodes: [llength $sourceNodes]\nSource components: [llength $sourceCompIds]\nTarget components: [llength $targetComps]\nWeld component: $seamCompName\nWeld mesh size: $cfg(weld_mesh_size)\nImprint target path nodes: [llength $imprintNodes]\nTarget path nodes: [llength $targetNodes]\nNew weld elements: [llength $weldElems]"]
    tk_messageBox -icon info -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $msg
}

proc ::MeshSeamWeld::run {} {
    ::MeshSeamWeld::runAction
}
