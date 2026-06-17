# ============================================================================
# Seam Surface Creation v0.7
# HyperMesh 2019 Tcl/Tk
#
# Creates seam geometry surfaces between midsurface components.
# Output components are named SEAM_Tx by the thinner adjacent shell thickness.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::SeamSurf {
    variable VERSION "0.7"
    variable RULE_FILE [file join [::HWFlow::configDir] "seam_rules.txt"]

    variable cfg
    array set cfg {
        max_gap_tol              2.0
        stitch_tolerance         0.2
        default_mode             LINE_SURFACE
        component_mode           by_thickness
        topology_connect         1
        prompt_candidates        0
        delete_construction_lines 1
        line_sync_divisions      8
        thickness_format         "%.3g"
    }

    variable ui
    array set ui {
        ok 0
        mode LINE_SURFACE
        status ""
        promptOk 0
        promptValue ""
        pickOk 0
        pickValue ""
    }

    variable stat
    array set stat {}
    variable seamKeyIndex
}

proc ::SeamSurf::defaultRuleText {} {
    return [join {
        {# Seam surface workflow defaults.}
        {key|value|note}
        {max_gap_tol|2.0|max allowed projection or stitching gap}
        {stitch_tolerance|0.2|topology stitch tolerance after seam surface creation}
        {default_mode|LINE_SURFACE|LINE_SURFACE or LINE_LINE}
        {component_mode|by_thickness|by_thickness or per_seam}
        {topology_connect|1|stitch seam surfaces to adjacent midsurfaces}
        {prompt_candidates|0|ask only when automatic seam detection cannot continue}
        {delete_construction_lines|1|delete copied source/projected construction lines after surface creation}
        {line_sync_divisions|8|minimum synchronized divisions used when building seam construction lines}
        {thickness_format|%.3g|T value format used in SEAM_Tx component names}
    } "\n"]
}

proc ::SeamSurf::normalizeMode {mode} {
    switch -- $mode {
        LINE_SURFACE -
        PROJECT_LINE -
        T_SURF {
            return LINE_SURFACE
        }
        LINE_LINE -
        L_LINES {
            return LINE_LINE
        }
    }
    return LINE_SURFACE
}

proc ::SeamSurf::ensureDefaultRules {} {
    variable RULE_FILE
    if {![file exists $RULE_FILE]} {
        ::HWFlow::writeTextFile $RULE_FILE [::SeamSurf::defaultRuleText]
    }
}

proc ::SeamSurf::loadRules {} {
    variable RULE_FILE
    variable cfg

    ::SeamSurf::ensureDefaultRules
    set data [::HWFlow::readTextFile $RULE_FILE]
    foreach rawLine [split $data "\n"] {
        set line [string trim $rawLine]
        if {$line eq "" || [string index $line 0] eq "#"} {
            continue
        }
        set cols [split $line "|"]
        set key [string trim [lindex $cols 0]]
        if {$key eq "key"} {
            continue
        }
        set value [string trim [lindex $cols 1]]
        if {[info exists cfg($key)]} {
            if {$key eq "default_mode"} {
                set cfg($key) [::SeamSurf::normalizeMode $value]
            } else {
                set cfg($key) $value
            }
        }
    }
}

proc ::SeamSurf::saveRules {} {
    variable RULE_FILE
    variable ui

    if {[info exists ui(mode)]} {
        set ui(mode) [::SeamSurf::normalizeMode $ui(mode)]
        set ui(default_mode) $ui(mode)
    }

    set notes {
        {max_gap_tol max allowed projection or stitching gap}
        {stitch_tolerance topology stitch tolerance after seam surface creation}
        {default_mode LINE_SURFACE or LINE_LINE}
        {component_mode by_thickness or per_seam}
        {topology_connect stitch seam surfaces to adjacent midsurfaces}
        {prompt_candidates ask only when automatic seam detection cannot continue}
        {delete_construction_lines delete copied source/projected construction lines after surface creation}
        {line_sync_divisions minimum synchronized divisions used when building seam construction lines}
        {thickness_format T value format used in SEAM_Tx component names}
    }

    set lines [list "# Seam surface workflow defaults." "key|value|note"]
    foreach item $notes {
        set key [lindex $item 0]
        set note [join [lrange $item 1 end] " "]
        lappend lines "$key|$ui($key)|$note"
    }
    ::HWFlow::writeTextFile $RULE_FILE [join $lines "\n"]
    set ui(status) "Rules saved."
}

proc ::SeamSurf::savePanelState {} {
    variable cfg
    variable ui

    foreach k [array names cfg] {
        if {[info exists ui($k)]} {
            set cfg($k) $ui($k)
        }
    }
    if {[info exists ui(mode)]} {
        set ui(mode) [::SeamSurf::normalizeMode $ui(mode)]
        set cfg(default_mode) $ui(mode)
        set ui(default_mode) $ui(mode)
    }

    if {![winfo exists .seam_surface]} {
        return
    }
    catch {::SeamSurf::saveRules}
}

proc ::SeamSurf::centerWindow {w} {
    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
}

proc ::SeamSurf::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::SeamSurf::showPanel {} {
    variable VERSION
    variable cfg
    variable ui

    ::SeamSurf::loadRules
    foreach k [array names cfg] {
        set ui($k) $cfg($k)
    }
    set ui(mode) [::SeamSurf::normalizeMode $cfg(default_mode)]
    set ui(ok) 0
    set ui(status) ""

    catch {destroy .seam_surface}
    set w .seam_surface
    toplevel $w
    wm title $w "[::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -font [::HWFlow::uiFont title]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.mode -text [::HWFlow::txt "1. 焊缝类型" "1. Seam Type"] -padx 8 -pady 8
    grid $w.main.mode -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    radiobutton $w.main.mode.ls -text [::HWFlow::txt "线-面：将所选边线投影到目标曲面" "Line-Surface: project selected line to selected surface"] \
        -variable ::SeamSurf::ui(mode) -value LINE_SURFACE
    radiobutton $w.main.mode.ll -text [::HWFlow::txt "线-线：桥接两条边界线" "Line-Line: bridge two selected boundary lines"] \
        -variable ::SeamSurf::ui(mode) -value LINE_LINE
    grid $w.main.mode.ls -row 0 -column 0 -sticky w -pady 2
    grid $w.main.mode.ll -row 1 -column 0 -sticky w -pady 2

    labelframe $w.main.param -text [::HWFlow::txt "2. 参数" "2. Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    set fields {
        {max_gap_tol "最大间隙容差" "Max gap tolerance"}
        {stitch_tolerance "缝合容差" "Stitch tolerance"}
        {line_sync_divisions "线同步分段数" "Line sync divisions"}
        {thickness_format "厚度格式" "Thickness format"}
    }
    set r 0
    foreach item $fields {
        set key [lindex $item 0]
        set text [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        label $w.main.param.l_$key -text $text -anchor w
        entry $w.main.param.e_$key -textvariable ::SeamSurf::ui($key) -width 16
        grid $w.main.param.l_$key -row $r -column 0 -sticky w -padx {0 8} -pady 2
        grid $w.main.param.e_$key -row $r -column 1 -sticky w -padx {0 20} -pady 2
        incr r
    }

    label $w.main.param.l_comp -text [::HWFlow::txt "组件模式" "Component mode"] -anchor w
    tk_optionMenu $w.main.param.m_comp ::SeamSurf::ui(component_mode) by_thickness per_seam
    grid $w.main.param.l_comp -row 0 -column 2 -sticky w -padx {0 8} -pady 2
    grid $w.main.param.m_comp -row 0 -column 3 -sticky w -pady 2

    labelframe $w.main.opt -text [::HWFlow::txt "3. 选项" "3. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    checkbutton $w.main.opt.topo -text [::HWFlow::txt "将焊缝面拓扑缝合到相邻中面" "Connect seam topology to adjacent midsurfaces"] \
        -variable ::SeamSurf::ui(topology_connect)
    checkbutton $w.main.opt.prompt -text [::HWFlow::txt "仅在自动焊缝识别无法继续时提示人工选择" "Ask only when automatic seam detection cannot continue"] \
        -variable ::SeamSurf::ui(prompt_candidates)
    checkbutton $w.main.opt.clean -text [::HWFlow::txt "创建焊缝面后删除复制的构造线" "Delete copied construction lines after creating the seam surface"] \
        -variable ::SeamSurf::ui(delete_construction_lines)
    grid $w.main.opt.topo -row 0 -column 0 -sticky w -pady 2
    grid $w.main.opt.prompt -row 1 -column 0 -sticky w -pady 2
    grid $w.main.opt.clean -row 2 -column 0 -sticky w -pady 2

    label $w.main.status -textvariable ::SeamSurf::ui(status) -width 74 -anchor w
    grid $w.main.status -row 4 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "::SeamSurf::savePanelState; set ::SeamSurf::ui(ok) 0; ::SeamSurf::backToHome .seam_surface"
    button $w.btn.save -text [::HWFlow::txt "保存规则" "Save Rules"] -width 12 -command "::SeamSurf::savePanelState"
    button $w.btn.start -text [::HWFlow::txt "开始" "Start"] -width 10 -command "::SeamSurf::acceptPanel"
    pack $w.btn.back -side right -padx 4
    pack $w.btn.start -side right -padx 4
    pack $w.btn.save -side right -padx 4

    bind $w <Escape> "::SeamSurf::savePanelState; set ::SeamSurf::ui(ok) 0; destroy .seam_surface"
    wm protocol $w WM_DELETE_WINDOW "::SeamSurf::savePanelState; set ::SeamSurf::ui(ok) 0; destroy .seam_surface"
    ::SeamSurf::centerWindow $w
    tkwait window $w
    return $ui(ok)
}

proc ::SeamSurf::acceptPanel {} {
    variable cfg
    variable ui

    foreach key {max_gap_tol stitch_tolerance} {
        if {![string is double -strict $ui($key)] || $ui($key) < 0} {
            tk_messageBox -icon warning -title [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -message [::HWFlow::txt "$key 必须为非负数值。" "$key must be a non-negative number."]
            return
        }
    }
    if {![string is integer -strict $ui(line_sync_divisions)] || $ui(line_sync_divisions) < 1} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -message [::HWFlow::txt "line_sync_divisions 必须为正整数。" "line_sync_divisions must be a positive integer."]
        return
    }
    if {$ui(component_mode) ni {by_thickness per_seam}} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -message [::HWFlow::txt "component_mode 必须为 by_thickness 或 per_seam。" "component_mode must be by_thickness or per_seam."]
        return
    }
    set ui(mode) [::SeamSurf::normalizeMode $ui(mode)]
    if {[string trim $ui(thickness_format)] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -message [::HWFlow::txt "thickness_format 不能为空。" "thickness_format cannot be empty."]
        return
    }

    foreach k [array names cfg] {
        set cfg($k) $ui($k)
    }
    set cfg(default_mode) $ui(mode)
    set ui(default_mode) $ui(mode)
    ::SeamSurf::saveRules
    set ui(ok) 1
    destroy .seam_surface
}

proc ::SeamSurf::msg {txt} {
    catch {hm_usermessage $txt}
    catch {puts $txt}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "SeamSurf: $txt"}
    }
}

proc ::SeamSurf::uniq {lst} {
    set out {}
    array set seen {}
    foreach v $lst {
        if {$v eq ""} {
            continue
        }
        if {![info exists seen($v)]} {
            set seen($v) 1
            lappend out $v
        }
    }
    return $out
}

proc ::SeamSurf::markEntities {etype markId ids} {
    catch {*clearmark $etype $markId}
    if {[llength $ids] == 0} {
        return 0
    }
    if {[catch {eval *createmark $etype $markId $ids}]} {
        return 0
    }
    return 1
}

proc ::SeamSurf::getMarkIds {etype markId} {
    if {[catch {set ids [hm_getmark $etype $markId]}]} {
        return {}
    }
    return $ids
}

proc ::SeamSurf::selectOneSurface {prompt} {
    catch {*clearmark surfs 1}
    *createmarkpanel surfs 1 $prompt
    set ids [::SeamSurf::getMarkIds surfs 1]
    catch {*clearmark surfs 1}
    if {[llength $ids] == 0} {
        error [::HWFlow::txt "未选择曲面。" "No surface was selected."]
    }
    return [lindex $ids 0]
}

proc ::SeamSurf::selectLines {prompt} {
    catch {*clearmark lines 1}
    *createmarkpanel lines 1 $prompt
    set ids [::SeamSurf::getMarkIds lines 1]
    catch {*clearmark lines 1}
    return [::SeamSurf::uniq $ids]
}

proc ::SeamSurf::latestId {entityTypes} {
    foreach etype $entityTypes {
        if {![catch {set id [hm_latestentityid $etype]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return 0
}

proc ::SeamSurf::entityExistsById {etype id} {
    catch {*clearmark $etype 2}
    if {![catch {*createmark $etype 2 $id}]} {
        if {![catch {set ids [hm_getmark $etype 2]}] && [lsearch -exact $ids $id] >= 0} {
            catch {*clearmark $etype 2}
            return 1
        }
    }
    catch {*clearmark $etype 2}
    return 0
}

proc ::SeamSurf::idsCreatedAfter {entityTypes beforeId afterId} {
    set out {}
    if {$afterId eq "" || $afterId == 0 || $afterId <= $beforeId} {
        return $out
    }
    for {set id [expr {$beforeId + 1}]} {$id <= $afterId} {incr id} {
        foreach etype $entityTypes {
            if {[::SeamSurf::entityExistsById $etype $id]} {
                lappend out $id
                break
            }
        }
    }
    return [::SeamSurf::uniq $out]
}

proc ::SeamSurf::getLastCreated {entityTypes} {
    foreach etype $entityTypes {
        if {![catch {set latest [hm_latestentityid $etype]}] && $latest ne "" && $latest != 0} {
            return [list $latest]
        }
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 -1}]} {
            if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                catch {*clearmark $etype 2}
                return $ids
            }
        }
        catch {*clearmark $etype 2}
    }
    return {}
}

proc ::SeamSurf::parseThicknessFromName {name} {
    if {[regexp {(^|_)T([0-9]+([.][0-9]+)?)(_|$)} $name -> pre value frac post]} {
        return $value
    }
    return ""
}

proc ::SeamSurf::formatThickness {value} {
    variable cfg

    if {$value eq "" || ![string is double -strict $value]} {
        return UNKNOWN
    }
    set fmt [string trim $cfg(thickness_format)]
    if {$fmt eq ""} {
        set fmt "%.3g"
    }
    if {[catch {set text [format $fmt $value]}]} {
        set text [format "%.3g" $value]
    }
    return [::HWFlow::sanitizeToken $text UNKNOWN]
}

proc ::SeamSurf::askThickness {label defaultValue reason} {
    variable ui

    catch {destroy .seam_thickness}
    set ui(promptOk) 0
    set ui(promptValue) $defaultValue
    if {$ui(promptValue) eq "" || $ui(promptValue) == 0} {
        set ui(promptValue) ""
    }

    set w .seam_thickness
    toplevel $w
    wm title $w [::HWFlow::txt "输入厚度" "Input Thickness"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    message $w.main.msg -width 420 -text "$label\n$reason"
    label $w.main.lab -text [::HWFlow::txt "厚度" "Thickness"]
    entry $w.main.entry -textvariable ::SeamSurf::ui(promptValue) -width 18
    grid $w.main.msg -row 0 -column 0 -columnspan 2 -sticky ew -pady {0 8}
    grid $w.main.lab -row 1 -column 0 -sticky w -padx {0 8}
    grid $w.main.entry -row 1 -column 1 -sticky w

    frame $w.btn -padx 12 -pady 8
    pack $w.btn -fill x
    button $w.btn.cancel -text [::HWFlow::txt "取消" "Cancel"] -width 10 -command "set ::SeamSurf::ui(promptOk) -1; destroy .seam_thickness"
    button $w.btn.ok -text [::HWFlow::txt "确定" "OK"] -width 10 -command "::SeamSurf::acceptThicknessPrompt"
    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.ok -side right -padx 4

    bind $w <Return> "::SeamSurf::acceptThicknessPrompt"
    bind $w <Escape> "set ::SeamSurf::ui(promptOk) -1; destroy .seam_thickness"
    ::SeamSurf::centerWindow $w
    tkwait window $w
    if {$ui(promptOk) < 0} {
        error [::HWFlow::txt "厚度输入已取消。" "Thickness input was cancelled."]
    }
    return $ui(promptValue)
}

proc ::SeamSurf::acceptThicknessPrompt {} {
    variable ui
    set v [string trim $ui(promptValue)]
    if {![string is double -strict $v] || $v <= 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "输入厚度" "Input Thickness"] -message [::HWFlow::txt "厚度必须为大于 0 的数值。" "Thickness must be a number greater than 0."]
        return
    }
    set ui(promptValue) $v
    set ui(promptOk) 1
    destroy .seam_thickness
}

proc ::SeamSurf::componentIdFromValue {value} {
    set v [string trim $value]
    if {$v eq ""} {
        return ""
    }
    if {[string is double -strict $v] && $v == 0} {
        return ""
    }
    if {[string is integer -strict $v]} {
        return $v
    }
    return [::HWFlow::componentIdByName $v]
}

proc ::SeamSurf::surfaceComponentId {surfId} {
    foreach dn {collector.id component.id componentid component collector} {
        if {![catch {set v [hm_getvalue surfs id=$surfId dataname=$dn]}] && $v ne ""} {
            set id [::SeamSurf::componentIdFromValue $v]
            if {$id ne ""} {
                return $id
            }
        }
        if {![catch {set v [hm_getvalue surfaces id=$surfId dataname=$dn]}] && $v ne ""} {
            set id [::SeamSurf::componentIdFromValue $v]
            if {$id ne ""} {
                return $id
            }
        }
        if {![catch {set v [hm_getentityvalue surfs $surfId $dn 0]}] && $v ne ""} {
            set id [::SeamSurf::componentIdFromValue $v]
            if {$id ne ""} {
                return $id
            }
        }
    }
    return ""
}

proc ::SeamSurf::surfaceComponentName {surfId} {
    set compId [::SeamSurf::surfaceComponentId $surfId]
    if {$compId ne ""} {
        return [::HWFlow::componentName $compId]
    }
    foreach dn {collector.name component.name name} {
        if {![catch {set v [hm_getvalue surfs id=$surfId dataname=$dn]}] && $v ne ""} {
            return $v
        }
    }
    return ""
}

proc ::SeamSurf::thicknessFromSurface {surfId} {
    set compName [::SeamSurf::surfaceComponentName $surfId]
    set t [::SeamSurf::parseThicknessFromName $compName]
    if {$t ne ""} {
        return $t
    }
    return [::SeamSurf::askThickness [::HWFlow::txt "曲面 $surfId" "Surface $surfId"] "" [::HWFlow::txt "无法从组件 \"$compName\" 中读取 _T 厚度标识。" "Cannot read a _T thickness token from component \"$compName\"."]]
}

proc ::SeamSurf::lineOwnerSurfaces {lineId} {
    set out {}
    foreach cmd [list \
        [list hm_getsurfacesfromedge $lineId] \
        [list hm_getsurfacesfromline $lineId] \
    ] {
        if {![catch {set ids [eval $cmd]}] && [llength $ids] > 0} {
            set out [concat $out $ids]
        }
    }
    return [::SeamSurf::uniq $out]
}

proc ::SeamSurf::chooseFromList {title items labels} {
    variable ui

    if {[llength $items] == 0} {
        return ""
    }
    if {[llength $items] == 1} {
        return [lindex $items 0]
    }

    catch {destroy .seam_pick}
    set ui(pickOk) 0
    set ui(pickValue) [lindex $items 0]

    set w .seam_pick
    toplevel $w
    wm title $w $title
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    listbox $w.main.list -height 9 -width 64 -exportselection 0
    scrollbar $w.main.ys -orient vertical -command "$w.main.list yview"
    $w.main.list configure -yscrollcommand "$w.main.ys set"
    grid $w.main.list -row 0 -column 0 -sticky news
    grid $w.main.ys -row 0 -column 1 -sticky ns

    for {set i 0} {$i < [llength $items]} {incr i} {
        $w.main.list insert end [lindex $labels $i]
    }
    $w.main.list selection set 0

    frame $w.btn -padx 12 -pady 8
    pack $w.btn -fill x
    button $w.btn.cancel -text [::HWFlow::txt "取消" "Cancel"] -width 10 -command "set ::SeamSurf::ui(pickOk) -1; destroy .seam_pick"
    button $w.btn.ok -text [::HWFlow::txt "确定" "OK"] -width 10 -command "::SeamSurf::acceptListPick $w.main.list [list $items]"
    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.ok -side right -padx 4

    bind $w <Double-Button-1> "::SeamSurf::acceptListPick $w.main.list [list $items]"
    bind $w <Return> "::SeamSurf::acceptListPick $w.main.list [list $items]"
    bind $w <Escape> "set ::SeamSurf::ui(pickOk) -1; destroy .seam_pick"
    ::SeamSurf::centerWindow $w
    tkwait window $w
    if {$ui(pickOk) < 0} {
        error [::HWFlow::txt "$title 已取消。" "$title was cancelled."]
    }
    return $ui(pickValue)
}

proc ::SeamSurf::acceptListPick {listWidget items} {
    variable ui
    set sel [$listWidget curselection]
    if {[llength $sel] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "选择项目" "Select Item"] -message [::HWFlow::txt "请选择一个项目。" "Select one item."]
        return
    }
    set idx [lindex $sel 0]
    set ui(pickValue) [lindex $items $idx]
    set ui(pickOk) 1
    destroy .seam_pick
}

proc ::SeamSurf::resolveLineOwnerSurface {lineId label {avoidSurf ""}} {
    set surfs [::SeamSurf::lineOwnerSurfaces $lineId]
    if {$avoidSurf ne "" && [llength $surfs] > 1} {
        set filtered {}
        foreach surf $surfs {
            if {$surf != $avoidSurf} {
                lappend filtered $surf
            }
        }
        if {[llength $filtered] > 0} {
            set surfs $filtered
        }
    }
    if {[llength $surfs] == 1} {
        return [lindex $surfs 0]
    }
    if {[llength $surfs] > 1} {
        foreach surf $surfs {
            set compName [::SeamSurf::surfaceComponentName $surf]
            if {[::SeamSurf::parseThicknessFromName $compName] ne ""} {
                return $surf
            }
        }
        return [lindex $surfs 0]
    }

    tk_messageBox -icon info -title [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -message [::HWFlow::txt "$label 线 $lineId 没有可读取的所属曲面。请手动选择所属中面。" "$label line $lineId has no readable owner surface. Select the owner midsurface now."]
    return [::SeamSurf::selectOneSurface [::HWFlow::txt "选择 $label 线 $lineId 的所属中面" "Select owner midsurface for $label line $lineId"]]
}

proc ::SeamSurf::surfaceEdges {surfId} {
    if {[catch {set loops [hm_getsurfaceedges $surfId]}]} {
        return {}
    }
    set edges {}
    foreach loop $loops {
        foreach edge $loop {
            lappend edges $edge
        }
    }
    return [::SeamSurf::uniq $edges]
}

proc ::SeamSurf::lineSurfaceDistance {lineId surfId} {
    if {[catch {set vals [hm_getclosestpointsbetweenlinesurface $lineId $surfId]}]} {
        return ""
    }
    if {[llength $vals] == 7} {
        return [lindex $vals 6]
    }
    if {[llength $vals] >= 6} {
        return 0.0
    }
    return ""
}

proc ::SeamSurf::dist3 {p q} {
    set dx [expr {[lindex $p 0] - [lindex $q 0]}]
    set dy [expr {[lindex $p 1] - [lindex $q 1]}]
    set dz [expr {[lindex $p 2] - [lindex $q 2]}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}

proc ::SeamSurf::clamp01 {v} {
    if {$v < 0.0} {
        return 0.0
    }
    if {$v > 1.0} {
        return 1.0
    }
    return $v
}

proc ::SeamSurf::gapExceeded {distance tolerance} {
    if {$tolerance <= 0} {
        return 0
    }
    set eps [expr {$tolerance * 1.0e-6}]
    if {$eps < 1.0e-6} {
        set eps 1.0e-6
    }
    expr {$distance > ($tolerance + $eps)}
}

proc ::SeamSurf::pointXYZ {pointId} {
    foreach etype {points point nodes node} {
        if {![catch {set xyz [hm_getvalue $etype id=$pointId dataname=coordinates]}] && [llength $xyz] >= 3} {
            return [lrange $xyz 0 2]
        }
        if {![catch {set xyz [hm_getentityvalue $etype $pointId coordinates 0]}] && [llength $xyz] >= 3} {
            return [lrange $xyz 0 2]
        }
    }
    return ""
}

proc ::SeamSurf::edgeEndPoints {edgeId} {
    if {![catch {set pts [hm_getverticesfromedge $edgeId]}] && [llength $pts] >= 2} {
        set p0 [::SeamSurf::pointXYZ [lindex $pts 0]]
        set p1 [::SeamSurf::pointXYZ [lindex $pts 1]]
        if {$p0 ne "" && $p1 ne ""} {
            return [list $p0 $p1]
        }
    }
    return ""
}

proc ::SeamSurf::linePointAtParam {lineId param} {
    set param [::SeamSurf::clamp01 $param]
    if {![catch {set pts [hm_getcoordinatesofpointsonline $lineId [list $param]]}]} {
        set p [lindex $pts 0]
        if {[llength $p] >= 3} {
            return [lrange $p 0 2]
        }
    }

    set ep [::SeamSurf::edgeEndPoints $lineId]
    if {$ep ne ""} {
        set p0 [lindex $ep 0]
        set p1 [lindex $ep 1]
        set out {}
        for {set i 0} {$i < 3} {incr i} {
            lappend out [expr {[lindex $p0 $i] + ([lindex $p1 $i] - [lindex $p0 $i]) * $param}]
        }
        return $out
    }

    error [::HWFlow::txt "无法读取线/边 $lineId 上的坐标。" "Cannot read coordinates on line/edge $lineId."]
}

proc ::SeamSurf::lineEndPoints {lineId} {
    if {![catch {set pts [hm_getcoordinatesofpointsonline $lineId [list 0.0 1.0]]}]} {
        if {[llength $pts] >= 2} {
            return [list [lrange [lindex $pts 0] 0 2] [lrange [lindex $pts 1] 0 2]]
        }
    }
    set ep [::SeamSurf::edgeEndPoints $lineId]
    if {$ep ne ""} {
        return $ep
    }
    error [::HWFlow::txt "无法读取线/边 $lineId 的端点。" "Cannot read endpoints for line/edge $lineId."]
}

proc ::SeamSurf::isClosedLine {lineId} {
    if {[catch {set ep [::SeamSurf::lineEndPoints $lineId]}]} {
        return 0
    }
    expr {[::SeamSurf::dist3 [lindex $ep 0] [lindex $ep 1]] <= 1.0e-6}
}

proc ::SeamSurf::lineLength {lineId} {
    set ep [::SeamSurf::lineEndPoints $lineId]
    return [::SeamSurf::dist3 [lindex $ep 0] [lindex $ep 1]]
}

proc ::SeamSurf::lineSampleCoords {lineId {divisions ""}} {
    variable cfg

    if {$divisions eq ""} {
        set divisions $cfg(line_sync_divisions)
    }
    if {![string is integer -strict $divisions] || $divisions < 1} {
        set divisions 8
    }

    set closed [::SeamSurf::isClosedLine $lineId]
    set maxI $divisions
    if {$closed} {
        set maxI [expr {$divisions - 1}]
    }
    set coords {}
    for {set i 0} {$i <= $maxI} {incr i} {
        set t [expr {$i / double($divisions)}]
        if {![catch {set p [::SeamSurf::linePointAtParam $lineId $t]}]} {
            lappend coords $p
        }
    }
    return [::SeamSurf::cleanCoordList $coords]
}

proc ::SeamSurf::sampleDivisions {} {
    variable cfg
    set n $cfg(line_sync_divisions)
    if {![string is integer -strict $n] || $n < 1} {
        set n 8
    }
    return $n
}

proc ::SeamSurf::surfaceClosestPoint {surfId point} {
    foreach {x y z} $point {}

    if {![catch {set vals [hm_findclosestpointonsurface $x $y $z $surfId]}] && [llength $vals] >= 4} {
        return [list [lrange $vals 0 2] [lindex $vals 3]]
    }

    if {![catch {set vals [hm_getcoordinatesfromnearestsurface $x $y $z [list $surfId]]}] && [llength $vals] >= 3} {
        set closest [lrange $vals 0 2]
        return [list $closest [::SeamSurf::dist3 $point $closest]]
    }

    if {![catch {set vals [hm_getsurfaceuvatcoordinate $surfId $x $y $z]}] && [llength $vals] >= 5} {
        set closest [lrange $vals 2 4]
        return [list $closest [::SeamSurf::dist3 $point $closest]]
    }

    error [::HWFlow::txt "无法在曲面 $surfId 上找到最近点。" "Cannot find closest point on surface $surfId."]
}

proc ::SeamSurf::runAverageDistance {samples} {
    if {[llength $samples] == 0} {
        return 1.0e99
    }
    set sum 0.0
    foreach sample $samples {
        set sum [expr {$sum + [lindex $sample 2]}]
    }
    return [expr {$sum / double([llength $samples])}]
}

proc ::SeamSurf::isBetterPairedRun {candidate current} {
    if {[llength $candidate] > [llength $current]} {
        return 1
    }
    if {[llength $candidate] < [llength $current]} {
        return 0
    }
    return [expr {[::SeamSurf::runAverageDistance $candidate] < [::SeamSurf::runAverageDistance $current]}]
}

proc ::SeamSurf::chooseBestPairedRun {samples label} {
    variable cfg

    if {[llength $samples] < 2} {
        error [::HWFlow::txt "$label 无法采样到足够的成对点。" "Cannot sample enough paired points for $label."]
    }

    set run {}
    set bestRun {}
    set minDist ""
    foreach sample $samples {
        set d [lindex $sample 2]
        if {$minDist eq "" || $d < $minDist} {
            set minDist $d
        }
        if {![::SeamSurf::gapExceeded $d $cfg(max_gap_tol)]} {
            lappend run $sample
        } else {
            if {[::SeamSurf::isBetterPairedRun $run $bestRun]} {
                set bestRun $run
            }
            set run {}
        }
    }
    if {[::SeamSurf::isBetterPairedRun $run $bestRun]} {
        set bestRun $run
    }

    if {$cfg(max_gap_tol) > 0 && [llength $bestRun] < 2} {
        error [::HWFlow::txt "$label 在 max_gap_tol=$cfg(max_gap_tol) 内没有连续成对跨度。最近采样距离=[format %.6g $minDist]。" "No continuous paired span is within max_gap_tol=$cfg(max_gap_tol) for $label. Nearest sampled distance=[format %.6g $minDist]."]
    }
    if {[llength $bestRun] < 2} {
        set bestRun $samples
    }
    return $bestRun
}

proc ::SeamSurf::chooseBestCircularPairedRun {samples label} {
    variable cfg

    if {[llength $samples] < 2} {
        error [::HWFlow::txt "$label 无法采样到足够的成对点。" "Cannot sample enough paired points for $label."]
    }

    if {$cfg(max_gap_tol) <= 0} {
        return $samples
    }

    set n [llength $samples]
    set valid {}
    set minDist ""
    for {set i 0} {$i < $n} {incr i} {
        set d [lindex [lindex $samples $i] 2]
        if {$minDist eq "" || $d < $minDist} {
            set minDist $d
        }
        lappend valid [expr {![::SeamSurf::gapExceeded $d $cfg(max_gap_tol)]}]
    }

    set allValid 1
    foreach ok $valid {
        if {!$ok} {
            set allValid 0
            break
        }
    }
    if {$allValid} {
        return $samples
    }

    set bestRun {}
    for {set start 0} {$start < $n} {incr start} {
        if {![lindex $valid $start]} {
            continue
        }
        set run {}
        for {set offset 0} {$offset < $n} {incr offset} {
            set idx [expr {($start + $offset) % $n}]
            if {![lindex $valid $idx]} {
                break
            }
            lappend run [lindex $samples $idx]
        }
        if {[::SeamSurf::isBetterPairedRun $run $bestRun]} {
            set bestRun $run
        }
    }

    if {[llength $bestRun] < 2} {
        error [::HWFlow::txt "$label 在 max_gap_tol=$cfg(max_gap_tol) 内没有连续成对跨度。最近采样距离=[format %.6g $minDist]。" "No continuous paired span is within max_gap_tol=$cfg(max_gap_tol) for $label. Nearest sampled distance=[format %.6g $minDist]."]
    }
    return $bestRun
}

proc ::SeamSurf::pairedRunCoords {samples label} {
    set sourceCoords {}
    set targetCoords {}
    set isClosed 0
    if {[llength $samples] > 0} {
        set meta [lindex [lindex $samples 0] 3]
        if {[string first "closed" $meta] >= 0} {
            set isClosed 1
        }
    }
    foreach sample $samples {
        lappend sourceCoords [lindex $sample 0]
        lappend targetCoords [lindex $sample 1]
    }

    set cleanSource {}
    set cleanTarget {}
    for {set i 0} {$i < [llength $sourceCoords]} {incr i} {
        set sp [lindex $sourceCoords $i]
        set tp [lindex $targetCoords $i]
        if {[llength $cleanSource] > 0} {
            set lastS [lindex $cleanSource end]
            set lastT [lindex $cleanTarget end]
            if {[::SeamSurf::dist3 $lastS $sp] <= 1.0e-8 || [::SeamSurf::dist3 $lastT $tp] <= 1.0e-8} {
                continue
            }
        }
        lappend cleanSource $sp
        lappend cleanTarget $tp
    }

    if {$isClosed && [llength $cleanSource] >= 3} {
        set firstS [lindex $cleanSource 0]
        set lastS [lindex $cleanSource end]
        set firstT [lindex $cleanTarget 0]
        set lastT [lindex $cleanTarget end]
        if {[::SeamSurf::dist3 $firstS $lastS] > 1.0e-8 && [::SeamSurf::dist3 $firstT $lastT] > 1.0e-8} {
            lappend cleanSource $firstS
            lappend cleanTarget $firstT
        }
    }

    if {[llength $cleanSource] < 2 || [llength $cleanTarget] < 2} {
        error [::HWFlow::txt "构建 $label 时成对点退化。" "Paired points collapsed while building $label."]
    }
    return [list $cleanSource $cleanTarget]
}

proc ::SeamSurf::projectLinePairedCoordsToSurface {lineId targetSurf} {
    set n [::SeamSurf::sampleDivisions]
    set closed [::SeamSurf::isClosedLine $lineId]
    set maxI $n
    set meta "open"
    if {$closed} {
        set maxI [expr {$n - 1}]
        set meta "closed"
    }
    set samples {}
    for {set i 0} {$i <= $maxI} {incr i} {
        set t [expr {$i / double($n)}]
        set source [::SeamSurf::linePointAtParam $lineId $t]
        set closestInfo [::SeamSurf::surfaceClosestPoint $targetSurf $source]
        set target [lindex $closestInfo 0]
        set d [lindex $closestInfo 1]
        lappend samples [list $source $target $d $meta]
    }

    if {$closed} {
        set bestRun [::SeamSurf::chooseBestCircularPairedRun $samples "Line-Surface projection"]
    } else {
        set bestRun [::SeamSurf::chooseBestPairedRun $samples "Line-Surface projection"]
    }
    return [::SeamSurf::pairedRunCoords $bestRun "Line-Surface projection"]
}

proc ::SeamSurf::projectLineCoordsToSurface {lineId targetSurf} {
    set pair [::SeamSurf::projectLinePairedCoordsToSurface $lineId $targetSurf]
    return [lindex $pair 1]
}

proc ::SeamSurf::lineClosestParam {lineId point} {
    foreach {x y z} $point {}
    if {![catch {set vals [hm_findclosestpointonline $x $y $z $lineId 1]}] && [llength $vals] >= 4} {
        set param [::SeamSurf::clamp01 [lindex $vals 3]]
        set closest [lrange $vals 0 2]
        return [list $param $closest [::SeamSurf::dist3 $point $closest]]
    }

    set ep [::SeamSurf::lineEndPoints $lineId]
    set p0 [lindex $ep 0]
    set p1 [lindex $ep 1]
    set vx [expr {[lindex $p1 0] - [lindex $p0 0]}]
    set vy [expr {[lindex $p1 1] - [lindex $p0 1]}]
    set vz [expr {[lindex $p1 2] - [lindex $p0 2]}]
    set wx [expr {[lindex $point 0] - [lindex $p0 0]}]
    set wy [expr {[lindex $point 1] - [lindex $p0 1]}]
    set wz [expr {[lindex $point 2] - [lindex $p0 2]}]
    set den [expr {$vx*$vx + $vy*$vy + $vz*$vz}]
    if {$den <= 0.0} {
        return [list 0.0 $p0 [::SeamSurf::dist3 $point $p0]]
    }
    set t [::SeamSurf::clamp01 [expr {($wx*$vx + $wy*$vy + $wz*$vz) / $den}]]
    set closest [::SeamSurf::linePointAtParam $lineId $t]
    return [list $t $closest [::SeamSurf::dist3 $point $closest]]
}

proc ::SeamSurf::lineProjectedInterval {baseLine otherLine} {
    set ep [::SeamSurf::lineEndPoints $otherLine]
    set a [::SeamSurf::lineClosestParam $baseLine [lindex $ep 0]]
    set b [::SeamSurf::lineClosestParam $baseLine [lindex $ep 1]]
    set p0 [lindex $a 0]
    set p1 [lindex $b 0]
    if {abs($p1 - $p0) < 1.0e-5} {
        return {0.0 1.0}
    }
    if {$p0 < $p1} {
        return [list $p0 $p1]
    }
    return [list $p1 $p0]
}

proc ::SeamSurf::linePairRunStats {run totalSamples minDist} {
    if {[llength $run] == 0 || $totalSamples <= 0} {
        return [dict create coverage 0.0 count 0 avgDist 1.0e99 targetSpan 0.0 minDist $minDist]
    }

    set sum 0.0
    set tMin ""
    set tMax ""
    foreach item $run {
        set t [lindex $item 0]
        set d [lindex $item 1]
        set sum [expr {$sum + $d}]
        if {$tMin eq "" || $t < $tMin} {
            set tMin $t
        }
        if {$tMax eq "" || $t > $tMax} {
            set tMax $t
        }
    }
    set count [llength $run]
    set avg [expr {$sum / double($count)}]
    set coverage [expr {$count / double($totalSamples)}]
    set span [expr {abs($tMax - $tMin)}]
    return [dict create coverage $coverage count $count avgDist $avg targetSpan $span minDist $minDist]
}

proc ::SeamSurf::linePairStats {sourceLine targetLine} {
    variable cfg

    set samples [::SeamSurf::lineSampleCoords $sourceLine]
    set total [llength $samples]
    if {$total < 2} {
        error [::HWFlow::txt "无法采样源边 $sourceLine。" "Cannot sample source edge $sourceLine."]
    }

    set run {}
    set bestRun {}
    set bestStats [dict create coverage 0.0 count 0 avgDist 1.0e99 targetSpan 0.0 minDist ""]
    set minDist ""

    foreach p $samples {
        if {[catch {set cp [::SeamSurf::lineClosestParam $targetLine $p]}]} {
            set stats [::SeamSurf::linePairRunStats $run $total $minDist]
            if {[::SeamSurf::isBetterLinePairStats $stats $bestStats]} {
                set bestStats $stats
                set bestRun $run
            }
            set run {}
            continue
        }
        set t [lindex $cp 0]
        set d [lindex $cp 2]
        if {$minDist eq "" || $d < $minDist} {
            set minDist $d
        }
        if {![::SeamSurf::gapExceeded $d $cfg(max_gap_tol)]} {
            lappend run [list $t $d]
        } else {
            set stats [::SeamSurf::linePairRunStats $run $total $minDist]
            if {[::SeamSurf::isBetterLinePairStats $stats $bestStats]} {
                set bestStats $stats
                set bestRun $run
            }
            set run {}
        }
    }

    set stats [::SeamSurf::linePairRunStats $run $total $minDist]
    if {[::SeamSurf::isBetterLinePairStats $stats $bestStats]} {
        set bestStats $stats
        set bestRun $run
    }
    dict set bestStats minDist $minDist
    dict set bestStats runCount [llength $bestRun]
    return $bestStats
}

proc ::SeamSurf::isBetterLinePairStats {candidate current} {
    set cCoverage [dict get $candidate coverage]
    set bCoverage [dict get $current coverage]
    if {$cCoverage > $bCoverage + 1.0e-6} {
        return 1
    }
    if {$cCoverage < $bCoverage - 1.0e-6} {
        return 0
    }

    set cSpan [dict get $candidate targetSpan]
    set bSpan [dict get $current targetSpan]
    if {$cSpan > $bSpan + 1.0e-6} {
        return 1
    }
    if {$cSpan < $bSpan - 1.0e-6} {
        return 0
    }

    set cAvg [dict get $candidate avgDist]
    set bAvg [dict get $current avgDist]
    return [expr {$cAvg < $bAvg}]
}

proc ::SeamSurf::lineLineDistance {lineA lineB} {
    if {![catch {set vals [hm_getclosestpointsbetweentwolines $lineA $lineB]}] && [llength $vals] >= 6} {
        return [::SeamSurf::dist3 [lrange $vals 0 2] [lrange $vals 3 5]]
    }

    if {[catch {set epA [::SeamSurf::lineEndPoints $lineA]}] || [catch {set epB [::SeamSurf::lineEndPoints $lineB]}]} {
        return ""
    }
    set best ""
    foreach p $epA {
        if {![catch {set c [::SeamSurf::lineClosestParam $lineB $p]}]} {
            set d [lindex $c 2]
            if {$best eq "" || $d < $best} {
                set best $d
            }
        }
    }
    foreach p $epB {
        if {![catch {set c [::SeamSurf::lineClosestParam $lineA $p]}]} {
            set d [lindex $c 2]
            if {$best eq "" || $d < $best} {
                set best $d
            }
        }
    }
    return $best
}

proc ::SeamSurf::chooseClosestLineToLine {sourceLine candidateLines} {
    set bestLine ""
    set bestDist ""
    foreach line $candidateLines {
        if {$line eq "" || $line == $sourceLine} {
            continue
        }
        set d [::SeamSurf::lineLineDistance $sourceLine $line]
        if {$d eq ""} {
            continue
        }
        if {$bestLine eq "" || $d < $bestDist} {
            set bestLine $line
            set bestDist $d
        }
    }
    if {$bestLine eq "" && [llength $candidateLines] > 0} {
        return [lindex $candidateLines 0]
    }
    return $bestLine
}

proc ::SeamSurf::chooseNearestTargetSurfaceEdge {sourceLine targetSurf} {
    variable cfg

    set candidates [::SeamSurf::freeSurfaceEdges $targetSurf]
    if {[llength $candidates] == 0} {
        set candidates [::SeamSurf::surfaceEdges $targetSurf]
    }

    set bestLine ""
    set bestDist ""
    foreach line $candidates {
        if {$line eq "" || $line == $sourceLine} {
            continue
        }
        set d [::SeamSurf::lineLineDistance $sourceLine $line]
        if {$d eq ""} {
            continue
        }
        if {$bestLine eq "" || $d < $bestDist} {
            set bestLine $line
            set bestDist $d
        }
    }

    if {$bestLine eq ""} {
        error [::HWFlow::txt "曲面 $targetSurf 上未找到可读取的目标边。" "No readable target surface edge was found on surface $targetSurf."]
    }
    if {[::SeamSurf::gapExceeded $bestDist $cfg(max_gap_tol)]} {
        error [::HWFlow::txt "最近目标边与源边距离为 [format %.6g $bestDist]，大于 max_gap_tol=$cfg(max_gap_tol)。" "Nearest target surface edge is [format %.6g $bestDist] away from the source edge, greater than max_gap_tol=$cfg(max_gap_tol)."]
    }
    return [list $bestLine $bestDist]
}

proc ::SeamSurf::chooseTFreeEdgePair {sourceSurf targetSurf} {
    set sourceEdges [::SeamSurf::freeSurfaceEdges $sourceSurf]
    set targetEdges [::SeamSurf::freeSurfaceEdges $targetSurf]
    if {[llength $sourceEdges] == 0} {
        error [::HWFlow::txt "源曲面 $sourceSurf 上未找到自由边。" "No free edge was found on source surface $sourceSurf."]
    }
    if {[llength $targetEdges] == 0} {
        error [::HWFlow::txt "目标曲面 $targetSurf 上未找到自由边。" "No free edge was found on target surface $targetSurf."]
    }

    set bestSource ""
    set bestTarget ""
    set bestStats ""
    foreach sourceEdge $sourceEdges {
        foreach targetEdge $targetEdges {
            if {[catch {set stats [::SeamSurf::linePairStats $sourceEdge $targetEdge]}]} {
                continue
            }
            if {[dict get $stats count] < 2} {
                continue
            }
            if {[dict get $stats targetSpan] < 0.02} {
                continue
            }
            if {$bestStats eq "" || [::SeamSurf::isBetterLinePairStats $stats $bestStats]} {
                set bestSource $sourceEdge
                set bestTarget $targetEdge
                set bestStats $stats
            }
        }
    }

    if {$bestSource eq "" || $bestTarget eq ""} {
        error [::HWFlow::txt "源曲面 $sourceSurf 与目标曲面 $targetSurf 之间未找到稳定的自由边配对。" "No stable free-edge pair was found between source surface $sourceSurf and target surface $targetSurf."]
    }
    return [list $bestSource $bestTarget $sourceSurf $targetSurf $bestStats]
}

proc ::SeamSurf::freeSurfaceEdges {surfId} {
    set edges [::SeamSurf::surfaceEdges $surfId]
    set free {}
    foreach edge $edges {
        set owners [::SeamSurf::lineOwnerSurfaces $edge]
        if {[llength $owners] == 0 || [llength $owners] == 1} {
            lappend free $edge
        }
    }
    if {[llength $free] == 0} {
        return $edges
    }
    return [::SeamSurf::uniq $free]
}

proc ::SeamSurf::chooseTProjectionPair {sourceSurf targetSurf} {
    variable cfg

    set candidates {}
    foreach edge [::SeamSurf::freeSurfaceEdges $sourceSurf] {
        set d [::SeamSurf::lineSurfaceDistance $edge $targetSurf]
        if {$d ne ""} {
            lappend candidates [list $d $edge $sourceSurf $targetSurf]
        }
    }
    if {[llength $candidates] == 0} {
        error [::HWFlow::txt "第一个已选 T 型焊缝面上未找到可读取的自由边候选。" "No readable free-edge candidate was found on the first selected T seam surface."]
    }

    set best [lindex [lsort -real -index 0 $candidates] 0]
    set d [lindex $best 0]
    if {[::SeamSurf::gapExceeded $d $cfg(max_gap_tol)]} {
        error [::HWFlow::txt "最近源自由边与第二个已选曲面的距离为 [format %.6g $d]，大于 max_gap_tol=$cfg(max_gap_tol)。" "Nearest source free edge is [format %.6g $d] away from the second selected surface, greater than max_gap_tol=$cfg(max_gap_tol)."]
    }
    return $best
}

proc ::SeamSurf::cleanCoordList {coords} {
    set out {}
    foreach p $coords {
        if {[llength $p] < 3} {
            continue
        }
        set p [lrange $p 0 2]
        if {[llength $out] == 0 || [::SeamSurf::dist3 [lindex $out end] $p] > 1.0e-8} {
            lappend out $p
        }
    }
    if {[llength $out] >= 3} {
        set first [lindex $out 0]
        set lastInput [lrange [lindex $coords end] 0 2]
        set lastOut [lindex $out end]
        if {[::SeamSurf::dist3 $first $lastInput] <= 1.0e-8 && [::SeamSurf::dist3 $lastOut $first] > 1.0e-8} {
            lappend out $first
        }
    }
    return $out
}

proc ::SeamSurf::createTempNodeAtCoord {point} {
    foreach {x y z} $point {}
    set before [::SeamSurf::latestId {nodes node}]
    *createnode $x $y $z 0 0 0
    set after [::SeamSurf::latestId {nodes node}]
    if {$after ne "" && $after != 0 && ($before eq "" || $after != $before)} {
        return $after
    }
    set nodes [::SeamSurf::getLastCreated {nodes node}]
    if {[llength $nodes] > 0} {
        return [lindex $nodes end]
    }
    error [::HWFlow::txt "临时节点未创建。" "Temporary node was not created."]
}

proc ::SeamSurf::deleteTempNodes {nodeIds} {
    set nodeIds [::SeamSurf::uniq $nodeIds]
    if {[llength $nodeIds] == 0} {
        return
    }
    catch {*clearmark nodes 2}
    if {![catch {eval *createmark nodes 2 $nodeIds}]} {
        catch {*deletemark nodes 2}
    }
    catch {*clearmark nodes 2}
}

proc ::SeamSurf::captureCreatedLine {before} {
    set after [::SeamSurf::latestId {lines line}]
    set created [::SeamSurf::idsCreatedAfter {lines line} $before $after]
    if {[llength $created] == 0 && $after != $before} {
        set created [list $after]
    }
    if {[llength $created] == 0} {
        set created [::SeamSurf::getLastCreated {lines line}]
    }
    if {[llength $created] == 0} {
        error [::HWFlow::txt "构造线未创建。" "Construction line was not created."]
    }
    return [lindex $created end]
}

proc ::SeamSurf::createLineFromCoords {coords} {
    set coords [::SeamSurf::cleanCoordList $coords]
    if {[llength $coords] < 2} {
        error [::HWFlow::txt "少于两个不同点，无法创建构造线。" "Cannot create a construction line with fewer than two distinct points."]
    }

    set before [::SeamSurf::latestId {lines line}]
    set nodeIds {}
    foreach p $coords {
        lappend nodeIds [::SeamSurf::createTempNodeAtCoord $p]
    }

    set errNodes ""
    catch {*createlist nodes 1}
    if {![catch {eval *createlist nodes 1 $nodeIds} errList]} {
        if {![catch {*linecreatefromnodes 1 0 150 5 179} errNodes]} {
            ::SeamSurf::deleteTempNodes $nodeIds
            return [::SeamSurf::captureCreatedLine $before]
        }
    } else {
        set errNodes $errList
    }

    ::SeamSurf::deleteTempNodes $nodeIds
    set p0 [lindex $coords 0]
    set p1 [lindex $coords end]
    foreach {x0 y0 z0} $p0 {}
    foreach {x1 y1 z1} $p1 {}
    if {![catch {*linecreatestraight $x0 $y0 $z0 $x1 $y1 $z1} errStraight]} {
        return [::SeamSurf::captureCreatedLine $before]
    }

    error [::HWFlow::txt "构造线未创建。linecreatefromnodes=$errNodes；linecreatestraight=$errStraight" "Construction line was not created. linecreatefromnodes=$errNodes; linecreatestraight=$errStraight"]
}

proc ::SeamSurf::createLineOnSurfaceFromCoords {targetSurf coords} {
    set coords [::SeamSurf::cleanCoordList $coords]
    if {[llength $coords] < 2} {
        error [::HWFlow::txt "少于两个不同投影点，无法创建目标线。" "Cannot create a target line with fewer than two distinct projected points."]
    }

    set before [::SeamSurf::latestId {lines line}]
    set nodeIds {}
    foreach p $coords {
        lappend nodeIds [::SeamSurf::createTempNodeAtCoord $p]
    }

    set errSurface ""
    catch {*createlist nodes 1}
    if {![catch {eval *createlist nodes 1 $nodeIds} errList]} {
        foreach options {1 0} {
            if {![catch {*linecreatefromnodesonsurface surfs $targetSurf nodes 1 0 $options} errSurface]} {
                if {![catch {set created [::SeamSurf::captureCreatedLine $before]}]} {
                    ::SeamSurf::deleteTempNodes $nodeIds
                    return $created
                }
            }
        }
    } else {
        set errSurface $errList
    }

    ::SeamSurf::deleteTempNodes $nodeIds
    set errFree ""
    if {![catch {set freeLine [::SeamSurf::createLineFromCoords $coords]} errFree]} {
        return $freeLine
    }
    error [::HWFlow::txt "未能在曲面 $targetSurf 上创建投影目标线。linecreatefromnodesonsurface=$errSurface；自由线回退=$errFree" "Projected target line was not created on surface $targetSurf. linecreatefromnodesonsurface=$errSurface; free line fallback=$errFree"]
}

proc ::SeamSurf::syncedConstructionLines {lineA lineB} {
    set n [::SeamSurf::sampleDivisions]
    set closed [::SeamSurf::isClosedLine $lineA]
    set maxI $n
    set meta "open"
    if {$closed} {
        set maxI [expr {$n - 1}]
        set meta "closed"
    }
    set samples {}
    for {set i 0} {$i <= $maxI} {incr i} {
        set t [expr {$i / double($n)}]
        set source [::SeamSurf::linePointAtParam $lineA $t]
        if {[catch {set closest [::SeamSurf::lineClosestParam $lineB $source]}]} {
            continue
        }
        set target [lindex $closest 1]
        set d [lindex $closest 2]
        lappend samples [list $source $target $d $meta]
    }

    if {$closed} {
        set bestRun [::SeamSurf::chooseBestCircularPairedRun $samples "Line-Line seam"]
    } else {
        set bestRun [::SeamSurf::chooseBestPairedRun $samples "Line-Line seam"]
    }
    set coordsPair [::SeamSurf::pairedRunCoords $bestRun "Line-Line seam"]
    set coordsA [lindex $coordsPair 0]
    set coordsB [lindex $coordsPair 1]

    set newA [::SeamSurf::createLineFromCoords $coordsA]
    set newB [::SeamSurf::createLineFromCoords $coordsB]
    return [list $newA $newB]
}

proc ::SeamSurf::enableInteractiveBrowserUpdates {} {
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {*setoption block_redraw=0}
    catch {*setoption block_messages=0}
    catch {hm_blockredraw 0}
    catch {hm_blockmessages 0}
    catch {hm_blockerrormessages 0}
    catch {hm_commandfilestate 1}
    catch {update idletasks}
}

proc ::SeamSurf::setCurrentComponent {compName} {
    if {[catch {*currentcollector component $compName} err1]} {
        if {[catch {*currentcollector components $compName} err2]} {
            if {[catch {*currentcollector(component,$compName)} err3]} {
                error [::HWFlow::txt "无法将当前组件设置为 $compName：$err1 / $err2 / $err3" "Cannot set current component to $compName: $err1 / $err2 / $err3"]
            }
        }
    }
}

proc ::SeamSurf::componentExistsByName {name} {
    return [::HWFlow::entityExistsByName components $name]
}

proc ::SeamSurf::uniqueComponentName {baseName} {
    set base [::HWFlow::sanitizeToken $baseName SEAM]
    if {![::SeamSurf::componentExistsByName $base]} {
        return $base
    }
    for {set i 1} {$i <= 999} {incr i} {
        set cand [format "%s_%02d" $base $i]
        if {![::SeamSurf::componentExistsByName $cand]} {
            return $cand
        }
    }
    return "${base}_[clock seconds]"
}

proc ::SeamSurf::markComponentByName {compName markId} {
    foreach etype {components comps} {
        catch {*clearmark $etype $markId}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $etype $markId $selector $compName}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                    return $etype
                }
            }
        }
    }

    set compId [::HWFlow::componentIdByName $compName]
    if {$compId ne ""} {
        foreach etype {components comps} {
            catch {*clearmark $etype $markId}
            if {![catch {*createmark $etype $markId "by id only" $compId}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} {
                    return $etype
                }
            }
        }
    }
    return ""
}

proc ::SeamSurf::refreshComponentBrowser {compName} {
    if {[llength [info commands ::HWFlow::activateAndShowComponent]] > 0} {
        catch {::HWFlow::activateAndShowComponent $compName 0}
        catch {::HWFlow::refreshBrowser}
        return
    }
    set markType [::SeamSurf::markComponentByName $compName 2]
    if {$markType ne ""} {
        catch {*marksuppressactive $markType 2 0}
        catch {*marksuppressoutput $markType 2 0}
        catch {*displaycollectorsbymark $markType 2 on 1 1}
        catch {*displaycollectorsallbymark 2 on 1 1}
        catch {*clearmark $markType 2}
    }
    catch {*displaycollector component on $compName 1 1}
    catch {*displaycollector components on $compName 1 1}
    catch {*displaycollectorwithfilter component on $compName 1 1}
    catch {*displaycollectorwithfilter components on $compName 1 1}
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {hm_redraw}
    catch {update idletasks}
    catch {update}
}

proc ::SeamSurf::seamComponentName {thickness} {
    variable cfg

    set base "SEAM_T[::SeamSurf::formatThickness $thickness]"
    if {$cfg(component_mode) eq "per_seam"} {
        return [::SeamSurf::uniqueComponentName $base]
    }
    return $base
}

proc ::SeamSurf::ensureSeamComponent {thickness} {
    set compName [::SeamSurf::seamComponentName $thickness]
    set compId [::HWFlow::componentIdByName $compName]
    if {$compId ne ""} {
        ::SeamSurf::setCurrentComponent $compName
        catch {::HWFlow::activateAndShowComponent $compName 0}
        ::SeamSurf::refreshComponentBrowser $compName
        return [list $compName $compId]
    }

    if {[llength [info commands ::HWFlow::createComponent]] > 0} {
        set compId [::HWFlow::createComponent $compName 11]
    } else {
        ::SeamSurf::enableInteractiveBrowserUpdates
        set histName "Created Component $compName"
        catch {*startnotehistorystate $histName}
        set createCode [catch {*createentity comps includeid=0 name=$compName} err1]
        if {$createCode} {
            set createCode [catch {*createentity components includeid=0 name=$compName} err1]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly comps $compName "" 11} err2]
        }
        if {$createCode} {
            set createCode [catch {*collectorcreateonly components $compName "" 11} err2]
        }
        if {$createCode} {
            catch {*endnotehistorystate $histName}
            error [::HWFlow::txt "无法创建焊缝组件 $compName：$err1 / $err2" "Cannot create seam component $compName: $err1 / $err2"]
        }
        catch {*endnotehistorystate $histName}
        set compId [::HWFlow::componentIdByName $compName]
    }

    ::SeamSurf::setCurrentComponent $compName
    if {$compId ne ""} {
        ::HWFlow::addComponentsToAssembly SEAM [list $compId] 11
    }
    catch {::HWFlow::activateAndShowComponent $compName 0}
    ::SeamSurf::refreshComponentBrowser $compName
    return [list $compName $compId]
}

proc ::SeamSurf::linePairSeamKey {lineA lineB sourceSurfs targetSurfs thickness} {
    set tText [::SeamSurf::formatThickness $thickness]
    set lines [lsort -integer [list $lineA $lineB]]
    set surfs [lsort -integer -unique [concat $sourceSurfs $targetSurfs]]
    return "linepair|T$tText|L=[join $lines ,]|S=[join $surfs ,]"
}

proc ::SeamSurf::coordPairSeamKey {sourceCoords targetCoords thickness} {
    set tText [::SeamSurf::formatThickness $thickness]
    set sourceKey [::HWFlow::coordListKey [::SeamSurf::cleanCoordList $sourceCoords] 0.001]
    set targetKey [::HWFlow::coordListKey [::SeamSurf::cleanCoordList $targetCoords] 0.001]
    if {[string compare $sourceKey $targetKey] > 0} {
        set tmp $sourceKey
        set sourceKey $targetKey
        set targetKey $tmp
    }
    return "coords|T$tText|A=$sourceKey|B=$targetKey"
}

proc ::SeamSurf::seamTagName {key} {
    return [::HWFlow::entityTagName SEAM_SURF $key]
}

proc ::SeamSurf::existingSeamByKey {key} {
    variable seamKeyIndex
    if {[info exists seamKeyIndex($key)]} {
        return [list 1 $seamKeyIndex($key)]
    }

    set tagName [::SeamSurf::seamTagName $key]
    set surfId [::HWFlow::entityIdByName {surfs surfaces} $tagName]
    if {$surfId ne ""} {
        set seamKeyIndex($key) $surfId
        return [list 1 $surfId]
    }
    return [list 0 ""]
}

proc ::SeamSurf::tagSeamSurface {surfId key} {
    variable seamKeyIndex
    set tagName [::SeamSurf::seamTagName $key]
    foreach etype {surfs surfaces} {
        catch {*setvalue $etype id=$surfId name=$tagName}
    }
    set seamKeyIndex($key) $surfId
    return $tagName
}

proc ::SeamSurf::copyLineOrEdgeToCurrent {lineId} {
    set before [::SeamSurf::latestId {lines line}]
    catch {*clearmark lines 1}
    if {[catch {*createmark lines 1 $lineId} errMark]} {
        catch {*clearmark lines 1}
        return $lineId
    }
    catch {*linefromsurfedgecomp lines 1 1}
    set after [::SeamSurf::latestId {lines line}]
    set created [::SeamSurf::idsCreatedAfter {lines line} $before $after]
    if {[llength $created] == 0 && $after == $before} {
        catch {*linefromsurfedge lines 1}
        catch {*linefromsurfedge 1}
    }
    catch {*clearmark lines 1}
    set after [::SeamSurf::latestId {lines line}]
    set created [::SeamSurf::idsCreatedAfter {lines line} $before $after]
    if {[llength $created] == 0 && $after != $before} {
        set created [list $after]
    }
    if {[llength $created] > 0} {
        return [lindex $created end]
    }
    return $lineId
}

proc ::SeamSurf::projectLineToSurfaceByClosestPoints {sourceLine targetSurf} {
    set pointErr ""
    if {![catch {
        set coords [::SeamSurf::projectLineCoordsToSurface $sourceLine $targetSurf]
        set targetLine [::SeamSurf::createLineFromCoords $coords]
    } pointErr]} {
        return [list $targetLine [list $targetSurf] [list $targetLine] {}]
    }

    error $pointErr
}

proc ::SeamSurf::splitSurfaceWithLine {targetSurf lineId} {
    variable cfg

    set beforeLine [::SeamSurf::latestId {lines line}]
    set beforeSurf [::SeamSurf::latestId {surfs surfaces}]

    catch {*clearmark surfs 1}
    catch {*clearmark lines 2}
    if {[catch {*createmark surfs 1 $targetSurf} errSurf]} {
        error [::HWFlow::txt "无法标记目标曲面 $targetSurf：$errSurf" "Cannot mark target surface $targetSurf: $errSurf"]
    }
    if {[catch {*createmark lines 2 $lineId} errLine]} {
        error [::HWFlow::txt "无法标记投影线 $lineId：$errLine" "Cannot mark projection line $lineId: $errLine"]
    }
    *createvector 1 0.0 0.0 1.0

    set trimFlag 12
    if {[catch {*surfacemarksplitwithlines 1 2 1 $trimFlag $cfg(max_gap_tol)} err]} {
        catch {*clearmark surfs 1}
        catch {*clearmark lines 2}
        error $err
    }
    catch {*clearmark surfs 1}
    catch {*clearmark lines 2}

    set afterLine [::SeamSurf::latestId {lines line}]
    set afterSurf [::SeamSurf::latestId {surfs surfaces}]
    set newSurfs [::SeamSurf::idsCreatedAfter {surfs surfaces} $beforeSurf $afterSurf]
    set newLines [::SeamSurf::idsCreatedAfter {lines line} $beforeLine $afterLine]
    return [list $newSurfs $newLines]
}

proc ::SeamSurf::projectLineToSurface {sourceLine targetSurf} {
    set projection [::SeamSurf::projectLineToSurfaceByClosestPoints $sourceLine $targetSurf]
    set targetLine [lindex $projection 0]
    set targetSurfs [lindex $projection 1]
    set targetLines [lindex $projection 2]

    set splitErr ""
    if {![catch {set splitInfo [::SeamSurf::splitSurfaceWithLine $targetSurf $targetLine]} splitErr]} {
        set newSurfs [lindex $splitInfo 0]
        set newLines [lindex $splitInfo 1]
        set targetSurfs [::SeamSurf::uniq [concat $targetSurfs $newSurfs]]
        set targetLines [::SeamSurf::uniq [concat $targetLines $newLines]]
    } else {
        ::SeamSurf::msg [::HWFlow::txt "线-面拓扑分割警告：$splitErr。将继续基于显式投影线创建焊缝面。" "Line-Surface topology split warning: $splitErr. Seam will still be created from the explicit projection line."]
    }

    return [list $targetLine $targetSurfs $targetLines {}]
}

proc ::SeamSurf::createRuledSurfaceBetweenLines {lineA lineB} {
    set before [::SeamSurf::latestId {surfs surfaces}]
    catch {*surfacemode 4}
    catch {*createlist lines 1}
    *createlist lines 1 $lineA $lineB

    set err1 ""
    if {[catch {*surfacecreateruled 1 1 0 2 1 0 0} err1]} {
        set err2 ""
        if {[catch {*surfaceskin 1 1} err2]} {
            error [::HWFlow::txt "无法在线 $lineA 与线 $lineB 之间创建焊缝面。ruled=$err1；skin=$err2" "Could not create seam surface between lines $lineA and $lineB. ruled=$err1; skin=$err2"]
        }
    }

    set after [::SeamSurf::latestId {surfs surfaces}]
    set newSurfs [::SeamSurf::idsCreatedAfter {surfs surfaces} $before $after]
    if {[llength $newSurfs] == 0 && $after != $before} {
        set newSurfs [list $after]
    }
    if {[llength $newSurfs] == 0} {
        set newSurfs [::SeamSurf::getLastCreated {surfs surfaces}]
    }
    if {[llength $newSurfs] == 0} {
        error [::HWFlow::txt "焊缝面命令已结束，但未能捕获新曲面 ID。" "Seam surface command finished but the new surface ID could not be captured."]
    }
    return [lindex $newSurfs end]
}

proc ::SeamSurf::deleteConstructionLines {lineIds} {
    variable cfg
    if {!$cfg(delete_construction_lines)} {
        return
    }
    set lineIds [::SeamSurf::uniq $lineIds]
    if {[llength $lineIds] == 0} {
        return
    }
    catch {*clearmark lines 1}
    if {![catch {eval *createmark lines 1 $lineIds}]} {
        catch {*deletemark lines 1}
    }
    catch {*clearmark lines 1}
}

proc ::SeamSurf::stitchSeamSurface {seamSurfs neighborSurfs} {
    variable cfg

    if {!$cfg(topology_connect)} {
        return 0
    }
    set ids [::SeamSurf::uniq [concat $seamSurfs $neighborSurfs]]
    if {[llength $ids] < 2} {
        return 0
    }
    catch {*clearmark surfs 1}
    if {[catch {eval *createmark surfs 1 $ids} errMark]} {
        catch {*clearmark surfs 1}
        ::SeamSurf::msg [::HWFlow::txt "焊缝面缝合警告：无法标记曲面：$errMark" "Seam stitch warning: could not mark surfaces: $errMark"]
        return 0
    }
    set ok 1
    set stitched 0
    foreach mode {130 2} {
        if {![catch {*selfstitchcombine 1 $mode $cfg(stitch_tolerance) $cfg(stitch_tolerance)} errStitch]} {
            set stitched 1
            break
        }
    }
    if {!$stitched} {
        ::SeamSurf::msg [::HWFlow::txt "焊缝面缝合警告：$errStitch" "Seam stitch warning: $errStitch"]
        set ok 0
    }
    catch {*clearmark surfs 1}
    return $ok
}

proc ::SeamSurf::minThickness {a b} {
    if {$a eq ""} {
        return $b
    }
    if {$b eq ""} {
        return $a
    }
    if {$a <= $b} {
        return $a
    }
    return $b
}

proc ::SeamSurf::createSeam {sourceLine targetLine sourceSurfs targetSurfs thickness} {
    variable stat

    set seamKey [::SeamSurf::linePairSeamKey $sourceLine $targetLine $sourceSurfs $targetSurfs $thickness]
    set existing [::SeamSurf::existingSeamByKey $seamKey]
    if {[lindex $existing 0]} {
        incr stat(skippedExisting)
        set compName [::SeamSurf::seamComponentName $thickness]
        lappend stat(details) [::HWFlow::txt "既有曲面 [lindex $existing 1] -> $compName，已跳过" "Existing surface [lindex $existing 1] -> $compName, skipped"]
        return [list [lindex $existing 1] $compName "" "" existing]
    }

    set compInfo [::SeamSurf::ensureSeamComponent $thickness]
    set compName [lindex $compInfo 0]

    set pair [::SeamSurf::syncedConstructionLines $sourceLine $targetLine]
    set sourceCopy [lindex $pair 0]
    set targetCopy [lindex $pair 1]
    set seamSurf [::SeamSurf::createRuledSurfaceBetweenLines $sourceCopy $targetCopy]
    ::SeamSurf::tagSeamSurface $seamSurf $seamKey
    set stitchOk [::SeamSurf::stitchSeamSurface [list $seamSurf] [concat $sourceSurfs $targetSurfs]]
    ::SeamSurf::deleteConstructionLines [list $sourceCopy $targetCopy]
    ::SeamSurf::refreshComponentBrowser $compName

    incr stat(created)
    if {$stitchOk} {
        incr stat(stitched)
    }
    lappend stat(details) [::HWFlow::txt "曲面 $seamSurf -> $compName" "Surface $seamSurf -> $compName"]
    return [list $seamSurf $compName $sourceCopy $targetCopy]
}

proc ::SeamSurf::createSeamFromPairedCoords {sourceCoords targetCoords sourceSurfs targetSurfs thickness {targetSurfForLine ""}} {
    variable stat

    set seamKey [::SeamSurf::coordPairSeamKey $sourceCoords $targetCoords $thickness]
    set existing [::SeamSurf::existingSeamByKey $seamKey]
    if {[lindex $existing 0]} {
        incr stat(skippedExisting)
        set compName [::SeamSurf::seamComponentName $thickness]
        lappend stat(details) [::HWFlow::txt "既有曲面 [lindex $existing 1] -> $compName，已跳过" "Existing surface [lindex $existing 1] -> $compName, skipped"]
        return [list [lindex $existing 1] $compName "" "" existing]
    }

    set compInfo [::SeamSurf::ensureSeamComponent $thickness]
    set compName [lindex $compInfo 0]

    set sourceCopy [::SeamSurf::createLineFromCoords $sourceCoords]
    set targetCopy [::SeamSurf::createLineFromCoords $targetCoords]
    if {$targetSurfForLine ne ""} {
        set splitErr ""
        if {![catch {set splitInfo [::SeamSurf::splitSurfaceWithLine $targetSurfForLine $targetCopy]} splitErr]} {
            set targetSurfs [::SeamSurf::uniq [concat $targetSurfs [lindex $splitInfo 0]]]
        } else {
            ::SeamSurf::msg [::HWFlow::txt "线-面拓扑分割警告：$splitErr。将仅在已记录的源跨度线与投影线之间创建焊缝面。" "Line-Surface topology split warning: $splitErr. Seam will still be created only between the recorded source span line and recorded projection line."]
        }
    }
    ::SeamSurf::msg [::HWFlow::txt "线-面记录线：源跨度线 $sourceCopy -> 投影线 $targetCopy。" "Line-Surface recorded lines: source span line $sourceCopy -> projection line $targetCopy."]

    set seamSurf [::SeamSurf::createRuledSurfaceBetweenLines $sourceCopy $targetCopy]
    ::SeamSurf::tagSeamSurface $seamSurf $seamKey
    set stitchOk [::SeamSurf::stitchSeamSurface [list $seamSurf] [concat $sourceSurfs $targetSurfs]]
    ::SeamSurf::deleteConstructionLines [list $sourceCopy $targetCopy]
    ::SeamSurf::refreshComponentBrowser $compName

    incr stat(created)
    if {$stitchOk} {
        incr stat(stitched)
    }
    lappend stat(details) [::HWFlow::txt "曲面 $seamSurf -> $compName" "Surface $seamSurf -> $compName"]
    return [list $seamSurf $compName $sourceCopy $targetCopy]
}

proc ::SeamSurf::processTSurface {} {
    set sourceSurf [::SeamSurf::selectOneSurface [::HWFlow::txt "选择 T 型焊缝源中面：其自由边将与第二个面的边界配对" "Select source midsurface for T seam: its free edge will pair with the second surface edge"]]
    set targetSurf [::SeamSurf::selectOneSurface [::HWFlow::txt "选择 T 型焊缝目标中面：将匹配其最近自由边" "Select target midsurface for T seam: its nearest free edge will be paired"]]
    if {$sourceSurf == $targetSurf} {
        error [::HWFlow::txt "源曲面和目标曲面必须不同。" "Source and target surfaces must be different."]
    }

    set t1 [::SeamSurf::thicknessFromSurface $sourceSurf]
    set t2 [::SeamSurf::thicknessFromSurface $targetSurf]
    set thickness [::SeamSurf::minThickness $t1 $t2]

    set edgePairErr ""
    if {![catch {set edgePair [::SeamSurf::chooseTFreeEdgePair $sourceSurf $targetSurf]} edgePairErr]} {
        set sourceEdge [lindex $edgePair 0]
        set targetLine [lindex $edgePair 1]
        set stats [lindex $edgePair 4]
        ::SeamSurf::msg [::HWFlow::txt "T 型焊缝自由边配对：源边 $sourceEdge -> 目标边 $targetLine，覆盖率=[format %.2f [dict get $stats coverage]]，平均间隙=[format %.6g [dict get $stats avgDist]]。" "T seam free-edge pair: source edge $sourceEdge -> target edge $targetLine, coverage=[format %.2f [dict get $stats coverage]], avg gap=[format %.6g [dict get $stats avgDist]]."]
        return [::SeamSurf::createSeam $sourceEdge $targetLine [list $sourceSurf] [list $targetSurf] $thickness]
    }

    ::SeamSurf::msg [::HWFlow::txt "T 型焊缝自由边配对警告：$edgePairErr。将使用投影回退方案。" "T seam free-edge pair warning: $edgePairErr. Using projection fallback."]
    set pair [::SeamSurf::chooseTProjectionPair $sourceSurf $targetSurf]
    set sourceEdge [lindex $pair 1]

    set paired [::SeamSurf::projectLinePairedCoordsToSurface $sourceEdge $targetSurf]
    set sourceCoords [lindex $paired 0]
    set targetCoords [lindex $paired 1]

    return [::SeamSurf::createSeamFromPairedCoords $sourceCoords $targetCoords [list $sourceSurf] [list $targetSurf] $thickness $targetSurf]
}

proc ::SeamSurf::processLineLine {} {
    set lines [::SeamSurf::selectLines [::HWFlow::txt "选择两条用于线-线焊缝的边界线" "Select two boundary lines for Line-Line seam"]]
    if {[llength $lines] != 2} {
        error [::HWFlow::txt "线-线焊缝需要且仅需要两条边界线。当前已选择 [llength $lines] 条。" "Line-Line seam requires exactly two boundary lines. Selected [llength $lines]."]
    }
    set lineA [lindex $lines 0]
    set lineB [lindex $lines 1]

    set surfA [::SeamSurf::resolveLineOwnerSurface $lineA [::HWFlow::txt "第一条" "First"]]
    set surfB [::SeamSurf::resolveLineOwnerSurface $lineB [::HWFlow::txt "第二条" "Second"]]
    set t1 [::SeamSurf::thicknessFromSurface $surfA]
    set t2 [::SeamSurf::thicknessFromSurface $surfB]
    set thickness [::SeamSurf::minThickness $t1 $t2]

    return [::SeamSurf::createSeam $lineA $lineB [list $surfA] [list $surfB] $thickness]
}

proc ::SeamSurf::processLineSurface {} {
    set lines [::SeamSurf::selectLines [::HWFlow::txt "选择线-面焊缝的源边线" "Select source line for Line-Surface seam"]]
    if {[llength $lines] != 1} {
        error [::HWFlow::txt "线-面焊缝需要且仅需要一条源边线。当前已选择 [llength $lines] 条。" "Line-Surface seam requires exactly one source line. Selected [llength $lines]."]
    }
    set sourceLine [lindex $lines 0]
    set targetSurf [::SeamSurf::selectOneSurface [::HWFlow::txt "选择线-面焊缝的目标中面" "Select target midsurface for Line-Surface seam"]]
    set sourceSurf [::SeamSurf::resolveLineOwnerSurface $sourceLine [::HWFlow::txt "源" "Source"] $targetSurf]
    if {$sourceSurf == $targetSurf} {
        error [::HWFlow::txt "源曲面和目标曲面必须不同。" "Source and target surfaces must be different."]
    }

    set t1 [::SeamSurf::thicknessFromSurface $sourceSurf]
    set t2 [::SeamSurf::thicknessFromSurface $targetSurf]
    set thickness [::SeamSurf::minThickness $t1 $t2]

    set paired [::SeamSurf::projectLinePairedCoordsToSurface $sourceLine $targetSurf]
    set sourceCoords [lindex $paired 0]
    set targetCoords [lindex $paired 1]

    return [::SeamSurf::createSeamFromPairedCoords $sourceCoords $targetCoords [list $sourceSurf] [list $targetSurf] $thickness $targetSurf]
}

proc ::SeamSurf::processLLines {} {
    return [::SeamSurf::processLineLine]
}

proc ::SeamSurf::processProjectionLine {} {
    return [::SeamSurf::processLineSurface]
}

proc ::SeamSurf::run {} {
    variable cfg
    variable ui
    variable stat
    variable seamKeyIndex

    if {![::SeamSurf::showPanel]} {
        catch {hm_usermessage [::HWFlow::txt "Seam Surface Creation 已取消。" "Seam Surface Creation cancelled."]}
        return
    }

    array unset stat
    array set stat {
        created 0
        stitched 0
        skippedExisting 0
        failed 0
        details {}
    }
    catch {array unset seamKeyIndex}
    array set seamKeyIndex {}

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] \
            [::HWFlow::txt "准备创建焊缝面..." "Preparing seam surface creation..."] \
            0]
    }
    ::SeamSurf::msg [::HWFlow::txt "Seam Surface Creation v$::SeamSurf::VERSION 开始。" "Seam Surface Creation v$::SeamSurf::VERSION started."]
    set ui(mode) [::SeamSurf::normalizeMode $ui(mode)]
    if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 20.0 \
            [::HWFlow::txt "Seam Surface Creation 正在执行" "Seam surface creation running"] \
            [::HWFlow::txt "模式：$ui(mode)" "Mode: $ui(mode)"] \
            1}
    }
    set err ""
    set code [catch {
        switch -- $ui(mode) {
            LINE_SURFACE {
                if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
                    catch {::HWFlow::progressUpdate 45.0 \
                        [::HWFlow::txt "Seam Surface Creation 正在执行" "Seam surface creation running"] \
                        [::HWFlow::txt "正在执行线-面焊缝流程..." "Running line-surface seam workflow..."] \
                        1}
                }
                ::SeamSurf::processLineSurface
            }
            LINE_LINE {
                if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
                    catch {::HWFlow::progressUpdate 45.0 \
                        [::HWFlow::txt "Seam Surface Creation 正在执行" "Seam surface creation running"] \
                        [::HWFlow::txt "正在执行线-线焊缝流程..." "Running line-line seam workflow..."] \
                        1}
                }
                ::SeamSurf::processLineLine
            }
            default {
                error [::HWFlow::txt "不支持的焊缝模式：$ui(mode)" "Unsupported seam mode: $ui(mode)"]
            }
        }
    } err]

    if {$progressOpened && [llength [info commands ::HWFlow::progressUpdate]] > 0} {
        catch {::HWFlow::progressUpdate 90.0 \
            [::HWFlow::txt "Seam Surface Creation 正在刷新结果" "Seam surface creation refreshing results"] \
            [::HWFlow::txt "正在刷新浏览器和图形窗口..." "Refreshing browser and graphics..."] \
            1}
    }
    ::HWFlow::refreshBrowser
    if {$code} {
        incr stat(failed)
        set msg [::HWFlow::txt "Seam Surface Creation 失败：\n$err" "Seam Surface Creation failed:\n$err"]
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "Seam Surface Creation 失败。" "Seam surface creation failed."] 100.0}
        }
        catch {tk_messageBox -icon error -title [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -message $msg}
        ::SeamSurf::msg $msg
        return
    }

    set msg [::HWFlow::txt "Seam Surface Creation 已完成。\n\n已创建焊缝面：$stat(created)\n已跳过既有焊缝面：$stat(skippedExisting)\n已完成拓扑缝合：$stat(stitched)" "Seam Surface Creation finished.\n\nCreated seam surfaces: $stat(created)\nSkipped existing seam surfaces: $stat(skippedExisting)\nTopology stitched: $stat(stitched)"]
    if {[llength $stat(details)] > 0} {
        append msg "\n\n[join $stat(details) \n]"
    }
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "Seam Surface Creation 已完成。" "Seam surface creation finished."] 100.0}
    }
    catch {tk_messageBox -icon info -title [::HWFlow::txt "Seam Surface Creation" "Seam Surface Creation"] -message $msg}
    ::SeamSurf::msg $msg
}
