source -encoding utf-8 [file join [file dirname [info script]] auto_group.tcl]

# Collect complete pairs without running detection or changing the model.
proc ::SolidSeam::collectSelectionPairs {} {
    variable ui; variable selectionOutcome; variable queuedPairCount
    set pairs {}; set queuedPairCount 0
    while {1} {
        ::SolidSeam::clearInputSelection
        set selectionOutcome SUBMIT
        set code [catch {
            if {$ui(input_type) eq "NODES_COMPS"} {
                set selection [::SolidSeam::selectNodesAndComponents]
            } else {
                set comps [::SolidSeam::selectComponents]
                set selection {}
                if {[llength $comps]} { set selection [dict create node_ids {} component_ids $comps] }
            }
        } err opts]
        ::SolidSeam::clearInputSelection
        if {$code} {
            ::SolidSeam::log ERROR "selection: $err"
            ::SolidSeam::message error $err
            continue
        }
        if {$selection eq ""} {
            if {$selectionOutcome eq "SUBMIT"} { break }
            continue
        }
        lappend pairs $selection
        set queuedPairCount [llength $pairs]
    }
    return $pairs
}

# Resolve all geometry before creating any weld. Later pairs must not detect
# nodes/elements introduced by earlier pairs in this same batch.
proc ::SolidSeam::prepareSelectionPairs {pairs} {
    variable ui
    set ownsCache [expr {$ui(input_type) eq "AUTO" &&
        (![info exists ::SolidSeam::groupRecognitionActive] || !$::SolidSeam::groupRecognitionActive)}]
    if {$ownsCache} {
        set components {}
        foreach selection $pairs {
            if {[dict exists $selection component_ids]} { set components [concat $components [dict get $selection component_ids]] }
        }
        ::SolidSeam::beginGroupRecognitionCache $components
    }
    set code [catch {::SolidSeam::prepareSelectionPairsImpl $pairs} result opts]
    if {$ownsCache} { ::SolidSeam::endGroupRecognitionCache }
    if {$code} { return -options $opts $result }
    return $result
}

proc ::SolidSeam::prepareSelectionPairsImpl {pairs} {
    variable ui; variable candidateRows
    set plans {}; set index 0
    foreach selection $pairs {
        incr index
        set candidateRows {}
        set code [catch {
            set comps [dict get $selection component_ids]
            if {[llength $comps] != 2} { error "A batch group requires exactly two components" }
            if {$ui(input_type) eq "NODES_COMPS"} {
                set rows [::SolidSeam::createFromNodes [dict get $selection node_ids] $comps 1]
            } else {
                set rows [::SolidSeam::autoDetectAndCreate $comps 1]
            }
            set tagged {}
            foreach row $rows {
                dict set row candidate_id "PAIR_${index}_[dict get $row candidate_id]"
                set row [::SolidSeam::finalizeCandidateDiagnostics $row]
                lappend tagged $row
            }
            if {![llength $tagged]} { error "No weld candidates in pair $index" }
        } err opts]
        ::SolidSeam::clearInputSelection
        if {$code} {
            lappend plans [dict create pair_index $index error $err]
        } else {
            lappend plans [dict create pair_index $index candidates $tagged]
        }
    }
    set candidateRows {}
    return $plans
}

proc ::SolidSeam::executeSelectionPlan {plan} {
    variable runtimeDir; variable candidateRows
    set runtimeDir ""
    set index [dict get $plan pair_index]
    set code [catch {
        ::SolidSeam::newRun
        ::SolidSeam::log INFO "batch pair=$index"
        if {[dict exists $plan recognition_timings]} { ::SolidSeam::log INFO "recognition timings=[dict get $plan recognition_timings]" }
        if {[dict exists $plan error]} { error [dict get $plan error] }
        set candidateRows [dict get $plan candidates]
        ::SolidSeam::createAcceptedCandidates
    } err opts]
    ::SolidSeam::clearInputSelection
    if {$runtimeDir ne ""} {
        catch {::HybridCore::finalizeTaskWorkspace $runtimeDir [expr {$code ? "FAILED" : "SUCCESS"}]}
    }
    if {$code} {
        ::SolidSeam::log ERROR "pair=$index: $err"
        if {$::SolidSeam::ui(input_type) ne "AUTO_GROUP"} {
            ::SolidSeam::message error [::SolidSeam::txt "第 $index 组执行失败：$err" "Pair $index failed: $err"]
        }
        return 0
    }
    return 1
}

proc ::SolidSeam::runDetection {} {
    variable running; variable ui; variable queuedPairCount; variable runtimeDir
    if {[info exists running] && $running} { return 0 }
    set running 1
    set runtimeDir ""
    catch {.solid_seam.buttons.run configure -state disabled}
    set windows {}; set sessionStarted 0; set groupWorkspace ""; set progressOpened 0
    set ::SolidSeam::groupLogPath ""
    set completed 0; set failed 0
    set code [catch {
        ::SolidSeam::validateSettings
        ::SolidSeam::saveState
        set windows [::HWFlow::nativePanelSessionBegin]
        set sessionStarted 1
        if {$ui(input_type) eq "AUTO_GROUP"} {
            set components [::SolidSeam::selectAutoGroupComponents]
            if {[llength $components]} {
                set workspace [::HybridCore::createTaskWorkspace solid_seam]
                set groupWorkspace [dict get $workspace task_dir]
                set ::SolidSeam::groupLogPath [file join $groupWorkspace operation.log]
                catch {set progressOpened [::HWFlow::progressOpen "Solid Seam AutoGroup" [::SolidSeam::txt "正在自动配对..." "Matching components..."] 0]}
            }
            set plans [::SolidSeam::prepareAutoGroup $components]
        } else {
            set pairs [::SolidSeam::collectSelectionPairs]
            set ui(status) [::SolidSeam::txt "正在计算 [llength $pairs] 组焊缝路径与参数..." "Preparing [llength $pairs] weld pairs..."]
            update idletasks
            set plans [::SolidSeam::prepareSelectionPairs $pairs]
        }
        foreach plan $plans {
            set index [dict get $plan pair_index]
            set ui(status) [::SolidSeam::txt "正在执行第 $index / [llength $plans] 组..." "Executing pair $index / [llength $plans]..."]
            update idletasks
            if {$ui(input_type) eq "AUTO_GROUP"} {
                ::SolidSeam::groupProgress [expr {50.0+50.0*($index-1)/max(1,[llength $plans])}] $ui(status) 1
            }
            if {[::SolidSeam::executeSelectionPlan $plan]} { incr completed } else { incr failed }
        }
        set ui(status) [::SolidSeam::txt \
            "批量执行结束：成功 $completed 组，失败 $failed 组。可调整参数后再次开始。" \
            "Batch complete: $completed successful pairs, $failed failed pairs. Adjust settings and start again."]
        if {$ui(input_type) eq "AUTO_GROUP"} {
            append ui(status) " " $::SolidSeam::autoGroupSummary
            ::SolidSeam::groupProgress 100 $ui(status) 1
        }
    } err opts]
    ::SolidSeam::clearInputSelection
    set queuedPairCount 0
    if {$sessionStarted} { ::HWFlow::nativePanelSessionEnd $windows }
    set running 0
    catch {.solid_seam.buttons.run configure -state normal}
    if {$groupWorkspace ne ""} {
        catch {::HybridCore::finalizeTaskWorkspace $groupWorkspace [expr {$code || $failed || $::SolidSeam::autoGroupIssues ? "FAILED" : "SUCCESS"}]}
    }
    set ::SolidSeam::groupLogPath ""
    if {$code} {
        set ui(status) [::SolidSeam::txt "批量任务未完成：$err" "Batch interrupted: $err"]
        ::SolidSeam::log ERROR $err
        ::SolidSeam::message error $ui(status)
        if {$progressOpened} { catch {::HWFlow::progressFinish $ui(status)} }
        return 0
    }
    if {$progressOpened} { catch {::HWFlow::progressFinish $ui(status)} }
    return [expr {$completed > 0}]
}

proc ::SolidSeam::runAction {} { return [::SolidSeam::showPanel] }
proc ::SolidSeam::run {} { ::SolidSeam::runAction }
