proc ::RB2Bolt::incrementalImportError {stage incrementalFem reader detail expected detected} {
    return "INCREMENTAL_IMPORT_FAILED stage=$stage incremental_fem=[file nativename $incrementalFem] reader=$reader expected_element_ids={$expected} detected_element_ids={$detected} detail={$detail} hint={Run one manual OptiStruct Solver Deck import in HM2019 and compare command.tcl import_reader/options. The source selection FEM and incremental FEM are retained in the task workspace.}"
}

proc ::RB2Bolt::existingExpectedElements {expectedIds} {
    set found {}
    foreach eid $expectedIds {
        set value ""
        if {![catch {set value [hm_getvalue elems id=$eid dataname=id]}] && $value ne "" && $value != 0} {
            lappend found $eid
        }
    }
    return [lsort -integer -unique $found]
}

proc ::RB2Bolt::verifyImportedSegments {segments incrementalFem reader} {
    set expected_element_ids {}
    foreach row $segments { lappend expected_element_ids [dict get $row element_id] }
    set detected [::RB2Bolt::existingExpectedElements $expected_element_ids]
    set missing {}
    set wrong {}
    foreach row $segments {
        set eid [dict get $row element_id]
        if {$eid ni $detected} { lappend missing $eid; continue }
        set actual {}
        catch {set actual [hm_getvalue elems id=$eid dataname=nodes]}
        set expected [lsort -integer [list [dict get $row node_1] [dict get $row node_2]]]
        if {[llength $actual] != 2 || [lsort -integer $actual] ne $expected} {
            lappend wrong "$eid:expected=$expected,actual=$actual"
            continue
        }
        set actualComponent ""
        catch {set actualComponent [hm_getvalue elems id=$eid dataname=collector.id]}
        if {$actualComponent ne "" && $actualComponent != [dict get $row component_id]} {
            lappend wrong "$eid:component_expected=[dict get $row component_id],component_actual=$actualComponent"
        }
    }
    if {[llength $missing] > 0 || [llength $wrong] > 0} {
        error [::RB2Bolt::incrementalImportError verify $incrementalFem $reader "missing={$missing}; endpoint_mismatch={$wrong}" $expected_element_ids $detected]
    }
    return [llength $detected]
}

proc ::RB2Bolt::organizeImportedSegments {segments} {
    set byComponent {}
    foreach row $segments {
        dict lappend byComponent [dict get $row component_id] [dict get $row element_id]
    }
    foreach componentId [dict keys $byComponent] {
        set componentName [::HybridCore::componentName $componentId]
        if {$componentName eq ""} { error "expected CBEAM output component $componentId is missing after import" }
        ::HybridCore::moveIdsToComponent {elems elements} [dict get $byComponent $componentId] $componentName
    }
}

proc ::RB2Bolt::allBeamSectionIds {} {
    foreach entityType {beamsects beamsections} {
        catch {*clearmark $entityType 2}
        if {![catch {*createmark $entityType 2 all}] && ![catch {set ids [hm_getmark $entityType 2]}]} {
            catch {*clearmark $entityType 2}
            return [lsort -integer -unique $ids]
        }
        catch {*clearmark $entityType 2}
    }
    return {}
}

proc ::RB2Bolt::deleteBeamSections {ids} {
    if {[llength $ids] == 0} {return}
    foreach entityType {beamsects beamsections} {
        catch {*clearmark $entityType 1}
        if {![catch {eval *createmark $entityType 1 $ids}] && ![catch {*deletemark $entityType 1}]} {
            catch {*clearmark $entityType 1}
            return
        }
        catch {*clearmark $entityType 1}
    }
}

proc ::RB2Bolt::cleanupIncrementalBoltImport {summary componentsBeforeImport {beamSectionIds {}}} {
    set componentIds [dict get $summary created_component_ids]
    foreach componentId [::HybridCore::allComponentIds] {
        if {$componentId ni $componentsBeforeImport && $componentId ni $componentIds} {
            lappend componentIds $componentId
        }
    }
    ::HybridCore::cleanupIncrementalEntities \
        [dict get $summary created_element_ids] \
        [dict get $summary temporary_node_ids] \
        $componentIds \
        [dict get $summary created_property_ids] \
        [dict get $summary created_material_ids]
    ::RB2Bolt::deleteBeamSections $beamSectionIds
    ::HybridCore::log WARN "incremental CBEAM import rolled back elements=[llength [dict get $summary created_element_ids]] nodes=[llength [dict get $summary temporary_node_ids]] components={$componentIds} properties={[dict get $summary created_property_ids]} materials={[dict get $summary created_material_ids]}"
}

proc ::RB2Bolt::configureImportedBoltAssignments {summary} {
    if {![dict exists $summary property_assignments]} {
        return [dict create assignments 0 solid_circle_sections 0 created_beam_section_ids {}]
    }
    set configured 0
    set solidCircles 0
    set createdBeamSections {}
    foreach row [dict get $summary property_assignments] {
        set componentId [dict get $row component_id]
        set propertyId [dict get $row property_id]
        set propertyName [dict get $row property_name]
        set propertyCard [dict get $row property_card]
        set elementIds [dict get $row element_ids]

        if {[dict exists $row create_solid_circle] && [dict get $row create_solid_circle]} {
            set sectionName [dict get $row beam_section_name]
            set existingSection [::RB2Bolt::entityIdByName {beamsects beamsections} $sectionName]
            set sectionInfo [::RB2Bolt::ensureCircleBeamSection [dict get $row diameter]]
            set sectionId [lindex $sectionInfo 1]
            if {$existingSection eq ""} {lappend createdBeamSections $sectionId}
            if {![::RB2Bolt::linkBeamSectionToProperty $propertyId $propertyName $propertyCard $sectionId]} {
                error "could not link Solid Circle beam section $sectionId to property $propertyName"
            }
            incr solidCircles
        }

        if {![::RB2Bolt::assignPropertyToComponent $componentId $propertyId $propertyName]} {
            error "could not assign property $propertyName to component $componentId"
        }
        catch {*clearmark elems 1}
        if {[catch {eval *createmark elems 1 $elementIds}] || [catch {*propertyupdate elems 1 $propertyName}]} {
            catch {*clearmark elems 1}
            error "could not assign property $propertyName to [llength $elementIds] CBEAM elements"
        }
        catch {*clearmark elems 1}
        if {![::RB2Bolt::entityHasProperty comps $componentId $propertyId $propertyName]} {
            error "component $componentId property verification failed expected=$propertyId"
        }
        foreach elementId $elementIds {
            if {![::RB2Bolt::entityHasProperty elems $elementId $propertyId $propertyName]} {
                error "CBEAM $elementId property verification failed expected=$propertyId"
            }
        }
        incr configured
    }
    return [dict create assignments $configured solid_circle_sections $solidCircles \
        created_beam_section_ids [lsort -integer -unique $createdBeamSections]]
}

proc ::RB2Bolt::replaceImportedEndpointProxies {replacements incrementalFem reader expectedElementIds {tolerance 1.0e-8}} {
    # Compatibility path for result manifests created before direct GRID reuse.
    # Keep this pairwise: HM2019 *equivalence can retain the proxy and remove the
    # original RBE2 center even when low-number retention is requested.
    set replaced 0
    foreach row $replacements {
        set temporaryNode [dict get $row temporary_node_id]
        set existingNode [dict get $row existing_node_id]
        if {![::RB2Bolt::replaceOneNode $temporaryNode $existingNode]} {
            error [::RB2Bolt::incrementalImportError reconnect $incrementalFem $reader \
                "could not replace temporary GRID $temporaryNode with existing GRID $existingNode" $expectedElementIds {}]
        }
        incr replaced
    }
    return [dict create replaced $replaced bulk_replaced 0 fallback_replaced $replaced]
}

proc ::RB2Bolt::verifyEndpointCoordinates {segments tolerance incrementalFem reader expectedElementIds} {
    foreach row $segments {
        foreach pair {{node_1 node_1_coordinates} {node_2 node_2_coordinates}} {
            lassign $pair nodeKey coordinateKey
            if {![dict exists $row $coordinateKey]} {continue}
            set nodeId [dict get $row $nodeKey]
            set actual {}
            set err ""
            if {[catch {set actual [hm_getvalue nodes id=$nodeId dataname=coordinates]} err] || [llength $actual] != 3} {
                error [::RB2Bolt::incrementalImportError preflight $incrementalFem $reader \
                    "could not read endpoint GRID $nodeId coordinates; hm_error=$err" $expectedElementIds {}]
            }
            set expected [dict get $row $coordinateKey]
            for {set index 0} {$index < 3} {incr index} {
                if {abs(double([lindex $actual $index])-double([lindex $expected $index])) > $tolerance} {
                    error [::RB2Bolt::incrementalImportError preflight $incrementalFem $reader \
                        "endpoint GRID $nodeId coordinates changed current={$actual} python_snapshot={$expected}" $expectedElementIds {}]
                }
            }
        }
    }
}

proc ::RB2Bolt::importIncrementalFem {payload {progressStart 65.0} {progressEnd 96.0}} {
    variable P
    set summary [dict get $payload summary]
    set incrementalFem [dict get $summary incremental_fem]
    set segments [dict get $summary expected_segments]
    set replacements [dict get $summary endpoint_replacements]
    set reuseExistingNodeIds [expr {[dict exists $summary reuse_existing_node_ids] && [dict get $summary reuse_existing_node_ids]}]
    set coordinateTolerance 1.0e-7
    if {[dict exists $summary endpoint_coordinate_tolerance]} {set coordinateTolerance [dict get $summary endpoint_coordinate_tolerance]}
    set expected_element_ids [dict get $summary created_element_ids]
    set temporary_node_ids [dict get $summary temporary_node_ids]
    set pairCount [dict get $summary pair_count]
    set existing [expr {$pairCount - [dict get $summary planned_create_count]}]
    if {$P(dryRun) || [llength $expected_element_ids] == 0} {
        return [dict create created 0 skipped 0 skipped_existing $existing pair_count $pairCount incremental_fem $incrementalFem]
    }
    if {![file isfile $incrementalFem]} {
        error [::RB2Bolt::incrementalImportError preflight $incrementalFem "#optistruct/optistruct" "incremental FEM does not exist" $expected_element_ids {}]
    }
    set occupied [::RB2Bolt::existingExpectedElements $expected_element_ids]
    if {[llength $occupied] > 0} {
        error [::RB2Bolt::incrementalImportError preflight $incrementalFem "#optistruct/optistruct" "generated element IDs already exist before import" $expected_element_ids $occupied]
    }
    set occupiedTemporaryNodes [::HybridCore::existingEntityIds {nodes} $temporary_node_ids]
    if {[llength $occupiedTemporaryNodes] > 0} {
        error [::RB2Bolt::incrementalImportError preflight $incrementalFem "#optistruct/optistruct" \
            "temporary GRID IDs already exist before import: $occupiedTemporaryNodes" $expected_element_ids {}]
    }
    foreach row $segments {
        foreach key {node_1 node_2} {
            set nid [dict get $row $key]
            set value ""
            if {[catch {set value [hm_getvalue nodes id=$nid dataname=id]} err] || $value eq "" || ([string is double -strict $value] && $value == 0)} {
                error [::RB2Bolt::incrementalImportError preflight $incrementalFem "#optistruct/optistruct" "endpoint GRID $nid is missing in current model; hm_error=$err" $expected_element_ids {}]
            }
        }
    }
    if {$reuseExistingNodeIds} {
        ::RB2Bolt::verifyEndpointCoordinates $segments $coordinateTolerance $incrementalFem "#optistruct/optistruct" $expected_element_ids
    }
    set componentsBeforeImport [::HybridCore::allComponentIds]

    set reader "#optistruct/optistruct"
    set overwriteFlag [expr {$reuseExistingNodeIds ? 1 : 0}]
    set importCommand "*feinputwithdata2 $reader <incremental_fem> $overwriteFlag 0 0 0 0 1 2 1 0"
    ::HybridCore::log INFO "incremental CBEAM import start pairs=$pairCount elements=[llength $expected_element_ids] reuse_existing_nodes=$reuseExistingNodeIds endpoint_proxies=[llength $temporary_node_ids] fem={$incrementalFem}"
    ::HybridCore::progressUpdate $progressStart "RBE2 Bolt Connector" "Importing incremental FEM into the current HyperMesh session..." 1
    *createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "
    set code [catch {
        if {$reuseExistingNodeIds} {
            *feinputwithdata2 $reader [file nativename $incrementalFem] 1 0 0 0 0 1 2 1 0
        } else {
            *feinputwithdata2 $reader [file nativename $incrementalFem] 0 0 0 0 0 1 2 1 0
        }
    } importError importOptions]
    if {$code} {
        set detected [::RB2Bolt::existingExpectedElements $expected_element_ids]
        set detail "command={$importCommand}; hm_error={$importError}; error_options={$importOptions}"
        ::RB2Bolt::cleanupIncrementalBoltImport $summary $componentsBeforeImport
        error [::RB2Bolt::incrementalImportError import $incrementalFem $reader $detail $expected_element_ids $detected]
    }
    ::HybridCore::log INFO "incremental CBEAM FEM imported elements=[llength $expected_element_ids] endpoint_proxies=[llength $temporary_node_ids]"
    if {[catch {::RB2Bolt::organizeImportedSegments $segments} organizeError]} {
        ::RB2Bolt::cleanupIncrementalBoltImport $summary $componentsBeforeImport
        error [::RB2Bolt::incrementalImportError organize $incrementalFem $reader $organizeError $expected_element_ids {}]
    }
    ::HybridCore::log INFO "incremental CBEAM elements organized components=[llength [dict get $summary created_component_ids]]"
    if {[catch {set reconnectStat [::RB2Bolt::replaceImportedEndpointProxies $replacements $incrementalFem $reader $expected_element_ids]} reconnectError]} {
        ::RB2Bolt::cleanupIncrementalBoltImport $summary $componentsBeforeImport
        error $reconnectError
    }
    set replaced [dict get $reconnectStat replaced]
    ::HybridCore::log INFO "incremental CBEAM endpoint proxies reconnected count=$replaced bulk=[dict get $reconnectStat bulk_replaced] fallback=[dict get $reconnectStat fallback_replaced]"
    if {[catch {set created [::RB2Bolt::verifyImportedSegments $segments $incrementalFem $reader]} verifyError]} {
        ::RB2Bolt::cleanupIncrementalBoltImport $summary $componentsBeforeImport
        error $verifyError
    }
    set remainingTemporaryNodes [::HybridCore::existingEntityIds {nodes} $temporary_node_ids]
    if {[llength $remainingTemporaryNodes] > 0} {
        ::RB2Bolt::cleanupIncrementalBoltImport $summary $componentsBeforeImport
        error [::RB2Bolt::incrementalImportError verify $incrementalFem $reader \
            "temporary endpoint GRID cleanup failed: $remainingTemporaryNodes" $expected_element_ids $expected_element_ids]
    }
    set beamSectionsBefore [::RB2Bolt::allBeamSectionIds]
    if {[catch {set assignmentStat [::RB2Bolt::configureImportedBoltAssignments $summary]} assignmentError]} {
        set createdBeamSections {}
        foreach beamSectionId [::RB2Bolt::allBeamSectionIds] {
            if {$beamSectionId ni $beamSectionsBefore} {lappend createdBeamSections $beamSectionId}
        }
        ::RB2Bolt::cleanupIncrementalBoltImport $summary $componentsBeforeImport $createdBeamSections
        error [::RB2Bolt::incrementalImportError property $incrementalFem $reader $assignmentError $expected_element_ids $expected_element_ids]
    }
    set deletedEmptyComponents [::HybridCore::deleteEmptyNewComponents $componentsBeforeImport [dict get $summary created_component_ids]]
    ::HybridCore::log INFO "incremental CBEAM import verified created=$created endpoint_proxies_reconnected=$replaced property_assignments=[dict get $assignmentStat assignments] solid_circle_sections=[dict get $assignmentStat solid_circle_sections] empty_components_deleted={$deletedEmptyComponents}"
    ::HybridCore::progressUpdate $progressEnd "RBE2 Bolt Connector" "Incremental FEM import verified: $created connectors." 1
    return [dict create created $created skipped 0 skipped_existing $existing pair_count $pairCount incremental_fem $incrementalFem]
}

# Compatibility entry point retained for callers and smoke tests.
proc ::RB2Bolt::executePythonPlans {payload {progressStart 65.0} {progressEnd 96.0}} {
    return [::RB2Bolt::importIncrementalFem $payload $progressStart $progressEnd]
}
