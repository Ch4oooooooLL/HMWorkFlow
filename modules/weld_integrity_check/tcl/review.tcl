proc ::WeldIntegrityCheck::displayedComponents {} {
    set ids {}
    foreach type {comps components} {
        catch {*clearmark $type 2}
        if {![catch {*createmark $type 2 displayed}]} {
            catch {set ids [hm_getmark $type 2]}
            catch {*clearmark $type 2}
            if {[llength $ids]} { break }
        }
    }
    return [lsort -integer -unique $ids]
}

proc ::WeldIntegrityCheck::setAllComponentsDisplay {state} {
    foreach type {comps components} {
        catch {*clearmark $type 1}
        if {![catch {*createmark $type 1 all}]} {
            catch {*displaycollectorsbymark $type 1 $state 1 1}
            catch {*displaycollectorsallbymark 1 $state 1 1}
            catch {*clearmark $type 1}
            return 1
        }
    }
    return 0
}

proc ::WeldIntegrityCheck::setComponentsDisplay {ids state} {
    if {![llength $ids]} { return 0 }
    foreach type {comps components} {
        catch {*clearmark $type 1}
        if {![catch {eval *createmark $type 1 $ids}]} {
            catch {*displaycollectorsbymark $type 1 $state 1 1}
            catch {*displaycollectorsallbymark 1 $state 1 1}
            catch {*clearmark $type 1}
            return 1
        }
    }
    return 0
}

proc ::WeldIntegrityCheck::restoreDisplay {} {
    variable displayCaptured; variable originalVisibleCompIds; variable isolated
    if {!$displayCaptured} { return }
    ::WeldIntegrityCheck::clearHighlight
    ::WeldIntegrityCheck::setAllComponentsDisplay off
    ::WeldIntegrityCheck::setComponentsDisplay $originalVisibleCompIds on
    set isolated 0
    catch {hm_redraw}; catch {update idletasks}
    ::WeldIntegrityCheck::log INFO "display restored visible_components=[llength $originalVisibleCompIds]"
}

proc ::WeldIntegrityCheck::componentExists {componentId} {
    if {[catch {set name [hm_getvalue comps id=$componentId dataname=name]}]} { return 0 }
    return [expr {[string trim $name] ne ""}]
}

proc ::WeldIntegrityCheck::pairById {pairId} {
    variable pairRows
    foreach pair $pairRows { if {[dict get $pair pair_id] eq $pairId} { return $pair } }
    return ""
}

proc ::WeldIntegrityCheck::currentPair {} {
    variable currentPairId
    if {$currentPairId eq ""} { return "" }
    return [::WeldIntegrityCheck::pairById $currentPairId]
}

proc ::WeldIntegrityCheck::pairLabel {pair} {
    set a [dict get $pair component_a]; set b [dict get $pair component_b]
    return "[dict get $a name] (ID [dict get $a id])  <->  [dict get $b name] (ID [dict get $b id])    [::WeldIntegrityCheck::txt "区域" "Regions"]:[dict get $pair candidate_region_count]"
}

proc ::WeldIntegrityCheck::matchesFilter {pair} {
    variable ui; variable pairStates
    set pairId [dict get $pair pair_id]; set state $pairStates($pairId)
    if {$ui(statusFilter) ne "all" && $state ne $ui(statusFilter)} { return 0 }
    set needle [string tolower [string trim $ui(filterText)]]
    if {$needle eq ""} { return 1 }
    set a [dict get $pair component_a]; set b [dict get $pair component_b]
    set haystack [string tolower "[dict get $a name] [dict get $a id] [dict get $b name] [dict get $b id]"]
    return [expr {[string first $needle $haystack] >= 0}]
}

proc ::WeldIntegrityCheck::refreshReview {} {
    variable pairRows; variable filteredRows; variable pairStates; variable currentPairId; variable ui
    set w .weld_integrity_review
    if {![winfo exists $w]} { return }
    set filteredRows {}
    set total [llength $pairRows]; set completed 0
    foreach pair $pairRows {
        set id [dict get $pair pair_id]
        if {$pairStates($id) eq "completed"} { incr completed }
        if {[::WeldIntegrityCheck::matchesFilter $pair]} { lappend filteredRows $pair }
    }
    set ui(summaryText) [::WeldIntegrityCheck::txt "总计：$total    待检查：[expr {$total-$completed}]    已完成：$completed" "Total: $total    Pending: [expr {$total-$completed}]    Completed: $completed"]
    $w.main.left.list delete 0 end
    set selectedIndex -1; set index 0
    foreach pair $filteredRows {
        $w.main.left.list insert end [::WeldIntegrityCheck::pairLabel $pair]
        if {[dict get $pair pair_id] eq $currentPairId} { set selectedIndex $index }
        incr index
    }
    if {$selectedIndex < 0 && [llength $filteredRows]} { set selectedIndex 0; set currentPairId [dict get [lindex $filteredRows 0] pair_id] }
    if {$selectedIndex >= 0} { $w.main.left.list selection set $selectedIndex; $w.main.left.list see $selectedIndex }
    ::WeldIntegrityCheck::updateDetails
}

proc ::WeldIntegrityCheck::onReviewSelection {} {
    variable filteredRows; variable currentPairId; variable currentRegionIndex
    set w .weld_integrity_review
    set selected [$w.main.left.list curselection]
    if {$selected eq ""} { return }
    set currentPairId [dict get [lindex $filteredRows [lindex $selected 0]] pair_id]
    set currentRegionIndex 0
    ::WeldIntegrityCheck::saveReviewState
    ::WeldIntegrityCheck::updateDetails
}

proc ::WeldIntegrityCheck::updateDetails {} {
    variable pairStates; variable currentRegionIndex; variable ui
    set w .weld_integrity_review; if {![winfo exists $w]} { return }
    set pair [::WeldIntegrityCheck::currentPair]
    if {$pair eq ""} { set ui(detailText) [::WeldIntegrityCheck::txt "无匹配结果" "No matching result"]; return }
    set a [dict get $pair component_a]; set b [dict get $pair component_b]; set id [dict get $pair pair_id]
    set regions [dict get $pair regions]; set count [llength $regions]
    if {$currentRegionIndex >= $count} { set currentRegionIndex 0 }
    set ui(detailText) [::WeldIntegrityCheck::txt \
        "Component A\n  [dict get $a name]  (ID [dict get $a id])\n\nComponent B\n  [dict get $b name]  (ID [dict get $b id])\n\n候选区域：$count\n总候选长度：[format %.4g [dict get $pair total_candidate_length]]\n最小/平均/最大距离：[format %.4g [dict get $pair minimum_distance]] / [format %.4g [dict get $pair average_distance]] / [format %.4g [dict get $pair maximum_distance]]\n状态：$pairStates($id)\n区域：[expr {$currentRegionIndex+1}] / $count" \
        "Component A\n  [dict get $a name]  (ID [dict get $a id])\n\nComponent B\n  [dict get $b name]  (ID [dict get $b id])\n\nRegions: $count\nTotal length: [format %.4g [dict get $pair total_candidate_length]]\nMin/avg/max distance: [format %.4g [dict get $pair minimum_distance]] / [format %.4g [dict get $pair average_distance]] / [format %.4g [dict get $pair maximum_distance]]\nStatus: $pairStates($id)\nRegion: [expr {$currentRegionIndex+1}] / $count"]
    if {$pairStates($id) eq "completed"} { $w.actions.complete configure -text [::WeldIntegrityCheck::txt "重新打开" "Reopen"] } else { $w.actions.complete configure -text [::WeldIntegrityCheck::txt "完成" "Complete"] }
}

proc ::WeldIntegrityCheck::clearHighlight {} {
    catch {*numbersclear}; catch {*clearmark nodes 1}; catch {*clearmark elems 1}; catch {*clearmark elems 2}
}

proc ::WeldIntegrityCheck::fitNodes {nodeIds} {
    set count 0
    foreach nodeId $nodeIds {
        if {[catch {set x [hm_getvalue nodes id=$nodeId dataname=x]}] || [catch {set y [hm_getvalue nodes id=$nodeId dataname=y]}] || [catch {set z [hm_getvalue nodes id=$nodeId dataname=z]}]} { continue }
        if {!$count} { set minX $x; set maxX $x; set minY $y; set maxY $y; set minZ $z; set maxZ $z } else {
            set minX [expr {min($minX,$x)}]; set maxX [expr {max($maxX,$x)}]; set minY [expr {min($minY,$y)}]; set maxY [expr {max($maxY,$y)}]; set minZ [expr {min($minZ,$z)}]; set maxZ [expr {max($maxZ,$z)}]
        }; incr count
    }
    if {!$count} { return }
    set radius [expr {max($maxX-$minX,$maxY-$minY,$maxZ-$minZ)}]; if {$radius <= 0} { set radius 10.0 }
    catch {*graphuserwindow_byXYZandR [expr {($minX+$maxX)/2.0}] [expr {($minY+$maxY)/2.0}] [expr {($minZ+$maxZ)/2.0}] [expr {$radius*1.4}]}
}

proc ::WeldIntegrityCheck::highlightCurrentRegion {} {
    variable currentRegionIndex
    set pair [::WeldIntegrityCheck::currentPair]; if {$pair eq ""} { return }
    set regions [dict get $pair regions]; if {![llength $regions]} { return }
    set region [lindex $regions $currentRegionIndex]
    set nodes [lsort -integer -unique [concat [dict get $region source_node_ids] [dict get $region target_near_node_ids]]]
    set elems [lsort -integer -unique [concat [dict get $region source_element_ids] [dict get $region target_near_element_ids]]]
    ::WeldIntegrityCheck::clearHighlight
    if {[llength $nodes]} { catch {eval *createmark nodes 1 $nodes}; catch {*numbersmark nodes 1 1} }
    if {[llength $elems]} { catch {eval *createmark elems 1 $elems}; catch {*numbersmark elems 1 1} }
    ::WeldIntegrityCheck::fitNodes $nodes
    ::WeldIntegrityCheck::log INFO "highlight pair=[dict get $pair pair_id] region=[dict get $region region_id] nodes=[llength $nodes] elems=[llength $elems]"
}

proc ::WeldIntegrityCheck::isolateCurrent {} {
    variable isolated
    set pair [::WeldIntegrityCheck::currentPair]; if {$pair eq ""} { return }
    set a [dict get $pair component_a]; set b [dict get $pair component_b]
    foreach component [list $a $b] {
        if {![::WeldIntegrityCheck::componentExists [dict get $component id]]} {
            tk_messageBox -icon warning -title [::WeldIntegrityCheck::txt "组件已失效" "Invalid Component"] -message [::WeldIntegrityCheck::txt "Component ID [dict get $component id] 已被删除，请重新检测。" "Component ID [dict get $component id] was deleted; run detection again."]
            return
        }
    }
    ::WeldIntegrityCheck::setAllComponentsDisplay off
    ::WeldIntegrityCheck::setComponentsDisplay [list [dict get $a id] [dict get $b id]] on
    set isolated 1; catch {hm_viewfit}; catch {hm_redraw}
    ::WeldIntegrityCheck::highlightCurrentRegion
}

proc ::WeldIntegrityCheck::changeRegion {delta} {
    variable currentRegionIndex
    set pair [::WeldIntegrityCheck::currentPair]; if {$pair eq ""} { return }
    set count [llength [dict get $pair regions]]; if {!$count} { return }
    set currentRegionIndex [expr {($currentRegionIndex + $delta + $count) % $count}]
    ::WeldIntegrityCheck::updateDetails
    ::WeldIntegrityCheck::highlightCurrentRegion
}

proc ::WeldIntegrityCheck::movePair {delta} {
    variable filteredRows; variable currentPairId; variable currentRegionIndex
    if {![llength $filteredRows]} { return }
    set index 0
    for {set i 0} {$i < [llength $filteredRows]} {incr i} { if {[dict get [lindex $filteredRows $i] pair_id] eq $currentPairId} { set index $i; break } }
    set index [expr {max(0,min([llength $filteredRows]-1,$index+$delta))}]
    set currentPairId [dict get [lindex $filteredRows $index] pair_id]; set currentRegionIndex 0
    ::WeldIntegrityCheck::refreshReview
    ::WeldIntegrityCheck::saveReviewState
}

proc ::WeldIntegrityCheck::toggleComplete {} {
    variable pairStates; variable currentPairId; variable cfg; variable isolated
    if {$currentPairId eq ""} { return }
    if {$pairStates($currentPairId) eq "completed"} { set pairStates($currentPairId) pending } else { set pairStates($currentPairId) completed }
    ::WeldIntegrityCheck::log INFO "review state pair=$currentPairId status=$pairStates($currentPairId)"
    ::WeldIntegrityCheck::saveReviewState
    ::WeldIntegrityCheck::refreshReview
    ::WeldIntegrityCheck::saveReviewState
    if {$cfg(auto_isolate_next) && $isolated && $currentPairId ne ""} { ::WeldIntegrityCheck::isolateCurrent }
}

proc ::WeldIntegrityCheck::saveReviewState {} {
    variable taskDir; variable taskId; variable pairStates; variable currentPairId
    if {$taskDir eq ""} { return }
    set rows {}; set tclRows {}
    foreach pairId [lsort [array names pairStates]] {
        lappend rows "    [::HybridCore::jsonString $pairId]: [::HybridCore::jsonString $pairStates($pairId)]"
        lappend tclRows [list $pairId $pairStates($pairId)]
    }
    set json "{\n  \"task_id\": [::HybridCore::jsonString $taskId],\n  \"updated_at\": [::HybridCore::jsonString [clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]],\n  \"pair_states\": {\n[join $rows ,\n]\n  },\n  \"current_pair_id\": [::HybridCore::jsonString $currentPairId]\n}\n"
    ::HybridCore::writeTextFile [file join $taskDir state review_state.json] $json
    ::HybridCore::writeTextFile [file join $taskDir state review_state.tcl] "# WELD_INTEGRITY_STATE_V1\nset ::WeldIntegrityCheck::savedPairStates [list $tclRows]\nset ::WeldIntegrityCheck::savedCurrentPairId [list $currentPairId]\n"
}

proc ::WeldIntegrityCheck::closeReview {} {
    ::WeldIntegrityCheck::saveReviewState
    ::WeldIntegrityCheck::restoreDisplay
    catch {destroy .weld_integrity_review}
    ::WeldIntegrityCheck::log INFO "review closed"
    catch {trace remove variable ::WeldIntegrityCheck::ui(statusFilter) write ::WeldIntegrityCheck::statusFilterChanged}
    ::WeldIntegrityCheck::closeLog
}

proc ::WeldIntegrityCheck::onReviewDestroy {window destroyedWindow} {
    if {$window ne $destroyedWindow} { return }
    ::WeldIntegrityCheck::saveReviewState
    ::WeldIntegrityCheck::restoreDisplay
    catch {trace remove variable ::WeldIntegrityCheck::ui(statusFilter) write ::WeldIntegrityCheck::statusFilterChanged}
    ::WeldIntegrityCheck::closeLog
}

proc ::WeldIntegrityCheck::showReview {} {
    variable ui
    set w .weld_integrity_review
    if {[winfo exists $w]} { raise $w; ::WeldIntegrityCheck::refreshReview; return }
    set ui(filterText) ""; set ui(statusFilter) pending
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle [::WeldIntegrityCheck::txt "网格焊缝完整性检查" "Mesh Weld Integrity Check"] "Mesh Weld Integrity Check"]
    wm minsize $w 920 560; wm protocol $w WM_DELETE_WINDOW ::WeldIntegrityCheck::closeReview
    bind $w <Escape> ::WeldIntegrityCheck::closeReview
    bind $w <Destroy> [list ::WeldIntegrityCheck::onReviewDestroy $w %W]
    frame $w.header -padx 12 -pady 8; pack $w.header -fill x
    label $w.header.title -text [::WeldIntegrityCheck::txt "网格焊缝完整性检查" "Mesh Weld Integrity Check"] -font [::HWFlow::uiFont heading] -anchor w
    label $w.header.summary -textvariable ::WeldIntegrityCheck::ui(summaryText) -anchor w
    pack $w.header.title $w.header.summary -fill x
    frame $w.filter -padx 12 -pady 4; pack $w.filter -fill x
    label $w.filter.searchLabel -text [::WeldIntegrityCheck::txt "名称或 ID" "Name or ID"]
    entry $w.filter.search -textvariable ::WeldIntegrityCheck::ui(filterText) -width 32
    label $w.filter.statusLabel -text [::WeldIntegrityCheck::txt "状态" "Status"]
    tk_optionMenu $w.filter.status ::WeldIntegrityCheck::ui(statusFilter) pending all completed
    pack $w.filter.searchLabel $w.filter.search $w.filter.statusLabel $w.filter.status -side left -padx {0 8}
    bind $w.filter.search <KeyRelease> ::WeldIntegrityCheck::refreshReview
    catch {trace remove variable ::WeldIntegrityCheck::ui(statusFilter) write ::WeldIntegrityCheck::statusFilterChanged}
    trace add variable ::WeldIntegrityCheck::ui(statusFilter) write ::WeldIntegrityCheck::statusFilterChanged
    frame $w.main -padx 12 -pady 8; pack $w.main -fill both -expand 1
    labelframe $w.main.left -text [::WeldIntegrityCheck::txt "Component Pair 列表" "Component Pair List"] -padx 5 -pady 5
    labelframe $w.main.right -text [::WeldIntegrityCheck::txt "当前 Pair 详情" "Current Pair Details"] -padx 10 -pady 10
    grid $w.main.left -row 0 -column 0 -sticky nsew; grid $w.main.right -row 0 -column 1 -sticky nsew -padx {8 0}
    grid columnconfigure $w.main 0 -weight 3; grid columnconfigure $w.main 1 -weight 2; grid rowconfigure $w.main 0 -weight 1
    listbox $w.main.left.list -selectmode browse -exportselection 0 -width 68 -height 20 -font [::HWFlow::uiFont fixedSmall]
    scrollbar $w.main.left.scroll -orient vertical -command "$w.main.left.list yview"
    $w.main.left.list configure -yscrollcommand "$w.main.left.scroll set"
    pack $w.main.left.scroll -side right -fill y; pack $w.main.left.list -side left -fill both -expand 1
    bind $w.main.left.list <<ListboxSelect>> ::WeldIntegrityCheck::onReviewSelection
    label $w.main.right.detail -textvariable ::WeldIntegrityCheck::ui(detailText) -justify left -anchor nw
    pack $w.main.right.detail -fill both -expand 1
    frame $w.region -padx 12 -pady 4; pack $w.region -fill x
    button $w.region.prev -text [::WeldIntegrityCheck::txt "上一区域" "Previous Region"] -command {::WeldIntegrityCheck::changeRegion -1}
    button $w.region.next -text [::WeldIntegrityCheck::txt "下一区域" "Next Region"] -command {::WeldIntegrityCheck::changeRegion 1}
    pack $w.region.prev $w.region.next -side left -padx {0 5}
    frame $w.actions -padx 12 -pady 10; pack $w.actions -fill x
    foreach spec {
        {isolate "孤立" "Isolate" ::WeldIntegrityCheck::isolateCurrent}
        {highlight "高亮区域" "Highlight Region" ::WeldIntegrityCheck::highlightCurrentRegion}
        {create "创建焊缝" "Create Weld" {::WeldIntegrityCheck::OpenWeldCreator [::WeldIntegrityCheck::currentPair]}}
        {previous "上一组" "Previous Pair" {::WeldIntegrityCheck::movePair -1}}
        {next "下一组" "Next Pair" {::WeldIntegrityCheck::movePair 1}}
        {complete "完成" "Complete" ::WeldIntegrityCheck::toggleComplete}
        {restore "恢复进入模块前显示" "Restore Original Display" ::WeldIntegrityCheck::restoreDisplay}
        {close "关闭" "Close" ::WeldIntegrityCheck::closeReview}
    } {
        button $w.actions.[lindex $spec 0] -text [::WeldIntegrityCheck::txt [lindex $spec 1] [lindex $spec 2]] -command [lindex $spec 3]
        pack $w.actions.[lindex $spec 0] -side left -padx {0 5}
    }
    ::WeldIntegrityCheck::refreshReview
}

proc ::WeldIntegrityCheck::statusFilterChanged {args} { after idle ::WeldIntegrityCheck::refreshReview }
