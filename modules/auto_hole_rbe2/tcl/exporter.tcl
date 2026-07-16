proc ::AutoHoleRBE2::hybridSurfaceElementType {nodes elementId} {
    switch -- [llength $nodes] {
        3 { return CTRIA3 }
        4 { return CQUAD4 }
    }
    error "Unsupported free-face connectivity for element $elementId: [llength $nodes] nodes"
}

proc ::AutoHoleRBE2::hybridComponentName {componentId} {
    if {![catch {set value [hm_getvalue comps id=$componentId dataname=name]}] && $value ne ""} { return $value }
    return "COMP_$componentId"
}

proc ::AutoHoleRBE2::writeHybridRequest {taskDir runId} {
    variable cfg; variable ui
    set settings [list]
    foreach key {featureAngleDeg loopNormalTolDeg cylFitTol loopRadiusTol minWallNodes minLoopNodes minRadius maxRadius innerNormalMaxDot eps} {
        lappend settings "    [::HybridCore::jsonString $key]: [::HybridCore::jsonNumber $cfg($key)]"
    }
    lappend settings "    \"requireInnerNormal\": [::HybridCore::jsonBool $cfg(requireInnerNormal)]"
    lappend settings "    \"rigidType\": [::HybridCore::jsonString $cfg(rigidType)]"
    lappend settings "    \"dof\": [::HybridCore::jsonString $cfg(dof)]"
    lappend settings "    \"outputComponentName\": [::HybridCore::jsonString $cfg(resultCompName)]"
    set modelState [::HybridCore::incrementalModelStateJson]
    set json "{\n  \"schema_version\": \"1.0\",\n  \"module\": \"auto_hole_rbe2\",\n  \"run_id\": [::HybridCore::jsonString $runId],\n  \"hypermesh_version\": \"2019\",\n  \"selected_component_ids\": [::HybridCore::jsonIntArray $ui(selectedComps)],\n  \"settings\": {\n[join $settings ,\n]\n  },\n$modelState,\n  \"options\": {\"debug\": false, \"keep_runtime_files\": true}\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir request.json] $json]
}

proc ::AutoHoleRBE2::validFaceNodes {nodes} {
    set count [llength $nodes]
    if {$count < 3 || $count > 4} { return 0 }
    foreach nodeId $nodes {
        if {![string is integer -strict $nodeId] || $nodeId <= 0} { return 0 }
    }
    return 1
}

proc ::AutoHoleRBE2::bulkFaceNodeMap {faceElements} {
    set result [dict create]
    if {[llength $faceElements] == 0} { return $result }

    catch {*clearmark elems 2}
    if {![catch {eval *createmark elems 2 $faceElements}]} {
        set markedElements {}
        catch {set markedElements [hm_getmark elems 2]}
        set bulkNodes {}
        if {![catch {set bulkNodes [hm_getvalue elems mark=2 dataname=nodes]}]} {
            if {[llength $markedElements] == 1 && [::AutoHoleRBE2::validFaceNodes $bulkNodes]} {
                dict set result [lindex $markedElements 0] [::AutoHoleRBE2::uniq $bulkNodes]
            } elseif {[llength $bulkNodes] == [llength $markedElements]} {
                foreach elementId $markedElements nodes $bulkNodes {
                    set nodes [::AutoHoleRBE2::uniq $nodes]
                    if {[::AutoHoleRBE2::validFaceNodes $nodes]} { dict set result $elementId $nodes }
                }
            }
        }
    }
    catch {*clearmark elems 2}
    set bulkCount [dict size $result]

    set total [llength $faceElements]
    set index 0
    foreach elementId $faceElements {
        incr index
        if {[dict exists $result $elementId]} { continue }
        set nodes {}
        if {[catch {set nodes [hm_nodelist $elementId]}] || ![::AutoHoleRBE2::validFaceNodes [::AutoHoleRBE2::uniq $nodes]]} {
            catch {set nodes [hm_getvalue elems id=$elementId dataname=nodes]}
        }
        set nodes [::AutoHoleRBE2::uniq $nodes]
        if {[::AutoHoleRBE2::validFaceNodes $nodes]} { dict set result $elementId $nodes }
        if {$index % 500 == 0} {
            ::HybridCore::progressUpdate 12.0 "Solid Through-Hole RIGIDS" "Reading free-face connectivity $index/$total" 1
        }
    }
    ::HybridCore::log INFO "surface connectivity faces=[llength $faceElements] bulk=$bulkCount fallback=[expr {[dict size $result]-$bulkCount}]"
    return $result
}

proc ::AutoHoleRBE2::validCoordinates {coordinates} {
    if {[llength $coordinates] < 3} { return 0 }
    foreach value [lrange $coordinates 0 2] {
        if {![string is double -strict $value]} { return 0 }
    }
    return 1
}

proc ::AutoHoleRBE2::bulkNodeCoordinateMap {nodeIds} {
    set result [dict create]
    if {[llength $nodeIds] == 0} { return $result }

    catch {*clearmark nodes 2}
    if {![catch {eval *createmark nodes 2 $nodeIds}]} {
        set markedNodes {}
        catch {set markedNodes [hm_getmark nodes 2]}
        set bulkCoordinates {}
        if {![catch {set bulkCoordinates [hm_getvalue nodes mark=2 dataname=coordinates]}]} {
            set nodeCount [llength $markedNodes]
            if {$nodeCount == 1 && [::AutoHoleRBE2::validCoordinates $bulkCoordinates]} {
                dict set result [lindex $markedNodes 0] [lrange $bulkCoordinates 0 2]
            } elseif {[llength $bulkCoordinates] == $nodeCount} {
                foreach nodeId $markedNodes coordinates $bulkCoordinates {
                    if {[::AutoHoleRBE2::validCoordinates $coordinates]} {
                        dict set result $nodeId [lrange $coordinates 0 2]
                    }
                }
            } elseif {[llength $bulkCoordinates] == 3*$nodeCount} {
                set coordinateIndex 0
                foreach nodeId $markedNodes {
                    set coordinates [lrange $bulkCoordinates $coordinateIndex [expr {$coordinateIndex+2}]]
                    if {[::AutoHoleRBE2::validCoordinates $coordinates]} { dict set result $nodeId $coordinates }
                    incr coordinateIndex 3
                }
            }
        }
    }
    catch {*clearmark nodes 2}
    set bulkCount [dict size $result]

    set total [llength $nodeIds]
    set index 0
    foreach nodeId $nodeIds {
        incr index
        if {![dict exists $result $nodeId]} { dict set result $nodeId [::AutoHoleRBE2::nodeXYZ $nodeId] }
        if {$index % 1000 == 0} {
            ::HybridCore::progressUpdate 16.0 "Solid Through-Hole RIGIDS" "Reading free-face coordinates $index/$total" 1
        }
    }
    ::HybridCore::log INFO "surface coordinates nodes=[llength $nodeIds] bulk=$bulkCount fallback=[expr {[dict size $result]-$bulkCount}]"
    return $result
}

proc ::AutoHoleRBE2::collectHybridSurfaceFaces {} {
    variable cfg; variable ui; variable stat
    set components $ui(selectedComps)
    if {[llength $components] == 0} { error "No solid components selected" }

    # Surface-only mode deliberately avoids materializing every source-solid
    # element ID merely for a count; *findfaces validates the selected scope.
    set stat(sourceElems) [::HWFlow::txt "未扫描（仅表面）" "not scanned (surface-only)"]

    array set oldFace {}
    if {$cfg(preDeleteOldFaces)} {
        ::AutoHoleRBE2::deleteComponentByName $cfg(faceCompName)
    } else {
        set oldFaceComp [::AutoHoleRBE2::componentIdByName $cfg(faceCompName)]
        if {$oldFaceComp ne ""} {
            foreach elementId [::AutoHoleRBE2::getElemsByComp $oldFaceComp] { set oldFace($elementId) 1 }
        }
    }

    ::AutoHoleRBE2::message [::HWFlow::txt "正在生成并读取自由面节点..." "Generating free faces and caching face node IDs..."]
    ::AutoHoleRBE2::clearMarks
    eval *createmark comps 1 $components
    set findFacesStarted [clock milliseconds]
    if {[catch {*findfaces components 1} faceErr]} {
        error "Failed to create free faces: $faceErr"
    }
    ::HybridCore::log INFO "surface generation milliseconds=[expr {[clock milliseconds]-$findFacesStarted}]"
    set faceCompId [::AutoHoleRBE2::componentIdByName $cfg(faceCompName)]
    if {$faceCompId eq ""} { error "The free-face component $cfg(faceCompName) was not created" }

    set faceElements [::AutoHoleRBE2::getElemsByComp $faceCompId]
    set newFaceElements {}
    foreach elementId $faceElements {
        if {![info exists oldFace($elementId)]} { lappend newFaceElements $elementId }
    }
    set faceNodeMap [::AutoHoleRBE2::bulkFaceNodeMap $newFaceElements]
    set records {}
    set surfaceComponentId [lindex $components 0]
    foreach elementId $newFaceElements {
        if {![dict exists $faceNodeMap $elementId]} { continue }
        set nodes [dict get $faceNodeMap $elementId]
        lappend records [dict create \
            element_id $elementId \
            component_id $surfaceComponentId \
            element_type [::AutoHoleRBE2::hybridSurfaceElementType $nodes $elementId] \
            node_ids $nodes]
    }
    set stat(freeFaces) [llength $newFaceElements]
    set stat(validFaces) [llength $records]
    if {$stat(validFaces) == 0} { error "No usable free-face node IDs were collected" }

    if {$cfg(deleteTempFaces)} { ::AutoHoleRBE2::deleteComponentByName $cfg(faceCompName) }
    ::AutoHoleRBE2::clearMarks
    return $records
}

proc ::AutoHoleRBE2::writeHybridMesh {taskDir faceRecords} {
    variable ui
    set componentRecords {}; set elementRecords {}
    array set seenNode {}
    foreach componentId $ui(selectedComps) {
        lappend componentRecords [dict create \
            component_id $componentId \
            component_name [::AutoHoleRBE2::hybridComponentName $componentId] \
            mesh_class SOLID]
    }
    foreach record $faceRecords {
        set nodes [dict get $record node_ids]
        foreach nodeId $nodes { set seenNode($nodeId) 1 }
        lappend elementRecords $record
    }
    set nodeRecords {}
    set uniqueNodes [lsort -integer [array names seenNode]]
    set coordinateMap [::AutoHoleRBE2::bulkNodeCoordinateMap $uniqueNodes]
    foreach nodeId $uniqueNodes {
        set xyz [dict get $coordinateMap $nodeId]
        lappend nodeRecords [list $nodeId [lindex $xyz 0] [lindex $xyz 1] [lindex $xyz 2]]
    }
    ::HybridCore::log INFO "binary mesh export components=[llength $componentRecords] elements=[llength $elementRecords] nodes=[llength $nodeRecords]"
    return [::HybridCore::writeBinaryMesh [file join $taskDir mesh.hmwf] \
        $componentRecords $nodeRecords $elementRecords]
}

proc ::AutoHoleRBE2::writeHybridExisting {taskDir} {
    variable cfg
    set rows {}
    set componentId [::AutoHoleRBE2::componentIdByName $cfg(resultCompName)]
    if {$componentId ne ""} {
        foreach elementId [::AutoHoleRBE2::getElemsByComp $componentId] {
            if {![::AutoHoleRBE2::elemLooksLikeRBE2 $elementId]} { continue }
            set center [::AutoHoleRBE2::rigidCenterNode $elementId]
            set nodes [::AutoHoleRBE2::uniq [::AutoHoleRBE2::elemNodes $elementId]]
            set dependent {}
            foreach nodeId $nodes { if {$nodeId != $center} { lappend dependent $nodeId } }
            lappend rows "    {\"element_id\": $elementId, \"independent_node_id\": $center, \"dependent_node_ids\": [::HybridCore::jsonIntArray [lsort -integer -unique $dependent]], \"component_id\": $componentId}"
        }
    }
    set json "{\n  \"schema_version\": \"1.0\",\n  \"rbe2\": \[\n[join $rows ,\n]\n  \]\n}\n"
    return [::HybridCore::writeTextFile [file join $taskDir existing_entities.json] $json]
}

proc ::AutoHoleRBE2::exportHybridInputs {taskDir runId} {
    set faceRecords [::AutoHoleRBE2::collectHybridSurfaceFaces]
    set request [::AutoHoleRBE2::writeHybridRequest $taskDir $runId]
    set mesh [::AutoHoleRBE2::writeHybridMesh $taskDir $faceRecords]
    set existing [::AutoHoleRBE2::writeHybridExisting $taskDir]
    return [dict create request $request mesh $mesh existing $existing delta [file join $taskDir rigid_import.fem]]
}
