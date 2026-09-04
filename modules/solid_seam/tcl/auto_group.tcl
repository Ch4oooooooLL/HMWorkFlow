# AutoGroup uses the same detector as Auto, preparing every pair before realization.
proc ::SolidSeam::groupProgress {percent text} {
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

# Prefer the direction with the smaller maximum gap relative to local mesh size.
# Equal scores retain sorted component order, never creating both directions.
proc ::SolidSeam::groupDirectionScore {rows} {
    set score 0.0
    foreach row $rows {
        set score [expr {$score + [dict get $row maximum_gap]/[dict get $row mesh_size]}]
    }
    return [expr {$score/max(1,[llength $rows])}]
}

proc ::SolidSeam::prepareAutoGroup {components} {
    variable autoGroupSummary; variable autoGroupIssues
    set autoGroupIssues 0
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
    set total [expr {[llength $usable]*([llength $usable]-1)/2}]; set checked 0
    # Stream combinations instead of allocating an O(n^2) pair list.
    for {set i 0} {$i < [llength $usable]} {incr i} {
        set a [lindex $usable $i]
        foreach b [lrange $usable [expr {$i+1}] end] {
            incr checked
            set percent [expr {10.0+40.0*$checked/max(1,$total)}]
            ::SolidSeam::groupProgress $percent "pair $checked/$total: comps=$a,$b"
            lassign [dict get $metadata $a] pitchA boundsA
            lassign [dict get $metadata $b] pitchB boundsB
            set pitch [expr {max($pitchA,$pitchB)}]; set radius [expr {1.5*$pitch}]
            if {![::SolidSeam::groupBoundsNear $boundsA $boundsB $radius]} {
                incr unmatched
                ::SolidSeam::log INFO "AutoGroup skip comps=$a,$b: outside search range"
                continue
            }
            set settings [dict create automatic 1 search_distance $radius max_search_distance $radius \
                min_weld_length 0.0 gap_jump_limit 0.0 default_width [expr {0.6*$pitch}] default_spacing [expr {0.6*$pitch}]]
            set best {}; set bestScore Inf; set pairError 0
            foreach direction [list [list $a $b] [list $b $a]] {
                lassign $direction source target
                ::SolidSeam::groupProgress $percent "detect $source -> $target"
                if {[catch {
                    set rows [::SolidSeam::autoDetectSeams $source $target $settings]
                    if {[llength $rows]} {
                        set score [::SolidSeam::groupDirectionScore $rows]
                        if {$score < $bestScore} { set best $rows; set bestScore $score }
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
            foreach row $best {
                dict set row candidate_id "GROUP_${pairIndex}_[dict get $row candidate_id]"
                dict set row status ACCEPTED
                lappend tagged $row
            }
            dict set matched $a 1; dict set matched $b 1
            lappend plans [dict create pair_index $pairIndex candidates $tagged]
            ::SolidSeam::log INFO "AutoGroup matched [dict get [lindex $best 0] source_component_id] -> [dict get [lindex $best 0] target_component_id]: seams=[llength $best] score=$bestScore"
        }
    }
    set isolated {}
    foreach component $usable { if {![dict exists $matched $component]} { lappend isolated $component } }
    set autoGroupIssues [expr {$errors+$invalid}]
    set autoGroupSummary [::SolidSeam::txt \
        "识别 [llength $plans] 对，跳过 $unmatched 对，识别失败 $errors 对，无效组件 $invalid 个，未配对组件：$isolated。" \
        "Matched [llength $plans] pairs, skipped $unmatched, detection failures $errors, invalid components $invalid; unmatched components: $isolated."]
    ::SolidSeam::groupProgress 50 $autoGroupSummary
    return $plans
}
