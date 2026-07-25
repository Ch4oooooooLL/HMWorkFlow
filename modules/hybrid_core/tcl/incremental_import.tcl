proc ::HybridCore::existingEntityIds {entityTypes ids} {
    set found {}
    foreach id $ids {
        foreach entityType $entityTypes {
            set value ""
            if {![catch {set value [hm_getvalue $entityType id=$id dataname=id]}] && $value ne "" && $value != 0} {
                lappend found $id
                break
            }
        }
    }
    return [lsort -integer -unique $found]
}

proc ::HybridCore::cleanupIncrementalEntities {elementIds nodeIds componentIds {propertyIds {}} {materialIds {}}} {
    foreach spec [list \
        [list elems $elementIds] [list nodes $nodeIds] [list comps $componentIds] \
        [list props $propertyIds] [list mats $materialIds]] {
        set entityType [lindex $spec 0]
        set ids [lindex $spec 1]
        if {[llength $ids] == 0} { continue }
        catch {*clearmark $entityType 1}
        if {![catch {eval *createmark $entityType 1 $ids}]} {
            catch {*deletemark $entityType 1}
        }
        catch {*clearmark $entityType 1}
    }
}

proc ::HybridCore::nodeCoordinates {nodeId} {
    set xyz ""
    catch {set xyz [hm_getvalue nodes id=$nodeId dataname=coordinates]}
    if {[llength $xyz] >= 3} { return [lrange $xyz 0 2] }
    set xyz {}
    foreach field {x y z} {
        set value ""
        if {[catch {set value [hm_getvalue nodes id=$nodeId dataname=$field]}]} { return {} }
        lappend xyz $value
    }
    return $xyz
}

proc ::HybridCore::coordinatesMatch {actual expected {tolerance 1.0e-7}} {
    if {[llength $actual] < 3 || [llength $expected] < 3} { return 0 }
    for {set index 0} {$index < 3} {incr index} {
        set av [lindex $actual $index]
        set ev [lindex $expected $index]
        if {![string is double -strict $av] || ![string is double -strict $ev]} { return 0 }
        set scale [expr {max(1.0, abs(double($ev)))}]
        if {abs(double($av)-double($ev)) > $tolerance*$scale} { return 0 }
    }
    return 1
}

proc ::HybridCore::callEntityResolver {resolver entityId} {
    return [uplevel #0 [concat $resolver [list $entityId]]]
}

proc ::HybridCore::verifyRigidManifest {expectedRigids centerResolver nodesResolver} {
    set verified 0
    set failures {}
    foreach row $expectedRigids {
        set elementId [dict get $row element_id]
        set nodeId [dict get $row independent_node_id]
        if {[llength [::HybridCore::existingEntityIds {elems elements} [list $elementId]]] == 0} {
            lappend failures "element=$elementId missing"
            continue
        }
        if {[llength [::HybridCore::existingEntityIds {nodes} [list $nodeId]]] == 0} {
            lappend failures "node=$nodeId missing"
            continue
        }
        set actualCenter ""
        catch {set actualCenter [::HybridCore::callEntityResolver $centerResolver $elementId]}
        if {$actualCenter ne $nodeId} {
            lappend failures "element=$elementId center_expected=$nodeId center_actual=$actualCenter"
            continue
        }
        set actualNodes {}
        catch {set actualNodes [::HybridCore::callEntityResolver $nodesResolver $elementId]}
        set actualDependent {}
        foreach value $actualNodes { if {$value != $nodeId} { lappend actualDependent $value } }
        set expectedDependent [lsort -integer -unique [dict get $row dependent_node_ids]]
        if {[lsort -integer -unique $actualDependent] ne $expectedDependent} {
            lappend failures "element=$elementId dependent_expected={$expectedDependent} dependent_actual={[lsort -integer -unique $actualDependent]}"
            continue
        }
        set actualCoordinates [::HybridCore::nodeCoordinates $nodeId]
        if {![::HybridCore::coordinatesMatch $actualCoordinates [dict get $row center]]} {
            lappend failures "node=$nodeId coordinate_expected={[dict get $row center]} coordinate_actual={$actualCoordinates}"
            continue
        }
        set actualComponent ""
        catch {set actualComponent [hm_getvalue elems id=$elementId dataname=collector.id]}
        if {$actualComponent ne "" && $actualComponent != [dict get $row component_id]} {
            lappend failures "element=$elementId component_expected=[dict get $row component_id] component_actual=$actualComponent"
            continue
        }
        incr verified
    }
    if {[llength $failures] > 0} { error "rigid verification failed: [join $failures {; }]" }
    return $verified
}

proc ::HybridCore::allComponentIds {} {
    foreach entityType {comps components} {
        catch {*clearmark $entityType 2}
        if {![catch {*createmark $entityType 2 all}] && ![catch {set ids [hm_getmark $entityType 2]}]} {
            catch {*clearmark $entityType 2}
            return [lsort -integer -unique $ids]
        }
        catch {*clearmark $entityType 2}
    }
    return {}
}

proc ::HybridCore::componentName {componentId} {
    foreach entityType {comps components} {
        set value ""
        if {![catch {set value [hm_getvalue $entityType id=$componentId dataname=name]}] && $value ne ""} {
            return $value
        }
    }
    return ""
}

proc ::HybridCore::moveIdsToComponent {entityTypes ids componentName} {
    if {[llength $ids] == 0} { return }
    foreach entityType $entityTypes {
        catch {*clearmark $entityType 1}
        if {[catch {eval *createmark $entityType 1 $ids}]} { continue }
        if {![catch {*movemark $entityType 1 $componentName}]} {
            catch {*clearmark $entityType 1}
            return
        }
    }
    error "could not move [llength $ids] entities to component $componentName"
}

proc ::HybridCore::organizeRigidManifest {expectedRigids} {
    set byComponent {}
    foreach row $expectedRigids {
        set componentId [dict get $row component_id]
        set elementIds {}
        if {[dict exists $byComponent $componentId]} {
            set elementIds [dict get $byComponent $componentId]
        }
        lappend elementIds [dict get $row element_id]
        dict set byComponent $componentId $elementIds
    }
    foreach componentId [dict keys $byComponent] {
        set componentName [::HybridCore::componentName $componentId]
        if {$componentName eq ""} { error "expected output component $componentId is missing after import" }
        ::HybridCore::moveIdsToComponent {elems elements} [dict get $byComponent $componentId] $componentName
    }
}

proc ::HybridCore::componentEntityCount {componentId entityType} {
    set componentName [::HybridCore::componentName $componentId]
    if {$componentName eq ""} { return 0 }
    foreach componentType {comps components} {
        set value ""
        if {![catch {set value [hm_entityincollector $componentType $componentId $entityType 0 0 -byid]}] &&
            [string is integer -strict $value]} { return $value }
    }
    return -1
}

proc ::HybridCore::deleteEmptyNewComponents {beforeIds expectedIds} {
    set deleted {}
    foreach componentId [::HybridCore::allComponentIds] {
        if {$componentId in $beforeIds || $componentId in $expectedIds} { continue }
        set elementCount [::HybridCore::componentEntityCount $componentId elems]
        # HM2019 nodes are not component-owned and querying a component's node
        # count returns an unsupported value.  Incremental decks handled here
        # contain only nodes and elements, so an element-empty unexpected
        # component is safe to remove.
        if {$elementCount != 0} { continue }
        foreach entityType {comps components} {
            catch {*clearmark $entityType 2}
            if {![catch {*createmark $entityType 2 $componentId}] && ![catch {*deletemark $entityType 2}]} {
                lappend deleted $componentId
                break
            }
        }
    }
    return $deleted
}

proc ::HybridCore::importRigidDelta {title summary centerResolver nodesResolver {progressStart 70.0} {progressEnd 96.0}} {
    set incrementalFem [dict get $summary incremental_fem]
    set elementIds [dict get $summary created_element_ids]
    set nodeIds [dict get $summary created_node_ids]
    set componentIds [dict get $summary created_component_ids]
    set expectedRigids [dict get $summary expected_rigids]
    if {[llength $elementIds] == 0} {
        return [dict create created 0 incremental_fem $incrementalFem]
    }
    if {![file isfile $incrementalFem]} { error "incremental FEM does not exist: $incrementalFem" }
    set occupiedElements [::HybridCore::existingEntityIds {elems elements} $elementIds]
    set occupiedNodes [::HybridCore::existingEntityIds {nodes} $nodeIds]
    set occupiedComponents [::HybridCore::existingEntityIds {comps components} $componentIds]
    if {[llength $occupiedElements] || [llength $occupiedNodes] || [llength $occupiedComponents]} {
        error "incremental IDs are already occupied: elements={$occupiedElements} nodes={$occupiedNodes} components={$occupiedComponents}"
    }
    set componentsBeforeImport [::HybridCore::allComponentIds]
    foreach row $expectedRigids {
        foreach dependentNode [dict get $row dependent_node_ids] {
            if {[llength [::HybridCore::existingEntityIds {nodes} [list $dependentNode]]] == 0} {
                error "dependent GRID $dependentNode is missing before incremental import"
            }
        }
    }

    set reader "#optistruct/optistruct"
    ::HybridCore::progressUpdate $progressStart $title "Importing incremental RIGIDS FEM..." 1
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    set code [catch {
        ::HWFlow::runHyperMeshIo import [list *feinputwithdata2 $reader \
            [file nativename $incrementalFem] 0 0 0 0 0 1 2 1 0]
    } importError importOptions]
    if {$code} {
        ::HybridCore::cleanupIncrementalEntities $elementIds $nodeIds $componentIds
        error "incremental import failed: fem={$incrementalFem} reader=$reader hm_error={$importError} options={$importOptions}"
    }
    if {[catch {::HybridCore::organizeRigidManifest $expectedRigids} organizeError]} {
        set newComponents {}
        foreach componentId [::HybridCore::allComponentIds] {
            if {$componentId ni $componentsBeforeImport} { lappend newComponents $componentId }
        }
        ::HybridCore::cleanupIncrementalEntities $elementIds $nodeIds [concat $componentIds $newComponents]
        error "incremental import organization failed: $organizeError"
    }
    if {[catch {set created [::HybridCore::verifyRigidManifest $expectedRigids $centerResolver $nodesResolver]} verifyError]} {
        set newComponents {}
        foreach componentId [::HybridCore::allComponentIds] {
            if {$componentId ni $componentsBeforeImport} { lappend newComponents $componentId }
        }
        ::HybridCore::cleanupIncrementalEntities $elementIds $nodeIds [concat $componentIds $newComponents]
        error "incremental import verification failed: $verifyError"
    }
    set deletedEmptyComponents [::HybridCore::deleteEmptyNewComponents $componentsBeforeImport $componentIds]
    ::HybridCore::log INFO "incremental RIGIDS import verified created=$created elements_organized=1 center_nodes_verified=1 empty_components_deleted={$deletedEmptyComponents}"
    ::HybridCore::progressUpdate $progressEnd $title "Incremental RIGIDS import verified: $created." 1
    return [dict create created $created incremental_fem $incrementalFem]
}
