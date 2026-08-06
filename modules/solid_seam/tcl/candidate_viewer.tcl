proc ::SolidSeam::candidateWindow {} { return .solid_seam_candidates }

proc ::SolidSeam::clearCandidatePreview {} {
    # *numbersmark annotations survive after the dialog is destroyed unless
    # they are explicitly cleared. Also clear this viewer's private node mark.
    catch {*numbersclear}
    catch {*clearmark nodes 1}
}

proc ::SolidSeam::closeCandidateWindow {} {
    set w [::SolidSeam::candidateWindow]
    ::SolidSeam::clearCandidatePreview
    if {[winfo exists $w]} { destroy $w }
}

proc ::SolidSeam::onCandidateWindowDestroy {window destroyedWindow} {
    # Covers indirect destruction, such as closing the parent toolkit.
    if {$destroyedWindow eq $window} { ::SolidSeam::clearCandidatePreview }
}

proc ::SolidSeam::fitCandidateNodes {nodeIds row} {
    set count 0
    foreach nodeId $nodeIds {
        if {[catch {set x [hm_getvalue nodes id=$nodeId dataname=x]}] ||
            [catch {set y [hm_getvalue nodes id=$nodeId dataname=y]}] ||
            [catch {set z [hm_getvalue nodes id=$nodeId dataname=z]}]} {
            continue
        }
        if {$count == 0} {
            set minX $x; set maxX $x
            set minY $y; set maxY $y
            set minZ $z; set maxZ $z
        } else {
            if {$x < $minX} { set minX $x }; if {$x > $maxX} { set maxX $x }
            if {$y < $minY} { set minY $y }; if {$y > $maxY} { set maxY $y }
            if {$z < $minZ} { set minZ $z }; if {$z > $maxZ} { set maxZ $z }
        }
        incr count
    }
    if {$count == 0} { return 0 }

    set centerX [expr {0.5 * ($minX + $maxX)}]
    set centerY [expr {0.5 * ($minY + $maxY)}]
    set centerZ [expr {0.5 * ($minZ + $maxZ)}]
    set radius [expr {max($maxX - $minX, $maxY - $minY, $maxZ - $minZ)}]

    # Adaptive seam parameters provide a model-scale lower bound for a short
    # chain. The 1.15 factor leaves modest padding around a normal chain.
    set contextRadius 0.0
    foreach field {line_spacing weld_width average_distance} {
        if {[dict exists $row $field] && [string is double -strict [dict get $row $field]]} {
            set contextRadius [expr {max($contextRadius, double([dict get $row $field]))}]
        }
    }
    set radius [expr {max(1.15 * $radius, 2.5 * $contextRadius)}]
    if {[dict exists $row realization_tolerance] &&
        [string is double -strict [dict get $row realization_tolerance]]} {
        # Search tolerance may legitimately be much larger than the weld
        # width, so give it context without letting it dominate the viewport.
        set radius [expr {max($radius, 1.25 * double([dict get $row realization_tolerance]))}]
    }
    if {$radius <= 0.0} { set radius 20.0 }

    if {[catch {*graphuserwindow_byXYZandR $centerX $centerY $centerZ $radius} err]} {
        ::SolidSeam::log WARN "candidate local fit failed: $err" [dict get $row candidate_id]
        return 0
    }
    return 1
}

proc ::SolidSeam::selectedCandidate {} {
    variable candidateRows
    set w [::SolidSeam::candidateWindow]
    if {![winfo exists $w] || [$w.main.list curselection] eq ""} { return "" }
    return [lindex $candidateRows [lindex [$w.main.list curselection] 0]]
}

proc ::SolidSeam::candidateLabel {row} {
    set pair "[dict get $row source_component_name] -> [dict get $row target_component_name]"
    return [format "%-12s %-36s %-11s %-13s %8.2f %8.2f %7.3f %-12s %-10s" \
        [dict get $row candidate_id] $pair [dict get $row joint_type] \
        [dict get $row suggested_realization] [dict get $row length] \
        [dict get $row average_distance] [dict get $row confidence] \
        [dict get $row duplicate_state] [dict get $row status]]
}

proc ::SolidSeam::candidateHeader {} {
    return [format "%-12s %-36s %-11s %-13s %8s %8s %7s %-12s %-10s" \
        "ID" [::SolidSeam::txt "源组件 -> 目标组件" "Source -> Target"] \
        [::SolidSeam::txt "接头" "Joint"] "PENTA" "Length" "Gap" "Conf." \
        [::SolidSeam::txt "重复" "Duplicate"] [::SolidSeam::txt "状态" "Status"]]
}

proc ::SolidSeam::candidateSummaryText {} {
    variable candidateRows
    array set counts {ACCEPTED 0 REJECTED 0 CREATED 0 FAILED 0 REVIEW 0}
    foreach row $candidateRows {
        set status [dict get $row status]
        if {[info exists counts($status)]} {
            incr counts($status)
        } else {
            incr counts(REVIEW)
        }
    }
    return [::SolidSeam::txt \
        "共 [llength $candidateRows] 条  |  已接受 $counts(ACCEPTED)  |  待审查 $counts(REVIEW)  |  已拒绝 $counts(REJECTED)  |  已创建 $counts(CREATED)  |  失败 $counts(FAILED)" \
        "Total [llength $candidateRows]  |  Accepted $counts(ACCEPTED)  |  Review $counts(REVIEW)  |  Rejected $counts(REJECTED)  |  Created $counts(CREATED)  |  Failed $counts(FAILED)"]
}

proc ::SolidSeam::refreshCandidateList {} {
    variable candidateRows
    set w [::SolidSeam::candidateWindow]
    if {![winfo exists $w]} { return }
    set selected [$w.main.list curselection]
    $w.main.list delete 0 end
    foreach row $candidateRows { $w.main.list insert end [::SolidSeam::candidateLabel $row] }
    if {$selected ne "" && [lindex $selected 0] < [llength $candidateRows]} { $w.main.list selection set [lindex $selected 0] }
    if {[winfo exists $w.summary]} { $w.summary configure -text [::SolidSeam::candidateSummaryText] }
}

proc ::SolidSeam::previewSelectedCandidate {} {
    set row [::SolidSeam::selectedCandidate]
    if {$row eq ""} { return }
    # Prevent node labels from accumulating while browsing candidates.
    catch {*numbersclear}
    catch {*clearmark nodes 1}
    if {[catch {eval *createmark nodes 1 [dict get $row node_ids]} err]} {
        ::SolidSeam::message error $err; return
    }
    # Native node mark is non-destructive. Keep selected source/target visible;
    # do not change topology or create temporary elements.
    catch {*numbersmark nodes 1 1}
    ::SolidSeam::fitCandidateNodes [dict get $row node_ids] $row
    ::SolidSeam::log INFO "preview nodes=[dict get $row node_ids]" [dict get $row candidate_id]
}

proc ::SolidSeam::setSelectedStatus {status} {
    set row [::SolidSeam::selectedCandidate]
    if {$row ne ""} { ::SolidSeam::updateCandidate [dict get $row candidate_id] status $status }
}

proc ::SolidSeam::setSelectedRealization {realization} {
    set row [::SolidSeam::selectedCandidate]
    if {$row ne ""} { ::SolidSeam::updateCandidate [dict get $row candidate_id] suggested_realization $realization }
}

proc ::SolidSeam::exportAcceptedCandidates {} {
    variable runtimeDir; variable candidateRows
    set lines [list "candidate_id,status,source_component_id,target_component_id,joint_type,realization,line_spacing,weld_width,realization_tolerance,side_mode,right_angled,node_ids"]
    foreach row $candidateRows {
        set values {}
        foreach field {candidate_id status source_component_id target_component_id joint_type suggested_realization line_spacing weld_width realization_tolerance side_mode right_angled} {
            lappend values [expr {[dict exists $row $field] ? [dict get $row $field] : ""}]
        }
        lappend values "\"[join [dict get $row node_ids] { }]\""
        lappend lines [join $values ,]
    }
    set path [file join $runtimeDir accepted_candidates.csv]
    ::HWFlow::writeTextFile $path [join $lines "\n"]
    ::SolidSeam::message info [::SolidSeam::txt "结果已导出：\n$path" "Results exported:\n$path"]
}

proc ::SolidSeam::showCandidateWindow {} {
    variable candidateRows
    set w [::SolidSeam::candidateWindow]
    if {[winfo exists $w]} { raise $w; ::SolidSeam::refreshCandidateList; return }
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::SolidSeam::txt "实体焊缝候选" "Solid Seam Candidates"] "Solid Seam Candidates"]
    wm minsize $w 1120 600
    wm protocol $w WM_DELETE_WINDOW ::SolidSeam::closeCandidateWindow
    bind $w <Escape> ::SolidSeam::closeCandidateWindow
    bind $w <Destroy> [list ::SolidSeam::onCandidateWindowDestroy $w %W]
    frame $w.header -padx 12 -pady 10; pack $w.header -fill x
    label $w.header.title -text [::SolidSeam::txt "可选焊缝列表" "Available Seam Candidates"] -font [::HWFlow::uiFont heading] -anchor w
    label $w.summary -text [::SolidSeam::candidateSummaryText] -anchor w
    label $w.header.note -anchor w -justify left -text [::SolidSeam::txt \
        "高置信度且无警告项可批量接受；REVIEW/LOW、分叉和重复项必须逐条审查。双击候选可预览节点。" \
        "High-confidence candidates without warnings may be batch accepted. Review REVIEW/LOW, branches, and duplicates individually. Double-click to preview nodes."]
    pack $w.header.title -fill x
    pack $w.summary -fill x -padx 12 -pady {0 4}
    pack $w.header.note -fill x -pady {4 0}

    frame $w.main -padx 12 -pady 6; pack $w.main -fill both -expand 1
    label $w.main.columns -text [::SolidSeam::candidateHeader] -font [::HWFlow::uiFont fixedSmall] -anchor w -relief groove -padx 3 -pady 3
    listbox $w.main.list -font [::HWFlow::uiFont fixedSmall] -selectmode browse -exportselection 0 -width 150 -height 18
    scrollbar $w.main.yscroll -orient vertical -command "$w.main.list yview"
    scrollbar $w.main.xscroll -orient horizontal -command "$w.main.list xview"
    $w.main.list configure -yscrollcommand "$w.main.yscroll set" -xscrollcommand "$w.main.xscroll set"
    grid $w.main.columns -row 0 -column 0 -sticky ew
    grid $w.main.list -row 1 -column 0 -sticky nsew
    grid $w.main.yscroll -row 1 -column 1 -sticky ns
    grid $w.main.xscroll -row 2 -column 0 -sticky ew
    grid rowconfigure $w.main 1 -weight 1
    grid columnconfigure $w.main 0 -weight 1
    bind $w.main.list <Double-1> ::SolidSeam::previewSelectedCandidate

    frame $w.actions -padx 12 -pady 6; pack $w.actions -fill x
    labelframe $w.actions.selected -text [::SolidSeam::txt "当前候选" "Selected Candidate"] -padx 6 -pady 5
    labelframe $w.actions.batch -text [::SolidSeam::txt "批量状态" "Batch Status"] -padx 6 -pady 5
    pack $w.actions.selected -side left -fill x
    pack $w.actions.batch -side left -fill x -padx {10 0}
    foreach spec {
        {preview "预览" "Preview" ::SolidSeam::previewSelectedCandidate}
        {accept "接受" "Accept" {::SolidSeam::setSelectedStatus ACCEPTED}}
        {reject "拒绝" "Reject" {::SolidSeam::setSelectedStatus REJECTED}}
        {reverse "反转节点顺序" "Reverse Nodes" ::SolidSeam::reverseSelectedCandidate}
    } {
        button $w.actions.selected.[lindex $spec 0] -text [::SolidSeam::txt [lindex $spec 1] [lindex $spec 2]] -command [lindex $spec 3]
        pack $w.actions.selected.[lindex $spec 0] -side left -padx {0 5}
    }
    menubutton $w.actions.selected.type -text [::SolidSeam::txt "修改 PENTA 类型" "Set PENTA Type"] -menu $w.actions.selected.type.menu
    menu $w.actions.selected.type.menu -tearoff 0
    foreach type {PENTA_MIG_T PENTA_MIG_L PENTA_MIG_B PENTA_MIG} { $w.actions.selected.type.menu add command -label $type -command [list ::SolidSeam::setSelectedRealization $type] }
    pack $w.actions.selected.type -side left

    foreach spec {
        {all "接受所有" "Accept All" ::SolidSeam::acceptAllCandidates}
        {high "仅接受全部高置信度" "Accept All High Only" ::SolidSeam::acceptHighConfidence}
        {none "拒绝所有" "Reject All" ::SolidSeam::rejectAll}
    } {
        button $w.actions.batch.[lindex $spec 0] -text [::SolidSeam::txt [lindex $spec 1] [lindex $spec 2]] -command [lindex $spec 3]
        pack $w.actions.batch.[lindex $spec 0] -side left -padx {0 5}
    }

    frame $w.footer -padx 12 -pady 10; pack $w.footer -fill x
    button $w.footer.create -text [::SolidSeam::txt "创建已接受焊缝" "Create Accepted Seams"] -command ::SolidSeam::createAcceptedCandidates -width 20
    button $w.footer.export -text [::SolidSeam::txt "导出结果" "Export Results"] -command ::SolidSeam::exportAcceptedCandidates
    button $w.footer.close -text [::SolidSeam::txt "关闭" "Close"] -command ::SolidSeam::closeCandidateWindow -width 10
    pack $w.footer.create $w.footer.export -side left -padx {0 6}
    pack $w.footer.close -side right
    ::SolidSeam::refreshCandidateList
    if {[llength $candidateRows] > 0} { $w.main.list selection set 0 }
    update idletasks
    set x [expr {([winfo screenwidth $w] - [winfo reqwidth $w]) / 2}]
    set y [expr {([winfo screenheight $w] - [winfo reqheight $w]) / 2}]
    wm geometry $w +$x+$y
}
