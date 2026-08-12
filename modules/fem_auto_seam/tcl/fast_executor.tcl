proc ::FemAutoSeam::executionRecord {plan status {createdElements 0} {error ""}} {
    set row [dict create candidate_id [dict get $plan candidate_id] status $status]
    foreach key {candidate_type confidence source_component_id target_component_id output_component_id delta_fem} {
        if {[dict exists $plan $key]} { dict set row $key [dict get $plan $key] }
    }
    dict set row created_elements $createdElements
    dict set row moved_nodes 0
    dict set row deleted_mother_elements [llength [dict get $plan delete_element_ids]]
    dict set row created_mother_elements [llength [dict get $plan replacement_elements]]
    dict set row created_weld_elements [llength [dict get $plan weld_elements]]
    dict set row created_nodes [llength [dict get $plan new_nodes]]
    if {$error ne ""} { dict set row error $error }
    return $row
}

proc ::FemAutoSeam::autoElementComponentId {elementId} {
    set value ""
    foreach dataName {collector.id collectorid component.id componentid} {
        if {![catch {set value [hm_getvalue elems id=$elementId dataname=$dataName]}] && $value ne ""} { return $value }
    }
    return ""
}

proc ::FemAutoSeam::autoElementPropertyId {elementId} {
    set value ""
    foreach dataName {property.id propertyid} {
        if {![catch {set value [hm_getvalue elems id=$elementId dataname=$dataName]}] && $value ne ""} { return $value }
    }
    return 0
}

proc ::FemAutoSeam::autoRemeshPropertiesByComponent {elementIds} {
    set values [dict create]
    foreach elementId $elementIds {
        set componentId [::FemAutoSeam::autoElementComponentId $elementId]
        set propertyId [::FemAutoSeam::autoElementPropertyId $elementId]
        if {$componentId eq "" || $propertyId <= 0} { continue }
        set existing {}
        if {[dict exists $values $componentId]} { set existing [dict get $values $componentId] }
        dict set values $componentId [lsort -integer -unique [concat $existing $propertyId]]
    }
    dict for {componentId propertyIds} $values {
        if {[llength $propertyIds] > 1} {
            error "batch remesh crosses multiple direct properties in component $componentId: $propertyIds"
        }
        dict set values $componentId [lindex $propertyIds 0]
    }
    return $values
}

proc ::FemAutoSeam::autoExistingShellIds {elementIds {allowedComponents {}}} {
    array set allowed {}
    foreach componentId $allowedComponents { set allowed($componentId) 1 }
    set result {}
    foreach elementId [lsort -integer -unique $elementIds] {
        if {[catch {set nodes [::FemAutoSeam::elemNodes $elementId]}] || [llength $nodes] ni {3 4}} { continue }
        if {[llength $allowedComponents]} {
            set componentId [::FemAutoSeam::autoElementComponentId $elementId]
            if {![info exists allowed($componentId)]} { continue }
        }
        lappend result $elementId
    }
    return $result
}

proc ::FemAutoSeam::autoExpandElementPatch {seedIds allowedComponents layers {markId 1}} {
    set seedIds [::FemAutoSeam::autoExistingShellIds $seedIds $allowedComponents]
    if {![llength $seedIds]} { return {} }
    catch {*clearmark elements $markId}; eval *createmark elements $markId $seedIds
    for {set layer 0} {$layer < $layers} {incr layer} {
        set expanded 0
        foreach entityType {elements elems} {
            foreach option {{by adjacent} adjacent} {
                if {![catch {*appendmark $entityType $markId $option}]} { set expanded 1; break }
            }
            if {$expanded} { break }
        }
        if {!$expanded} { break }
    }
    set marked {}; catch {set marked [hm_getmark elements $markId]}
    if {![llength $marked]} { catch {set marked [hm_getmark elems $markId]} }
    set filtered [::FemAutoSeam::autoExistingShellIds $marked $allowedComponents]
    catch {*clearmark elements $markId}
    if {[llength $filtered]} { eval *createmark elements $markId $filtered }
    return $filtered
}

proc ::FemAutoSeam::autoBoundaryNodes {elementIds} {
    array set edgeCount {}
    array set edgeNodes {}
    foreach elementId $elementIds {
        set nodes [::FemAutoSeam::elemNodes $elementId]
        set count [llength $nodes]
        for {set index 0} {$index < $count} {incr index} {
            set first [lindex $nodes $index]
            set second [lindex $nodes [expr {($index+1)%$count}]]
            set ordered [lsort -integer [list $first $second]]
            set key "[lindex $ordered 0],[lindex $ordered 1]"
            if {![info exists edgeCount($key)]} { set edgeCount($key) 0; set edgeNodes($key) $ordered }
            incr edgeCount($key)
        }
    }
    set result {}
    foreach key [array names edgeCount] {
        if {$edgeCount($key) == 1} { set result [concat $result $edgeNodes($key)] }
    }
    return [lsort -integer -unique $result]
}

proc ::FemAutoSeam::autoElementsForNodes {nodeIds allowedComponents} {
    set validNodes {}
    foreach nodeId [lsort -integer -unique $nodeIds] {
        if {[llength [::HybridCore::existingEntityIds {nodes} [list $nodeId]]]} { lappend validNodes $nodeId }
    }
    if {![llength $validNodes]} { return {} }
    catch {*clearmark elems 2}
    eval *createmark elems 2 {"by node id"} $validNodes
    set result [::FemAutoSeam::autoExistingShellIds [hm_getmark elems 2] $allowedComponents]
    catch {*clearmark elems 2}
    return $result
}

proc ::FemAutoSeam::autoRemeshChunks {elementIds maximumElements} {
    set ordered [lsort -integer -unique $elementIds]
    if {$maximumElements <= 0 || [llength $ordered] <= $maximumElements} { return [list $ordered] }
    set byNode [dict create]
    set remaining [dict create]
    foreach elementId $ordered {
        dict set remaining $elementId 1
        foreach nodeId [::FemAutoSeam::elemNodes $elementId] {
            dict lappend byNode $nodeId $elementId
        }
    }
    set groups {}; set seedIndex 0; set total [llength $ordered]
    while {[dict size $remaining]} {
        while {$seedIndex < $total && ![dict exists $remaining [lindex $ordered $seedIndex]]} { incr seedIndex }
        if {$seedIndex >= $total} { break }
        set seed [lindex $ordered $seedIndex]
        set queue [list $seed]; set head 0; set group {}
        dict unset remaining $seed
        while {$head < [llength $queue] && [llength $group] < $maximumElements} {
            set elementId [lindex $queue $head]; incr head
            lappend group $elementId
            foreach nodeId [::FemAutoSeam::elemNodes $elementId] {
                if {![dict exists $byNode $nodeId]} { continue }
                foreach neighbor [dict get $byNode $nodeId] {
                    if {[llength $group] + [llength $queue] - $head >= $maximumElements} { break }
                    if {![dict exists $remaining $neighbor]} { continue }
                    dict unset remaining $neighbor
                    lappend queue $neighbor
                }
            }
        }
        lappend groups [lsort -integer -unique $group]
    }
    return $groups
}

proc ::FemAutoSeam::autoChunkProtectedNodes {elementIds protectedNodeIds} {
    array set protected {}
    foreach nodeId $protectedNodeIds { set protected($nodeId) 1 }
    set result [::FemAutoSeam::autoBoundaryNodes $elementIds]
    foreach elementId $elementIds {
        foreach nodeId [::FemAutoSeam::elemNodes $elementId] {
            if {[info exists protected($nodeId)]} { lappend result $nodeId }
        }
    }
    return [lsort -integer -unique $result]
}

proc ::FemAutoSeam::runBatchElementAutomesh {elementIds protectedNodeIds elementSize featureAngle} {
    if {![llength $elementIds]} { return [dict create input_elements 0 output_elements 0 faces 0] }
    catch {*clearmark elements 1}; eval *createmark elements 1 $elementIds
    if {[llength $protectedNodeIds]} {
        catch {*clearmark nodes 2}; eval *createmark nodes 2 $protectedNodeIds
        *elementsaddnodesfixed 1 2
    }
    *setedgedensitylinkwithaspectratio -1
    *elementorder 1
    *featureangleset $featureAngle
    *setusefeatures 3
    set entered 0
    set stored 0
    set faceCount 0
    set code [catch {
        *interactiveremeshelems 1 $elementSize 2 2 1 1 2 $featureAngle
        set entered 1
        # HM creates one temporary face per connected/feature-delimited mesh
        # area. Probe consecutive face indices and mesh every valid face before
        # committing all generated elements to the database once.
        for {set faceIndex 0} {$faceIndex < [llength $elementIds]} {incr faceIndex} {
            # hm_getmeshfaceparams reports "entity not found" on both builds
            # even right after a successful *set_meshfaceparams (audit probe
            # fem_auto_seam_semantics), so it cannot be used as the loop guard.
            if {[catch {*set_meshfaceparams $faceIndex 2 2 0 0 1 0.5 1 1}]} { break }
            if {[catch {*automesh $faceIndex 2 2} meshError]} {
                if {$faceIndex == 0} { error $meshError }
                break
            }
            incr faceCount
        }
        if {$faceCount == 0} { error "HyperMesh automesh did not produce any temporary face mesh" }
        *storemeshtodatabase 1
        set stored 1
    } error options]
    if {$code && $entered && !$stored} { catch {*rejectmesh 0} }
    catch {*ameshclearsurface}
    catch {*featureangleset 60}
    catch {*setusefeatures 0}
    catch {*clearmark nodes 2}
    catch {*clearmark elements 1}
    if {$code} { return -options $options $error }
    return [dict create input_elements [llength $elementIds] faces $faceCount]
}

proc ::FemAutoSeam::validateAutoBatchResult {plans protectedNodeIds allowedComponents baselineIds baselineFailed afterIds expectedProperties} {
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        foreach expected [dict get $plan weld_elements] {
            set elementId [dict get $expected element_id]
            set actual [::FemAutoSeam::elemNodes $elementId]
            if {[lsort -integer $actual] ne [lsort -integer [dict get $expected node_ids]]} {
                error "weld shell $elementId connectivity changed during batch remesh"
            }
        }
    }
    foreach nodeId $protectedNodeIds {
        set attached [::FemAutoSeam::autoElementsForNodes [list $nodeId] $allowedComponents]
        if {![llength $attached]} { error "protected seam/boundary node $nodeId lost its mother-shell connection" }
    }
    foreach elementId $afterIds {
        set componentId [::FemAutoSeam::autoElementComponentId $elementId]
        if {![dict exists $expectedProperties $componentId]} { continue }
        set expected [dict get $expectedProperties $componentId]
        set actual [::FemAutoSeam::autoElementPropertyId $elementId]
        if {$actual != $expected} {
            error "remeshed shell $elementId property mismatch: expected=$expected actual=$actual"
        }
    }
    set failed [::FemAutoSeam::autoNativeQualityFailures $afterIds]
    set baselineCount [llength $baselineIds]
    set afterCount [llength $afterIds]
    set baselineRate [expr {$baselineCount > 0 ? [llength $baselineFailed]/double($baselineCount) : 0.0}]
    set maxAllowed 0
    foreach plan $plans {
        if {[dict exists $plan max_new_failed_elements] && [dict get $plan max_new_failed_elements] > $maxAllowed} {
            set maxAllowed [dict get $plan max_new_failed_elements]
        }
    }
    set allowedFailed [expr {int(ceil($baselineRate*$afterCount-1.0e-12))+$maxAllowed}]
    if {[llength $failed] > $allowedFailed} {
        error "batch remesh quality worsened: before=[llength $baselineFailed]/$baselineCount after=[llength $failed]/$afterCount allowed_failed=$allowedFailed ids=$failed"
    }
    return [dict create checked $afterCount failed [llength $failed]]
}

proc ::FemAutoSeam::assignAutoRemeshProperties {elementIds expectedProperties} {
    dict for {componentId propertyId} $expectedProperties {
        set propertyName ""
        foreach entityType {props properties} {
            if {![catch {set propertyName [hm_getvalue $entityType id=$propertyId dataname=name]}] && $propertyName ne ""} { break }
        }
        if {$propertyName eq ""} { error "remesh property $propertyId is missing for component $componentId" }
        set owned {}
        foreach elementId $elementIds {
            if {[::FemAutoSeam::autoElementComponentId $elementId] == $componentId} { lappend owned $elementId }
        }
        if {![llength $owned]} { continue }
        catch {*clearmark elems 1}; eval *createmark elems 1 $owned
        if {[catch {*propertyupdate elems 1 $propertyName} propertyError]} {
            catch {*clearmark elements 1}; eval *createmark elements 1 $owned
            if {[catch {*propertyupdate elements 1 $propertyName} propertyError]} {
                error "could not restore property $propertyId on remeshed component $componentId: $propertyError"
            }
        }
        catch {*clearmark elems 1}; catch {*clearmark elements 1}
    }
}

proc ::FemAutoSeam::executeAutoPlans {taskDir plans resultFem {backupSnapshot ""} {progressStart 70.0} {progressEnd 93.0}} {
    variable cfg
    set taskStarted [clock milliseconds]
    if {$backupSnapshot eq ""} {
        error "the standalone original-model backup is required for rollback"
    }
    if {![file isfile $backupSnapshot] || [file size $backupSnapshot] == 0} {
        error "original model backup is missing or empty: $backupSnapshot"
    }
    set readyPlans {}; set allowedComponents {}
    foreach plan $plans {
        if {[dict get $plan status] ne "READY"} { continue }
        lappend readyPlans $plan
        lappend allowedComponents [dict get $plan source_component_id] [dict get $plan target_component_id]
    }
    set allowedComponents [lsort -integer -unique $allowedComponents]
    set results {}; set created 0
    set code [catch {
        ::FemAutoSeam::workflowProgressUpdate $progressStart [::HWFlow::txt "正在打开修改后的 FEM 替换当前模型" "Opening the modified FEM as the new model"] "[llength $readyPlans] candidates"
        if {[file exists [file join $taskDir state cancel.flag]]} { error "cancel requested before the model was replaced" }
        ::FemAutoSeam::openAutoResultModel $resultFem
        set created [::FemAutoSeam::validateAutoModelContents $readyPlans]
        foreach plan $readyPlans { lappend results [::FemAutoSeam::executionRecord $plan CREATED [expr {[llength [dict get $plan replacement_elements]] + [llength [dict get $plan weld_elements]]}]] }
        ::FemAutoSeam::workflowProgressUpdate [expr {$progressStart + ($progressEnd - $progressStart) * 0.15}] \
            [::HWFlow::txt "正在校验新模型中的焊缝拓扑" "Verifying weld topology in the new model"] \
            [::HWFlow::txt "已校验 [llength $readyPlans] 个候选" "[llength $readyPlans] candidates verified"]
        set seedIds {}; set protectedNodeIds {}
        foreach plan $readyPlans {
            foreach element [dict get $plan replacement_elements] { lappend seedIds [dict get $element element_id] }
            foreach element [dict get $plan weld_elements] { set protectedNodeIds [concat $protectedNodeIds [dict get $element node_ids]] }
            foreach node [dict get $plan new_nodes] { lappend protectedNodeIds [dict get $node node_id] }
        }
        # Baseline quality is measured on the freshly opened model, before the
        # native remesh touches the replacement neighborhood.  Mother shells
        # no longer exist here; the replacement shells are the new seeds.
        set remeshIds [::FemAutoSeam::autoExpandElementPatch $seedIds $allowedComponents $cfg(remesh_expand_layers)]
        if {![llength $remeshIds]} { error "batch remesh selection is empty in the opened model" }
        set baselineIds $remeshIds
        set baselineFailed [::FemAutoSeam::autoNativeQualityFailures $baselineIds]
        set expectedProperties [::FemAutoSeam::autoRemeshPropertiesByComponent $remeshIds]
        set protectedNodeIds [lsort -integer -unique [concat $protectedNodeIds [::FemAutoSeam::autoBoundaryNodes $remeshIds]]]
        set remeshChunks [::FemAutoSeam::autoRemeshChunks $remeshIds $cfg(remesh_chunk_elements)]
        set remeshResult [dict create input_elements 0 faces 0 chunks [llength $remeshChunks]]
        set chunkIndex 0
        foreach chunk $remeshChunks {
            incr chunkIndex
            if {[file exists [file join $taskDir state cancel.flag]] ||
                ([llength [info commands ::HWFlow::progressCancelled]] && [::HWFlow::progressCancelled])} {
                error "cancel requested before remesh chunk $chunkIndex"
            }
            set fraction [expr {0.55+0.35*($chunkIndex-1)/double(max(1,[llength $remeshChunks]))}]
            ::FemAutoSeam::workflowProgressUpdate [expr {$progressStart+($progressEnd-$progressStart)*$fraction}] \
                [::HWFlow::txt "HyperMesh 正在分批重绘受影响网格" "HyperMesh is remeshing affected elements in bounded chunks"] \
                [::HWFlow::txt "第 $chunkIndex/[llength $remeshChunks] 批，[llength $chunk] 个单元" "Chunk $chunkIndex/[llength $remeshChunks], [llength $chunk] elements"]
            set chunkProtected [::FemAutoSeam::autoChunkProtectedNodes $chunk $protectedNodeIds]
            set chunkResult [::FemAutoSeam::runBatchElementAutomesh $chunk $chunkProtected $cfg(remesh_element_size) $cfg(remesh_feature_angle)]
            dict incr remeshResult input_elements [dict get $chunkResult input_elements]
            dict incr remeshResult faces [dict get $chunkResult faces]
            if {[llength [info commands ::HWFlow::progressPumpEvents]]} { catch {::HWFlow::progressPumpEvents 1} }
        }
        set afterSeeds [::FemAutoSeam::autoElementsForNodes $protectedNodeIds $allowedComponents]
        set afterIds [::FemAutoSeam::autoExpandElementPatch $afterSeeds $allowedComponents $cfg(remesh_expand_layers)]
        ::FemAutoSeam::assignAutoRemeshProperties $afterIds $expectedProperties
        set quality [::FemAutoSeam::validateAutoBatchResult $readyPlans $protectedNodeIds $allowedComponents $baselineIds $baselineFailed $afterIds $expectedProperties]
    } error options]
    if {$code} {
        catch {*ameshclearsurface}; catch {*setusefeatures 0}
        if {[catch {::FemAutoSeam::restoreAutoSnapshot $backupSnapshot} restoreError]} {
            error "batch creation/remesh failed: $error; task restore failed: $restoreError"
        }
        return -options $options "batch creation/remesh failed and the task was restored: $error"
    }
    catch {::HWFlow::refreshBrowser}
    set totalSeconds [expr {([clock milliseconds]-$taskStarted)/1000.0}]
    set performance [dict create total_seconds $totalSeconds batch_automesh_chunks [dict get $remeshResult chunks] batch_automesh_faces [dict get $remeshResult faces] quality_checked [dict get $quality checked] quality_failed [dict get $quality failed]]
    return [dict create created $created succeeded [llength $readyPlans] rolled_back 0 moved_nodes 0 remeshed_elements [dict get $remeshResult input_elements] results $results snapshot $backupSnapshot performance $performance]
}
