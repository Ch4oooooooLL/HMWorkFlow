proc ::MeshSeamWeld::autoCandidateLabel {candidate} {
    set warning ""
    if {[dict get $candidate joint_type] eq "REVIEW"} { set warning " !" }
    return "[dict get $candidate candidate_id]  [dict get $candidate joint_type]  [format %.3f [dict get $candidate confidence]]  L=[format %.3f [dict get $candidate length]]$warning"
}

proc ::MeshSeamWeld::autoVisibleComponents {} {
    set ids {}; catch {*clearmark comps 2}
    if {![catch {*createmark comps 2 displayed}]} { catch {set ids [hm_getmark comps 2]} }
    catch {*clearmark comps 2}; return $ids
}

proc ::MeshSeamWeld::restoreAutoReviewDisplay {} {
    variable autoOriginalVisible
    if {![info exists autoOriginalVisible]} { return }
    catch {*clearmark comps 1}; catch {*createmark comps 1 all}; catch {*displaycollectorsallbymark 1 off 1 1}
    if {[llength $autoOriginalVisible]} { catch {*clearmark comps 1}; eval *createmark comps 1 $autoOriginalVisible; catch {*displaycollectorsallbymark 1 on 1 1} }
    catch {*numbersclear}; catch {hm_redraw}
}

proc ::MeshSeamWeld::autoReviewRefresh {} {
    variable autoCandidates; variable autoDecision; variable autoForcedType; variable autoSwap
    set w .mesh_seam_auto_review
    if {![winfo exists $w]} { return }
    $w.body.list delete 0 end
    foreach candidate $autoCandidates {
        set id [dict get $candidate candidate_id]
        set suffix ""
        if {$autoForcedType($id) ne ""} { append suffix "  ->$autoForcedType($id)" }
        if {$autoSwap($id)} { append suffix "  SWAP" }
        $w.body.list insert end "$autoDecision($id)  [::MeshSeamWeld::autoCandidateLabel $candidate]$suffix"
    }
}

proc ::MeshSeamWeld::autoReviewCycleType {} {
    variable autoCandidates; variable autoForcedType
    set selected [.mesh_seam_auto_review.body.list curselection]; if {$selected eq ""} { return }
    set candidate [lindex $autoCandidates [lindex $selected 0]]; set id [dict get $candidate candidate_id]
    set types {T_PATH CONNECT L_SURF REVIEW}; set current $autoForcedType($id)
    if {$current eq ""} { set current [dict get $candidate joint_type] }
    set index [lsearch -exact $types $current]; set autoForcedType($id) [lindex $types [expr {($index+1)%[llength $types]}]]
    ::MeshSeamWeld::autoReviewRefresh; .mesh_seam_auto_review.body.list selection set [lindex $selected 0]
}

proc ::MeshSeamWeld::autoReviewSwap {} {
    variable autoCandidates; variable autoSwap
    set selected [.mesh_seam_auto_review.body.list curselection]; if {$selected eq ""} { return }
    set id [dict get [lindex $autoCandidates [lindex $selected 0]] candidate_id]; set autoSwap($id) [expr {!$autoSwap($id)}]
    ::MeshSeamWeld::autoReviewRefresh; .mesh_seam_auto_review.body.list selection set [lindex $selected 0]
}

proc ::MeshSeamWeld::autoReviewSet {decision} {
    variable autoCandidates; variable autoDecision
    set selected [.mesh_seam_auto_review.body.list curselection]
    if {$selected eq ""} { return }
    set id [dict get [lindex $autoCandidates [lindex $selected 0]] candidate_id]
    set autoDecision($id) $decision
    ::MeshSeamWeld::autoReviewRefresh
    .mesh_seam_auto_review.body.list selection set [lindex $selected 0]
}

proc ::MeshSeamWeld::selectedAutoCandidate {} {
    variable autoCandidates
    set selected [.mesh_seam_auto_review.body.list curselection]
    if {$selected eq ""} { return "" }
    return [lindex $autoCandidates [lindex $selected 0]]
}

proc ::MeshSeamWeld::autoReviewLocate {} {
    set candidate [::MeshSeamWeld::selectedAutoCandidate]; if {$candidate eq ""} { return }
    set nodes [lsort -integer -unique [concat [dict get $candidate source_node_ids] [dict get $candidate target_hint_node_ids]]]
    set elements [lsort -integer -unique [concat [dict get $candidate source_element_ids] [dict get $candidate target_hint_element_ids]]]
    catch {*numbersclear}; catch {*clearmark nodes 1}; catch {*clearmark elems 1}
    if {[llength $nodes]} { eval *createmark nodes 1 $nodes; catch {*numbersmark nodes 1 1} }
    if {[llength $elements]} { eval *createmark elems 1 $elements; catch {*numbersmark elems 1 1} }
    catch {*viewfit}; catch {hm_redraw}
}

proc ::MeshSeamWeld::autoReviewIsolate {} {
    set candidate [::MeshSeamWeld::selectedAutoCandidate]; if {$candidate eq ""} { return }
    set ids [list [dict get $candidate source_component_id] [dict get $candidate target_component_id]]
    catch {*clearmark comps 1}; catch {*createmark comps 1 all}; catch {*displaycollectorsallbymark 1 off 1 1}
    catch {*clearmark comps 1}; eval *createmark comps 1 $ids; catch {*displaycollectorsallbymark 1 on 1 1}
    ::MeshSeamWeld::autoReviewLocate
}

proc ::MeshSeamWeld::autoReviewAcceptHigh {} {
    variable autoCandidates; variable autoDecision; variable cfg
    foreach candidate $autoCandidates {
        set id [dict get $candidate candidate_id]
        if {[dict get $candidate joint_type] ne "REVIEW" && [dict get $candidate duplicate_status] eq "NEW" && [dict get $candidate confidence] >= $cfg(auto_accept_confidence)} { set autoDecision($id) ACCEPT }
    }
    ::MeshSeamWeld::autoReviewRefresh
}

proc ::MeshSeamWeld::showAutoReview {candidates} {
    variable autoCandidates; variable autoDecision; variable autoForcedType; variable autoSwap; variable autoReviewConfirmed; variable autoReviewFallback; variable autoOriginalVisible
    set autoCandidates $candidates; array unset autoDecision; array unset autoForcedType; array unset autoSwap
    foreach candidate $autoCandidates { set id [dict get $candidate candidate_id]; set autoDecision($id) PENDING; set autoForcedType($id) ""; set autoSwap($id) 0 }
    set autoReviewConfirmed 0; set autoReviewFallback ""; set autoOriginalVisible [::MeshSeamWeld::autoVisibleComponents]; set w .mesh_seam_auto_review; catch {destroy $w}
    ::HWFlow::createTopLevel $w; wm title $w [::HWFlow::txt "自动壳焊缝候选复核" "Automatic Shell Seam Review"]; wm minsize $w 760 440
    frame $w.body -padx 12 -pady 12; pack $w.body -fill both -expand 1
    label $w.body.note -text [::HWFlow::txt "自动创建前必须明确接受候选；REVIEW 和重复项不能批量接受。" "Candidates must be explicitly accepted before creation; REVIEW and duplicates are excluded from bulk acceptance."] -anchor w
    listbox $w.body.list -width 100 -height 18 -exportselection 0 -font [::HWFlow::uiFont fixedSmall]
    pack $w.body.note -fill x -pady {0 8}; pack $w.body.list -fill both -expand 1
    frame $w.actions -padx 12 -pady 10; pack $w.actions -fill x
    button $w.actions.accept -text [::HWFlow::txt "接受所选" "Accept Selected"] -command {::MeshSeamWeld::autoReviewSet ACCEPT}
    button $w.actions.reject -text [::HWFlow::txt "拒绝所选" "Reject Selected"] -command {::MeshSeamWeld::autoReviewSet REJECT}
    button $w.actions.high -text [::HWFlow::txt "接受全部高置信度项" "Accept All High Confidence"] -command ::MeshSeamWeld::autoReviewAcceptHigh
    button $w.actions.type -text [::HWFlow::txt "修改类型" "Change Type"] -command ::MeshSeamWeld::autoReviewCycleType
    button $w.actions.swap -text [::HWFlow::txt "切换主从侧" "Swap Source/Target"] -command ::MeshSeamWeld::autoReviewSwap
    button $w.actions.locate -text [::HWFlow::txt "定位" "Locate"] -command ::MeshSeamWeld::autoReviewLocate
    button $w.actions.isolate -text [::HWFlow::txt "孤立" "Isolate"] -command ::MeshSeamWeld::autoReviewIsolate
    button $w.actions.manual -text [::HWFlow::txt "转到手动网格焊缝" "Open Manual Mesh Weld"] -command {set ::MeshSeamWeld::autoReviewFallback MANUAL; destroy .mesh_seam_auto_review}
    button $w.actions.geometry -text [::HWFlow::txt "转到几何焊缝" "Open Geometry Seam"] -command {set ::MeshSeamWeld::autoReviewFallback GEOMETRY; destroy .mesh_seam_auto_review}
    button $w.actions.cancel -text [::HWFlow::txt "取消" "Cancel"] -command {set ::MeshSeamWeld::autoReviewConfirmed 0; destroy .mesh_seam_auto_review}
    button $w.actions.plan -text [::HWFlow::txt "生成创建计划" "Generate Creation Plan"] -command {set ::MeshSeamWeld::autoReviewConfirmed 1; destroy .mesh_seam_auto_review}
    pack $w.actions.accept $w.actions.reject $w.actions.high $w.actions.type $w.actions.swap $w.actions.locate $w.actions.isolate -side left -padx {0 6}; pack $w.actions.plan $w.actions.cancel -side right -padx {6 0}
    pack $w.actions.manual $w.actions.geometry -side bottom -padx {0 6} -pady {6 0}
    bind $w <Escape> {set ::MeshSeamWeld::autoReviewConfirmed 0; destroy .mesh_seam_auto_review}
    ::MeshSeamWeld::autoReviewRefresh; tkwait window $w; ::MeshSeamWeld::restoreAutoReviewDisplay
    if {!$autoReviewConfirmed} { return [dict create accepted_ids {} type_overrides {} swap_ids {} fallback $autoReviewFallback] }
    set accepted {}; set overrides {}; set swaps {}
    foreach candidate $autoCandidates {
        set id [dict get $candidate candidate_id]
        if {$autoDecision($id) eq "ACCEPT"} { lappend accepted $id }
        if {$autoForcedType($id) ne ""} { dict set overrides $id $autoForcedType($id) }
        if {$autoSwap($id)} { lappend swaps $id }
    }
    return [dict create accepted_ids $accepted type_overrides $overrides swap_ids $swaps fallback ""]
}
