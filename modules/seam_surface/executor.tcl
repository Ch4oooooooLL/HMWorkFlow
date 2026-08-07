namespace eval ::hmtoolkit::seam::executor {}
namespace eval ::hmtoolkit::seam::naming {}

proc ::hmtoolkit::seam::naming::format_thickness {value} {
    return [::HWFlow::formatThicknessToken $value]
}

proc ::hmtoolkit::seam::naming::thickness_from_data {data} {
    if {[dict exists $data thickness]} {
        set value [dict get $data thickness]
        if {[string is double -strict $value] && $value > 0.0} { return [expr {double($value)}] }
    }
    # Primary source: real Property thickness via the public query API.
    # The Component-name _Txx parser is only a legacy fallback and logs a
    # warning so the report's "thickness from name" issue stays visible.
    set values {}
    foreach key {source_components target_components} {
        if {![dict exists $data $key]} { continue }
        foreach compId [dict get $data $key] {
            set value [::hmtoolkit::seam::native::component_thickness $compId]
            if {$value eq ""} {
                set value [::HWFlow::thicknessFromComponentName [::HWFlow::componentName $compId]]
                if {$value ne ""} {
                    ::hmtoolkit::seam::log::write WARN \
                        "Component $compId has no readable Property thickness; using _Txx name fallback"
                }
            }
            if {$value ne ""} { lappend values $value }
        }
    }
    if {[llength $values] == 0} { error "Unable to determine a positive plate thickness" }
    return [lindex [lsort -real $values] 0]
}

proc ::hmtoolkit::seam::naming::get_or_create_component {thickness} {
    set name "SEAM_T[::hmtoolkit::seam::naming::format_thickness $thickness]_Surf"
    # -history external: the seam transaction owns the undo/redo block.
    set id [::HWFlow::createComponent $name "" external]
    if {$id eq ""} { error "Unable to create or reuse seam component $name" }
    ::HWFlow::addComponentsToAssembly Seam_Comps [list $id] 11
    # Every native geometry command that routes new entities into this
    # component depends on the current collector; verify it, never swallow it.
    ::hmtoolkit::seam::native::set_current_component_checked $name $id
    return [list $name $id]
}

proc ::hmtoolkit::seam::executor::success {strategy createdSurfs createdComponents {warnings {}} {message ""}} {
    return [dict create success 1 strategy $strategy created_surfs $createdSurfs created_components $createdComponents warnings $warnings message $message]
}

proc ::hmtoolkit::seam::executor::mark_inputs {data lineKey targetKey} {
    set lines [::hmtoolkit::seam::validation::require_ids $data $lineKey lines]
    set targets [::hmtoolkit::seam::validation::require_ids $data $targetKey surfs]
    ::hmtoolkit::seam::entity::mark lines 1 $lines
    ::hmtoolkit::seam::entity::mark surfs 1 $targets
    return [list $lines $targets]
}

proc ::hmtoolkit::seam::executor::existing_surfaces {surfaceIds} {
    set existing {}
    foreach surfaceId [lsort -integer -unique $surfaceIds] {
        if {[::hmtoolkit::seam::entity::exists surfs $surfaceId]} {
            lappend existing $surfaceId
        }
    }
    return $existing
}

proc ::hmtoolkit::seam::executor::line_owner_surfaces {lineId} {
    set owners {}
    # hm_getsurfacesfromedge is the documented query present on both local
    # builds; hm_getsurfacesfromline exists on neither (2026-08-07 probe) and
    # was removed from the fallback chain.
    if {![catch {set found [hm_getsurfacesfromedge $lineId]}] && [llength $found] > 0} {
        set owners [concat $owners $found]
    }
    return [lsort -integer -unique $owners]
}

proc ::hmtoolkit::seam::executor::surfaces_from_lines {lineIds} {
    set surfaces {}
    foreach lineId $lineIds {
        set surfaces [concat $surfaces [::hmtoolkit::seam::executor::line_owner_surfaces $lineId]]
    }
    return [lsort -integer -unique $surfaces]
}

proc ::hmtoolkit::seam::executor::external_owner_surfaces {seamSurfs} {
    array set isSeam {}
    foreach surfaceId $seamSurfs { set isSeam($surfaceId) 1 }
    set owners {}
    foreach lineId [::hmtoolkit::seam::entity::surface_lines $seamSurfs] {
        foreach owner [::hmtoolkit::seam::executor::line_owner_surfaces $lineId] {
            if {![info exists isSeam($owner)]} { lappend owners $owner }
        }
    }
    return [lsort -integer -unique $owners]
}

proc ::hmtoolkit::seam::executor::owners_connect_all_inputs {owners sourceSurfs targetSurfs} {
    set owners [lsort -integer -unique $owners]
    foreach surfaceId [lsort -integer -unique [concat $sourceSurfs $targetSurfs]] {
        if {[lsearch -exact $owners $surfaceId] < 0} { return 0 }
    }
    return 1
}

proc ::hmtoolkit::seam::executor::surfaces_share_edge {firstSurfs secondSurfs} {
    array set firstLines {}
    foreach lineId [::hmtoolkit::seam::entity::surface_lines $firstSurfs] {
        set firstLines($lineId) 1
    }
    foreach lineId [::hmtoolkit::seam::entity::surface_lines $secondSurfs] {
        if {[info exists firstLines($lineId)]} { return 1 }
    }
    return 0
}

proc ::hmtoolkit::seam::executor::seam_connects_all_inputs {seamSurfs sourceSurfs targetSurfs} {
    foreach surfaceId [lsort -integer -unique [concat $sourceSurfs $targetSurfs]] {
        if {![::hmtoolkit::seam::executor::surfaces_share_edge $seamSurfs [list $surfaceId]]} {
            return 0
        }
    }
    return 1
}

proc ::hmtoolkit::seam::executor::stitch_surface_set {surfaceIds modes} {
    set tolerance [::hmtoolkit::seam::config::get stitch_tolerance]
    set ran 0
    foreach mode $modes {
        set current [::hmtoolkit::seam::executor::existing_surfaces $surfaceIds]
        if {[llength $current] < 2} { continue }
        if {[catch {::hmtoolkit::seam::entity::mark surfs 1 $current}]} { continue }
        if {![catch {*selfstitchcombine 1 $mode $tolerance $tolerance}]} {
            set ran 1
        }
    }
    catch {*clearmark surfs 1}
    return $ran
}

proc ::hmtoolkit::seam::executor::equivalence_created_surfaces {created sourceSurfs targetSurfs componentId beforeComponentSurfs} {
    set created [::hmtoolkit::seam::executor::existing_surfaces $created]
    set sourceSurfs [::hmtoolkit::seam::executor::existing_surfaces $sourceSurfs]
    set targetSurfs [::hmtoolkit::seam::executor::existing_surfaces $targetSurfs]
    if {[llength $created] == 0 || [llength $sourceSurfs] == 0 || [llength $targetSurfs] == 0} {
        error "Topology equivalence requires new seam surfaces and both contacting surface groups"
    }
    set allSurfs [lsort -integer -unique [concat $created $sourceSurfs $targetSurfs]]
    set attempts [list $allSurfs]
    # Retry each contacting surface independently. HyperMesh can complete only
    # part of a grouped stitch when one seam spans several target surfaces.
    foreach surfaceId [concat $sourceSurfs $targetSurfs] {
        lappend attempts [lsort -integer -unique [concat $created [list $surfaceId]]]
    }
    # A seam operation may create several surfaces. Retry the smallest useful
    # sets as well, because a single grouped self-stitch can silently join only
    # one member of the mark and leave the rest geometrically coincident.
    foreach createdSurf $created {
        foreach contactSurf [concat $sourceSurfs $targetSurfs] {
            lappend attempts [lsort -integer -unique [list $createdSurf $contactSurf]]
        }
    }
    array set attempted {}
    set ran 0
    foreach modes {{134 6} {130 2}} {
        foreach surfaceSet $attempts {
            set key [join $surfaceSet ,]
            if {$key eq "" || [info exists attempted($key,$modes)]} { continue }
            set attempted($key,$modes) 1
            if {[::hmtoolkit::seam::executor::stitch_surface_set $surfaceSet $modes]} {
                set ran 1
            }
            set final [::hmtoolkit::seam::validation::created_surfaces_in_component $beforeComponentSurfs $componentId]
            # Shared edge IDs are the direct topology signal and remain usable
            # on HM versions where the reverse edge-to-surface query is absent.
            if {[::hmtoolkit::seam::executor::seam_connects_all_inputs \
                $final $sourceSurfs $targetSurfs]} {
                return $final
            }
            set owners [::hmtoolkit::seam::executor::external_owner_surfaces $final]
            if {[::hmtoolkit::seam::executor::owners_connect_all_inputs \
                $owners $sourceSurfs $targetSurfs]} {
                return $final
            }
        }
    }
    set final [::hmtoolkit::seam::validation::created_surfaces_in_component $beforeComponentSurfs $componentId]
    set message ""
    if {!$ran} {
        set message "Topology equivalence command could not run for the local seam surfaces"
    } else {
        set message "The seam surface was created geometrically but is not topologically connected to both contacting sides"
    }
    if {[::hmtoolkit::seam::config::get topology_connection_required] > 0} {
        error $message
    }
    # Audit section 19.1: a strict equivalence failure rolls back geometry.
    # With topology_connection_required=0 the failure is downgraded to a
    # warning and the created, correctly-owned geometry is kept for review.
    ::hmtoolkit::seam::log::write WARN \
        "$message; topology_connection_required=0 keeps the created geometry: $final"
    return $final
}

proc ::hmtoolkit::seam::executor::lap_result_surfaces {tempComponents newlyCreated} {
    set pool $newlyCreated
    set componentIds {}
    foreach component $tempComponents {
        set componentId [lindex $component 1]
        lappend componentIds $componentId
        set pool [concat $pool [::hmtoolkit::seam::entity::component_surfaces $componentId]]
    }
    set final {}
    foreach surfaceId [::hmtoolkit::seam::executor::existing_surfaces $pool] {
        set owner [::hmtoolkit::seam::entity::surface_component $surfaceId]
        if {[lsearch -exact $componentIds $owner] >= 0} { lappend final $surfaceId }
    }
    return [lsort -integer -unique $final]
}

proc ::hmtoolkit::seam::executor::temp_component_solids {tempComponents} {
    set solids {}
    foreach component $tempComponents {
        catch {*clearmark solids 1}
        if {[catch {*createmark solids 1 "by comp" [lindex $component 0]} markErr]} {
            error "Failed to mark solids in temporary component '[lindex $component 0]': $markErr"
        }
        set found {}
        catch {set found [hm_getmark solids 1]}
        set solids [concat $solids $found]
    }
    catch {*clearmark solids 1}
    return [lsort -integer -unique $solids]
}

proc ::hmtoolkit::seam::executor::extended_result_surfaces {source newlyCreated sourceCompId} {
    set result {}
    foreach surfaceId [::hmtoolkit::seam::executor::existing_surfaces \
        [concat $source $newlyCreated]] {
        if {[string equal [::hmtoolkit::seam::entity::surface_component $surfaceId] $sourceCompId]} {
            lappend result $surfaceId
        }
    }
    return [lsort -integer -unique $result]
}

proc ::hmtoolkit::seam::executor::resolve_extend_source {owners} {
    set seamSurfs {}
    set componentIds {}
    foreach surfaceId [lsort -integer -unique $owners] {
        set componentId [::hmtoolkit::seam::entity::surface_component $surfaceId]
        if {$componentId eq ""} { continue }
        lappend componentIds $componentId
        if {[string match "SEAM_T*_Surf" [::HWFlow::componentName $componentId]]} {
            lappend seamSurfs $surfaceId
        }
    }
    if {[llength $seamSurfs] > 0} { return $seamSurfs }
    if {[llength [lsort -unique $componentIds]] == 1} {
        return [lsort -integer -unique $owners]
    }
    error "The selected edge has several owners and none belongs to a SEAM_T*_Surf component"
}

proc ::hmtoolkit::seam::executor::prepare_ruled_surface_lists {first second} {
    eval [linsert $first 0 *createlist lines 1]
    *createlist nodes 1
    eval [linsert $second 0 *createlist lines 2]
    *createlist nodes 2
}

# Shared CONNECT/T_LIST post-processing after *linearsurfacebetweenlines:
# mark the preliminary ruled surfaces and merge their edges under the pinned
# session cleanup tolerance. This is what turns a free-standing ruled sheet
# into a seam that is topologically connected to the contacting sides.
proc ::hmtoolkit::seam::executor::merge_ruled_surfaces {preliminary} {
    ::hmtoolkit::seam::entity::mark surfs 1 $preliminary
    ::hmtoolkit::seam::native::with_cleanup_tolerance \
        [::hmtoolkit::seam::config::get cleanup_tolerance] {
        *multi_surfs_lines_merge 1 0 0
    }
}

proc ::hmtoolkit::seam::executor::_create_t {data strategy} {
    set lines [::hmtoolkit::seam::validation::require_ids $data seam_lines lines]
    set sourceSurfs [::hmtoolkit::seam::validation::require_ids $data source_surfs surfs]
    set targetSurfs [::hmtoolkit::seam::validation::require_ids $data target_surfs surfs]
    set allSurfs [lsort -integer -unique [concat $sourceSurfs $targetSurfs]]
    if {[llength $allSurfs] < 2} { error "Source and target surfaces must be different" }
    set topology [::hmtoolkit::seam::candidate::path_topology $lines ::hmtoolkit::seam::candidate::line_points]
    if {[dict get $topology kind] eq "BRANCH"} { error "Branched seam lines require manual review" }
    if {$strategy eq "T_PATH" && [dict get $topology kind] ne "PATH"} { error "T_PATH requires one connected, unbranched path" }
    set thickness [::hmtoolkit::seam::naming::thickness_from_data $data]
    set component [::hmtoolkit::seam::naming::get_or_create_component $thickness]
    set componentName [lindex $component 0]
    set componentId [lindex $component 1]
    set minAngle [::hmtoolkit::seam::config::get connect_min_angle_to_target]
    set maxAngle [::hmtoolkit::seam::config::get connect_max_angle_edge_to_surf]
    set guideAngle [::hmtoolkit::seam::config::get connect_guide_angle]
    set trimMode [::hmtoolkit::seam::config::get t_surface_trim_mode]
    set created {}
    set warnings {}
    foreach targetSurf $targetSurfs {
        ::hmtoolkit::seam::native::ensure_current_component $componentName $componentId
        set before [::hmtoolkit::seam::entity::component_surfaces $componentId]
        set beforeAll [::hmtoolkit::seam::entity::snapshot_ids surfs]
        foreach type {surfs lines} {
            foreach markId {1 2} {
                catch {*clearmark $type $markId}
            }
        }
        ::hmtoolkit::seam::entity::mark lines 1 $lines
        ::hmtoolkit::seam::entity::mark surfs 1 $sourceSurfs
        ::hmtoolkit::seam::entity::mark surfs 2 [list $targetSurf]
        # Process every target independently. A grouped target mark can produce
        # valid geometry for only the first intersected surface and silently
        # leave the remaining targets topologically detached.
        ::hmtoolkit::seam::log::write INFO \
            "T List native args: *connect_surfaces_11 1 2 3 $trimMode 0 $minAngle $maxAngle 1 0 2 $guideAngle 59 0; target=$targetSurf"
        *connect_surfaces_11 1 2 3 $trimMode 0 $minAngle $maxAngle 1 0 2 $guideAngle 59 0
        # 2026-08-07 dual-version kernel evidence (2019.0.0.70 / 2022.0.0.33,
        # gapped T-joint fixture, identical on both): extend_mode 3 consumes
        # the source surface (the kernel rebuilds it with a new id) and
        # creates the seam strips as new surfaces. The strips share the
        # target's edge lines; the rebuilt source does not. Identify the
        # strips, re-home them into the seam component, and use the rebuilt
        # surface as the source-side topology partner.
        set globalCreated [::hmtoolkit::seam::entity::diff_ids \
            $beforeAll [::hmtoolkit::seam::entity::snapshot_ids surfs]]
        if {[llength $globalCreated] == 0} {
            error "The native extension created no seam surface. Check the seam line, gap and angle settings."
        }
        set targetLines [::hmtoolkit::seam::entity::surface_lines [list $targetSurf]]
        set strips {}
        set rebuilt {}
        foreach surfId $globalCreated {
            set sharesTarget 0
            foreach lineId [::hmtoolkit::seam::entity::surface_lines [list $surfId]] {
                if {[lsearch -exact $targetLines $lineId] >= 0} { set sharesTarget 1; break }
            }
            if {$sharesTarget} { lappend strips $surfId } else { lappend rebuilt $surfId }
        }
        if {[llength $strips] == 0} {
            error "The native extension created surfaces but none shares the target edge; the seam is not connected to the target."
        }
        ::hmtoolkit::seam::entity::mark surfs 1 $strips
        *movemark surfs 1 $componentName
        set targetCreated [::hmtoolkit::seam::validation::created_surfaces_for_component \
            $before $beforeAll $componentId]
        set sourceNow [::hmtoolkit::seam::executor::existing_surfaces $sourceSurfs]
        if {[llength $sourceNow] == 0 && [llength $rebuilt] > 0} {
            lappend warnings \
                "The native extension renumbered the source surface ($sourceSurfs -> $rebuilt); seam geometry was created against the rebuilt source."
            set sourceNow $rebuilt
        }
        if {[llength $sourceNow] == 0} {
            error "The native extension consumed the source surface and no replacement was created"
        }
        set targetCreated [::hmtoolkit::seam::executor::equivalence_created_surfaces \
            $targetCreated $sourceNow [list $targetSurf] $componentId $before]
        set created [concat $created $targetCreated]
    }
    set created [lsort -integer -unique $created]
    return [::hmtoolkit::seam::executor::success $strategy $created [list $componentName] $warnings "Seam surfaces created successfully."]
}

proc ::hmtoolkit::seam::executor::create_t_path {data} {
    # Project baseline (HM2019 / 2022.2): the line-based T path flow
    # (`*connect_surfaces_11 1 2 3 ... 59 0`) is the T-type creation route.
    return [::hmtoolkit::seam::transaction::run "Create T Path Seam" [list ::hmtoolkit::seam::executor::_create_t $data T_PATH]]
}

proc ::hmtoolkit::seam::executor::create_t_list {data} {
    # Project baseline (HM2019 / 2022.2): same line-based route as the
    # legacy T list flow.
    return [::hmtoolkit::seam::transaction::run "Create T List Seam" [list ::hmtoolkit::seam::executor::_create_t $data T_LIST]]
}

proc ::hmtoolkit::seam::executor::_create_l_surface {data} {
    variable ::hmtoolkit::seam::runtime
    set sourceSurfs [::hmtoolkit::seam::validation::require_ids $data source_surfs surfs 1]
    set targetSurfs [::hmtoolkit::seam::validation::require_ids $data target_surfs surfs 1]
    if {[lindex $sourceSurfs 0] == [lindex $targetSurfs 0]} { error "Source and target surfaces must be different" }
    set thickness [::hmtoolkit::seam::naming::thickness_from_data $data]
    set component [::hmtoolkit::seam::naming::get_or_create_component $thickness]
    set before [::hmtoolkit::seam::entity::component_surfaces [lindex $component 1]]
    set offset [::hmtoolkit::seam::config::get geometry_offset_distance]
    if {$offset <= 0.0} { error "geometry_offset_distance must be positive" }
    set scope $runtime(active_temp_token)
    set tempA [::hmtoolkit::seam::temp::create_component $scope]
    set tempB [::hmtoolkit::seam::temp::create_component $scope]
    # Duplicate the two plate surfaces into their own temporary components so
    # the solid pipeline never touches the originals. Each duplicate step is
    # verified: the copies must really be owned by the temp component.
    ::hmtoolkit::seam::native::ensure_current_component [lindex $tempA 0] [lindex $tempA 1]
    ::hmtoolkit::seam::entity::mark surfs 1 $sourceSurfs
    *duplicatemark surfs 1 1
    set copiesA [::hmtoolkit::seam::native::mark_by_component_checked surfs 1 [lindex $tempA 0]]
    ::hmtoolkit::seam::native::ensure_current_component [lindex $tempB 0] [lindex $tempB 1]
    ::hmtoolkit::seam::entity::mark surfs 1 $targetSurfs
    *duplicatemark surfs 1 1
    set copiesB [::hmtoolkit::seam::native::mark_by_component_checked surfs 1 [lindex $tempB 0]]

    ::hmtoolkit::seam::entity::mark surfs 1 $copiesA
    *solid_offset_from_surfs 1 [expr {-$offset}] 5 2
    ::hmtoolkit::seam::entity::mark surfs 1 $copiesB
    *solid_offset_from_surfs 1 [expr {-$offset}] 5 2
    set solidsA [::hmtoolkit::seam::native::mark_by_component_checked solids 1 [lindex $tempA 0]]
    set solidsB [::hmtoolkit::seam::native::mark_by_component_checked solids 2 [lindex $tempB 0]]
    # Boolean semantics: the reviewed pipeline executes a Union of the two
    # offset solids (lap_boolean_opcode=8). The audit flagged that the previous
    # error message claimed an "intersection" while the opcode was a Union;
    # the message is now neutral. Switching to Intersection (14) is a real
    # algorithm change: re-validate trim/volume-ranking/face extraction with
    # audit Experiment 1 before flipping this configuration.
    set booleanOpcode [::hmtoolkit::seam::config::get lap_boolean_opcode]
    ::hmtoolkit::seam::log::write INFO \
        "Lap boolean: *boolean_merge_solids 1 2 $booleanOpcode 3 (opcode 8=Union, 14=Intersection)"
    *boolean_merge_solids 1 2 $booleanOpcode 3
    set merged [::hmtoolkit::seam::executor::temp_component_solids [list $tempA $tempB]]
    ::hmtoolkit::seam::temp::register_entity $scope solids $merged
    if {[llength $merged] != 1} { error "Offset boolean produced [llength $merged] solids; exactly one merged solid was expected" }
    set mergedVolume [hm_getvolumeofsolid solids [lindex $merged 0]]

    ::hmtoolkit::seam::entity::mark solids 1 $merged
    ::hmtoolkit::seam::entity::mark surfs 2 [concat $sourceSurfs $targetSurfs]
    ::hmtoolkit::seam::native::undocumented::trim_solids_by_surfaces 1 2 1
    set trimSolids [::hmtoolkit::seam::executor::temp_component_solids [list $tempA $tempB]]
    ::hmtoolkit::seam::temp::register_entity $scope solids $trimSolids
    if {[llength $trimSolids] < 2} { error "Solid trim did not create enough transaction-owned regions" }

    set volumeTolerance [::hmtoolkit::seam::config::get volume_tolerance]
    set ranked {}
    foreach solidId $trimSolids {
        set volume [hm_getvolumeofsolid solids $solidId]
        if {$volume > $volumeTolerance} { lappend ranked [list [expr {abs($mergedVolume-$volume)}] $solidId] }
    }
    if {[llength $ranked] < 2} { error "Trimmed solid volumes are below tolerance" }
    set ranked [lsort -real -index 0 $ranked]
    # Preserve the reviewed command semantics while selecting solely from
    # transaction-owned IDs: delete the closest-volume region without its
    # faces, then completely remove the other trim regions.
    set preserveFacesIds [list [lindex [lindex $ranked 0] 1]]
    if {[::hmtoolkit::seam::entity::exists solids [lindex $merged 0]]} { lappend preserveFacesIds [lindex $merged 0] }
    if {[llength $preserveFacesIds] > 0} {
        ::hmtoolkit::seam::entity::mark solids 1 $preserveFacesIds
        *deletesolidswithelems 1 0 1
    }
    set discard {}
    foreach row [lrange $ranked 1 end] { lappend discard [lindex $row 1] }
    if {[llength $discard] > 0} {
        ::hmtoolkit::seam::entity::mark solids 1 $discard
        *deletesolidswithelems 1 1 1
    }

    set seamBefore [::hmtoolkit::seam::entity::snapshot_ids surfs]
    set tempFaces [lsort -integer -unique \
        [concat [::hmtoolkit::seam::entity::component_surfaces [lindex $tempA 1]] \
                [::hmtoolkit::seam::entity::component_surfaces [lindex $tempB 1]]]]
    if {[llength $tempFaces] == 0} {
        error "No temporary faces survived the lap solid pipeline"
    }
    ::hmtoolkit::seam::entity::mark surfaces 1 $tempFaces
    ::hmtoolkit::seam::entity::mark surfaces 2 [concat $sourceSurfs $targetSurfs]
    set lapDistance [::hmtoolkit::seam::config::get lap_connect_distance]
    set minAngle [::hmtoolkit::seam::config::get connect_min_angle_to_target]
    set maxAngle [::hmtoolkit::seam::config::get connect_max_angle_edge_to_surf]
    set guideAngle [::hmtoolkit::seam::config::get connect_guide_angle]
    *connect_surfaces_11 1 2 1 1 $lapDistance $minAngle $maxAngle 1 0 2 $guideAngle 3 0
    set created [::hmtoolkit::seam::entity::diff_ids $seamBefore [::hmtoolkit::seam::entity::snapshot_ids surfs]]
    # advanced_options=3 extends the temporary faces in place. Those faces are
    # valid results even when HyperMesh allocates no new surface IDs.
    set final [::hmtoolkit::seam::executor::lap_result_surfaces \
        [list $tempA $tempB] $created]
    if {[llength $final] == 0} { error "No lap seam surfaces were extracted" }
    ::hmtoolkit::seam::entity::mark surfs 1 $final
    *movemark surfs 1 [lindex $component 0]
    ::hmtoolkit::seam::validation::surface_ids $final [lindex $component 1]
    set final [::hmtoolkit::seam::executor::equivalence_created_surfaces \
        $final $sourceSurfs $targetSurfs [lindex $component 1] $before]
    return [::hmtoolkit::seam::executor::success L_SURF $final [list [lindex $component 0]] {} "Lap seam surfaces created successfully."]
}

proc ::hmtoolkit::seam::executor::create_l_surface {data} {
    return [::hmtoolkit::seam::transaction::run "Create Lap Surface Seam" [list ::hmtoolkit::seam::executor::_create_l_surface $data]]
}

proc ::hmtoolkit::seam::executor::create_l_list {data} {
    return [::hmtoolkit::seam::transaction::run "Create Lap List Seam" [list ::hmtoolkit::seam::executor::_create_t $data L_LIST]]
}

proc ::hmtoolkit::seam::executor::_connect_edges {data} {
    set first [::hmtoolkit::seam::validation::require_ids $data first_lines lines]
    set second [::hmtoolkit::seam::validation::require_ids $data second_lines lines]
    if {[llength [lsort -integer -unique [concat $first $second]]] != [expr {[llength $first]+[llength $second]}]} { error "Edge groups must not overlap" }
    set organized [::hmtoolkit::seam::candidate::organize_ruled_surface_lines $first $second]
    set first [dict get $organized first_lines]
    set second [dict get $organized second_lines]
    set thickness [::hmtoolkit::seam::naming::thickness_from_data $data]
    set component [::hmtoolkit::seam::naming::get_or_create_component $thickness]
    set before [::hmtoolkit::seam::entity::component_surfaces [lindex $component 1]]
    set beforeAll [::hmtoolkit::seam::entity::snapshot_ids surfs]
    set firstSurfs [::hmtoolkit::seam::executor::surfaces_from_lines $first]
    set secondSurfs [::hmtoolkit::seam::executor::surfaces_from_lines $second]
    ::hmtoolkit::seam::executor::prepare_ruled_surface_lists $first $second
    *linearsurfacebetweenlines 1 1 2 2 1
    set preliminary [::hmtoolkit::seam::validation::created_surfaces_for_component $before $beforeAll [lindex $component 1]]
    # *multi_surfs_lines_merge consumes the global cleanup tolerance; the
    # shared helper pins it for this call and restores the session value.
    ::hmtoolkit::seam::executor::merge_ruled_surfaces $preliminary
    set created [::hmtoolkit::seam::validation::created_surfaces_for_component $before $beforeAll [lindex $component 1]]
    set created [::hmtoolkit::seam::executor::equivalence_created_surfaces \
        $created $firstSurfs $secondSurfs [lindex $component 1] $before]
    return [::hmtoolkit::seam::executor::success CONNECT $created [list [lindex $component 0]]]
}

proc ::hmtoolkit::seam::executor::connect_edges {data} {
    return [::hmtoolkit::seam::transaction::run "Connect Seam Edges" [list ::hmtoolkit::seam::executor::_connect_edges $data]]
}

proc ::hmtoolkit::seam::executor::_split_surface {data strategy} {
    set lines [::hmtoolkit::seam::validation::require_ids $data seam_lines lines]
    set surfaces [::hmtoolkit::seam::validation::require_ids $data target_surfs surfs]
    set beforeEdges [::hmtoolkit::seam::entity::surface_lines $surfaces]
    set created {}
    foreach surfaceId $surfaces {
        set before [::hmtoolkit::seam::entity::snapshot_ids surfs]
        ::hmtoolkit::seam::entity::mark lines 2 $lines
        ::hmtoolkit::seam::entity::mark surfs 1 [list $surfaceId]
        *surfacemarksplitwithlines 1 2 0 13 0
        set targetCreated [::hmtoolkit::seam::entity::diff_ids \
            $before [::hmtoolkit::seam::entity::snapshot_ids surfs]]
        set created [concat $created $targetCreated]
    }
    set created [lsort -integer -unique $created]
    # Surface splitting can update the selected surface in place. A successful
    # native command therefore remains valid even when no new surface ID is
    # allocated; rolling it back here made Project appear to do nothing.
    set afterEdges [::hmtoolkit::seam::entity::surface_lines \
        [::hmtoolkit::seam::executor::existing_surfaces $surfaces]]
    if {[llength $created] == 0 && $beforeEdges ne "" && $beforeEdges eq $afterEdges} {
        error "The surface split created no new surface and did not change the selected surfaces; check the projection direction and line-to-surface distance"
    }
    set result [::hmtoolkit::seam::executor::success \
        $strategy $created {} {} "Target surfaces split successfully."]
    dict set result modified_surfs [lsort -integer -unique $surfaces]
    return $result
}

proc ::hmtoolkit::seam::executor::project_lines {data} {
    return [::hmtoolkit::seam::transaction::run "Project Seam Lines" [list ::hmtoolkit::seam::executor::_split_surface $data PROJECT]]
}

proc ::hmtoolkit::seam::executor::split_surface {data} {
    return [::hmtoolkit::seam::transaction::run "Split Surface" [list ::hmtoolkit::seam::executor::_split_surface $data SPLIT]]
}

proc ::hmtoolkit::seam::executor::_combine_surfaces {data} {
    set surfaces [::hmtoolkit::seam::validation::require_ids $data surfaces surfs]
    ::hmtoolkit::seam::entity::mark surfs 1 $surfaces
    set beforeEdges [::hmtoolkit::seam::entity::surface_lines $surfaces]
    ::hmtoolkit::seam::native::with_cleanup_tolerance \
        [::hmtoolkit::seam::config::get cleanup_tolerance] {
        *multi_surfs_lines_merge 1 0 0
    }
    set afterEdges [::hmtoolkit::seam::entity::surface_lines $surfaces]
    set warnings {}
    if {[lsort -integer -unique $beforeEdges] eq [lsort -integer -unique $afterEdges]} {
        lappend warnings "No topology change was required: the surfaces were already equivalent."
    }
    return [::hmtoolkit::seam::executor::success COMBINE {} {} $warnings]
}

proc ::hmtoolkit::seam::executor::combine_surfaces {data} {
    return [::hmtoolkit::seam::transaction::run "Combine Seam Surfaces" [list ::hmtoolkit::seam::executor::_combine_surfaces $data]]
}

proc ::hmtoolkit::seam::executor::_distribute_points {data} {
    set lines [::hmtoolkit::seam::validation::require_ids $data seam_lines lines]
    set spacing [::hmtoolkit::seam::config::get point_spacing]
    if {[dict exists $data spacing]} { set spacing [dict get $data spacing] }
    if {![string is double -strict $spacing] || $spacing <= 0.0} { error "Point spacing must be positive" }
    set created {}; set warnings {}
    foreach lineId $lines {
        set length [::hmtoolkit::seam::candidate::line_length $lineId]
        set segments [expr {max(1,round($length/double($spacing)))}]
        set count [expr {$segments-1}]
        if {$count < 1} { lappend warnings "Line $lineId is too short; no point was created."; continue }
        set before [::hmtoolkit::seam::entity::snapshot_ids points]
        if {[catch {
            ::hmtoolkit::seam::entity::mark lines 1 [list $lineId]
            ::hmtoolkit::seam::native::undocumented::edges_mark_add_points 1 $count
        } message]} {
            lappend warnings "Line $lineId failed: $message"; continue
        }
        set created [concat $created [::hmtoolkit::seam::entity::diff_ids $before [::hmtoolkit::seam::entity::snapshot_ids points]]]
    }
    set created [lsort -integer -unique $created]
    if {[llength $created] == 0} {
        error "No distributed points were created. [join $warnings {; }]"
    }
    return [dict create success 1 strategy DISTRIBUTE_POINTS created_points $created created_surfs {} created_components {} warnings $warnings message "Distributed points completed."]
}

proc ::hmtoolkit::seam::executor::distribute_points {data} {
    return [::hmtoolkit::seam::transaction::run "Distribute Seam Points" [list ::hmtoolkit::seam::executor::_distribute_points $data]]
}

proc ::hmtoolkit::seam::executor::_replace_point {data} {
    set point [lindex [::hmtoolkit::seam::validation::require_ids $data points points 1] 0]
    set line [lindex [::hmtoolkit::seam::validation::require_ids $data seam_lines lines 1] 0]
    set before [::hmtoolkit::seam::entity::snapshot_ids points]
    ::hmtoolkit::seam::entity::mark points 1 [list $point]
    ::hmtoolkit::seam::entity::mark lines 2 [list $line]
    # HM2019 baseline: -1 is the legacy "nearest edge, unlimited distance"
    # behavior recorded from the working replace-point flow. The audit's
    # explicit 1e6 tolerance was verified on HM2022.3 only.
    *projectpointstoedges 2 1 -1 0
    set projected [::hmtoolkit::seam::entity::diff_ids $before [::hmtoolkit::seam::entity::snapshot_ids points]]
    if {[llength $projected] > 1} { error "Projection created [llength $projected] points; at most one was expected" }
    set warnings {}
    if {[llength $projected] == 1} {
        ::hmtoolkit::seam::entity::mark points 1 [list $point]
        *verticescombine [lindex $projected 0] 1
    } else {
        lappend warnings "The edge was updated in place or already contained the projected vertex."
    }
    set result [::hmtoolkit::seam::executor::success REPLACE_POINT {} {} $warnings]
    dict set result modified_lines [list $line]
    dict set result created_points $projected
    return $result
}

proc ::hmtoolkit::seam::executor::replace_point {data} {
    return [::hmtoolkit::seam::transaction::run "Replace Seam Point" [list ::hmtoolkit::seam::executor::_replace_point $data]]
}

proc ::hmtoolkit::seam::executor::extend_to_target {line source target sourceCompId sourceCompName} {
    variable ::hmtoolkit::seam::runtime
    set temp [::hmtoolkit::seam::temp::create_component $runtime(active_temp_token)]
    set tempName [lindex $temp 0]
    set tempId [lindex $temp 1]
    ::hmtoolkit::seam::native::ensure_current_component $tempName $tempId
    # Duplicate the target into the temporary component and verify ownership
    # before anything else: the offset/extension pipeline depends on it.
    ::hmtoolkit::seam::entity::mark surfs 2 [list $target]
    *duplicatemark surfs 2 1
    set copies [::hmtoolkit::seam::native::mark_by_component_checked surfs 2 $tempName]
    # Dual-version probe evidence (2026-08-07, local 2019.0.0.70 and
    # 2022.0.0.33, identical fixture on both): *offset_surfaces_and_modify
    # parses
    #   entity_type mark_id surf_mark_id line_mark offset_type offset
    # with the signed distance LAST. The previous "recorded" layout
    # (surfaces 2 2 1 -<dist> 2) consumed the configured distance as an
    # ignored offset_type flag and hard-coded a +2 offset on BOTH builds
    # (measured new-vertex z=+2 vs the documented -12), so
    # extend_offset_distance never took effect. surf_mark_id is reserved and
    # must be 0 or an empty mark; offset_type=2 is disjoint offset with
    # degeneration removal (probe-verified to execute on both builds).
    ::hmtoolkit::seam::entity::mark surfs 2 $copies
    *offset_surfaces_and_modify surfaces 2 0 1 2 \
        [expr {-[::hmtoolkit::seam::config::get extend_offset_distance]}]
    # The offset may modify the copies in place or create new guide surfaces;
    # either way the guide set is everything the temp component owns now.
    set copies [::hmtoolkit::seam::native::mark_by_component_checked surfs 2 $tempName]
    set before [::hmtoolkit::seam::entity::snapshot_ids surfs]
    set sourceEdgesBefore [::hmtoolkit::seam::entity::surface_lines $source]
    ::hmtoolkit::seam::entity::mark lines 1 [list $line]
    ::hmtoolkit::seam::entity::mark surfs 1 [concat $source $copies]
    ::hmtoolkit::seam::log::write INFO \
        "Extend native args: *offset_surfaces_and_modify surfaces 2 0 1 2 [expr {-[::hmtoolkit::seam::config::get extend_offset_distance]}]; *connect_surfaces_11 1 1 3 2 0 15 30 1 0 2 30 3 0; target=$target"
    *connect_surfaces_11 1 1 3 2 0 15 30 1 0 2 30 3 0
    set created [::hmtoolkit::seam::entity::diff_ids $before [::hmtoolkit::seam::entity::snapshot_ids surfs]]
    if {[llength $created] > 0} {
        ::hmtoolkit::seam::entity::mark surfs 1 $created
        *movemark surfs 1 $sourceCompName
    }
    # A no-op native extension must not be reported as a successful seam
    # extension: created surfaces are the normal outcome; an in-place source
    # modification is the only legitimate empty-created case, detected through
    # the source edge topology. When the edge query itself is unavailable the
    # guard degrades to the legacy behavior instead of guessing.
    set sourceEdgesAfter [::hmtoolkit::seam::entity::surface_lines \
        [::hmtoolkit::seam::executor::existing_surfaces $source]]
    if {[llength $created] == 0 && $sourceEdgesBefore ne "" && $sourceEdgesBefore eq $sourceEdgesAfter} {
        error "The native extension created no seam surface and left the source surface unchanged; check the extension offset distance and trim mode"
    }
    set extended [::hmtoolkit::seam::executor::extended_result_surfaces \
        $source $created $sourceCompId]
    if {[llength $extended] == 0} { error "No extended seam surface survived the native extension" }
    ::hmtoolkit::seam::validation::surface_ids $extended $sourceCompId
    # The target is intentionally offset before extension, so it is a guide
    # rather than a coincident topology partner. Requiring a shared edge with
    # the original, unoffset target would always undo a valid extension.
    return $extended
}

proc ::hmtoolkit::seam::executor::_extend_surface {data} {
    set line [lindex [::hmtoolkit::seam::validation::require_ids $data seam_lines lines 1] 0]
    set targets [::hmtoolkit::seam::validation::require_ids $data target_surfs surfs]
    set owners [::hmtoolkit::seam::executor::surfaces_from_lines [list $line]]
    if {[llength $owners] == 0} { error "Selected line has no owner surface" }
    set source [::hmtoolkit::seam::executor::resolve_extend_source $owners]
    set sourceCompId [::hmtoolkit::seam::entity::surface_component [lindex $source 0]]
    set sourceCompName [::HWFlow::componentName $sourceCompId]
    if {$sourceCompName eq ""} { error "Unable to resolve the source seam component" }
    set created {}
    foreach target $targets {
        set targetCreated [::hmtoolkit::seam::executor::extend_to_target \
            $line $source $target $sourceCompId $sourceCompName]
        set created [concat $created $targetCreated]
    }
    set created [lsort -integer -unique $created]
    return [::hmtoolkit::seam::executor::success EXTEND $created {}]
}

proc ::hmtoolkit::seam::executor::extend_surface {data} {
    return [::hmtoolkit::seam::transaction::run "Extend Seam Surface" [list ::hmtoolkit::seam::executor::_extend_surface $data]]
}

proc ::hmtoolkit::seam::executor::_delete_seam_surface {data} {
    set surfaces [::hmtoolkit::seam::validation::require_ids $data surfaces surfs]
    set beforeLines [::hmtoolkit::seam::entity::snapshot_ids lines]
    ::hmtoolkit::seam::entity::mark surfs 1 $surfaces
    *deletemark surfs 1
    set newLines [::hmtoolkit::seam::entity::diff_ids $beforeLines [::hmtoolkit::seam::entity::snapshot_ids lines]]
    set warnings {}
    foreach lineId $newLines {
        if {[catch {::hmtoolkit::seam::entity::mark lines 1 [list $lineId]; *edgesmarkuntrim 1} message]} {
            lappend warnings "Line $lineId could not be untrimmed: $message"
        }
    }
    return [dict create success 1 strategy DELETE deleted_surfs $surfaces created_surfs {} created_components {} warnings $warnings message "Seam surfaces deleted."]
}

proc ::hmtoolkit::seam::executor::delete_seam_surface {data} {
    return [::hmtoolkit::seam::transaction::run "Delete Seam Surfaces" [list ::hmtoolkit::seam::executor::_delete_seam_surface $data]]
}

proc ::hmtoolkit::seam::executor::dispatch {strategy data} {
    switch -- $strategy {
        T_PATH { return [::hmtoolkit::seam::executor::create_t_path $data] }
        T_LIST { return [::hmtoolkit::seam::executor::create_t_list $data] }
        L_SURF { return [::hmtoolkit::seam::executor::create_l_surface $data] }
        L_LIST { return [::hmtoolkit::seam::executor::create_l_list $data] }
        CONNECT { return [::hmtoolkit::seam::executor::connect_edges $data] }
        PROJECT { return [::hmtoolkit::seam::executor::project_lines $data] }
        EXTEND { return [::hmtoolkit::seam::executor::extend_surface $data] }
        COMBINE { return [::hmtoolkit::seam::executor::combine_surfaces $data] }
        SPLIT { return [::hmtoolkit::seam::executor::split_surface $data] }
        REPLACE_POINT { return [::hmtoolkit::seam::executor::replace_point $data] }
        DISTRIBUTE_POINTS { return [::hmtoolkit::seam::executor::distribute_points $data] }
        DELETE { return [::hmtoolkit::seam::executor::delete_seam_surface $data] }
        default { return [dict create success 0 error_code UNSUPPORTED_STRATEGY message "Unsupported or review-only seam strategy: $strategy" warnings {}] }
    }
}
