# AutoGroup uses the same detector as Auto, preparing every pair before realization.
proc ::SolidSeam::groupProgress {percent text {force 0}} {
    variable groupProgressLastMs
    set now [clock milliseconds]
    if {!$force && [info exists groupProgressLastMs] && $now-$groupProgressLastMs < 100} { return }
    set groupProgressLastMs $now
    ::SolidSeam::log INFO "AutoGroup: $text"
    catch {hm_usermessage $text}
    catch {::HWFlow::progressUpdate $percent $text}
    catch {::HWFlow::progressPumpEvents 0}
}

proc ::SolidSeam::selectAutoGroupComponents {} {
    ::SolidSeam::clearInputSelection
    set code [catch {
        set ids [lsort -integer -unique [::HWFlow::nativeMarkPanel components 1 \
            [::SolidSeam::txt "AutoGroup：一次选择所有待处理组件（至少两个；空选取消）" "AutoGroup: select all components (at least two; empty cancels)"]]]
        if {[llength $ids] == 1} { error [::SolidSeam::txt "AutoGroup 至少需要两个组件。" "AutoGroup requires at least two components."] }
    } err opts]
    ::SolidSeam::clearInputSelection
    if {$code} { return -options $opts $err }
    return $ids
}

proc ::SolidSeam::groupComponentBounds {component} {
    if {[llength [info commands hm_getboundingbox]] && ![catch {set saved [hm_getmark comps 1]}]} {
        set code [catch {
            *createmark comps 1 $component
            set box [hm_getboundingbox comps 1 1 0 0]
            if {[llength $box] != 6} { error "Invalid native bounding box" }
            foreach value $box { if {![string is double -strict $value] || abs($value) == Inf} { error "Invalid bounding coordinate" } }
        }]
        *clearmark comps 1
        if {[llength $saved]} { *createmark comps 1 {*}$saved }
        if {!$code} { return [list [lrange $box 0 2] [lrange $box 3 5]] }
    }
    set low {Inf Inf Inf}; set high {-Inf -Inf -Inf}
    set nodes [::SolidSeam::componentNodeIds $component]
    if {![llength $nodes]} { error "Component $component has no mesh nodes" }
    foreach node $nodes {
        set xyz [::SolidSeam::nodeXYZ $node]
        for {set axis 0} {$axis < 3} {incr axis} {
            set value [lindex $xyz $axis]
            lset low $axis [expr {min([lindex $low $axis],$value)}]
            lset high $axis [expr {max([lindex $high $axis],$value)}]
        }
    }
    return [list $low $high]
}

proc ::SolidSeam::groupBoundsNear {a b radius} {
    set squared 0.0
    for {set axis 0} {$axis < 3} {incr axis} {
        set gap [expr {max(0.0, [lindex $a 0 $axis]-[lindex $b 1 $axis], [lindex $b 0 $axis]-[lindex $a 1 $axis])}]
        set squared [expr {$squared+$gap*$gap}]
    }
    return [expr {$squared <= $radius*$radius}]
}

# Conservative broad phase for the unchanged legacy AABB-distance test.
# Each box is expanded by its own Auto radius. Expanded overlap is a superset
# of every pair accepted by groupBoundsNear(max(radiusA,radiusB)); the exact
# legacy test below removes false positives. Returned pairs are sorted back to
# the old nested-loop order so candidate and native creation order stay stable.
proc ::SolidSeam::groupSpatialPairs {components metadata} {
    set records {}; set index 0
    foreach component $components {
        lassign [dict get $metadata $component] pitch bounds
        set radius [expr {1.5*$pitch}]
        lassign $bounds low high
        lappend records [list \
            [expr {[lindex $low 0]-$radius}] [expr {[lindex $high 0]+$radius}] \
            [expr {[lindex $low 1]-$radius}] [expr {[lindex $high 1]+$radius}] \
            [expr {[lindex $low 2]-$radius}] [expr {[lindex $high 2]+$radius}] \
            $index $component]
        incr index
    }
    set active {}; set candidates {}; set sweepTests 0
    foreach current [lsort -real -index 0 $records] {
        lassign $current xmin xmax ymin ymax zmin zmax currentIndex currentComponent
        set retained {}
        foreach prior $active {
            lassign $prior pxmin pxmax pymin pymax pzmin pzmax priorIndex priorComponent
            if {$pxmax < $xmin} { continue }
            lappend retained $prior
            incr sweepTests
            if {$pymax < $ymin || $ymax < $pymin || $pzmax < $zmin || $zmax < $pzmin} { continue }
            set i $priorIndex; set j $currentIndex
            set componentA $priorComponent; set componentB $currentComponent
            if {$i > $j} { set swap $i; set i $j; set j $swap; set swap $componentA; set componentA $componentB; set componentB $swap }
            lassign [dict get $metadata $componentA] pitchA boundsA
            lassign [dict get $metadata $componentB] pitchB boundsB
            if {![::SolidSeam::groupBoundsNear $boundsA $boundsB [expr {1.5*max($pitchA,$pitchB)}]]} { continue }
            set rank [expr {$i*[llength $components]+$j}]
            lappend candidates [list $rank $componentA $componentB]
        }
        lappend retained $current
        set active $retained
    }
    set pairs {}
    foreach candidate [lsort -integer -index 0 $candidates] {
        lappend pairs [lrange $candidate 1 2]
    }
    set total [expr {[llength $components]*([llength $components]-1)/2}]
    return [dict create pairs $pairs total $total sweep_tests $sweepTests]
}

# Prefer the direction with the smaller maximum gap relative to local mesh size.
# Equal scores retain sorted component order, never creating both directions.
proc ::SolidSeam::groupDirectionScore {rows} {
    set score 0.0
    foreach row $rows {
        set score [expr {$score + [dict get $row maximum_gap]/[dict get $row mesh_size]}]
    }
    return [expr {$score/max(1,[llength $rows])}]
}

# Rows short enough to be layer-split debris cannot argue for a direction; a
# 2-node fragment otherwise outscored a real seam on a coarse target.  Debris
# is only kept when neither direction offers a real chain.
proc ::SolidSeam::groupUsableRows {rows} {
    set usable {}
    foreach row $rows {
        if {![dict exists $row node_ids] || [llength [dict get $row node_ids]] >= 3} { lappend usable $row }
    }
    return $usable
}

proc ::SolidSeam::beginGroupRecognitionCache {components} {
    variable groupRecognitionActive 1
    variable groupRecognitionComponents [lsort -integer -unique $components]
    variable groupStableElements; set groupStableElements [dict create]
    variable groupReadCache; array unset groupReadCache
    variable groupCoordinates; array unset groupCoordinates
    variable groupElementNodes; array unset groupElementNodes
    variable groupElementConfigs; array unset groupElementConfigs
}

proc ::SolidSeam::endGroupRecognitionCache {} {
    variable groupRecognitionActive 0
    variable groupRecognitionComponents {}
    variable groupStableElements; set groupStableElements [dict create]
    variable groupReadCache; array unset groupReadCache
    variable groupCoordinates; array unset groupCoordinates
    variable groupElementNodes; array unset groupElementNodes
    variable groupElementConfigs; array unset groupElementConfigs
}

proc ::SolidSeam::prepareAutoGroup {components} {
    ::SolidSeam::beginGroupRecognitionCache $components
    set code [catch {
        ::SolidSeam::prefetchComponentConnectivity $components
        ::SolidSeam::prepareAutoGroupImpl $components
    } result opts]
    ::SolidSeam::endGroupRecognitionCache
    if {$code} { return -options $opts $result }
    return $result
}

proc ::SolidSeam::prepareAutoGroupImpl {components} {
    variable autoGroupSummary; variable autoGroupIssues; variable groupProgressLastMs
    unset -nocomplain groupProgressLastMs
    set autoGroupIssues 0
    set totalStarted [clock milliseconds]
    set metadataStarted $totalStarted
    set components [lsort -integer -unique $components]
    set metadata {}; set usable {}; set invalid 0; set unmatched 0; set errors 0
    set plans {}; set matched {}; set index 0
    foreach component $components {
        incr index
        ::SolidSeam::groupProgress [expr {10.0*$index/max(1,[llength $components])}] "mesh $index/[llength $components]: comp=$component"
        if {[catch {
            set pitch [::SolidSeam::componentMeshPitch $component]
            set bounds [::SolidSeam::groupComponentBounds $component]
        } err]} {
            incr invalid
            ::SolidSeam::log ERROR "AutoGroup skip comp=$component: $err"
            continue
        }
        dict set metadata $component [list $pitch $bounds]
        lappend usable $component
    }
    set metadataMs [expr {[clock milliseconds]-$metadataStarted}]
    set broadphaseStarted [clock milliseconds]
    set broadphase [::SolidSeam::groupSpatialPairs $usable $metadata]
    set broadphaseMs [expr {[clock milliseconds]-$broadphaseStarted}]
    set total [dict get $broadphase total]
    set spatialPairs [dict get $broadphase pairs]
    set checked 0
    set unmatched [expr {$total-[llength $spatialPairs]}]
    ::SolidSeam::log INFO "AutoGroup broadphase total=$total survivors=[llength $spatialPairs] sweep_tests=[dict get $broadphase sweep_tests]"
    set directionalStarted [clock milliseconds]
    foreach pair $spatialPairs {
            lassign $pair a b
            incr checked
            set percent [expr {10.0+40.0*$checked/max(1,[llength $spatialPairs])}]
            ::SolidSeam::groupProgress $percent "candidate pair $checked/[llength $spatialPairs] (all=$total): comps=$a,$b"
            lassign [dict get $metadata $a] pitchA boundsA
            lassign [dict get $metadata $b] pitchB boundsB
            set pitch [expr {max($pitchA,$pitchB)}]; set radius [expr {1.5*$pitch}]
            set settings [dict create automatic 1 search_distance $radius max_search_distance $radius \
                min_weld_length 0.0 gap_jump_limit 0.0 default_width [expr {0.6*$pitch}] default_spacing [expr {0.6*$pitch}]]
            set best {}; set bestScore Inf; set bestUsable -1; set bestTimings {}; set pairError 0
            foreach direction [list [list $a $b] [list $b $a]] {
                lassign $direction source target
                ::SolidSeam::groupProgress $percent "detect $source -> $target"
                if {[catch {
                    set rows [::SolidSeam::autoDetectSeams $source $target $settings]
                    if {[llength $rows]} {
                        set usableRows [::SolidSeam::groupUsableRows $rows]
                        if {[llength $usableRows]} { set scored $usableRows; set usableFlag 1 } else { set scored $rows; set usableFlag 0 }
                        set score [::SolidSeam::groupDirectionScore $scored]
                        # Directions with a real chain beat debris-only ones;
                        # equal standing keeps the strict score comparison and
                        # the legacy first-direction tie-break.
                        if {$best eq "" || $usableFlag > $bestUsable ||
                            ($usableFlag == $bestUsable && $score < $bestScore)} {
                            set best $scored; set bestScore $score; set bestUsable $usableFlag; set bestTimings {}
                            if {[info exists ::SolidSeam::lastDetectionStages]} { set bestTimings $::SolidSeam::lastDetectionStages }
                        }
                    }
                } err]} {
                    set pairError 1
                    ::SolidSeam::log ERROR "AutoGroup detect $source -> $target: $err"
                }
            }
            if {![llength $best]} {
                if {$pairError} { incr errors } else { incr unmatched }
                ::SolidSeam::log INFO "AutoGroup skip comps=$a,$b: no usable seam; detection_error=$pairError"
                continue
            }
            set pairIndex [expr {[llength $plans]+1}]; set tagged {}
            set source [dict get [lindex $best 0] source_component_id]
            set target [dict get [lindex $best 0] target_component_id]
            set shadow {}
            if {[info exists ::SolidSeam::ui(shadow_face_distance)] && $::SolidSeam::ui(shadow_face_distance)} {
                if {[catch {set shadow [::SolidSeam::shadowFaceDistanceAudit $source $target $best $radius]} shadowError]} {
                    ::SolidSeam::log WARN "AutoGroup shadow face-distance failed $source -> $target: $shadowError"
                } else { ::SolidSeam::log INFO "AutoGroup shadow face-distance $source -> $target: $shadow" }
            }
            foreach row $best {
                dict set row candidate_id "GROUP_${pairIndex}_[dict get $row candidate_id]"
                dict set row status ACCEPTED
                dict set row recognition_timings $bestTimings
                if {$shadow ne ""} { dict set row shadow_face_summary $shadow }
                set row [::SolidSeam::finalizeCandidateDiagnostics $row]
                lappend tagged $row
            }
            dict set matched $a 1; dict set matched $b 1
            lappend plans [dict create pair_index $pairIndex candidates $tagged recognition_timings $bestTimings]
            ::SolidSeam::log INFO "AutoGroup matched [dict get [lindex $best 0] source_component_id] -> [dict get [lindex $best 0] target_component_id]: seams=[llength $best] score=$bestScore"
    }
    set isolated {}
    foreach component $usable { if {![dict exists $matched $component]} { lappend isolated $component } }
    set autoGroupIssues [expr {$errors+$invalid}]
    set directionalMs [expr {[clock milliseconds]-$directionalStarted}]
    set totalMs [expr {[clock milliseconds]-$totalStarted}]
    set groupTimings [dict create metadata_ms $metadataMs broadphase_ms $broadphaseMs directional_detection_ms $directionalMs total_prepare_ms $totalMs]
    set autoGroupSummary [::SolidSeam::txt \
        "识别 [llength $plans] 对，跳过 $unmatched 对，识别失败 $errors 对，无效组件 $invalid 个，未配对组件：$isolated。" \
        "Matched [llength $plans] pairs, skipped $unmatched, detection failures $errors, invalid components $invalid; unmatched components: $isolated."]
    ::SolidSeam::groupProgress 50 $autoGroupSummary 1
    ::SolidSeam::log INFO "AutoGroup stage timings=$groupTimings"
    return $plans
}
