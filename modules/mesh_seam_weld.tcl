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
    variable VERSION "0.10"
    variable MODULE_DIR [file join [file dirname [file normalize [info script]]] mesh_seam_weld]

    variable cfg
    array set cfg {
        output_component       MESH_SEAM_WELD
        weld_mesh_size         8
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
    variable freeEdgePrimedComponents
    array set elemNodesCache {}
    array set nodeElemsCache {}
    array set elemComponentCache {}
    array set nodeFreeEdgeNeighborsCache {}
    array set nodeXYZCache {}
    array set freeEdgePrimedComponents {}
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
        "连续节点按开放 node path 处理；彼此不连续的节点分别作为闭合边界种子，并共用一个目标 component。imprint 后会校正目标路径方向，再按焊缝网格尺寸生成多层连接带。" \
        "Continuous nodes form an open node path. Disconnected nodes are closed-boundary seeds sharing one target component. After imprint, target-path orientation is aligned and a multilayer strip is meshed at the weld mesh size."]
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
        nodeFreeEdgeNeighborsCache nodeXYZCache freeEdgePrimedComponents
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
    set prompt [::HWFlow::txt "按路径顺序选择焊缝源节点" "Select weld source nodes in path order"]
    # The by-path collector repeatedly expands and processes adjacent elements
    # after every click.  On large models that blocks the UI even when only one
    # node is wanted.  A regular list preserves pick order without doing that
    # interactive element traversal; retain by-path only as a compatibility
    # fallback for installations where the regular list panel is unavailable.
    if {[catch {*createlistpanel nodes 1 $prompt} listErr]} {
        if {[catch {*createlistbypathpanel nodes 1 $prompt} pathErr]} {
            error [::HWFlow::txt \
                "无法打开节点列表选择面板：$listErr；备用 path 面板错误：$pathErr" \
                "Could not open the node list selection panel: $listErr; fallback path panel error: $pathErr"]
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
    ::HWFlow::nativeMarkPanel comps 1 [::HWFlow::txt "选择要投影到的目标网格组件" "Select target mesh components for projection"]
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
    set allCountsAvailable 1
    foreach compId $compIds {
        set countAvailable 0
        foreach dn {elements-count elementcount numelems} {
            if {![catch {set count [hm_getvalue comps id=$compId dataname=$dn]}] &&
                [string is integer -strict $count]} {
                set countAvailable 1
                if {$count > 0} {
                    return 1
                }
                break
            }
        }
        if {!$countAvailable} {
            set allCountsAvailable 0
        }
    }
    # Older HyperMesh versions do not expose a cheap component element count.
    # Let imprint validate those models instead of selecting every target
    # element here and then processing the same elements again during imprint.
    return [expr {!$allCountsAvailable}]
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

proc ::MeshSeamWeld::adjacentElementsForNodes {nodeIds} {
    set nodeIds [::MeshSeamWeld::uniq $nodeIds]
    if {[llength $nodeIds] == 0} {
        return {}
    }

    catch {*clearmark elems 2}
    set marked 0
    # Query all nodes in one operation.  The old per-node fallback caused
    # HyperMesh to rebuild the element selection repeatedly.
    foreach command {hm_createmark *createmark} {
        if {![catch {eval $command elems 2 [list "by node id"] $nodeIds}]} {
            set marked 1
            break
        }
    }
    set elems {}
    if {$marked} {
        catch {set elems [hm_getmark elems 2]}
    }
    catch {*clearmark elems 2}
    return [::MeshSeamWeld::uniq $elems]
}

proc ::MeshSeamWeld::cacheNodeElementIncidence {elemIds {onlyNodeIds {}}} {
    variable nodeElemsCache

    array set wanted {}
    foreach nodeId $onlyNodeIds {
        set wanted($nodeId) 1
        set nodeElemsCache($nodeId) {}
    }
    set filter [expr {[llength $onlyNodeIds] > 0}]

    foreach elemId [::MeshSeamWeld::uniq $elemIds] {
        foreach nodeId [::MeshSeamWeld::elemNodes $elemId] {
            if {$filter && ![info exists wanted($nodeId)]} {
                continue
            }
            if {![info exists nodeElemsCache($nodeId)]} {
                set nodeElemsCache($nodeId) {}
            }
            lappend nodeElemsCache($nodeId) $elemId
        }
    }
}

proc ::MeshSeamWeld::primeSelectedNodeElements {nodeIds} {
    variable nodeElemsCache
    set missing {}
    foreach nodeId [::MeshSeamWeld::uniq $nodeIds] {
        if {![info exists nodeElemsCache($nodeId)]} {
            lappend missing $nodeId
        }
    }
    if {[llength $missing] == 0} {
        return {}
    }
    set elemIds [::MeshSeamWeld::adjacentElementsForNodes $missing]
    ::MeshSeamWeld::cacheNodeElementIncidence $elemIds $missing
    return $elemIds
}

proc ::MeshSeamWeld::primeFreeEdgeComponent {seedNode} {
    variable freeEdgePrimedComponents
    set seedElems [::MeshSeamWeld::primeSelectedNodeElements [list $seedNode]]
    if {[llength $seedElems] == 0} {
        set seedElems [::MeshSeamWeld::nodeElementIds $seedNode]
    }
    set compIds {}
    foreach elemId $seedElems {
        set compId [::MeshSeamWeld::elemComponentId $elemId]
        if {$compId ne ""} {
            lappend compIds $compId
        }
    }

    set componentElems {}
    foreach compId [::MeshSeamWeld::uniq $compIds] {
        if {[info exists freeEdgePrimedComponents($compId)]} {
            continue
        }
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
        set componentElems [concat $componentElems $elems]
        set freeEdgePrimedComponents($compId) 1
    }
    if {[llength $componentElems] > 0} {
        ::MeshSeamWeld::cacheNodeElementIncidence $componentElems
    }
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

proc ::MeshSeamWeld::nodesShareElementEdge {a b} {
    ::MeshSeamWeld::primeSelectedNodeElements [list $a $b]
    foreach elemId [::MeshSeamWeld::nodeElementIds $a] {
        if {[lsearch -exact [::MeshSeamWeld::nodeElementIds $b] $elemId] >= 0 &&
            [::MeshSeamWeld::elementContainsEdge $elemId $a $b]} {
            return 1
        }
    }
    return 0
}

proc ::MeshSeamWeld::selectedNodesFormContinuousPath {nodeIds} {
    if {[llength $nodeIds] < 2} {
        return 0
    }
    ::MeshSeamWeld::primeSelectedNodeElements $nodeIds
    for {set i 1} {$i < [llength $nodeIds]} {incr i} {
        if {![::MeshSeamWeld::nodesShareElementEdge \
            [lindex $nodeIds [expr {$i - 1}]] [lindex $nodeIds $i]]} {
            return 0
        }
    }
    return 1
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

proc ::MeshSeamWeld::closedFreeEdgeLoopsFromSeeds {seedNodes} {
    set loops {}
    array set seenLoops {}
    foreach seedNode $seedNodes {
        ::MeshSeamWeld::primeFreeEdgeComponent $seedNode
        set loop [::MeshSeamWeld::closedFreeEdgeLoopFromNode $seedNode]
        set signature [join [lsort -integer $loop] ,]
        if {[info exists seenLoops($signature)]} {
            continue
        }
        set seenLoops($signature) 1
        lappend loops $loop
    }
    return $loops
}

proc ::MeshSeamWeld::componentIdsFromNodes {nodeIds} {
    ::MeshSeamWeld::primeSelectedNodeElements $nodeIds
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
    if {[llength [info commands ::HWFlow::thicknessFromComponentName]] > 0} {
        return [::HWFlow::thicknessFromComponentName $name]
    }
    return ""
}

proc ::MeshSeamWeld::formatThickness {thickness} {
    if {[llength [info commands ::HWFlow::formatThicknessToken]] > 0} {
        return [::HWFlow::formatThicknessToken $thickness]
    }
    return [format "%.6g" $thickness]
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

proc ::MeshSeamWeld::distanceBetweenNodes {a b} {
    return [expr {sqrt([::MeshSeamWeld::dist2 \
        [::MeshSeamWeld::nodeXYZ $a] [::MeshSeamWeld::nodeXYZ $b]])}]
}

proc ::MeshSeamWeld::nodePathLength {nodeIds {closedLoop 0}} {
    set count [llength $nodeIds]
    if {$count < 2} {
        return 0.0
    }
    set length 0.0
    for {set i 1} {$i < $count} {incr i} {
        set length [expr {$length + [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $nodeIds [expr {$i - 1}]] [lindex $nodeIds $i]]}]
    }
    if {$closedLoop} {
        set length [expr {$length + [::MeshSeamWeld::distanceBetweenNodes \
            [lindex $nodeIds end] [lindex $nodeIds 0]]}]
    }
    return $length
}

proc ::MeshSeamWeld::meshDensityForLength {length meshSize {minimum 1}} {
    if {$minimum < 1} {
        set minimum 1
    }
    set density [expr {int(ceil(double($length) / double($meshSize)))}]
    if {$density < $minimum} {
        set density $minimum
    }
    return $density
}

proc ::MeshSeamWeld::shortestMeshBoundaryPath {elemIds startNode endNode} {
    # Build the free-boundary graph of only the newly created weld elements.
    # The short path between a source/target endpoint pair is the transverse
    # automesh edge, while the alternative travels around the other three
    # sides of the open strip.
    array set edgeCount {}
    array set edgeEnds {}
    foreach elemId $elemIds {
        set nodes [::MeshSeamWeld::elemNodes $elemId]
        set count [llength $nodes]
        if {$count < 3} {
            continue
        }
        for {set i 0} {$i < $count} {incr i} {
            set a [lindex $nodes $i]
            set b [lindex $nodes [expr {($i + 1) % $count}]]
            if {$a == $b} {
                continue
            }
            if {$a < $b} {
                set key "$a,$b"
            } else {
                set key "$b,$a"
            }
            if {![info exists edgeCount($key)]} {
                set edgeCount($key) 0
                set edgeEnds($key) [list $a $b]
            }
            incr edgeCount($key)
        }
    }

    array set neighbors {}
    foreach key [array names edgeCount] {
        if {$edgeCount($key) != 1} {
            continue
        }
        foreach {a b} $edgeEnds($key) break
        lappend neighbors($a) $b
        lappend neighbors($b) $a
    }
    if {![info exists neighbors($startNode)] || ![info exists neighbors($endNode)]} {
        error [::HWFlow::txt \
            "无法在焊缝网格边界上定位封口端点。" \
            "Could not locate closure endpoints on the weld mesh boundary."]
    }

    set queue [list $startNode]
    set head 0
    array set visited [list $startNode 1]
    array set parent {}
    while {$head < [llength $queue]} {
        set current [lindex $queue $head]
        incr head
        if {$current == $endNode} {
            break
        }
        foreach next $neighbors($current) {
            if {[info exists visited($next)]} {
                continue
            }
            set visited($next) 1
            set parent($next) $current
            lappend queue $next
        }
    }
    if {![info exists visited($endNode)]} {
        error [::HWFlow::txt \
            "焊缝横向边界不连续，无法创建闭环封口。" \
            "The transverse weld boundary is discontinuous; closure cannot be created."]
    }

    set path [list $endNode]
    set current $endNode
    while {$current != $startNode} {
        set current $parent($current)
        set path [linsert $path 0 $current]
    }
    return $path
}

proc ::MeshSeamWeld::createClosedStripElements {elemIds sourceNodes targetNodes expectedDensity} {
    set startCross [::MeshSeamWeld::shortestMeshBoundaryPath $elemIds \
        [lindex $sourceNodes 0] [lindex $targetNodes 0]]
    set endCross [::MeshSeamWeld::shortestMeshBoundaryPath $elemIds \
        [lindex $sourceNodes end] [lindex $targetNodes end]]
    set startDensity [expr {[llength $startCross] - 1}]
    set endDensity [expr {[llength $endCross] - 1}]
    if {$startDensity != $expectedDensity || $endDensity != $expectedDensity} {
        error [::HWFlow::txt \
            "闭环首尾横向网格层数异常（期望 $expectedDensity 层，首端 $startDensity 层，末端 $endDensity 层）。" \
            "Unexpected closure density (expected $expectedDensity, start $startDensity, end $endDensity)."]
    }

    set created {}
    for {set i 0} {$i < [llength $startCross] - 1} {incr i} {
        set quadNodes [list \
            [lindex $endCross $i] [lindex $startCross $i] \
            [lindex $startCross [expr {$i + 1}]] [lindex $endCross [expr {$i + 1}]]]
        if {[catch {
            eval *createlist nodes 1 $quadNodes
            *createelement 104 1 1 1
        } err]} {
            error [::HWFlow::txt \
                "创建闭环封口第 [expr {$i + 1}] 层单元失败：$err" \
                "Failed to create closure element layer [expr {$i + 1}]: $err"]
        }
        set elemId ""
        catch {set elemId [hm_latestentityid elems]}
        if {$elemId ne "" && $elemId != 0} {
            lappend created $elemId
        }
    }
    return $created
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
    ::HybridCore::log INFO "imprint list2 raw_count=[llength $list2] source_count=[llength $sourceNodes] before_node=$beforeNode"
    if {[llength $list2] != [llength $sourceNodes]} {
        return {}
    }
    set list2 [::MeshSeamWeld::uniq $list2]
    if {[llength $list2] != [llength $sourceNodes]} {
        return {}
    }
    # HyperMesh 2019 may remesh the target with new nodes, but it may also
    # reuse target nodes that already existed before the imprint.  List 2 is
    # cleared immediately before *imprint_nodelist, so an ID does not need to
    # be greater than beforeNode to belong to this operation.
    array set sourceSet {}
    foreach nodeId $sourceNodes { set sourceSet($nodeId) 1 }
    set reusedCount 0
    foreach nodeId $list2 {
        if {![string is integer -strict $nodeId] || [info exists sourceSet($nodeId)]} {
            return {}
        }
        if {[catch {::MeshSeamWeld::nodeXYZ $nodeId}]} {
            return {}
        }
        if {$beforeNode ne "" && $nodeId <= $beforeNode} { incr reusedCount }
    }
    ::HybridCore::log INFO "imprint list2 accepted count=[llength $list2] reused_count=$reusedCount"
    return $list2
}

proc ::MeshSeamWeld::componentNodeIds {compIds} {
    set elemIds {}
    foreach compId [::MeshSeamWeld::uniq $compIds] {
        set elems {}
        if {[llength [info commands ::HWFlow::getCompEntityIds]] > 0} {
            catch {set elems [::HWFlow::getCompEntityIds $compId elems elems]}
        }
        if {[llength $elems] == 0} {
            catch {*clearmark elems 2}
            if {![catch {*createmark elems 2 "by comp id" $compId}]} {
                catch {set elems [hm_getmark elems 2]}
            }
            catch {*clearmark elems 2}
        }
        set elemIds [concat $elemIds $elems]
    }
    set nodeIds {}
    foreach elemId [::MeshSeamWeld::uniq $elemIds] {
        set nodeIds [concat $nodeIds [::MeshSeamWeld::elemNodes $elemId]]
    }
    return [::MeshSeamWeld::uniq $nodeIds]
}

proc ::MeshSeamWeld::targetCandidatesAfterImprint {sourceNodes targetComps beforeNode} {
    set listNodes [::MeshSeamWeld::targetNodesFromImprintList $sourceNodes $beforeNode]
    if {[llength $listNodes] > 0} {
        return $listNodes
    }

    set createdNodes [::MeshSeamWeld::entityIdsCreatedAfter nodes $beforeNode]
    if {[llength $createdNodes] >= [llength $sourceNodes]} {
        ::HybridCore::log INFO "imprint fallback=new_nodes count=[llength $createdNodes]"
        return $createdNodes
    }

    # Some HM2019 imprint cases return no output list and create no node IDs:
    # the target mesh is updated by reusing its existing boundary nodes.  In
    # that case, obtain the target component nodes and reduce them to one
    # nearest, unique candidate per source node before handing off to Python.
    set componentNodes [::MeshSeamWeld::componentNodeIds $targetComps]
    array set sourceSet {}
    foreach nodeId $sourceNodes { set sourceSet($nodeId) 1 }
    set candidates {}
    foreach nodeId [::MeshSeamWeld::uniq [concat $createdNodes $componentNodes]] {
        if {![info exists sourceSet($nodeId)]} { lappend candidates $nodeId }
    }
    ::HybridCore::log INFO "imprint fallback=target_components created_count=[llength $createdNodes] component_node_count=[llength $componentNodes] candidate_count=[llength $candidates]"
    return [::MeshSeamWeld::matchTargetPathNodes $sourceNodes $candidates]
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

proc ::MeshSeamWeld::pathPairingCost {sourceNodes targetNodes} {
    if {[llength $sourceNodes] != [llength $targetNodes]} {
        return Inf
    }
    set cost 0.0
    foreach sourceNode $sourceNodes targetNode $targetNodes {
        set cost [expr {$cost + [::MeshSeamWeld::dist2 \
            [::MeshSeamWeld::nodeXYZ $sourceNode] \
            [::MeshSeamWeld::nodeXYZ $targetNode]]}]
    }
    return $cost
}

proc ::MeshSeamWeld::rotateList {items offset} {
    set count [llength $items]
    if {$count == 0} {
        return {}
    }
    set offset [expr {(($offset % $count) + $count) % $count}]
    if {$offset == 0} {
        return $items
    }
    return [concat [lrange $items $offset end] [lrange $items 0 [expr {$offset - 1}]]]
}

proc ::MeshSeamWeld::alignTargetPathNodes {sourceNodes targetNodes {closedLoop 0}} {
    if {[llength $sourceNodes] != [llength $targetNodes]} {
        error [::HWFlow::txt "源 node path 与目标 node path 数量不一致。" "Source and target node path counts do not match."]
    }
    if {[llength $sourceNodes] < 2} {
        return $targetNodes
    }

    if {!$closedLoop} {
        set reversed [lreverse $targetNodes]
        if {[::MeshSeamWeld::pathPairingCost $sourceNodes $reversed] <
            [::MeshSeamWeld::pathPairingCost $sourceNodes $targetNodes]} {
            return $reversed
        }
        return $targetNodes
    }

    # imprint may return a closed path with either direction and any start
    # node.  Anchor both orientations at the target node closest to the first
    # source node, then retain whichever complete pairing has the lower cost.
    set firstPoint [::MeshSeamWeld::nodeXYZ [lindex $sourceNodes 0]]
    set bestIndex 0
    set bestD2 ""
    for {set i 0} {$i < [llength $targetNodes]} {incr i} {
        set d2 [::MeshSeamWeld::dist2 $firstPoint \
            [::MeshSeamWeld::nodeXYZ [lindex $targetNodes $i]]]
        if {$bestD2 eq "" || $d2 < $bestD2} {
            set bestD2 $d2
            set bestIndex $i
        }
    }
    set forward [::MeshSeamWeld::rotateList $targetNodes $bestIndex]
    set reverseBase [lreverse $targetNodes]
    set reverseIndex [lsearch -exact $reverseBase [lindex $forward 0]]
    set reversed [::MeshSeamWeld::rotateList $reverseBase $reverseIndex]
    if {[::MeshSeamWeld::pathPairingCost $sourceNodes $reversed] <
        [::MeshSeamWeld::pathPairingCost $sourceNodes $forward]} {
        return $reversed
    }
    return $forward
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

    set sourceLength [::MeshSeamWeld::nodePathLength $sourceNodes $closedLoop]
    set targetLength [::MeshSeamWeld::nodePathLength $targetNodes $closedLoop]
    set pathLength [expr {max($sourceLength, $targetLength)}]
    set pathMinimum [expr {$closedLoop ? [llength $sourceNodes] : [llength $sourceNodes] - 1}]
    set pathMinimum [expr {max($pathMinimum, $cfg(mesh_path_param))}]
    set pathDensity [::MeshSeamWeld::meshDensityForLength \
        $pathLength $cfg(weld_mesh_size) $pathMinimum]
    set crossStartLength [::MeshSeamWeld::distanceBetweenNodes \
        [lindex $sourceNodes 0] [lindex $targetNodes 0]]
    set crossEndLength [::MeshSeamWeld::distanceBetweenNodes \
        [lindex $sourceNodes end] [lindex $targetNodes end]]
    set crossStartDensity [::MeshSeamWeld::meshDensityForLength \
        $crossStartLength $cfg(weld_mesh_size) $cfg(mesh_cross_param)]
    set crossEndDensity [::MeshSeamWeld::meshDensityForLength \
        $crossEndLength $cfg(weld_mesh_size) $cfg(mesh_cross_param)]
    set crossDensity [expr {max($crossStartDensity, $crossEndDensity)}]

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

        # Keep the ruled surface open.  HyperMesh ignores a repeated first
        # node in these lists, so relying on it for closure leaves exactly one
        # longitudinal cell missing.  The transverse end-node chains are read
        # from the accepted mesh and explicitly connected below.
        eval *createlist nodes 1 $sourceNodes
        eval *createlist nodes 2 $targetNodes
        *linearsurfacebetweennodes 1 2 1

        *set_meshfaceparams 0 $cfg(mesh_face_shape) $cfg(mesh_elem_type) 0 0 $cfg(mesh_smooth_method) $cfg(mesh_smooth_tol) $cfg(mesh_size_control) $cfg(mesh_skew_control)
        # Signature: edge_index, element density, algorithm type, then bias
        # and chordal controls.  Density is derived from physical edge length;
        # passing mesh size directly here used to force a single cross layer.
        *set_meshedgeparams 0 $pathDensity 1 0 0 0 0 0 0
        *set_meshedgeparams 1 $crossDensity 1 0 0 0 0 0 0
        *set_meshedgeparams 2 $pathDensity 1 0 0 0 0 0 0
        *set_meshedgeparams 3 $crossDensity 1 0 0 0 0 0 0
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
    set openStripElems [::MeshSeamWeld::entityIdsCreatedAfter elems $beforeElem]
    if {$closedLoop} {
        set closureCode [catch {
            ::MeshSeamWeld::createClosedStripElements \
                $openStripElems $sourceNodes $targetNodes $crossDensity
        } closureErr]
        if {$closureCode} {
            if {$historyStarted} {
                catch {*endnotehistorystate {Create ruled surface and mesh}}
            }
            error $closureErr
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

    set selectedNodes [::MeshSeamWeld::pickNodes]
    if {[llength $selectedNodes] == 0} {
        return
    }

    set closedSeedMode [expr {[llength $selectedNodes] == 1 ||
        ![::MeshSeamWeld::selectedNodesFormContinuousPath $selectedNodes]}]
    set sourceSelectionMode [expr {$closedSeedMode ?
        "closed free-edge seed nodes" : "open node path"}]

    set targetComps [::MeshSeamWeld::pickComponents]
    if {[llength $targetComps] == 0} {
        return
    }
    if {![::MeshSeamWeld::componentsHaveElements $targetComps]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt "目标组件中没有可用网格单元。" "Target components contain no usable mesh elements."]
        return
    }
    if {$closedSeedMode && [llength $targetComps] != 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message [::HWFlow::txt \
            "闭合边界批量任务只能选择一个目标组件，所有闭合边界将投影到同一组件。" \
            "A closed-boundary batch must use exactly one target component; every loop is projected to that component."]
        return
    }

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "网格焊缝命令流" "Mesh Seam Weld Command Stream"] \
            [::HWFlow::txt "正在准备闭合边界任务..." "Preparing closed-boundary jobs..."] 0]
    }

    set code [catch {
        if {$closedSeedMode} {
            set sourcePaths [::MeshSeamWeld::closedFreeEdgeLoopsFromSeeds $selectedNodes]
            if {[llength $sourcePaths] == 0} {
                error [::HWFlow::txt "没有识别到有效闭合自由边。" "No valid closed free-edge loop was found."]
            }
        } else {
            set sourcePaths [list $selectedNodes]
        }

        set allSourceNodes {}
        set allSourceCompIds {}
        set allSeamCompNames {}
        set allImprintNodes {}
        set allTargetNodes {}
        set allWeldElems {}
        set pathTotal [llength $sourcePaths]
        set pathIndex 0
        foreach sourceNodes $sourcePaths {
            incr pathIndex
            set result [::MeshSeamWeld::processWeldPath $sourceNodes $targetComps \
                $closedSeedMode $progressOpened $pathIndex $pathTotal]
            foreach {key value} $result {
                switch -- $key {
                    sourceNodes { set allSourceNodes [concat $allSourceNodes $value] }
                    sourceCompIds { set allSourceCompIds [concat $allSourceCompIds $value] }
                    seamCompName { lappend allSeamCompNames $value }
                    imprintNodes { set allImprintNodes [concat $allImprintNodes $value] }
                    targetNodes { set allTargetNodes [concat $allTargetNodes $value] }
                    weldElems { set allWeldElems [concat $allWeldElems $value] }
                }
            }
        }
    } err]

    if {$code} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "网格焊缝命令流失败。" "Mesh seam weld command stream failed."] 100.0}
        }
        tk_messageBox -icon error -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $err
        return
    }

    catch {::HWFlow::refreshBrowser}
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "网格焊缝命令流已完成。" "Mesh seam weld command stream finished."] 100.0}
    }
    set sourceCompIds [::MeshSeamWeld::uniq $allSourceCompIds]
    set seamCompNames [::MeshSeamWeld::uniq $allSeamCompNames]
    set msg [::HWFlow::txt \
        "网格焊缝完成。\n源选择模式：$sourceSelectionMode\n闭合边界/路径数：[llength $sourcePaths]\n源节点：[llength $allSourceNodes]\n源组件：[llength $sourceCompIds]\n目标组件：[llength $targetComps]\n焊缝组件：[join $seamCompNames {, }]\n焊缝网格尺寸：$cfg(weld_mesh_size)\nimprint 目标路径节点：[llength $allImprintNodes]\n目标路径节点：[llength $allTargetNodes]\n新建焊缝单元：[llength $allWeldElems]" \
        "Mesh seam weld finished.\nSource selection mode: $sourceSelectionMode\nClosed boundaries/paths: [llength $sourcePaths]\nSource nodes: [llength $allSourceNodes]\nSource components: [llength $sourceCompIds]\nTarget components: [llength $targetComps]\nWeld components: [join $seamCompNames {, }]\nWeld mesh size: $cfg(weld_mesh_size)\nImprint target path nodes: [llength $allImprintNodes]\nTarget path nodes: [llength $allTargetNodes]\nNew weld elements: [llength $allWeldElems]"]
    tk_messageBox -icon info -title [::HWFlow::txt "网格焊缝" "Mesh Seam Weld"] -message $msg
}

proc ::MeshSeamWeld::run {} {
    ::MeshSeamWeld::runAction
}

foreach hybridFile {bridge.tcl exporter.tcl executor.tcl workflow.tcl} {
    source [file join $::MeshSeamWeld::MODULE_DIR tcl $hybridFile]
}
