# Quick deletion for a single FEM automatic seam.  A weld is one edge-connected
# shell island inside a SEAM component; other islands in the same component are
# deliberately kept.

proc ::FemAutoSeam::quickDeleteFromPanel {} {
    variable cfg
    variable ui
    if {[catch {::FemAutoSeam::validateUi} error]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "FEM 自动焊缝" "FEM Automatic Seam"] -message $error
        return
    }
    foreach key [::FemAutoSeam::stateKeys] { set cfg($key) $ui($key) }
    ::FemAutoSeam::saveState
    set ui(ok) 0
    catch {destroy .fem_auto_seam}
    after idle ::FemAutoSeam::quickDeleteWeld
}

proc ::FemAutoSeam::pickQuickDeleteElement {} {
    catch {*clearmark elems 1}
    if {[catch {*createmarkpanel elems 1 [::HWFlow::txt "选择一个需要删除的焊缝单元" "Select one weld element to delete"]}]} {
        catch {*clearmark elems 1}
        return {}
    }
    set ids [lsort -integer -unique [hm_getmark elems 1]]
    catch {*clearmark elems 1}
    return $ids
}

proc ::FemAutoSeam::quickDeleteEdgeKey {first second} {
    if {$first < $second} { return "$first,$second" }
    return "$second,$first"
}

proc ::FemAutoSeam::quickDeleteWeldIsland {seedElement componentElements} {
    set edgeOwners [dict create]
    set elementEdges [dict create]
    foreach elementId [lsort -integer -unique $componentElements] {
        if {[catch {set nodes [::FemAutoSeam::elemNodes $elementId]}] || [llength $nodes] ni {3 4}} { continue }
        set edges {}
        for {set index 0} {$index < [llength $nodes]} {incr index} {
            set key [::FemAutoSeam::quickDeleteEdgeKey [lindex $nodes $index] [lindex $nodes [expr {($index+1)%[llength $nodes]}]]]
            lappend edges $key
            dict lappend edgeOwners $key $elementId
        }
        dict set elementEdges $elementId $edges
    }
    if {![dict exists $elementEdges $seedElement]} { return {} }
    set pending [list $seedElement]
    set found [dict create $seedElement 1]
    for {set cursor 0} {$cursor < [llength $pending]} {incr cursor} {
        set elementId [lindex $pending $cursor]
        foreach edge [dict get $elementEdges $elementId] {
            foreach neighbor [dict get $edgeOwners $edge] {
                if {[dict exists $found $neighbor]} { continue }
                dict set found $neighbor 1
                lappend pending $neighbor
            }
        }
    }
    return [lsort -integer [dict keys $found]]
}

proc ::FemAutoSeam::quickDeleteStructuralSeeds {weldNodeIds weldComponentId} {
    catch {*clearmark elems 2}
    eval *createmark elems 2 {"by node id"} [lsort -integer -unique $weldNodeIds]
    set result {}
    foreach elementId [hm_getmark elems 2] {
        if {[catch {set nodes [::FemAutoSeam::elemNodes $elementId]}] || [llength $nodes] ni {3 4}} { continue }
        set componentId [::FemAutoSeam::autoElementComponentId $elementId]
        if {$componentId eq "" || $componentId == $weldComponentId} { continue }
        set name [::FemAutoSeam::componentExportName $componentId]
        if {[string match -nocase "SEAM*" $name]} { continue }
        lappend result $elementId
    }
    catch {*clearmark elems 2}
    return [lsort -integer -unique $result]
}

# Expand each original component independently and filter the mark after every
# layer.  This prevents traversal through the weld component or another panel.
proc ::FemAutoSeam::quickDeleteExpandStructuralPatch {seedIds layers} {
    set byComponent [dict create]
    foreach elementId [lsort -integer -unique $seedIds] {
        set componentId [::FemAutoSeam::autoElementComponentId $elementId]
        if {$componentId ne ""} { dict lappend byComponent $componentId $elementId }
    }
    set result {}
    dict for {componentId componentSeeds} $byComponent {
        set current [::FemAutoSeam::autoExistingShellIds $componentSeeds [list $componentId]]
        for {set layer 0} {$layer < $layers && [llength $current]} {incr layer} {
            catch {*clearmark elems 1}
            eval *createmark elems 1 $current
            set expanded 0
            foreach entityType {elements elems} {
                foreach option {{by adjacent} adjacent} {
                    if {![catch {*appendmark $entityType 1 $option}]} { set expanded 1; break }
                }
                if {$expanded} { break }
            }
            if {!$expanded} { break }
            set marked {}
            catch {set marked [hm_getmark elements 1]}
            if {![llength $marked]} { catch {set marked [hm_getmark elems 1]} }
            set current [::FemAutoSeam::autoExistingShellIds $marked [list $componentId]]
        }
        set result [concat $result $current]
    }
    catch {*clearmark elements 1}; catch {*clearmark elems 1}
    return [lsort -integer -unique $result]
}

proc ::FemAutoSeam::quickDeleteEnableUndo {} {
    foreach command {*sethistoryrecord *startnotehistorystate *endnotehistorystate *undohistorystate} {
        if {[llength [info commands ::$command]] == 0} { error "HyperMesh command $command is unavailable" }
    }
    if {[llength [info commands ::hm_gethistorylimit]]} {
        set limit [hm_gethistorylimit]
        if {$limit <= 0} {
            if {[llength [info commands ::*sethistorylimit]] == 0} { error "HyperMesh native undo history is disabled" }
            *sethistorylimit 100
        }
    }
    *sethistoryrecord 1
    if {[llength [info commands ::hm_private_frwk]]} { catch {hm_private_frwk enablehistoryfromtcl 1} }
}

proc ::FemAutoSeam::quickDeleteWeld {} {
    variable cfg
    ::FemAutoSeam::loadState
    set selected [::FemAutoSeam::pickQuickDeleteElement]
    if {![llength $selected]} { return 0 }
    if {[llength $selected] != 1} {
        tk_messageBox -icon warning -message [::HWFlow::txt "请只选择一个焊缝单元。" "Select exactly one weld element."]
        return 0
    }
    set seedElement [lindex $selected 0]
    set weldComponentId [::FemAutoSeam::autoElementComponentId $seedElement]
    if {$weldComponentId eq ""} {
        tk_messageBox -icon warning -message [::HWFlow::txt "无法读取所选单元的 Component。" "Could not read the selected element's component."]
        return 0
    }
    set weldComponentName [::FemAutoSeam::componentExportName $weldComponentId]
    if {![string match -nocase "SEAM*" $weldComponentName]} {
        tk_messageBox -icon warning -message [::HWFlow::txt "所选单元不在 SEAM 焊缝 Component 中，未作修改。" "The selected element is not in a SEAM weld component; nothing was changed."]
        return 0
    }
    set componentElements [::FemAutoSeam::componentElementIds $weldComponentId]
    set weldElements [::FemAutoSeam::quickDeleteWeldIsland $seedElement $componentElements]
    if {![llength $weldElements]} {
        tk_messageBox -icon warning -message [::HWFlow::txt "无法识别所选单元所在的连续焊缝。" "Could not identify the connected weld containing the selected element."]
        return 0
    }
    set weldNodes {}
    foreach elementId $weldElements { set weldNodes [concat $weldNodes [::FemAutoSeam::elemNodes $elementId]] }
    set weldNodes [lsort -integer -unique $weldNodes]
    set structuralSeeds [::FemAutoSeam::quickDeleteStructuralSeeds $weldNodes $weldComponentId]
    if {![llength $structuralSeeds]} {
        tk_messageBox -icon warning -message [::HWFlow::txt "未找到焊缝连接的原始壳网格，未作修改。" "No connected original shell mesh was found; nothing was changed."]
        return 0
    }
    set structuralPatch [::FemAutoSeam::quickDeleteExpandStructuralPatch $structuralSeeds $cfg(remesh_expand_layers)]
    if {![llength $structuralPatch]} { error "quick weld deletion produced an empty structural remesh patch" }
    set structuralComponents {}
    foreach elementId $structuralPatch { lappend structuralComponents [::FemAutoSeam::autoElementComponentId $elementId] }
    set structuralComponents [lsort -integer -unique $structuralComponents]
    set expectedProperties [::FemAutoSeam::autoRemeshPropertiesByComponent $structuralPatch]
    set fixedBoundaryNodes [::FemAutoSeam::autoBoundaryNodes $structuralPatch]
    # A different weld may terminate inside this local base patch.  Its shared
    # attachment nodes must stay fixed even though its elements are never put
    # on the remesh mark.
    array set structuralNode {}
    foreach elementId $structuralPatch {
        foreach nodeId [::FemAutoSeam::elemNodes $elementId] { set structuralNode($nodeId) 1 }
    }
    foreach componentId [::HybridCore::allComponentIds] {
        set componentName [::FemAutoSeam::componentExportName $componentId]
        if {![string match -nocase "SEAM*" $componentName]} { continue }
        foreach elementId [::FemAutoSeam::componentElementIds $componentId] {
            if {$elementId in $weldElements} { continue }
            foreach nodeId [::FemAutoSeam::elemNodes $elementId] {
                if {[info exists structuralNode($nodeId)]} { lappend fixedBoundaryNodes $nodeId }
            }
        }
    }
    set fixedBoundaryNodes [lsort -integer -unique $fixedBoundaryNodes]
    set baselineScopeSeeds [::FemAutoSeam::autoElementsForNodes $fixedBoundaryNodes $structuralComponents]
    set baselineScope [::FemAutoSeam::quickDeleteExpandStructuralPatch $baselineScopeSeeds $cfg(remesh_expand_layers)]
    if {![llength $baselineScope]} { set baselineScope $structuralPatch }
    set preservedWeldElements {}
    set preservedWeldConnectivity [dict create]
    foreach elementId $componentElements {
        if {$elementId in $weldElements} { continue }
        lappend preservedWeldElements $elementId
        dict set preservedWeldConnectivity $elementId [::FemAutoSeam::elemNodes $elementId]
    }

    if {[tk_messageBox -type yesno -icon question -message [::HWFlow::txt \
        "删除焊缝 $weldComponentName 中连续的 [llength $weldElements] 个单元，并局部重绘 [llength $structuralPatch] 个底面单元？" \
        "Delete [llength $weldElements] connected elements from weld $weldComponentName and locally remesh [llength $structuralPatch] supporting elements?"]] ne "yes"} { return 0 }

    if {[catch {uplevel #0 [list *readqualitycriteria [::FemAutoSeam::effectiveSpecificationPath criteria_path]]} criteriaError]} {
        tk_messageBox -icon error -message [::HWFlow::txt "质量标准加载失败，未作修改：$criteriaError" "Quality criteria could not be loaded; nothing was changed: $criteriaError"]
        return 0
    }
    set baselineFailed [::FemAutoSeam::autoNativeQualityFailures $baselineScope]
    if {[catch {::FemAutoSeam::quickDeleteEnableUndo} undoError]} {
        tk_messageBox -icon error -message [::HWFlow::txt "无法建立可回滚操作，未作修改：$undoError" "Could not create a rollback-safe operation; nothing was changed: $undoError"]
        return 0
    }

    set historyName "Quick delete FEM weld $seedElement"
    set historyStarted 0
    set code [catch {
        *startnotehistorystate $historyName
        set historyStarted 1
        catch {*clearmark elems 1}; eval *createmark elems 1 $weldElements
        *deletemark elems 1
        set remeshResult [::FemAutoSeam::runBatchElementAutomesh $structuralPatch $fixedBoundaryNodes $cfg(remesh_element_size) $cfg(remesh_feature_angle)]
        set afterSeeds [::FemAutoSeam::autoElementsForNodes $fixedBoundaryNodes $structuralComponents]
        set afterPatch [::FemAutoSeam::quickDeleteExpandStructuralPatch $afterSeeds $cfg(remesh_expand_layers)]
        if {![llength $afterPatch]} { error "local remesh did not leave a verifiable supporting patch" }
        ::FemAutoSeam::assignAutoRemeshProperties $afterPatch $expectedProperties
        if {[llength [::HybridCore::existingEntityIds {comps components} $structuralComponents]] != [llength $structuralComponents]} { error "an original component was removed during deletion" }
        if {[llength [::HybridCore::existingEntityIds {elements elems} $weldElements]] != 0} { error "the selected weld was not completely deleted" }
        set existingPreserved [::HybridCore::existingEntityIds {elements elems} $preservedWeldElements]
        if {[llength $existingPreserved] != [llength $preservedWeldElements]} { error "another weld in $weldComponentName changed during deletion" }
        foreach elementId $preservedWeldElements {
            if {[::FemAutoSeam::elemNodes $elementId] ne [dict get $preservedWeldConnectivity $elementId]} {
                error "another weld in $weldComponentName changed connectivity during deletion"
            }
        }
        set afterFailed [::FemAutoSeam::autoNativeQualityFailures $afterPatch]
        set baselineRate [expr {[llength $baselineScope] ? [llength $baselineFailed]/double([llength $baselineScope]) : 0.0}]
        set allowedFailed [expr {int(ceil($baselineRate*[llength $afterPatch]-1.0e-12))+$cfg(max_new_failed_elements)}]
        if {[llength $afterFailed] > $allowedFailed} {
            error "local remesh quality worsened: before=[llength $baselineFailed]/[llength $baselineScope] after=[llength $afterFailed]/[llength $afterPatch]"
        }
    } error options]
    if {$historyStarted} {
        if {[catch {*endnotehistorystate $historyName} endError] && !$code} {
            set code 1
            set error "could not commit the native undo transaction: $endError"
        }
    }
    if {$code} {
        set rollbackError ""
        if {$historyStarted && [catch {*undohistorystate 1} rollbackError]} {
            set error "$error; native rollback also failed: $rollbackError"
        }
        catch {::HWFlow::refreshBrowser}
        if {$rollbackError eq ""} {
            set message [::HWFlow::txt "快速删除失败并已回滚：$error" "Quick weld deletion failed and was rolled back: $error"]
        } else {
            set message [::HWFlow::txt "快速删除失败，且原生回滚失败，请立即检查模型：$error" "Quick weld deletion failed, and native rollback also failed. Inspect the model immediately: $error"]
        }
        tk_messageBox -icon error -message $message
        return 0
    }
    catch {::HWFlow::refreshBrowser}
    tk_messageBox -icon info -message [::HWFlow::txt \
        "已删除所选焊缝（[llength $weldElements] 个焊缝单元），并局部重绘 [dict get $remeshResult input_elements] 个底面单元。原始 Component 和其他焊缝均已保留。" \
        "The selected weld ([llength $weldElements] weld elements) was deleted and [dict get $remeshResult input_elements] supporting elements were locally remeshed. Original components and other welds were preserved."]
    return 1
}
