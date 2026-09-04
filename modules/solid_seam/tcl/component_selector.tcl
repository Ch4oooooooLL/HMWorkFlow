proc ::SolidSeam::clearInputSelection {} {
    variable selectedComponentIds; variable primaryComponentIds; variable secondaryComponentIds
    set selectedComponentIds {}; set primaryComponentIds {}; set secondaryComponentIds {}
    foreach slot {1 2} {
        catch {*clearlist nodes $slot}
        foreach entity {nodes elems components comps connectors} { catch {*clearmark $entity $slot} }
    }
}

proc ::SolidSeam::selectionPrompt {zh en {target 0}} {
    variable queuedPairCount
    if {![info exists queuedPairCount]} { set queuedPairCount 0 }
    if {$target} {
        return [::SolidSeam::txt "$zh（已缓存 $queuedPairCount 组；空选取消当前组）" "$en ($queuedPairCount pairs cached; empty selection cancels this pair)"]
    }
    return [::SolidSeam::txt "$zh（已缓存 $queuedPairCount 组；空选开始批量执行）" "$en ($queuedPairCount pairs cached; empty selection executes the batch)"]
}

proc ::SolidSeam::selectComponents {} {
    variable selectionOutcome; set selectionOutcome SUBMIT
    variable selectedComponentIds; variable primaryComponentIds; variable secondaryComponentIds
    catch {*clearmark components 1}; catch {*clearmark comps 1}
    # Component order is part of the realization contract: weld location
    # nodes always come from the FIRST component; the SECOND component is
    # geometry/link reference only. A multi-select mark cannot express click
    # order reliably, so collect the two roles in separate native panels.
    set prompt [::SolidSeam::selectionPrompt "选择第一个 Component（焊缝节点来源）" "Select the first component (weld-node source)"]
    set primaryComponentIds [lsort -integer -unique [::HWFlow::nativeMarkPanel components 1 $prompt]]
    if {[llength $primaryComponentIds] == 0} { catch {set primaryComponentIds [lsort -integer -unique [hm_getmark comps 1]]} }
    if {[llength $primaryComponentIds] == 0} { return {} }
    if {[llength $primaryComponentIds] != 1} { error [::SolidSeam::txt "第一次只能选择一个 Component；焊缝节点将取自该组件。" "Select exactly one first component; weld nodes come from it."] }

    set secondaryComponentIds {}
    catch {*clearmark components 2}; catch {*clearmark comps 2}
    set selectionOutcome RETRY
    set prompt [::SolidSeam::selectionPrompt "选择第二个 Component（几何参照与连接目标）" "Select the second component (geometry/link target)" 1]
    set secondaryComponentIds [lsort -integer -unique [::HWFlow::nativeMarkPanel components 2 $prompt]]
    if {[llength $secondaryComponentIds] == 0} { catch {set secondaryComponentIds [lsort -integer -unique [hm_getmark comps 2]]} }
    if {[llength $secondaryComponentIds] == 0} { return {} }
    if {[llength $secondaryComponentIds] != 1} { error [::SolidSeam::txt "第二次只能选择一个 Component。" "Select exactly one component in the second panel."] }
    if {[lindex $secondaryComponentIds 0] == [lindex $primaryComponentIds 0]} { error [::SolidSeam::txt "两次不能选择同一个 Component。" "The two selections must be different components."] }

    set selectedComponentIds [concat $primaryComponentIds $secondaryComponentIds]
    ::SolidSeam::log INFO "primary_components=$primaryComponentIds secondary_components=$secondaryComponentIds"
    return $selectedComponentIds
}

proc ::SolidSeam::selectNodeList {} {
    catch {*clearlist nodes 1}
    catch {*clearmark nodes 1}
    set windows [::HWFlow::nativePanelSessionBegin]
    set code [catch {
        set prompt [::SolidSeam::selectionPrompt "选择一个闭环种子点，或按路径顺序选择多个焊缝节点" "Select one closed-boundary seed or multiple weld nodes in path order"]
        *createlistbypathpanel nodes 1 $prompt
        set nodes [hm_getlist nodes 1]
    } err opts]
    catch {*clearlist nodes 1}
    catch {*clearmark nodes 1}
    ::HWFlow::nativePanelSessionEnd $windows
    if {$code} { return -options $opts $err }
    return $nodes
}

# Intersect the component ownership of EVERY input node, excluding the
# explicitly selected target. Never choose a component merely by its ID.
proc ::SolidSeam::sourceComponentForNodes {nodeIds targetId} {
    set owners {}
    set first 1
    foreach nodeId $nodeIds {
        set attached [::SolidSeam::queryMarkedIds elems 1 "by node id" $nodeId]
        set nodeOwners {}
        foreach elementId $attached {
            # Existing weld RBE3/1D attachments do not own the source mesh.
            set config [hm_getvalue elems id=$elementId dataname=config]
            if {$config ni {103 104 106 108 204 205 206 208 210 213 215 220}} { continue }
            set componentId [hm_getvalue elems id=$elementId dataname=component]
            if {$componentId != $targetId && $componentId > 0} { dict set nodeOwners $componentId 1 }
        }
        if {$first} {
            set owners $nodeOwners
            set first 0
        } else {
            foreach componentId [dict keys $owners] {
                if {![dict exists $nodeOwners $componentId]} { dict unset owners $componentId }
            }
        }
        if {[dict size $owners] == 0} { break }
    }
    catch {*clearmark elems 1}
    if {[dict size $owners] != 1} {
        error [::SolidSeam::txt \
            "无法唯一确定节点所属的源组件（排除目标后候选：[dict keys $owners]）。请在同一个源组件中选取焊缝节点，或使用 comps+comps。" \
            "Cannot uniquely resolve the source component for all nodes (excluding target: [dict keys $owners]). Select weld nodes from one source component, or use comps+comps."]
    }
    return [lindex [dict keys $owners] 0]
}

proc ::SolidSeam::selectNodesAndComponents {} {
    variable selectionOutcome; set selectionOutcome SUBMIT
    variable selectedComponentIds; variable primaryComponentIds; variable secondaryComponentIds
    set selectedComponentIds {}; set primaryComponentIds {}; set secondaryComponentIds {}
    set nodes [::SolidSeam::selectNodeList]
    if {[llength $nodes] == 0} { return {} }
    if {[llength [lsort -unique $nodes]] != [llength $nodes]} {
        error [::SolidSeam::txt "请选择一个闭环种子点，或多个不重复的有序节点。" "Select one closed-boundary seed or distinct ordered nodes."]
    }
    catch {*clearmark components 2}
    set selectionOutcome RETRY
    set targets [::HWFlow::nativeMarkPanel components 2 [::SolidSeam::selectionPrompt "选择一个目标 Component" "Select one target component" 1]]
    if {[llength $targets] == 0} { return {} }
    if {[llength $targets] != 1} { error [::SolidSeam::txt "只能选择一个目标组件。" "Select exactly one target component."] }
    set source [::SolidSeam::sourceComponentForNodes $nodes [lindex $targets 0]]
    set primaryComponentIds [list $source]
    set secondaryComponentIds $targets
    set selectedComponentIds [concat $primaryComponentIds $secondaryComponentIds]
    return [dict create node_ids $nodes component_ids $selectedComponentIds]
}
