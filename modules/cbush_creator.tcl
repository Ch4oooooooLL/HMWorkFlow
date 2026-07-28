# ============================================================================
# CBUSH Creator
# HyperMesh 2019 / OptiStruct
#
# Select one existing node, create a temporary node at global Z + 5, and
# connect both nodes with a Spring config 21 / CBUSH type 6 element.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::CBushCreator {
    variable Z_OFFSET 5.0
    variable OUTPUT_COLOR 6
}

proc ::CBushCreator::uniq {values} {
    set result {}
    array set seen {}
    foreach value $values {
        if {$value eq "" || [info exists seen($value)]} {
            continue
        }
        set seen($value) 1
        lappend result $value
    }
    return $result
}

proc ::CBushCreator::outputComponentName {sourceComponentName} {
    set sourceComponentName [string trim $sourceComponentName]
    if {$sourceComponentName eq ""} {
        set sourceComponentName COMPONENT
    }
    return "CBUSH_$sourceComponentName"
}

proc ::CBushCreator::offsetCoordinates {coordinates} {
    variable Z_OFFSET
    if {[llength $coordinates] < 3} {
        error [::HWFlow::txt "源节点坐标无效。" "The source-node coordinates are invalid."]
    }
    lassign $coordinates x y z
    foreach value [list $x $y $z] {
        if {![string is double -strict $value]} {
            error [::HWFlow::txt "源节点坐标无效。" "The source-node coordinates are invalid."]
        }
    }
    return [list $x $y [expr {double($z) + $Z_OFFSET}]]
}

proc ::CBushCreator::nodeCoordinates {nodeId} {
    set coordinates {}
    foreach dataName {x y z} {
        if {[catch {set value [hm_getvalue nodes id=$nodeId dataname=$dataName]}] ||
            ![string is double -strict $value]} {
            set coordinates {}
            break
        }
        lappend coordinates $value
    }
    if {[llength $coordinates] == 3} {
        return $coordinates
    }
    if {![catch {set values [hm_nodevalue $nodeId]}] && [llength $values] >= 3} {
        return [lrange $values 0 2]
    }
    error [::HWFlow::txt \
        "无法读取源节点 $nodeId 的坐标。" \
        "Cannot read the coordinates of source node $nodeId."]
}

proc ::CBushCreator::elementComponentId {elementId} {
    foreach dataName {collector.id component.id comp.id component collector} {
        if {[catch {set value [hm_getvalue elems id=$elementId dataname=$dataName]}] ||
            $value eq "" || $value eq "0"} {
            continue
        }
        if {[string is integer -strict $value]} {
            return $value
        }
        set componentId [::HWFlow::componentIdByName $value]
        if {$componentId ne ""} {
            return $componentId
        }
    }
    return ""
}

proc ::CBushCreator::sourceComponentIds {nodeId} {
    # Prefer the node's own collector when the active HyperMesh profile
    # exposes it. This remains unambiguous even at equivalenced interfaces.
    foreach dataName {collector.id component.id comp.id} {
        if {![catch {set componentId [hm_getvalue nodes id=$nodeId dataname=$dataName]}] &&
            [string is integer -strict $componentId] && $componentId > 0} {
            return [list $componentId]
        }
    }

    set elementIds {}
    foreach dataName {elems elements} {
        if {![catch {set elementIds [hm_getvalue nodes id=$nodeId dataname=$dataName]}] &&
            [llength $elementIds] > 0} {
            break
        }
    }
    if {[llength $elementIds] == 0} {
        foreach selector [list [list "by node id" $nodeId] [list "by node" $nodeId] [list "by nodes" $nodeId]] {
            catch {*clearmark elems 2}
            if {![catch {eval *createmark elems 2 $selector}]} {
                catch {set elementIds [hm_getmark elems 2]}
            }
            catch {*clearmark elems 2}
            if {[llength $elementIds] > 0} {
                break
            }
        }
    }

    set componentIds {}
    foreach elementId $elementIds {
        set componentId [::CBushCreator::elementComponentId $elementId]
        if {$componentId ne ""} {
            lappend componentIds $componentId
        }
    }
    return [::CBushCreator::uniq $componentIds]
}

proc ::CBushCreator::sourceComponentId {nodeId} {
    set componentIds [::CBushCreator::sourceComponentIds $nodeId]
    if {[llength $componentIds] == 0} {
        error [::HWFlow::txt \
            "节点 $nodeId 不属于任何可识别的 component。" \
            "Node $nodeId does not belong to a recognizable component."]
    }
    if {[llength $componentIds] > 1} {
        error [::HWFlow::txt \
            "节点 $nodeId 同时属于多个 component，无法确定 CBUSH 名称。" \
            "Node $nodeId belongs to multiple components; the CBUSH name is ambiguous."]
    }
    return [lindex $componentIds 0]
}

proc ::CBushCreator::deleteNodeIfPresent {nodeId} {
    if {$nodeId eq "" || $nodeId == 0} {
        return
    }
    catch {*clearmark nodes 2}
    catch {*createmark nodes 2 "by id only" $nodeId}
    catch {*deletemark nodes 2}
    catch {*clearmark nodes 2}
}

proc ::CBushCreator::deleteElementIfPresent {elementId} {
    if {$elementId eq "" || $elementId == 0} {
        return
    }
    catch {*clearmark elems 2}
    catch {*createmark elems 2 "by id only" $elementId}
    catch {*deletemark elems 2}
    catch {*clearmark elems 2}
}

proc ::CBushCreator::setElementCidZero {elementId} {
    # The systemId argument of *springos is not sufficient to make the CID
    # field explicit in every supported HyperMesh version/profile.  Turn the
    # card attribute on and write global system 0 after the element exists.
    if {[catch {*setvalue elems id=$elementId CID=0 STATUS=1} setError]} {
        error [::HWFlow::txt \
            "无法将 CBUSH 单元 $elementId 的 CID 设置为 0：$setError" \
            "Cannot set CID to 0 on CBUSH element $elementId: $setError"]
    }
}

proc ::CBushCreator::createForNode {sourceNodeId} {
    variable OUTPUT_COLOR

    set sourceComponentId [::CBushCreator::sourceComponentId $sourceNodeId]
    set sourceComponentName [::HWFlow::componentName $sourceComponentId]
    set outputComponentName [::CBushCreator::outputComponentName $sourceComponentName]
    set coordinates [::CBushCreator::offsetCoordinates [::CBushCreator::nodeCoordinates $sourceNodeId]]
    lassign $coordinates x y z

    # createComponent is name-idempotent: sequential source nodes owned by the
    # same component intentionally place every CBUSH in this one collector.
    ::HWFlow::createComponent $outputComponentName $OUTPUT_COLOR
    catch {*currentcollector component $outputComponentName}
    catch {*currentcollector components $outputComponentName}

    set previousNode ""
    catch {set previousNode [hm_latestentityid nodes]}
    if {[catch {*createnode $x $y $z 0 0 0} nodeError]} {
        error [::HWFlow::txt \
            "创建 Z+5 临时节点失败：$nodeError" \
            "Failed to create the Z+5 temporary node: $nodeError"]
    }
    set offsetNodeId ""
    catch {set offsetNodeId [hm_latestentityid nodes]}
    if {$offsetNodeId eq "" || $offsetNodeId == 0 || $offsetNodeId eq $previousNode} {
        error [::HWFlow::txt \
            "临时节点已执行创建，但无法取得其 ID。" \
            "The temporary node was created, but its ID could not be determined."]
    }

    set previousElement ""
    catch {set previousElement [hm_latestentityid elems]}
    set createCode [catch {
        # OptiStruct CBUSH is HyperMesh Spring configuration 21, solver type 6.
        *elementtype 21 6
        *springos $sourceNodeId $offsetNodeId "" 0 0 0 0 0 0 0
    } elementError]
    if {$createCode} {
        ::CBushCreator::deleteNodeIfPresent $offsetNodeId
        error [::HWFlow::txt \
            "创建 CBUSH 单元失败：$elementError" \
            "Failed to create the CBUSH element: $elementError"]
    }

    set elementId ""
    catch {set elementId [hm_latestentityid elems]}
    if {$elementId eq "" || $elementId == 0 || $elementId eq $previousElement} {
        ::CBushCreator::deleteNodeIfPresent $offsetNodeId
        error [::HWFlow::txt \
            "CBUSH 创建命令已执行，但无法取得新单元 ID。" \
            "The CBUSH creation command ran, but the new element ID could not be determined."]
    }

    if {[catch {::CBushCreator::setElementCidZero $elementId} cidError]} {
        ::CBushCreator::deleteElementIfPresent $elementId
        ::CBushCreator::deleteNodeIfPresent $offsetNodeId
        error $cidError
    }

    catch {*createmark elems 1 "by id only" $elementId}
    catch {*numbersmark elems 1 1}
    catch {*clearmark elems 1}
    catch {hm_entityrecorder elems off}
    catch {*redraw}
    return [dict create \
        source_node $sourceNodeId \
        offset_node $offsetNodeId \
        element $elementId \
        component $outputComponentName]
}

proc ::CBushCreator::createForNodes {sourceNodeIds} {
    set sourceNodeIds [::CBushCreator::uniq $sourceNodeIds]
    set results {}
    set failures {}
    set components {}
    foreach sourceNodeId $sourceNodeIds {
        if {[catch {set result [::CBushCreator::createForNode $sourceNodeId]} errorMessage]} {
            lappend failures [dict create source_node $sourceNodeId message $errorMessage]
            continue
        }
        lappend results $result
        lappend components [dict get $result component]
    }
    return [dict create \
        selected_count [llength $sourceNodeIds] \
        successful_count [llength $results] \
        failed_count [llength $failures] \
        results $results \
        failures $failures \
        components [::CBushCreator::uniq $components]]
}

proc ::CBushCreator::pickSourceNode {} {
    catch {*clearmark nodes 1}
    set selected [::HWFlow::nativeMarkPanel nodes 1 [::HWFlow::txt \
        "选择一个或多个源节点；中键确认，Esc 取消" \
        "Select one or more source nodes; middle-click to confirm or Esc to cancel"]]
    catch {*clearmark nodes 1}
    return [::CBushCreator::uniq $selected]
}

proc ::CBushCreator::runAction {} {
    set selected [::CBushCreator::pickSourceNode]
    if {[llength $selected] == 0} {
        return ""
    }

    set summary [::CBushCreator::createForNodes $selected]
    set successfulCount [dict get $summary successful_count]
    set failedCount [dict get $summary failed_count]
    set componentNames [dict get $summary components]
    set failureLines {}
    foreach failure [dict get $summary failures] {
        lappend failureLines [::HWFlow::txt \
            "节点 [dict get $failure source_node]：[dict get $failure message]" \
            "Node [dict get $failure source_node]: [dict get $failure message]"]
    }
    set icon [expr {$failedCount == 0 ? "info" : ($successfulCount == 0 ? "error" : "warning")}]
    set message [::HWFlow::txt \
        "CBUSH 批量创建完成。\n选择节点：[dict get $summary selected_count]\n成功：$successfulCount\n失败：$failedCount\nComponent：[join $componentNames {, }]" \
        "CBUSH batch creation completed.\nSelected nodes: [dict get $summary selected_count]\nSucceeded: $successfulCount\nFailed: $failedCount\nComponents: [join $componentNames {, }]"]
    if {[llength $failureLines] > 0} {
        append message "\n\n" [join $failureLines "\n"]
    }
    tk_messageBox -icon $icon -title "CBUSH Creator" -message $message
    return $summary
}
