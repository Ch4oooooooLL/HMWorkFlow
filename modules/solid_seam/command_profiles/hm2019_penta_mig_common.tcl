namespace eval ::SolidSeamCommandProfile {}

proc ::SolidSeamCommandProfile::snapshotIds {entityType} {
    catch {*clearmark $entityType 1}
    *createmark $entityType 1 all
    return [hm_getmark $entityType 1]
}

proc ::SolidSeamCommandProfile::newIds {before after} {
    set result {}
    foreach entityId $after {
        if {[lsearch -exact $before $entityId] < 0} { lappend result $entityId }
    }
    return $result
}

proc ::SolidSeamCommandProfile::ensureOptiStructTemplate {} {
    set templateType [string tolower [string trim [hm_info templatetype]]]
    if {$templateType eq "none" || $templateType eq ""} {
        set executableDir [hm_info -appinfo EXECUTABLEDIR]
        set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
        if {![file isfile $templatePath]} {
            error "OptiStruct template is not loaded and was not found at $templatePath"
        }
        *templatefileset $templatePath
        set templateType [string tolower [string trim [hm_info templatetype]]]
    }
    # HyperMesh 2019 reports the OptiStruct profile as "nastran" here.
    if {$templateType ni {nastran optistruct}} {
        error "penta (mig) realization requires the HM2019 OptiStruct profile; current template type is '$templateType'"
    }
}

proc ::SolidSeamCommandProfile::elementIdsByConfig {elementIds wantedConfig} {
    set result {}
    foreach elementId $elementIds {
        if {[catch {set config [hm_getvalue elems id=$elementId dataname=config]}]} { continue }
        if {[string trim $config] eq [string trim $wantedConfig]} { lappend result $elementId }
    }
    return $result
}

proc ::SolidSeamCommandProfile::candidateValue {candidate key fallback} {
    if {[dict exists $candidate $key] && [string trim [dict get $candidate $key]] ne ""} {
        return [dict get $candidate $key]
    }
    return $fallback
}

# Estimate a minimum realization tolerance from the actual model so the
# native seam realization cannot fail with "connector realization failed"
# because the search tolerance is smaller than the local mesh/gap scale.
# The user's default width/spacing is 6; the tolerance must cover at least
# the local mesh size plus the joint gap.
proc ::SolidSeamCommandProfile::adaptiveTolerance {candidate requestedTolerance} {
    set nodeIds [dict get $candidate node_ids]
    set meshSize [::SolidSeamCommandProfile::candidateValue $candidate mesh_size 0.0]
    set maxGap [::SolidSeamCommandProfile::candidateValue $candidate maximum_gap 0.0]
    if {$meshSize <= 0.0} {
        # measure from the node list: median edge length along the chain
        set lengths {}
        set previous ""
        foreach nodeId $nodeIds {
            if {$previous ne ""} {
                set x1 [hm_getvalue nodes id=$previous dataname=x]
                set y1 [hm_getvalue nodes id=$previous dataname=y]
                set z1 [hm_getvalue nodes id=$previous dataname=z]
                set x2 [hm_getvalue nodes id=$nodeId dataname=x]
                set y2 [hm_getvalue nodes id=$nodeId dataname=y]
                set z2 [hm_getvalue nodes id=$nodeId dataname=z]
                set d [expr {sqrt(($x2-$x1)*($x2-$x1) + ($y2-$y1)*($y2-$y1) + ($z2-$z1)*($z2-$z1))}]
                if {$d > 1.0e-8} { lappend lengths $d }
            }
            set previous $nodeId
        }
        if {[llength $lengths] > 0} {
            set sorted [lsort -real $lengths]
            set mid [expr {[llength $sorted] / 2}]
            set meshSize [lindex $sorted $mid]
        }
    }
    # tolerance must comfortably cover one mesh edge plus the joint gap;
    # never below the caller default (user's 6) so small models still work.
    set floor [expr {max(6.0, 1.5 * $meshSize, $maxGap + $meshSize)}]
    if {$requestedTolerance < $floor} {
        set requestedTolerance $floor
    }
    return $requestedTolerance
}

proc ::SolidSeamCommandProfile::ensureOutputComponent {} {
    set componentName "SEAM_SOLID"
    set componentColor 3
    catch {*clearmark comps 1}
    catch {*createmark comps 1 "by name only" $componentName}
    set componentIds {}
    catch {set componentIds [hm_getmark comps 1]}
    if {[llength $componentIds] == 0} {
        *collectorcreateonly components $componentName "" $componentColor
        *createmark comps 1 "by name only" $componentName
        set componentIds [hm_getmark comps 1]
    }
    if {[llength $componentIds] != 1} {
        error "Expected exactly one output component named $componentName; found [llength $componentIds]"
    }
    *colormark comps 1 $componentColor
    catch {*clearmark comps 1}
    return [dict create id [lindex $componentIds 0] name $componentName color $componentColor]
}

proc ::SolidSeamCommandProfile::moveRealizationToOutputComponent {elementIds beforeComponentIds outputComponent} {
    set componentName [dict get $outputComponent name]
    if {[llength $elementIds] > 0} {
        eval *createmark elems 1 $elementIds
        *movemark elems 1 $componentName
    }

    set afterComponentIds [::SolidSeamCommandProfile::snapshotIds comps]
    set generatedComponentIds [::SolidSeamCommandProfile::newIds $beforeComponentIds $afterComponentIds]
    foreach componentId $generatedComponentIds {
        if {$componentId == [dict get $outputComponent id]} { continue }
        catch {*clearmark elems 1}
        catch {eval *createmark elems 1 "by comp id" $componentId}
        set remainingElements {}
        catch {set remainingElements [hm_getmark elems 1]}
        if {[llength $remainingElements] == 0} {
            *createmark comps 1 $componentId
            catch {*deletemark comps 1}
        }
    }
    *createmark comps 1 "by name only" $componentName
    *colormark comps 1 [dict get $outputComponent color]
    catch {*clearmark elems 1}
    catch {*clearmark comps 1}
}

proc ::SolidSeamCommandProfile::realizePentaMig {candidate profile feType feName} {
    ::SolidSeamCommandProfile::ensureOptiStructTemplate

    set sourceComponentId [dict get $candidate source_component_id]
    set targetComponentId [dict get $candidate target_component_id]
    set nodeIds [dict get $candidate node_ids]
    set tolerance [::SolidSeamCommandProfile::candidateValue $candidate realization_tolerance [dict get $profile default_tolerance]]
    set tolerance [::SolidSeamCommandProfile::adaptiveTolerance $candidate $tolerance]
    set width [::SolidSeamCommandProfile::candidateValue $candidate weld_width [dict get $profile default_width]]
    set spacing [::SolidSeamCommandProfile::candidateValue $candidate line_spacing $width]
    set rightAngledRaw [string tolower [::SolidSeamCommandProfile::candidateValue $candidate right_angled false]]
    set rightAngled [expr {$rightAngledRaw in {1 true yes on}}]

    set outputComponent [::SolidSeamCommandProfile::ensureOutputComponent]
    set beforeComponents [::SolidSeamCommandProfile::snapshotIds comps]
    set beforeConnectors [::SolidSeamCommandProfile::snapshotIds connectors]
    set beforeElements [::SolidSeamCommandProfile::snapshotIds elems]

    # Location must be an ORDERED node list (native 1D connector seam flow).
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 $nodeIds
    catch {*clearmark comps 2}
    eval *createmark comps 2 $sourceComponentId $targetComponentId

    # The connector entity is assigned to the CURRENT COLLECTOR component at
    # creation time.  The weld nodes come from the FIRST component, so the
    # connector must be marked on it too - never on the second component.
    # (Verified on 2019.0.0.70: ce_comp follows *currentcollector components.)
    catch {set sourceComponentName [hm_getvalue comps id=$sourceComponentId dataname=name]}
    if {$sourceComponentName ne ""} {
        catch {*currentcollector components $sourceComponentName}
    }

    set executableDir [hm_info -appinfo EXECUTABLEDIR]
    set feConfigPath [file join $executableDir feconfig.cfg]
    if {![file isfile $feConfigPath]} { error "HM2019 connector configuration is missing: $feConfigPath" }

    # Option set verified on 2019.0.0.70 and 2022.0.0.33 (user-recorded
    # command file + headless harness): the 45 native seam options with
    # ce_pentafitoption=2, width fed into ce_fedepth, spacing into
    # line_spacing.  ce_configfile/ce_propertyscript are optional; the
    # explicit config file keeps the custom (1001) FE types resolvable.
    set options [list \
        "link_elems_geom=elems" \
        "link_rule=now" \
        "relink_rule=none" \
        "tol_flag=1" \
        "tol=[format %.6f $tolerance]" \
        "line_spacing=[format %.6f $spacing]" \
        "line_density=0" \
        "line_preserve_nodes=0" \
        "seam_area_group=2" \
        "ce_fedepth=[format %.6f $width]" \
        "ce_fe_tapered_t_input=$rightAngled" \
        "ce_jacobian_flag=0" \
        "ce_jacobian=0.000000" \
        "ce_warpage_flag=0" \
        "ce_warpage=0.000000" \
        "ce_aspect_flag=0" \
        "ce_aspect=0.000000" \
        "ce_fe_factor_a=1.500000" \
        "ce_fe_factor_b=2.500000" \
        "ce_fe_edgesnapping_t=2" \
        "ce_fe_edgesnapping_l=1" \
        "ce_pentafitoption=2" \
        "ce_fe_offsetangle=45.000000" \
        "ce_fe_thck_flag=1" \
        "ce_fe_density=1" \
        "ce_fe_strips=1" \
        "ce_fe_rows=1" \
        "ce_fe_const_height=0.000000" \
        "ce_fe_maint_gaps=0.000000" \
        "ce_nonnormal=1" \
        "ce_connectivity=2" \
        "ce_dir_assign=0" \
        "ce_prop_opt=1" \
        "ce_propertyid=0" \
        "ce_fe_height=5.000000" \
        "ce_fe_createcap=1" \
        "ce_fe_runoffangle=10.000000" \
        "ce_fe_capangle=65.000000" \
        "ce_fe_sharpcorner=0" \
        "ce_hexaoffsetcheck=1" \
        "ce_hexa_position_opt=0" \
        "ce_hexa_tapered_t_position_opt=0" \
        "ce_bl_connection_ang=10.000000" \
        "ce_lt_connection_ang=60.000000" \
        "ce_extralinknum=0" \
        "ce_configfile=$feConfigPath" \
        "ce_propertyscript=" \
    ]
    eval *createstringarray [llength $options] $options

    if {[catch {
        *CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 seam 2 comps 2 optistruct 1001 $feType $tolerance 1 [llength $options]
    } commandError commandOptions]} {
        error "HM2019 $feName creation command failed: $commandError"
    }

    set afterConnectors [::SolidSeamCommandProfile::snapshotIds connectors]
    set afterElements [::SolidSeamCommandProfile::snapshotIds elems]
    set connectorIds [::SolidSeamCommandProfile::newIds $beforeConnectors $afterConnectors]
    set newElementIds [::SolidSeamCommandProfile::newIds $beforeElements $afterElements]

    if {[llength $connectorIds] != 1} {
        error "HM2019 $feName creation returned [llength $connectorIds] new connectors; expected 1"
    }
    set connectorId [lindex $connectorIds 0]
    if {[catch {set connectorState [string toupper [hm_ce_state $connectorId]]} stateError]} {
        error "Cannot query connector $connectorId state: $stateError"
    }

    # HM2019 element configs: 206=PENTA6 and 56=RBE3.
    set pentaIds [::SolidSeamCommandProfile::elementIdsByConfig $newElementIds 206]
    set rbe3Ids [::SolidSeamCommandProfile::elementIdsByConfig $newElementIds 56]
    if {$connectorState ne "REALIZED"} {
        error "Connector $connectorId realization state is $connectorState"
    }
    if {[llength $pentaIds] == 0} {
        error "Connector $connectorId is realized but generated no PENTA6 elements"
    }

    ::SolidSeamCommandProfile::moveRealizationToOutputComponent $newElementIds $beforeComponents $outputComponent

    return [dict create \
        connector_id $connectorId \
        connector_state $connectorState \
        penta_ids $pentaIds \
        rbe3_ids $rbe3Ids \
        linked_component_ids [list $sourceComponentId $targetComponentId] \
        output_component_id [dict get $outputComponent id] \
        output_component_name [dict get $outputComponent name] \
        applied_parameters [dict create spacing $spacing width $width tolerance $tolerance side POSITIVE right_angled $rightAngled connectivity ENSURE_PROJECTION] \
    ]
}
