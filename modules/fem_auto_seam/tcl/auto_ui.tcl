proc ::FemAutoSeam::autoCandidateValue {candidate key {fallback ""}} {
    if {[dict exists $candidate $key]} { return [dict get $candidate $key] }
    return $fallback
}

proc ::FemAutoSeam::autoCandidateById {candidateId} {
    variable autoCandidates
    foreach candidate $autoCandidates {
        if {[dict get $candidate candidate_id] eq $candidateId} { return $candidate }
    }
    return ""
}

proc ::FemAutoSeam::autoVisibleComponents {} {
    set ids {}; catch {*clearmark comps 2}
    if {![catch {*createmark comps 2 displayed}]} { catch {set ids [hm_getmark comps 2]} }
    catch {*clearmark comps 2}; return $ids
}

proc ::FemAutoSeam::restoreAutoReviewDisplay {} {
    variable autoOriginalVisible
    if {![info exists autoOriginalVisible]} { return }
    catch {*clearmark comps 1}; catch {*createmark comps 1 all}; catch {*displaycollectorsallbymark 1 off 1 1}
    if {[llength $autoOriginalVisible]} {
        catch {*clearmark comps 1}; eval *createmark comps 1 $autoOriginalVisible
        catch {*displaycollectorsallbymark 1 on 1 1}
    }
    catch {*numbersclear}; catch {hm_redraw}
}

proc ::FemAutoSeam::autoReviewMatches {candidate} {
    variable autoDecision; variable autoReviewFilter; variable autoReviewMinimumConfidence
    set id [dict get $candidate candidate_id]
    if {$autoDecision($id) eq "DELETE"} { return 0 }
    set confidence [expr {double([::FemAutoSeam::autoCandidateValue $candidate confidence 0.0])}]
    if {![string is double -strict $autoReviewMinimumConfidence]} { set autoReviewMinimumConfidence 0.0 }
    if {$confidence < $autoReviewMinimumConfidence} { return 0 }
    set autoEligible [::FemAutoSeam::autoCandidateValue $candidate auto_eligible 0]
    switch -- $autoReviewFilter {
        HIGH { return [expr {$autoEligible && $confidence >= $::FemAutoSeam::cfg(auto_accept_confidence)}] }
        REVIEW { return [expr {$autoDecision($id) in {PENDING PASS} && (!$autoEligible || $confidence < $::FemAutoSeam::cfg(auto_accept_confidence))}] }
        DONE { return [expr {$autoDecision($id) eq "DONE"}] }
        default { return 1 }
    }
}

proc ::FemAutoSeam::autoReviewRefresh {} {
    variable autoCandidates; variable autoDecision; variable autoForcedType; variable autoSwap
    set tree .fem_auto_seam_review.body.table.tree
    if {![winfo exists $tree]} { return }
    set selected [$tree selection]
    foreach item [$tree children {}] { $tree delete $item }
    foreach candidate $autoCandidates {
        if {![::FemAutoSeam::autoReviewMatches $candidate]} { continue }
        set id [dict get $candidate candidate_id]
        set type [::FemAutoSeam::autoCandidateValue $candidate candidate_type [::FemAutoSeam::autoCandidateValue $candidate joint_type REVIEW]]
        if {$autoForcedType($id) ne ""} { set type $autoForcedType($id) }
        if {$autoSwap($id)} { append type " / SWAP" }
        set reasons [join [::FemAutoSeam::autoCandidateValue $candidate reasons {}] "; "]
        set warnings [join [::FemAutoSeam::autoCandidateValue $candidate warnings {}] "; "]
        if {$warnings ne ""} { if {$reasons ne ""} { append reasons "; " }; append reasons $warnings }
        $tree insert {} end -id $id -values [list \
            $autoDecision($id) $type \
            [format %.3f [::FemAutoSeam::autoCandidateValue $candidate confidence 0.0]] \
            [format %.3f [::FemAutoSeam::autoCandidateValue $candidate length 0.0]] \
            [dict get $candidate source_component_id] [dict get $candidate target_component_id] $reasons]
    }
    foreach id $selected {
        if {[$tree exists $id]} { $tree selection set $id; $tree focus $id; break }
    }
    set count [llength [$tree children {}]]
    .fem_auto_seam_review.body.summary configure -text [::HWFlow::txt "当前显示 $count 项；单击候选将只显示相关两个 component。" "$count candidates shown; selecting a row isolates its two related components."]
}

proc ::FemAutoSeam::selectedAutoCandidate {} {
    set tree .fem_auto_seam_review.body.table.tree
    if {![winfo exists $tree]} { return "" }
    set selected [$tree selection]
    if {![llength $selected]} { return "" }
    return [::FemAutoSeam::autoCandidateById [lindex $selected 0]]
}

proc ::FemAutoSeam::autoReviewSet {decision} {
    variable autoDecision
    set candidate [::FemAutoSeam::selectedAutoCandidate]
    if {$candidate eq ""} { return }
    if {$decision eq "ACCEPT" && ![::FemAutoSeam::autoCandidateValue $candidate auto_eligible 0]} {
        tk_messageBox -icon info -message [::HWFlow::txt "该候选只能人工处理；请完成后选择 Done，暂不处理选择 Pass。" "This candidate requires manual handling. Choose Done after handling it, or Pass to leave it pending."]
        return
    }
    set id [dict get $candidate candidate_id]
    set autoDecision($id) $decision
    ::FemAutoSeam::autoReviewRefresh
}

proc ::FemAutoSeam::autoReviewCycleType {} {
    variable autoForcedType
    set candidate [::FemAutoSeam::selectedAutoCandidate]; if {$candidate eq ""} { return }
    set id [dict get $candidate candidate_id]
    set types {T_PATH L_SURF REVIEW}; set current $autoForcedType($id)
    if {$current eq ""} { set current [::FemAutoSeam::autoCandidateValue $candidate joint_type REVIEW] }
    set index [lsearch -exact $types $current]
    set autoForcedType($id) [lindex $types [expr {($index + 1) % [llength $types]}]]
    ::FemAutoSeam::autoReviewRefresh
}

proc ::FemAutoSeam::autoReviewSwap {} {
    variable autoSwap
    set candidate [::FemAutoSeam::selectedAutoCandidate]; if {$candidate eq ""} { return }
    set id [dict get $candidate candidate_id]; set autoSwap($id) [expr {!$autoSwap($id)}]
    ::FemAutoSeam::autoReviewRefresh
}

proc ::FemAutoSeam::autoReviewLocate {{fitView 1}} {
    set candidate [::FemAutoSeam::selectedAutoCandidate]; if {$candidate eq ""} { return }
    set nodes {}
    foreach key {source_node_ids target_hint_node_ids target_node_ids} {
        foreach nodeId [::FemAutoSeam::autoCandidateValue $candidate $key {}] {
            if {[string is integer -strict $nodeId] && $nodeId > 0} { lappend nodes $nodeId }
        }
    }
    set elements [concat \
        [::FemAutoSeam::autoCandidateValue $candidate source_element_ids {}] \
        [::FemAutoSeam::autoCandidateValue $candidate target_hint_element_ids {}]]
    set nodes [lsort -integer -unique $nodes]; set elements [lsort -integer -unique $elements]
    catch {*numbersclear}; catch {*clearmark nodes 1}; catch {*clearmark elems 1}
    if {[llength $nodes]} { eval *createmark nodes 1 $nodes; catch {*numbersmark nodes 1 1} }
    if {[llength $elements]} { eval *createmark elems 1 $elements; catch {*numbersmark elems 1 1} }
    if {$fitView} {
        catch {hm_redraw}; catch {update idletasks}; catch {hm_viewfit}; catch {hm_redraw}
    } else {
        catch {hm_redraw}
    }
}

proc ::FemAutoSeam::autoReviewFitIsolated {ids} {
    if {![winfo exists .fem_auto_seam_review]} { return }
    set candidate [::FemAutoSeam::selectedAutoCandidate]
    if {$candidate eq ""} { return }
    set current [lsort -integer -unique [list [dict get $candidate source_component_id] [dict get $candidate target_component_id]]]
    if {$current ne $ids} { return }
    # Display state changes are committed by HyperMesh after the selection
    # callback returns.  Fit on the next Tk event so *viewfit sees only the
    # isolated source/target pair instead of the previous global display.
    catch {hm_redraw}
    catch {update idletasks}
    catch {hm_viewfit}
    catch {hm_redraw}
}

proc ::FemAutoSeam::autoReviewIsolate {} {
    set candidate [::FemAutoSeam::selectedAutoCandidate]; if {$candidate eq ""} { return }
    set ids [lsort -integer -unique [list [dict get $candidate source_component_id] [dict get $candidate target_component_id]]]
    catch {*clearmark comps 1}; catch {*createmark comps 1 all}; catch {*displaycollectorsallbymark 1 off 1 1}
    catch {*clearmark comps 1}; eval *createmark comps 1 $ids; catch {*displaycollectorsallbymark 1 on 1 1}
    ::FemAutoSeam::autoReviewLocate 0
    after idle [list ::FemAutoSeam::autoReviewFitIsolated $ids]
}

proc ::FemAutoSeam::autoReviewAcceptHigh {} {
    variable autoCandidates; variable autoDecision; variable cfg
    foreach candidate $autoCandidates {
        set id [dict get $candidate candidate_id]
        if {[::FemAutoSeam::autoCandidateValue $candidate auto_eligible 0] &&
            [::FemAutoSeam::autoCandidateValue $candidate confidence 0.0] >= $cfg(auto_accept_confidence)} {
            set autoDecision($id) ACCEPT
        }
    }
    ::FemAutoSeam::autoReviewRefresh
}

proc ::FemAutoSeam::showAutoReview {candidates} {
    variable autoCandidates; variable autoDecision; variable autoForcedType; variable autoSwap
    variable autoReviewConfirmed; variable autoOriginalVisible
    variable autoReviewFilter; variable autoReviewMinimumConfidence; variable cfg
    set autoCandidates $candidates; array unset autoDecision; array unset autoForcedType; array unset autoSwap
    foreach candidate $autoCandidates {
        set id [dict get $candidate candidate_id]
        set autoDecision($id) PENDING; set autoForcedType($id) ""; set autoSwap($id) 0
        if {[::FemAutoSeam::autoCandidateValue $candidate auto_eligible 0] &&
            [::FemAutoSeam::autoCandidateValue $candidate confidence 0.0] >= $cfg(auto_accept_confidence)} {
            set autoDecision($id) ACCEPT
        }
    }
    set autoReviewFilter REVIEW; set autoReviewMinimumConfidence 0.0
    set autoReviewConfirmed 0
    set autoOriginalVisible [::FemAutoSeam::autoVisibleComponents]
    set w .fem_auto_seam_review; catch {destroy $w}
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "FEM 自动焊缝候选复核" "FEM Automatic Seam Review"] "FEM Automatic Seam Review"]
    wm minsize $w 1060 560

    frame $w.body -padx 12 -pady 12; pack $w.body -fill both -expand 1
    frame $w.body.filters; pack $w.body.filters -fill x -pady {0 8}
    label $w.body.filters.l_filter -text [::HWFlow::txt "列表" "List"]
    ttk::combobox $w.body.filters.filter -state readonly -width 14 -textvariable ::FemAutoSeam::autoReviewFilter -values {REVIEW ALL HIGH DONE}
    label $w.body.filters.l_confidence -text [::HWFlow::txt "最低置信度" "Minimum confidence"]
    entry $w.body.filters.confidence -width 8 -textvariable ::FemAutoSeam::autoReviewMinimumConfidence
    button $w.body.filters.apply -text [::HWFlow::txt "筛选" "Filter"] -command ::FemAutoSeam::autoReviewRefresh
    button $w.body.filters.restore -text [::HWFlow::txt "恢复显示" "Restore Display"] -command ::FemAutoSeam::restoreAutoReviewDisplay
    pack $w.body.filters.l_filter $w.body.filters.filter $w.body.filters.l_confidence $w.body.filters.confidence $w.body.filters.apply -side left -padx {0 6}
    pack $w.body.filters.restore -side right

    frame $w.body.table; pack $w.body.table -fill both -expand 1
    ttk::treeview $w.body.table.tree -show headings -selectmode browse -columns {status type confidence length source target reason}
    foreach item {
        {status "状态" "Status" 72}
        {type "类型" "Type" 120}
        {confidence "置信度" "Confidence" 78}
        {length "长度" "Length" 78}
        {source "源组件" "Source" 70}
        {target "目标组件" "Target" 70}
        {reason "原因 / 警告" "Reason / Warning" 480}
    } {
        set key [lindex $item 0]
        $w.body.table.tree heading $key -text [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        $w.body.table.tree column $key -width [lindex $item 3] -stretch [expr {$key eq "reason"}]
    }
    scrollbar $w.body.table.ys -orient vertical -command [list $w.body.table.tree yview]
    scrollbar $w.body.table.xs -orient horizontal -command [list $w.body.table.tree xview]
    $w.body.table.tree configure -yscrollcommand [list $w.body.table.ys set] -xscrollcommand [list $w.body.table.xs set]
    grid $w.body.table.tree -row 0 -column 0 -sticky nsew
    grid $w.body.table.ys -row 0 -column 1 -sticky ns
    grid $w.body.table.xs -row 1 -column 0 -sticky ew
    grid rowconfigure $w.body.table 0 -weight 1; grid columnconfigure $w.body.table 0 -weight 1
    label $w.body.summary -anchor w; pack $w.body.summary -fill x -pady {6 0}

    frame $w.actions -padx 12 -pady 10; pack $w.actions -fill x
    foreach spec {
        {accept "自动创建" "Auto Create" ACCEPT}
        {pass "Pass" "Pass" PASS}
        {done "Done" "Done" DONE}
        {delete "Delete" "Delete" DELETE}
    } {
        button $w.actions.[lindex $spec 0] -text [::HWFlow::txt [lindex $spec 1] [lindex $spec 2]] -command [list ::FemAutoSeam::autoReviewSet [lindex $spec 3]]
        pack $w.actions.[lindex $spec 0] -side left -padx {0 6}
    }
    button $w.actions.high -text [::HWFlow::txt "接受全部高置信度项" "Accept All High Confidence"] -command ::FemAutoSeam::autoReviewAcceptHigh
    button $w.actions.locate -text [::HWFlow::txt "定位" "Locate"] -command ::FemAutoSeam::autoReviewLocate
    pack $w.actions.high $w.actions.locate -side left -padx {0 6}
    button $w.actions.cancel -text [::HWFlow::txt "取消" "Cancel"] -command {set ::FemAutoSeam::autoReviewConfirmed 0; destroy .fem_auto_seam_review}
    button $w.actions.plan -text [::HWFlow::txt "应用自动项并保存队列" "Apply Automatic and Save Queue"] -command {set ::FemAutoSeam::autoReviewConfirmed 1; destroy .fem_auto_seam_review}
    pack $w.actions.plan $w.actions.cancel -side right -padx {6 0}

    bind $w.body.table.tree <<TreeviewSelect>> ::FemAutoSeam::autoReviewIsolate
    bind $w <Escape> {set ::FemAutoSeam::autoReviewConfirmed 0; destroy .fem_auto_seam_review}
    wm protocol $w WM_DELETE_WINDOW {set ::FemAutoSeam::autoReviewConfirmed 0; destroy .fem_auto_seam_review}
    ::FemAutoSeam::autoReviewRefresh
    tkwait window $w
    ::FemAutoSeam::restoreAutoReviewDisplay
    if {!$autoReviewConfirmed} { return [dict create accepted_ids {} decisions {}] }
    set accepted {}; set decisions {}
    foreach candidate $autoCandidates {
        set id [dict get $candidate candidate_id]
        dict set decisions $id $autoDecision($id)
        if {$autoDecision($id) eq "ACCEPT"} { lappend accepted $id }
    }
    return [dict create accepted_ids $accepted decisions $decisions]
}

proc ::FemAutoSeam::pendingReviewClose {} {
    ::FemAutoSeam::restoreAutoReviewDisplay
    catch {destroy .fem_auto_seam_review}
}

proc ::FemAutoSeam::pendingReviewOpenMeshSeamWeld {} {
    set candidate [::FemAutoSeam::selectedAutoCandidate]
    if {$candidate eq ""} {
        tk_messageBox -icon info -message [::HWFlow::txt "请先选择一个待处理项。" "Select a pending item first."]
        return
    }
    # Keep the selected pair isolated for the manual module.  The existing Mesh
    # Seam Weld workflow then performs its own node-path and target selections.
    ::FemAutoSeam::autoReviewIsolate
    catch {destroy .fem_auto_seam_review}
    if {[llength [info commands ::MeshSeamWeld::runAction]] == 0} {
        ::FemAutoSeam::restoreAutoReviewDisplay
        tk_messageBox -icon error -message [::HWFlow::txt "网格焊缝模块尚未加载。" "Mesh Seam Weld is not loaded."]
        return
    }
    after idle ::MeshSeamWeld::runAction
}

proc ::FemAutoSeam::showPendingReview {candidates} {
    variable autoCandidates; variable autoDecision; variable autoForcedType; variable autoSwap
    variable autoOriginalVisible; variable autoReviewFilter; variable autoReviewMinimumConfidence
    if {![llength $candidates]} { return "" }
    set autoCandidates $candidates
    array unset autoDecision; array unset autoForcedType; array unset autoSwap
    foreach candidate $autoCandidates {
        set id [dict get $candidate candidate_id]
        set autoDecision($id) PENDING; set autoForcedType($id) ""; set autoSwap($id) 0
    }
    set autoReviewFilter ALL; set autoReviewMinimumConfidence 0.0
    set autoOriginalVisible [::FemAutoSeam::autoVisibleComponents]
    set w .fem_auto_seam_review; catch {destroy $w}
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::HWFlow::txt "FEM 自动焊缝 - 待人工处理" "FEM Automatic Seam - Pending Manual Work"] "FEM Automatic Seam - Pending Manual Work"]
    wm minsize $w 1060 560

    frame $w.body -padx 12 -pady 12; pack $w.body -fill both -expand 1
    frame $w.body.filters; pack $w.body.filters -fill x -pady {0 8}
    label $w.body.filters.l_confidence -text [::HWFlow::txt "最低置信度" "Minimum confidence"]
    entry $w.body.filters.confidence -width 8 -textvariable ::FemAutoSeam::autoReviewMinimumConfidence
    button $w.body.filters.apply -text [::HWFlow::txt "筛选" "Filter"] -command ::FemAutoSeam::autoReviewRefresh
    button $w.body.filters.restore -text [::HWFlow::txt "恢复显示" "Restore Display"] -command ::FemAutoSeam::restoreAutoReviewDisplay
    pack $w.body.filters.l_confidence $w.body.filters.confidence $w.body.filters.apply -side left -padx {0 6}
    pack $w.body.filters.restore -side right

    frame $w.body.table; pack $w.body.table -fill both -expand 1
    ttk::treeview $w.body.table.tree -show headings -selectmode browse -columns {status type confidence length source target reason}
    foreach item {
        {status "状态" "Status" 72}
        {type "类型" "Type" 120}
        {confidence "置信度" "Confidence" 78}
        {length "长度" "Length" 78}
        {source "源组件" "Source" 70}
        {target "目标组件" "Target" 70}
        {reason "原因 / 警告" "Reason / Warning" 480}
    } {
        set key [lindex $item 0]
        $w.body.table.tree heading $key -text [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        $w.body.table.tree column $key -width [lindex $item 3] -stretch [expr {$key eq "reason"}]
    }
    scrollbar $w.body.table.ys -orient vertical -command [list $w.body.table.tree yview]
    scrollbar $w.body.table.xs -orient horizontal -command [list $w.body.table.tree xview]
    $w.body.table.tree configure -yscrollcommand [list $w.body.table.ys set] -xscrollcommand [list $w.body.table.xs set]
    grid $w.body.table.tree -row 0 -column 0 -sticky nsew
    grid $w.body.table.ys -row 0 -column 1 -sticky ns
    grid $w.body.table.xs -row 1 -column 0 -sticky ew
    grid rowconfigure $w.body.table 0 -weight 1; grid columnconfigure $w.body.table 0 -weight 1
    label $w.body.summary -anchor w; pack $w.body.summary -fill x -pady {6 0}

    frame $w.actions -padx 12 -pady 10; pack $w.actions -fill x
    button $w.actions.locate -text [::HWFlow::txt "定位" "Locate"] -command ::FemAutoSeam::autoReviewIsolate
    button $w.actions.manual -text [::HWFlow::txt "调用网格焊缝" "Open Mesh Seam Weld"] -command ::FemAutoSeam::pendingReviewOpenMeshSeamWeld
    button $w.actions.close -text [::HWFlow::txt "关闭" "Close"] -command ::FemAutoSeam::pendingReviewClose
    pack $w.actions.locate $w.actions.manual -side left -padx {0 6}
    pack $w.actions.close -side right

    bind $w.body.table.tree <<TreeviewSelect>> ::FemAutoSeam::autoReviewIsolate
    bind $w <Escape> ::FemAutoSeam::pendingReviewClose
    wm protocol $w WM_DELETE_WINDOW ::FemAutoSeam::pendingReviewClose
    ::FemAutoSeam::autoReviewRefresh
    return $w
}

