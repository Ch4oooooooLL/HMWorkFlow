namespace eval ::SolidSeamCommandProfile {}

# A recorder scope belongs to one synchronous CE call, including each closed
# arc. Fall back before creation when recorders are unavailable. Never retry
# the creation command after an error (it may have partially changed the model).
proc ::SolidSeamCommandProfile::recordCreation {script} {
    variable recorderShadow
    set shadow [expr {[info exists recorderShadow] && $recorderShadow}]
    set enabled {}; set useRecorder [expr {[llength [info commands hm_entityrecorder]] > 0}]
    if {$useRecorder} {
        foreach entity {elems connectors} {
            if {[catch {hm_entityrecorder $entity on}]} { set useRecorder 0; break }
            lappend enabled $entity
        }
    }
    if {!$useRecorder} {
        foreach entity $enabled { hm_entityrecorder $entity off }
        set enabled {}
    }
    set code [catch {
        if {!$useRecorder || $shadow} {
            foreach entity {elems connectors} { set before($entity) [::SolidSeamCommandProfile::snapshotIds $entity] }
        }
        uplevel 1 $script
    } result opts]
    set stopError ""
    foreach entity $enabled {
        if {[catch {hm_entityrecorder $entity off} err]} { set stopError $err }
    }
    if {$code} { return -options $opts $result }
    if {$stopError ne ""} { error "Cannot stop entity recorder: $stopError" }
    set created {}
    foreach entity {elems connectors} {
        if {$useRecorder} {
            set ids [hm_entityrecorder $entity ids]
            # CE can create and delete temporary entities in the same call.
            set surviving {}
            foreach id $ids {
                if {![catch {set found [hm_getvalue $entity id=$id dataname=id]}] && $found eq $id} { lappend surviving $id }
            }
            set ids [lsort -integer -unique $surviving]
        }
        if {!$useRecorder || $shadow} {
            set delta [lsort -integer [::SolidSeamCommandProfile::newIds $before($entity) [::SolidSeamCommandProfile::snapshotIds $entity]]]
            if {$useRecorder && $delta ne $ids} { error "Entity recorder differs from snapshot: $entity" }
            set ids $delta
        }
        dict set created $entity $ids
    }
    return $created
}

proc ::SolidSeamCommandProfile::snapshotIds {entityType} {
    # Read-only enumeration: never put the entire model into a UI mark.
    return [hm_entitylist $entityType id all]
}

proc ::SolidSeamCommandProfile::newIds {before after} {
    set known [dict create]
    foreach entityId $before { dict set known $entityId 1 }
    set result {}
    foreach entityId $after {
        if {![dict exists $known $entityId]} { lappend result $entityId }
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
        set remainingElements [hm_getvalue comps id=$componentId dataname=elements]
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
    if {[::SolidSeamCommandProfile::candidateValue $candidate is_closed 0]} {
        return [::SolidSeamCommandProfile::realizeClosedPentaMig $candidate $profile $feType $feName]
    }
    ::SolidSeamCommandProfile::ensureOptiStructTemplate

    set sourceComponentId [dict get $candidate source_component_id]
    set targetComponentId [dict get $candidate target_component_id]
    set nodeIds [dict get $candidate node_ids]
    set tolerance [::SolidSeamCommandProfile::candidateValue $candidate realization_tolerance [dict get $profile default_tolerance]]
    set closedPiece [::SolidSeamCommandProfile::candidateValue $candidate closed_boundary_piece 0]
    if {[::SolidSeamCommandProfile::candidateValue $candidate parameter_strategy ""] ni {USER_EXPLICIT AUTO_GEOMETRY_V1}} {
        set tolerance [::SolidSeamCommandProfile::adaptiveTolerance $candidate $tolerance]
    }
    set width [::SolidSeamCommandProfile::candidateValue $candidate weld_width [dict get $profile default_width]]
    set spacing [::SolidSeamCommandProfile::candidateValue $candidate line_spacing $width]
    set side [::SolidSeamCommandProfile::candidateValue $candidate side_mode POSITIVE]
    if {$side ni {POSITIVE NEGATIVE BOTH}} { error "Invalid weld side: $side" }
    set sideOption [dict get {POSITIVE 1 NEGATIVE 2 BOTH 3} $side]
    set rightAngledRaw [string tolower [::SolidSeamCommandProfile::candidateValue $candidate right_angled false]]
    set rightAngled [expr {$rightAngledRaw in {1 true yes on}}]

    set outputComponent [::SolidSeamCommandProfile::ensureOutputComponent]
    set beforeComponents [::SolidSeamCommandProfile::snapshotIds comps]

    # Location must be an ORDERED node list (native 1D connector seam flow).
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 $nodeIds
    catch {*clearmark comps 2}
    eval *createmark comps 2 $sourceComponentId $targetComponentId

    # The connector entity is assigned to the CURRENT COLLECTOR component at
    # creation time.  The weld nodes come from the FIRST component, so the
    # connector must be marked on it too - never on the second component.
    # (Verified on 2019.0.0.70: ce_comp follows *currentcollector components.)
    set sourceComponentName ""
    catch {set sourceComponentName [hm_getvalue comps id=$sourceComponentId dataname=name]}
    if {$sourceComponentName ne ""} {
        catch {*currentcollector components $sourceComponentName}
    }

    set executableDir [hm_info -appinfo EXECUTABLEDIR]
    set feConfigPath [file join $executableDir feconfig.cfg]
    if {![file isfile $feConfigPath]} { error "HM2019 connector configuration is missing: $feConfigPath" }

    # Base option set verified on 2019.0.0.70 and 2022.0.0.33 (user-recorded
    # command file + headless harness). ce_pentasideoption is the creation
    # keyword; ce_penta_side_option is the stored detail name (1/2/3).
    # The native seam options use
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
        "ce_pentasideoption=$sideOption" \
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
        "ce_fe_createcap=[expr {!$closedPiece}]" \
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
        set created [::SolidSeamCommandProfile::recordCreation {
            *CE_ConnectorCreateByListAndRealizeWithDetails nodes 1 seam 2 comps 2 optistruct 1001 $feType $tolerance 1 [llength $options]
        }]
    } commandError commandOptions]} {
        error "HM2019 $feName creation command failed: $commandError"
    }

    set connectorIds [dict get $created connectors]
    set newElementIds [dict get $created elems]

    if {[llength $connectorIds] != 1} {
        error "HM2019 $feName creation returned [llength $connectorIds] new connectors; expected 1"
    }
    set connectorId [lindex $connectorIds 0]
    if {[catch {set connectorState [string toupper [hm_ce_state $connectorId]]} stateError]} {
        error "Cannot query connector $connectorId state: $stateError"
    }

    # HM2019 element configs: 206=PENTA6 and 56=RBE3.
    set pentaIds {}; set rbe3Ids {}
    foreach chunk [::SolidSeam::queryChunks $newElementIds] {
        set configs {}
        if {[catch {
            set ids [hm_getvalue elems "user_ids=$chunk" dataname=id]
            set configs [hm_getvalue elems "user_ids=$chunk" dataname=config]
            if {[lsort -integer $ids] ne [lsort -integer $chunk] || [llength $configs] != [llength $ids]} { error "Invalid batch configs" }
        }]} {
            set ids $chunk; set configs {}
            foreach id $ids { lappend configs [hm_getvalue elems id=$id dataname=config] }
        }
        foreach id $ids config $configs {
            if {$config == 206} { lappend pentaIds $id }
            if {$config == 56} { lappend rbe3Ids $id }
        }
    }
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
        applied_parameters [dict create spacing $spacing width $width tolerance $tolerance side $side right_angled $rightAngled connectivity ENSURE_PROJECTION] \
    ]
}

# HM2019 *createlist removes duplicate IDs, including a repeated start node.
# Two open arcs share both endpoints and together cover each boundary edge
# exactly once. They require no duplicate input IDs or synthetic model nodes.
proc ::SolidSeamCommandProfile::closedBoundaryArcs {nodes} {
    if {[llength $nodes] < 3 || [llength [lsort -unique $nodes]] != [llength $nodes]} {
        error "A closed boundary needs at least three distinct ordered nodes"
    }
    set middle [expr {[llength $nodes] / 2}]
    return [list [lrange $nodes 0 $middle] [concat [lrange $nodes $middle end] [list [lindex $nodes 0]]]]
}

proc ::SolidSeamCommandProfile::realizeClosedPentaMig {candidate profile feType feName} {
    set paths [::SolidSeamCommandProfile::closedBoundaryArcs [dict get $candidate node_ids]]
    dict set candidate is_closed 0
    dict set candidate closed_boundary_piece 1
    set connectors {}; set pentas {}; set rigids {}
    foreach path $paths {
        dict set candidate node_ids $path
        if {[catch {set result [::SolidSeamCommandProfile::realizePentaMig $candidate $profile $feType $feName]} err opts]} {
            return -options $opts "Closed boundary creation failed (completed arc connectors: $connectors): $err"
        }
        lappend connectors [dict get $result connector_id]
        set pentas [concat $pentas [dict get $result penta_ids]]
        set rigids [concat $rigids [dict get $result rbe3_ids]]
    }
    dict set result connector_id [lindex $connectors 0]
    dict set result connector_ids $connectors
    dict set result penta_ids $pentas
    dict set result rbe3_ids $rigids
    dict set result applied_parameters closed_boundary 1
    return $result
}
