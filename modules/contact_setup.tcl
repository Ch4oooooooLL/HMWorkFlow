# ============================================================================
# Contact Setup
# HyperMesh 2019 Tcl/Tk
#
# Lightweight workflow:
#   1) pick the two contact regions separately with HyperMesh's face selector
#   2) create two contact surfaces directly from the selected face elements
#   3) orient both contact surfaces toward one another
#   4) create a contact group that references the two surfaces
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::ContactSetup {
    variable VERSION "0.3"
    variable RULE_FILE [file join [::HWFlow::configDir] "contact_rules.txt"]

    variable cfg
    array set cfg {
        contact_type         STICK
        main_side            AUTO
        result_prefix        AUTO_CONTACT
        try_group            1
    }

    variable ui
    array set ui {
        selectedElemsA ""
        selectedElemsB ""
        selectedText  "No contact faces selected"
        selectionActive 0
        selectionWindows ""
        selectionAfter ""
        selectionAutoCreate 0
        status        ""
    }

    variable last
    array set last {}

    variable geometryElemNodes
    variable geometryNodeXYZ
    array set geometryElemNodes {}
    array set geometryNodeXYZ {}
}

proc ::ContactSetup::defaultRuleText {} {
    return [join {
        {# Lightweight contact setup defaults.}
        {key|value|note}
        {contact_type|STICK|OptiStruct CONTACT type: SLIDE, STICK or FREEZE}
        {main_side|AUTO|AUTO, FIRST or SECOND}
        {result_prefix|AUTO_CONTACT|name prefix for generated contact surfaces/groups}
        {try_group|1|create solver contact group after contact surfaces}
    } "\n"]
}

proc ::ContactSetup::stateKeys {} {
    return {contact_type main_side result_prefix try_group}
}

proc ::ContactSetup::ensureRuleFile {} {
    variable RULE_FILE
    if {![file exists $RULE_FILE]} {
        ::HWFlow::writeTextFile $RULE_FILE [::ContactSetup::defaultRuleText]
    }
}

proc ::ContactSetup::loadRules {} {
    variable RULE_FILE
    variable cfg

    ::ContactSetup::ensureRuleFile
    foreach raw [split [::HWFlow::readTextFile $RULE_FILE] "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} {
            continue
        }
        set cols [split $line "|"]
        if {[llength $cols] < 2} {
            continue
        }
        set key [string trim [lindex $cols 0]]
        if {$key eq "key" || ![info exists cfg($key)]} {
            continue
        }
        set cfg($key) [string trim [lindex $cols 1]]
    }
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray contact_setup ::ContactSetup::cfg
    }
    if {$cfg(contact_type) ni {SLIDE STICK FREEZE}} {
        set cfg(contact_type) STICK
    }
}

proc ::ContactSetup::saveRules {} {
    variable RULE_FILE
    variable cfg
    variable ui

    foreach key [::ContactSetup::stateKeys] {
        if {[info exists ui($key)]} {
            set cfg($key) $ui($key)
        }
    }
    set rows [list "# Lightweight contact setup defaults." "key|value|note"]
    foreach key [::ContactSetup::stateKeys] {
        lappend rows "$key|$cfg($key)|"
    }
    ::HWFlow::writeTextFile $RULE_FILE [join $rows "\n"]
    if {[llength [info commands ::HWFlow::saveArrayState]] > 0} {
        ::HWFlow::saveArrayState contact_setup ::ContactSetup::cfg
    }
}

proc ::ContactSetup::savePanelState {} {
    catch {::ContactSetup::saveRules}
}

proc ::ContactSetup::msg {text} {
    variable ui
    set ui(status) $text
    catch {hm_usermessage $text}
    catch {puts "ContactSetup: $text"}
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "ContactSetup: $text"}
    }
    catch {update idletasks}
}

proc ::ContactSetup::centerWindow {w} {
    update idletasks
    wm geometry $w +[expr {([winfo screenwidth $w] - [winfo reqwidth $w]) / 2}]+[expr {([winfo screenheight $w] - [winfo reqheight $w]) / 2}]
}

proc ::ContactSetup::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::ContactSetup::showPanel {{settingsOnly 0}} {
    variable VERSION
    variable cfg
    variable ui

    ::ContactSetup::loadRules
    foreach key [::ContactSetup::stateKeys] {
        set ui($key) $cfg($key)
    }
    set ui(selectedElemsA) ""
    set ui(selectedElemsB) ""
    set ui(selectedText) [::HWFlow::txt "未选择接触面" "No contact faces selected"]
    set ui(status) [::HWFlow::txt "依次选择两侧 Face 候选单元，筛选公共区域后创建相向接触。" "Pick both candidate faces; their common region will be used for opposing contact surfaces."]

    catch {destroy .contact_setup}
    set w .contact_setup
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "Contact Setup" "Contact Setup"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Contact Setup" "Contact Setup"] -font [::HWFlow::uiFont title]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 接触面选择" "1. Contact Face Selection"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.sel.pick -text [::HWFlow::txt "分两次选择 Face" "Pick Two Faces"] -width 18 -command "::ContactSetup::pickContactFaces"
    label $w.main.sel.info -textvariable ::ContactSetup::ui(selectedText) -width 78 -anchor w
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.type -text [::HWFlow::txt "2. 接触定义" "2. Contact Definition"] -padx 8 -pady 8
    grid $w.main.type -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.type.l_type -text [::HWFlow::txt "接触类型" "Contact type"] -anchor w
    tk_optionMenu $w.main.type.m_type ::ContactSetup::ui(contact_type) SLIDE STICK FREEZE
    label $w.main.type.l_side -text [::HWFlow::txt "主面" "Main side"] -anchor w
    tk_optionMenu $w.main.type.m_side ::ContactSetup::ui(main_side) AUTO FIRST SECOND
    grid $w.main.type.l_type -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.type.m_type -row 0 -column 1 -sticky w -padx {0 16} -pady 2
    grid $w.main.type.l_side -row 0 -column 2 -sticky w -padx {0 6} -pady 2
    grid $w.main.type.m_side -row 0 -column 3 -sticky w -pady 2

    labelframe $w.main.opt -text [::HWFlow::txt "3. 输出" "3. Output"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.opt.l_prefix -text [::HWFlow::txt "结果名前缀" "Result prefix"] -anchor w
    entry $w.main.opt.e_prefix -textvariable ::ContactSetup::ui(result_prefix) -width 22
    checkbutton $w.main.opt.group -text [::HWFlow::txt "创建接触 group" "Create contact group"] -variable ::ContactSetup::ui(try_group)
    grid $w.main.opt.l_prefix -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.opt.e_prefix -row 0 -column 1 -sticky w -pady 2
    grid $w.main.opt.group -row 1 -column 0 -columnspan 2 -sticky w -pady 2

    label $w.main.status -textvariable ::ContactSetup::ui(status) -width 92 -anchor w
    grid $w.main.status -row 4 -column 0 -columnspan 4 -sticky ew

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 \
        -command "::ContactSetup::savePanelState; ::ContactSetup::restoreView; ::ContactSetup::backToHome .contact_setup"
    button $w.btn.save -text [::HWFlow::txt "保存参数" "Save Parameters"] -width 12 -command "::ContactSetup::saveRules"
    button $w.btn.restore -text [::HWFlow::txt "恢复视图" "Restore View"] -width 12 -command "::ContactSetup::restoreView"
    if {!$settingsOnly} {
        button $w.btn.trim -text [::HWFlow::txt "修改接触" "Trim Contact"] -width 12 -command "::ContactSetup::trimContact"
        button $w.btn.create -text [::HWFlow::txt "创建接触" "Create Contact"] -width 12 -command "::ContactSetup::createContact"
    }
    pack $w.btn.back -side right -padx 4
    pack $w.btn.restore -side right -padx 4
    if {!$settingsOnly} {
        pack $w.btn.trim -side right -padx 4
        pack $w.btn.create -side right -padx 4
    }
    pack $w.btn.save -side right -padx 4

    bind $w <Escape> "::ContactSetup::savePanelState; ::ContactSetup::restoreView; destroy .contact_setup"
    wm protocol $w WM_DELETE_WINDOW "::ContactSetup::savePanelState; ::ContactSetup::restoreView; destroy .contact_setup"
    ::ContactSetup::centerWindow $w
    tkwait window $w
}

# HyperMesh 2019 supports face_edge_mode=1 and filter=6 on the native element
# picker.  This starts in 2D-face mode and exposes only face / face-ext modes,
# so the user selects a connected face without a Tcl-side component scan.
proc ::ContactSetup::finishFaceSelectionSession {} {
    variable ui
    if {$ui(selectionAfter) ne ""} {
        catch {after cancel $ui(selectionAfter)}
    }
    set ui(selectionAfter) ""
    catch {::HWFlow::nativePanelSessionEnd $ui(selectionWindows)}
    set ui(selectionWindows) ""
    set ui(selectionActive) 0
}

proc ::ContactSetup::pickContactFaces {{autoCreate 0}} {
    variable ui

    if {$ui(selectionActive)} {
        return 0
    }
    set ui(selectedElemsA) ""
    set ui(selectedElemsB) ""
    set ui(selectionActive) 1
    set ui(selectionAutoCreate) $autoCreate
    set ui(selectionWindows) [::HWFlow::nativePanelSessionBegin]
    set code [catch {
        set elemsA [::HWFlow::nativeMarkPanelInSession elems 1 [::HWFlow::txt \
            "选择第一侧接触 Face（中键确认）" \
            "Select the first contact face (middle-click to accept)"] 1 6]
    } err]
    if {$code} {
        ::ContactSetup::finishFaceSelectionSession
        tk_messageBox -icon error -title [::HWFlow::txt "Contact Setup" "Contact Setup"] -message $err
        return 0
    }
    set elemsA [::ContactSetup::uniq $elemsA]
    if {[llength $elemsA] == 0} {
        set ui(selectedElemsA) ""
        set ui(selectedElemsB) ""
        set ui(selectedText) [::HWFlow::txt "第一侧未选择，操作已取消。" "Nothing selected for side A; selection cancelled."]
        ::ContactSetup::finishFaceSelectionSession
        return 0
    }

    set ui(selectedElemsA) $elemsA
    set ui(selectedText) [::HWFlow::txt \
        "A 侧已选择 [llength $elemsA] 个单元，正在打开 B 侧选择..." \
        "Side A: [llength $elemsA] elements. Opening side B..."]
    # The current UI callback must unwind completely before HM2019 will accept
    # another push panel.  Opening B from a timer callback avoids the recursive
    # panel state that prevents middle-click acceptance from advancing.
    set ui(selectionAfter) [after 100 ::ContactSetup::pickSecondContactFace]
    return 1
}

proc ::ContactSetup::pickSecondContactFace {} {
    variable ui
    if {!$ui(selectionActive)} {
        return 0
    }
    set ui(selectionAfter) ""
    set code [catch {
        set elemsB [::HWFlow::nativeMarkPanelInSession elems 2 [::HWFlow::txt \
            "选择第二侧相向接触 Face（中键确认）" \
            "Select the opposing contact face (middle-click to accept)"] 1 6]
    } err]
    if {$code} {
        set ui(selectedElemsA) ""
        set ui(selectedElemsB) ""
        ::ContactSetup::finishFaceSelectionSession
        tk_messageBox -icon error -title [::HWFlow::txt "Contact Setup" "Contact Setup"] -message $err
        return 0
    }
    set elemsB [::ContactSetup::uniq $elemsB]
    if {[llength $elemsB] == 0} {
        set ui(selectedElemsA) ""
        set ui(selectedElemsB) ""
        set ui(selectedText) [::HWFlow::txt "第二侧未选择，操作已取消。" "Nothing selected for side B; selection cancelled."]
        ::ContactSetup::finishFaceSelectionSession
        return 0
    }

    set ui(selectedElemsB) $elemsB
    set ui(selectedText) [::HWFlow::txt \
        "已选择：A=[llength $ui(selectedElemsA)] 个单元，B=[llength $elemsB] 个单元" \
        "Selected: A=[llength $ui(selectedElemsA)] elements, B=[llength $elemsB] elements"]
    set autoCreate $ui(selectionAutoCreate)
    ::ContactSetup::finishFaceSelectionSession
    if {$autoCreate} {
        after idle ::ContactSetup::createContact
    }
    return 1
}

proc ::ContactSetup::validateSelectedFaces {} {
    variable ui
    if {[llength $ui(selectedElemsA)] == 0 || [llength $ui(selectedElemsB)] == 0} {
        error [::HWFlow::txt "请先分两次选择两侧接触 Face。" "Select both contact faces first."]
    }
    array set onA {}
    foreach eid $ui(selectedElemsA) { set onA($eid) 1 }
    foreach eid $ui(selectedElemsB) {
        if {[info exists onA($eid)]} {
            error [::HWFlow::txt \
                "两次选择包含相同单元 $eid；请分别选择相向的两侧。" \
                "The two selections share element $eid; select the two opposing sides separately."]
        }
    }
}

proc ::ContactSetup::validatePanel {} {
    variable ui
    ::ContactSetup::validateSelectedFaces
    if {$ui(contact_type) ni {SLIDE STICK FREEZE}} {
        error [::HWFlow::txt "接触类型无效。" "Invalid contact type."]
    }
    if {$ui(main_side) ni {AUTO FIRST SECOND}} {
        error [::HWFlow::txt "主面选项无效。" "Invalid main side."]
    }
    if {[string trim $ui(result_prefix)] eq ""} {
        error [::HWFlow::txt "结果名前缀不能为空。" "Result prefix cannot be empty."]
    }
}

proc ::ContactSetup::safeName {name} {
    set out $name
    regsub -all {[^A-Za-z0-9_]+} $out {_} out
    regsub -all {_+} $out {_} out
    set out [string trim $out _]
    if {$out eq ""} {
        return CONTACT
    }
    return $out
}

proc ::ContactSetup::uniq {items} {
    set out {}
    array set seen {}
    foreach item $items {
        if {![info exists seen($item)]} {
            set seen($item) 1
            lappend out $item
        }
    }
    return $out
}

proc ::ContactSetup::vsub {a b} {
    return [list \
        [expr {[lindex $a 0] - [lindex $b 0]}] \
        [expr {[lindex $a 1] - [lindex $b 1]}] \
        [expr {[lindex $a 2] - [lindex $b 2]}]]
}

proc ::ContactSetup::vcross {a b} {
    return [list \
        [expr {[lindex $a 1]*[lindex $b 2] - [lindex $a 2]*[lindex $b 1]}] \
        [expr {[lindex $a 2]*[lindex $b 0] - [lindex $a 0]*[lindex $b 2]}] \
        [expr {[lindex $a 0]*[lindex $b 1] - [lindex $a 1]*[lindex $b 0]}]]
}

proc ::ContactSetup::vnorm {a} {
    set x [lindex $a 0]
    set y [lindex $a 1]
    set z [lindex $a 2]
    return [expr {sqrt($x*$x + $y*$y + $z*$z)}]
}

proc ::ContactSetup::vdot {a b} {
    return [expr {
        [lindex $a 0]*[lindex $b 0] +
        [lindex $a 1]*[lindex $b 1] +
        [lindex $a 2]*[lindex $b 2]
    }]
}

proc ::ContactSetup::vnormalize {a} {
    set n [::ContactSetup::vnorm $a]
    if {$n <= 1.0e-12} {
        return {0.0 0.0 0.0}
    }
    return [list [expr {[lindex $a 0]/$n}] [expr {[lindex $a 1]/$n}] [expr {[lindex $a 2]/$n}]]
}

proc ::ContactSetup::nodeXYZ {nodeId} {
    variable geometryNodeXYZ
    if {[info exists geometryNodeXYZ($nodeId)]} {
        return $geometryNodeXYZ($nodeId)
    }
    if {![catch {hm_getvalue nodes id=$nodeId dataname=x} x] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=y} y] &&
        ![catch {hm_getvalue nodes id=$nodeId dataname=z} z]} {
        return [list $x $y $z]
    }
    if {![catch {hm_nodevalue $nodeId} val]} {
        if {[llength $val] == 1} {
            set val [lindex $val 0]
        }
        return [list [lindex $val 0] [lindex $val 1] [lindex $val 2]]
    }
    error [::HWFlow::txt "无法读取节点 $nodeId 坐标。" "Cannot read coordinates for node $nodeId."]
}

proc ::ContactSetup::elemsByComp {compId} {
    set elems [::HWFlow::getCompEntityIds $compId elems elems]
    if {[llength $elems] > 0} {
        return $elems
    }
    catch {*clearmark elems 2}
    catch {*createmark elems 2 "by comp id" $compId}
    catch {set elems [hm_getmark elems 2]}
    catch {*clearmark elems 2}
    return [::ContactSetup::uniq $elems]
}

proc ::ContactSetup::elemNodes {elemId} {
    variable geometryElemNodes
    if {[info exists geometryElemNodes($elemId)]} {
        return $geometryElemNodes($elemId)
    }
    if {![catch {hm_getvalue elems id=$elemId dataname=nodes} nodes] && [llength $nodes] > 0} {
        return $nodes
    }
    if {![catch {hm_nodelist $elemId} nodes] && [llength $nodes] > 0} {
        return $nodes
    }
    return {}
}

proc ::ContactSetup::centroidNodes {nodes} {
    set nodes [::ContactSetup::uniq $nodes]
    set sx 0.0
    set sy 0.0
    set sz 0.0
    set n 0
    foreach nodeId $nodes {
        set p [::ContactSetup::nodeXYZ $nodeId]
        set sx [expr {$sx + [lindex $p 0]}]
        set sy [expr {$sy + [lindex $p 1]}]
        set sz [expr {$sz + [lindex $p 2]}]
        incr n
    }
    if {$n == 0} {
        return {0.0 0.0 0.0}
    }
    return [list [expr {$sx/double($n)}] [expr {$sy/double($n)}] [expr {$sz/double($n)}]]
}

proc ::ContactSetup::faceNormal {nodes} {
    set nodes [::ContactSetup::uniq $nodes]
    if {[llength $nodes] < 3} {
        return {0.0 0.0 0.0}
    }
    set p0 [::ContactSetup::nodeXYZ [lindex $nodes 0]]
    for {set i 1} {$i < [expr {[llength $nodes] - 1}]} {incr i} {
        set p1 [::ContactSetup::nodeXYZ [lindex $nodes $i]]
        set p2 [::ContactSetup::nodeXYZ [lindex $nodes [expr {$i + 1}]]]
        set cr [::ContactSetup::vcross [::ContactSetup::vsub $p1 $p0] [::ContactSetup::vsub $p2 $p0]]
        if {[::ContactSetup::vnorm $cr] > 1.0e-12} {
            return [::ContactSetup::vnormalize $cr]
        }
    }
    return {0.0 0.0 0.0}
}

# Use one reference element per selected side.  The native face selector has
# already resolved the full regions, so reading every node on every selected
# element would only block HyperMesh on large meshes.  The returned flags are
# passed directly to contactsurfcreatewithshells as reverse_normals.
proc ::ContactSetup::referenceOrientations {elemsA elemsB} {
    set elemA [lindex $elemsA 0]
    set elemB [lindex $elemsB 0]
    if {$elemA eq "" || $elemB eq ""} {
        return [list "" 0 "" 1]
    }

    set nodesA [::ContactSetup::elemNodes $elemA]
    set nodesB [::ContactSetup::elemNodes $elemB]
    if {[llength $nodesA] < 3 || [llength $nodesB] < 3} {
        return [list $elemA 0 $elemB 1]
    }

    set centerA [::ContactSetup::centroidNodes $nodesA]
    set centerB [::ContactSetup::centroidNodes $nodesB]
    set towardB [::ContactSetup::vsub $centerB $centerA]
    set towardA [::ContactSetup::vsub $centerA $centerB]
    set normalA [::ContactSetup::faceNormal $nodesA]
    set normalB [::ContactSetup::faceNormal $nodesB]
    set reverseA [expr {[::ContactSetup::vdot $normalA $towardB] < 0.0 ? 1 : 0}]
    set reverseB [expr {[::ContactSetup::vdot $normalB $towardA] < 0.0 ? 1 : 0}]
    return [list $elemA $reverseA $elemB $reverseB]
}

proc ::ContactSetup::elemComponentId {elemId} {
    foreach dataname {collector.id component.id comp.id} {
        if {![catch {set value [hm_getvalue elems id=$elemId dataname=$dataname]}] &&
            $value ne "" && $value != 0} {
            return $value
        }
    }
    return ""
}

proc ::ContactSetup::componentForElems {elems fallback} {
    set compId [::ContactSetup::elemComponentId [lindex $elems 0]]
    if {$compId eq ""} {
        return $fallback
    }
    return $compId
}

proc ::ContactSetup::elemSpan {elemId} {
    set nodes [::ContactSetup::uniq [::ContactSetup::elemNodes $elemId]]
    if {[llength $nodes] < 2} {
        return 0.0
    }
    set first 1
    foreach nodeId $nodes {
        set p [::ContactSetup::nodeXYZ $nodeId]
        if {$first} {
            set xmin [lindex $p 0]; set xmax $xmin
            set ymin [lindex $p 1]; set ymax $ymin
            set zmin [lindex $p 2]; set zmax $zmin
            set first 0
        } else {
            set x [lindex $p 0]; set y [lindex $p 1]; set z [lindex $p 2]
            if {$x < $xmin} {set xmin $x}
            if {$x > $xmax} {set xmax $x}
            if {$y < $ymin} {set ymin $y}
            if {$y > $ymax} {set ymax $y}
            if {$z < $zmin} {set zmin $z}
            if {$z > $zmax} {set zmax $z}
        }
    }
    return [expr {sqrt(($xmax-$xmin)*($xmax-$xmin) + ($ymax-$ymin)*($ymax-$ymin) + ($zmax-$zmin)*($zmax-$zmin))}]
}

proc ::ContactSetup::median {values} {
    set vals {}
    foreach value $values {
        if {[string is double -strict $value] && $value > 0.0} {
            lappend vals $value
        }
    }
    set n [llength $vals]
    if {$n == 0} {
        return 0.0
    }
    set vals [lsort -real $vals]
    set mid [expr {$n / 2}]
    if {[expr {$n % 2}] == 1} {
        return [lindex $vals $mid]
    }
    return [expr {([lindex $vals [expr {$mid - 1}]] + [lindex $vals $mid]) / 2.0}]
}

proc ::ContactSetup::bboxForElems {elems} {
    set first 1
    foreach eid $elems {
        foreach nodeId [::ContactSetup::elemNodes $eid] {
            set p [::ContactSetup::nodeXYZ $nodeId]
            if {$first} {
                set xmin [lindex $p 0]; set xmax $xmin
                set ymin [lindex $p 1]; set ymax $ymin
                set zmin [lindex $p 2]; set zmax $zmin
                set first 0
            } else {
                set x [lindex $p 0]; set y [lindex $p 1]; set z [lindex $p 2]
                if {$x < $xmin} {set xmin $x}
                if {$x > $xmax} {set xmax $x}
                if {$y < $ymin} {set ymin $y}
                if {$y > $ymax} {set ymax $y}
                if {$z < $zmin} {set zmin $z}
                if {$z > $zmax} {set zmax $z}
            }
        }
    }
    if {$first} {
        error [::HWFlow::txt "没有可读取的接触候选单元节点。" "No readable nodes found in contact candidate elements."]
    }
    set center [list [expr {($xmin+$xmax)/2.0}] [expr {($ymin+$ymax)/2.0}] [expr {($zmin+$zmax)/2.0}]]
    set range [list [expr {$xmax-$xmin}] [expr {$ymax-$ymin}] [expr {$zmax-$zmin}]]
    return [dict create min [list $xmin $ymin $zmin] max [list $xmax $ymax $zmax] center $center range $range]
}

proc ::ContactSetup::bboxGap {bboxA bboxB} {
    set minA [dict get $bboxA min]
    set maxA [dict get $bboxA max]
    set minB [dict get $bboxB min]
    set maxB [dict get $bboxB max]
    set sum2 0.0
    for {set i 0} {$i < 3} {incr i} {
        set gap 0.0
        if {[lindex $maxA $i] < [lindex $minB $i]} {
            set gap [expr {[lindex $minB $i] - [lindex $maxA $i]}]
        } elseif {[lindex $maxB $i] < [lindex $minA $i]} {
            set gap [expr {[lindex $minA $i] - [lindex $maxB $i]}]
        }
        set sum2 [expr {$sum2 + $gap*$gap}]
    }
    return [expr {sqrt($sum2)}]
}

proc ::ContactSetup::faceRecords {elems} {
    set records {}
    set spans {}
    foreach eid $elems {
        set nodes [::ContactSetup::elemNodes $eid]
        if {[llength [::ContactSetup::uniq $nodes]] < 3} {
            continue
        }
        set center [::ContactSetup::centroidNodes $nodes]
        set normal [::ContactSetup::faceNormal $nodes]
        set span [::ContactSetup::elemSpan $eid]
        lappend spans $span
        lappend records [dict create elem $eid center $center normal $normal span $span]
    }
    return [list $records [::ContactSetup::median $spans]]
}

# Build the per-element geometry records and the side bounding box in one
# traversal.  The previous path walked every element once for bboxForElems and
# then three more times inside faceRecords (centroid, normal and span).
proc ::ContactSetup::faceGeometryData {elems {includeNormals 1}} {
    set records {}
    set spans {}
    set overallFirst 1
    foreach eid $elems {
        set nodes [::ContactSetup::uniq [::ContactSetup::elemNodes $eid]]
        if {[llength $nodes] < 3} {
            continue
        }

        set points {}
        set sx 0.0; set sy 0.0; set sz 0.0
        set first 1
        foreach nodeId $nodes {
            set p [::ContactSetup::nodeXYZ $nodeId]
            lappend points $p
            set x [lindex $p 0]; set y [lindex $p 1]; set z [lindex $p 2]
            set sx [expr {$sx + $x}]
            set sy [expr {$sy + $y}]
            set sz [expr {$sz + $z}]
            if {$first} {
                set xmin $x; set xmax $x
                set ymin $y; set ymax $y
                set zmin $z; set zmax $z
                set first 0
            } else {
                if {$x < $xmin} {set xmin $x}
                if {$x > $xmax} {set xmax $x}
                if {$y < $ymin} {set ymin $y}
                if {$y > $ymax} {set ymax $y}
                if {$z < $zmin} {set zmin $z}
                if {$z > $zmax} {set zmax $z}
            }
        }

        set count [llength $points]
        set center [list \
            [expr {$sx/double($count)}] \
            [expr {$sy/double($count)}] \
            [expr {$sz/double($count)}]]
        set normal {}
        if {$includeNormals} {
            set normal {0.0 0.0 0.0}
            set p0 [lindex $points 0]
            for {set i 1} {$i < [expr {$count - 1}]} {incr i} {
                set cr [::ContactSetup::vcross \
                    [::ContactSetup::vsub [lindex $points $i] $p0] \
                    [::ContactSetup::vsub [lindex $points [expr {$i + 1}]] $p0]]
                if {[::ContactSetup::vnorm $cr] > 1.0e-12} {
                    set normal [::ContactSetup::vnormalize $cr]
                    break
                }
            }
        }
        set span [expr {sqrt(
            ($xmax-$xmin)*($xmax-$xmin) +
            ($ymax-$ymin)*($ymax-$ymin) +
            ($zmax-$zmin)*($zmax-$zmin))}]
        lappend spans $span
        lappend records [dict create elem $eid center $center normal $normal span $span]

        if {$overallFirst} {
            set oxmin $xmin; set oxmax $xmax
            set oymin $ymin; set oymax $ymax
            set ozmin $zmin; set ozmax $zmax
            set overallFirst 0
        } else {
            if {$xmin < $oxmin} {set oxmin $xmin}
            if {$xmax > $oxmax} {set oxmax $xmax}
            if {$ymin < $oymin} {set oymin $ymin}
            if {$ymax > $oymax} {set oymax $ymax}
            if {$zmin < $ozmin} {set ozmin $zmin}
            if {$zmax > $ozmax} {set ozmax $zmax}
        }
    }
    if {$overallFirst} {
        error [::HWFlow::txt "没有可读取的接触候选单元节点。" "No readable nodes found in contact candidate elements."]
    }
    set bbox [dict create \
        min [list $oxmin $oymin $ozmin] \
        max [list $oxmax $oymax $ozmax] \
        center [list \
            [expr {($oxmin+$oxmax)/2.0}] \
            [expr {($oymin+$oymax)/2.0}] \
            [expr {($ozmin+$ozmax)/2.0}]] \
        range [list \
            [expr {$oxmax-$oxmin}] \
            [expr {$oymax-$oymin}] \
            [expr {$ozmax-$ozmin}]]]
    return [list $records [::ContactSetup::median $spans] $bbox]
}

proc ::ContactSetup::distance2 {a b} {
    set dx [expr {[lindex $a 0] - [lindex $b 0]}]
    set dy [expr {[lindex $a 1] - [lindex $b 1]}]
    set dz [expr {[lindex $a 2] - [lindex $b 2]}]
    return [expr {$dx*$dx + $dy*$dy + $dz*$dz}]
}

proc ::ContactSetup::gridKey {point cell} {
    set ix [expr {int(floor([lindex $point 0] / double($cell)))}]
    set iy [expr {int(floor([lindex $point 1] / double($cell)))}]
    set iz [expr {int(floor([lindex $point 2] / double($cell)))}]
    return "${ix}_${iy}_${iz}"
}

proc ::ContactSetup::buildRecordGrid {records cell gridVar} {
    upvar 1 $gridVar grid
    catch {array unset grid}
    array set grid {}
    set idx 0
    foreach rec $records {
        set key [::ContactSetup::gridKey [dict get $rec center] $cell]
        lappend grid($key) $idx
        incr idx
    }
}

proc ::ContactSetup::nearestRecord {rec otherRecords gridVar cell} {
    upvar 1 $gridVar grid
    set c [dict get $rec center]
    set key [::ContactSetup::gridKey $c $cell]
    scan $key "%d_%d_%d" ix iy iz
    set bestIdx -1
    set bestD2 ""
    for {set dx -1} {$dx <= 1} {incr dx} {
        for {set dy -1} {$dy <= 1} {incr dy} {
            for {set dz -1} {$dz <= 1} {incr dz} {
                set nkey "[expr {$ix+$dx}]_[expr {$iy+$dy}]_[expr {$iz+$dz}]"
                if {![info exists grid($nkey)]} {
                    continue
                }
                foreach idx $grid($nkey) {
                    set d2 [::ContactSetup::distance2 $c [dict get [lindex $otherRecords $idx] center]]
                    if {$bestD2 eq "" || $d2 < $bestD2} {
                        set bestD2 $d2
                        set bestIdx $idx
                    }
                }
            }
        }
    }
    if {$bestIdx < 0} {
        return {}
    }
    return [list $bestIdx $bestD2]
}

# Contact-region filtering only needs to know whether an opposite element is
# within searchTol.  Returning on the first qualifying center preserves the
# selected element sets while avoiding a full exact-nearest scan of all 27
# neighboring grid cells.
proc ::ContactSetup::firstNearbyRecord {rec otherRecords gridVar cell maxD2} {
    upvar 1 $gridVar grid
    set c [dict get $rec center]
    set key [::ContactSetup::gridKey $c $cell]
    scan $key "%d_%d_%d" ix iy iz
    for {set dx -1} {$dx <= 1} {incr dx} {
        for {set dy -1} {$dy <= 1} {incr dy} {
            for {set dz -1} {$dz <= 1} {incr dz} {
                set nkey "[expr {$ix+$dx}]_[expr {$iy+$dy}]_[expr {$iz+$dz}]"
                if {![info exists grid($nkey)]} {
                    continue
                }
                foreach idx $grid($nkey) {
                    set d2 [::ContactSetup::distance2 \
                        $c [dict get [lindex $otherRecords $idx] center]]
                    if {$d2 <= $maxD2} {
                        return [list $idx $d2]
                    }
                }
            }
        }
    }
    return {}
}

proc ::ContactSetup::progress {percent message detail {force 0}} {
    if {[llength [info commands ::HWFlow::progressIsActive]] == 0 ||
        ![::HWFlow::progressIsActive] ||
        [llength [info commands ::HWFlow::progressUpdate]] == 0} {
        return
    }
    catch {::HWFlow::progressUpdate $percent $message $detail $force}
}

proc ::ContactSetup::selectNearestContactFaces {elemsA elemsB} {
    set totalStarted [clock milliseconds]
    set geometryStarted $totalStarted
    # Normals are only required later for one reference element per side.
    # Computing them for every selected element is wasted work on large faces.
    set dataA [::ContactSetup::faceGeometryData $elemsA 0]
    set dataB [::ContactSetup::faceGeometryData $elemsB 0]
    set recsA [lindex $dataA 0]
    set recsB [lindex $dataB 0]
    set medA [lindex $dataA 1]
    set medB [lindex $dataB 1]
    set bboxA [lindex $dataA 2]
    set bboxB [lindex $dataB 2]
    set geometryMs [expr {[clock milliseconds] - $geometryStarted}]
    if {[llength $recsA] == 0 || [llength $recsB] == 0} {
        return [dict create elemsA {} elemsB {} pairMapA {} pairMapB {} searchTol 0 \
            perf [dict create geometry_ms $geometryMs grid_ms 0 match_ms 0 total_ms $geometryMs]]
    }

    set elemScale [expr {max($medA, $medB, 1.0e-6)}]
    set gap [::ContactSetup::bboxGap $bboxA $bboxB]
    set searchTol [expr {max($gap + 2.5*$elemScale, 2.5*$elemScale)}]
    set cell $searchTol
    set maxD2 [expr {$searchTol * $searchTol}]

    set gridStarted [clock milliseconds]
    array set gridA {}
    array set gridB {}
    ::ContactSetup::buildRecordGrid $recsA $cell gridA
    ::ContactSetup::buildRecordGrid $recsB $cell gridB
    set gridMs [expr {[clock milliseconds] - $gridStarted}]
    array set keepA {}
    array set keepB {}
    array set pairA {}
    array set pairB {}

    set matchStarted [clock milliseconds]
    set countA [llength $recsA]
    set countB [llength $recsB]
    for {set i 0} {$i < $countA} {incr i} {
        if {$i > 0 && [expr {$i % 2000}] == 0} {
            set pct [expr {30.0 + 12.0*$i/double(max($countA, 1))}]
            ::ContactSetup::progress $pct \
                [::HWFlow::txt "正在匹配第一侧接触区域" "Matching first contact side"] \
                "$i/$countA"
        }
        set near [::ContactSetup::firstNearbyRecord \
            [lindex $recsA $i] $recsB gridB $cell $maxD2]
        if {[llength $near] == 0} {
            continue
        }
        set j [lindex $near 0]
        set eidA [dict get [lindex $recsA $i] elem]
        set eidB [dict get [lindex $recsB $j] elem]
        set keepA($eidA) 1
        set keepB($eidB) 1
        set pairA($eidA) $eidB
    }

    for {set j 0} {$j < $countB} {incr j} {
        if {$j > 0 && [expr {$j % 2000}] == 0} {
            set pct [expr {42.0 + 13.0*$j/double(max($countB, 1))}]
            ::ContactSetup::progress $pct \
                [::HWFlow::txt "正在匹配第二侧接触区域" "Matching second contact side"] \
                "$j/$countB"
        }
        set near [::ContactSetup::firstNearbyRecord \
            [lindex $recsB $j] $recsA gridA $cell $maxD2]
        if {[llength $near] == 0} {
            continue
        }
        set i [lindex $near 0]
        set eidA [dict get [lindex $recsA $i] elem]
        set eidB [dict get [lindex $recsB $j] elem]
        set keepA($eidA) 1
        set keepB($eidB) 1
        set pairB($eidB) $eidA
    }

    set matchMs [expr {[clock milliseconds] - $matchStarted}]
    set totalMs [expr {[clock milliseconds] - $totalStarted}]
    return [dict create \
        elemsA [lsort -integer [array names keepA]] \
        elemsB [lsort -integer [array names keepB]] \
        pairMapA [array get pairA] \
        pairMapB [array get pairB] \
        recordsA $recsA \
        recordsB $recsB \
        searchTol $searchTol \
        perf [dict create geometry_ms $geometryMs grid_ms $gridMs match_ms $matchMs total_ms $totalMs]]
}

proc ::ContactSetup::recordMapByElem {records} {
    array set out {}
    foreach rec $records {
        set out([dict get $rec elem]) $rec
    }
    return [array get out]
}

proc ::ContactSetup::orientationByOppositeGeometry {elems recordMap pairMap otherRecordMap fallbackVector} {
    array set records $recordMap
    array set pairs $pairMap
    array set otherRecords $otherRecordMap
    set bestElem ""
    set bestDot 0.0
    set bestAbs -1.0
    foreach eid $elems {
        if {![info exists records($eid)]} {
            continue
        }
        set rec $records($eid)
        set n [dict get $rec normal]
        if {[llength $n] != 3} {
            set n [::ContactSetup::faceNormal [::ContactSetup::elemNodes $eid]]
        }
        set v $fallbackVector
        if {[info exists pairs($eid)] && [info exists otherRecords($pairs($eid))]} {
            set v [::ContactSetup::vsub [dict get $otherRecords($pairs($eid)) center] [dict get $rec center]]
        }
        set len [::ContactSetup::vnorm $v]
        if {$len <= 1.0e-12} {
            continue
        }
        set v [::ContactSetup::vnormalize $v]
        set dot [expr {[lindex $n 0]*[lindex $v 0] + [lindex $n 1]*[lindex $v 1] + [lindex $n 2]*[lindex $v 2]}]
        set absDot [expr {abs($dot)}]
        if {$absDot > $bestAbs} {
            set bestAbs $absDot
            set bestDot $dot
            set bestElem $eid
        }
    }
    if {$bestElem eq ""} {
        return [list [lindex $elems 0] 0]
    }
    return [list $bestElem [expr {$bestDot < 0.0 ? 1 : 0}]]
}

proc ::ContactSetup::elemConfig {elemId} {
    if {![catch {hm_getvalue elems id=$elemId dataname=config} cfg]} {
        return $cfg
    }
    return ""
}

proc ::ContactSetup::isSolidElem {elemId} {
    set cfg [::ContactSetup::elemConfig $elemId]
    if {[lsearch -exact {204 205 206 208 210 213 215 220} $cfg] >= 0} {
        return 1
    }
    return [regexp -nocase {(tetra|tet|penta|wedge|hex|hexa|pyramid|solid)} $cfg]
}

proc ::ContactSetup::isShellElem {elemId} {
    if {[::ContactSetup::isSolidElem $elemId]} {
        return 0
    }
    set n [llength [::ContactSetup::uniq [::ContactSetup::elemNodes $elemId]]]
    return [expr {$n >= 3 && $n <= 4}]
}

proc ::ContactSetup::deleteComponentByName {compName} {
    foreach etype {comps components} {
        catch {*clearmark $etype 2}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $etype 2 $selector $compName}]} {
                if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                    catch {*deletemark $etype 2}
                    catch {*clearmark $etype 2}
                    return 1
                }
            }
        }
    }
    return 0
}

proc ::ContactSetup::moveElemsToComponent {elems compName} {
    if {[llength $elems] == 0} {
        return 0
    }
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elems}]} {
        return 0
    }
    set ok [expr {![catch {*movemark elems 1 $compName}]}]
    catch {*clearmark elems 1}
    return $ok
}

proc ::ContactSetup::contactElemsForComponent {compId tag} {
    set elems [::ContactSetup::elemsByComp $compId]
    set shellElems {}
    set hasSolid 0
    foreach eid $elems {
        if {[::ContactSetup::isSolidElem $eid]} {
            set hasSolid 1
        } elseif {[::ContactSetup::isShellElem $eid]} {
            lappend shellElems $eid
        }
    }
    if {!$hasSolid} {
        return [dict create elems $shellElems tempComp ""]
    }

    set compName [::HWFlow::componentName $compId]
    set tempName "__CONTACT_FACE_${tag}_[::ContactSetup::safeName $compName]"
    ::ContactSetup::deleteComponentByName $tempName
    ::ContactSetup::deleteComponentByName "^faces"

    catch {*clearmark comps 1}
    if {[catch {*createmark comps 1 $compId}]} {
        catch {*createmark components 1 $compId}
    }
    if {[catch {*findfaces components 1} err]} {
        error [::HWFlow::txt "实体 component 生成自由面失败：$err" "Failed to create free faces for solid component: $err"]
    }
    set faceCompId [::HWFlow::componentIdByName "^faces"]
    if {$faceCompId eq ""} {
        error [::HWFlow::txt "未找到 ^faces 自由面组件。" "The ^faces free-face component was not found."]
    }
    set faceElems [::ContactSetup::elemsByComp $faceCompId]
    if {[llength $faceElems] == 0} {
        error [::HWFlow::txt "实体 component 没有生成可用自由面。" "No usable free-face elements were generated."]
    }
    ::HWFlow::createComponent $tempName 35
    ::ContactSetup::moveElemsToComponent $faceElems $tempName
    ::ContactSetup::deleteComponentByName "^faces"
    set tempId [::HWFlow::componentIdByName $tempName]
    return [dict create elems [::ContactSetup::elemsByComp $tempId] tempComp $tempName]
}

proc ::ContactSetup::deleteContactSurfByName {name} {
    foreach etype {contactsurfs contactsurf} {
        catch {*clearmark $etype 2}
        foreach selector {"by name only" "by name"} {
            if {![catch {*createmark $etype 2 $selector $name}]} {
                if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                    catch {*deletemark $etype 2}
                    catch {*clearmark $etype 2}
                    return 1
                }
            }
        }
    }
    return 0
}

proc ::ContactSetup::contactSurfIdByName {name} {
    foreach etype {contactsurfs contactsurf} {
        if {![catch {set id [hm_entityinfo id $etype $name -byname]}] && $id ne "" && $id != 0} {
            return $id
        }
        if {![catch {set id [hm_getvalue $etype name=$name dataname=id]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return ""
}

proc ::ContactSetup::adjustContactSurfNormal {name elems orientationElem reverseNormal} {
    if {$orientationElem eq "" || [llength $elems] == 0} {
        return 0
    }
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elems}]} {
        return 0
    }
    set ok [expr {![catch {*adjustcontactsurfacenormal $name 1 1 $orientationElem $reverseNormal}]}]
    catch {*clearmark elems 1}
    return $ok
}

proc ::ContactSetup::createContactSurf {name elems color orientationElem orientationReverse} {
    if {[llength $elems] == 0} {
        error [::HWFlow::txt "没有可用于 $name 的接触单元。" "No contact elements for $name."]
    }
    ::ContactSetup::deleteContactSurfByName $name
    # Create the shell-defined contact surface and populate it in one call.
    # *contactsurfcreatewithshells is the only creation path that yields a
    # contact surface *addshellstocontactsurf can later append to; creating the
    # entity with *createentity contactsurfs cardimage=SURF leaves it in a
    # definition type that rejects element addition, which surfaced at runtime
    # as a "write contact surf failed" error from *addshellstocontactsurf.
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elems} err]} {
        ::ContactSetup::deleteContactSurfByName $name
        error [::HWFlow::txt "接触面 $name 打 mark 失败：$err" "Failed to mark contact elements for $name: $err"]
    }
    if {[catch {*contactsurfcreatewithshells $name $color 1 $orientationReverse} err]} {
        catch {*clearmark elems 1}
        ::ContactSetup::deleteContactSurfByName $name
        error [::HWFlow::txt "创建 SURF contact surface $name 失败：$err" "Failed to create SURF contact surface $name: $err"]
    }
    catch {*clearmark elems 1}
    # *contactsurfcreatewithshells can leave the entity without the SURF card
    # image, in which case CONTACT exports its IDs but no matching SURF cards
    # are written.  Load the SURF dictionary explicitly, mirroring HyperMesh's
    # own OptiStruct contact wizard (autocontact_tab.tcl).
    if {![catch {set template [hm_info templatefilename]}] && $template ne ""} {
        catch {*clearmark contactsurfs 1}
        if {![catch {*createmark contactsurfs 1 "by name only" $name}]} {
            if {![catch {hm_marklength contactsurfs 1} len] && $len} {
                catch {*dictionaryload contactsurfs 1 $template "SURF"}
            }
            catch {*clearmark contactsurfs 1}
        }
    }
    set id [::ContactSetup::contactSurfIdByName $name]
    if {$id eq ""} {
        error [::HWFlow::txt "contact surface $name 已创建但无法读取 ID。" "Contact surface $name was created, but its ID could not be read."]
    }
    set cardImage ""
    if {[catch {set cardImage [hm_getvalue contactsurfs id=$id dataname=cardimage]}] ||
        ![string equal -nocase $cardImage SURF]} {
        ::ContactSetup::deleteContactSurfByName $name
        error [::HWFlow::txt \
            "contact surface $name 未绑定 OptiStruct SURF 卡片，已停止创建 CONTACT。" \
            "Contact surface $name is not backed by an OptiStruct SURF card; CONTACT creation was stopped."]
    }
    set actualElems {}
    if {[catch {set actualElems [hm_getvalue contactsurfs id=$id dataname=elements]}] ||
        [llength $actualElems] == 0} {
        ::ContactSetup::deleteContactSurfByName $name
        error [::HWFlow::txt \
            "contact surface $name 未包含任何单元，已停止创建 CONTACT。" \
            "Contact surface $name contains no elements; CONTACT creation was stopped."]
    }
    return $id
}

proc ::ContactSetup::baseName {compA compB} {
    variable ui
    set nameA "FACE_A"
    set nameB "FACE_B"
    if {$compA ne "" && $compA != 0} {
        catch {set nameA [::HWFlow::componentName $compA]}
    }
    if {$compB ne "" && $compB != 0} {
        catch {set nameB [::HWFlow::componentName $compB]}
    }
    set nA [::ContactSetup::safeName $nameA]
    set nB [::ContactSetup::safeName $nameB]
    set base "[::ContactSetup::safeName $ui(result_prefix)]_${ui(contact_type)}_${nA}_TO_${nB}"
    if {[string length $base] > 90} {
        set base "[::ContactSetup::safeName $ui(result_prefix)]_${ui(contact_type)}_[::HWFlow::stableHash ${nA}_${nB}]"
    }
    return $base
}

proc ::ContactSetup::groupReferenceIds {groupId side} {
    if {$side eq "main"} {
        set datanames {maincontactsurflist mastercontactsurflist}
    } else {
        set datanames {secondarycontactsurflist slavecontactsurflist}
    }
    foreach dataname $datanames {
        if {![catch {set ids [hm_getvalue groups id=$groupId dataname=$dataname]}] && [llength $ids] > 0} {
            return $ids
        }
    }
    return {}
}

proc ::ContactSetup::groupDefinitionMode {groupId side} {
    if {$side eq "main"} {
        set datanames {maindefinition masterdefinition}
    } else {
        set datanames {secondarydefinition slavedefinition}
    }
    foreach dataname $datanames {
        if {![catch {set mode [hm_getvalue groups id=$groupId dataname=$dataname]}] && $mode ne ""} {
            return $mode
        }
    }
    return ""
}

proc ::ContactSetup::contactTypeValue {contactType} {
    switch -- $contactType {
        SLIDE { return 0 }
        STICK { return 1 }
        FREEZE { return 2 }
    }
    error "Unsupported OptiStruct CONTACT type: $contactType"
}

proc ::ContactSetup::setContactGroupType {groupId contactType} {
    set attributeName ""
    set attributeNames {}
    catch {set attributeNames [hm_attributelist groups $groupId name -byid]}
    foreach preferred {CONTACT_PROP_TYPE TYPE CONTACT_TYPE CT_TYPE} {
        foreach candidate $attributeNames {
            if {[string equal -nocase $candidate $preferred]} {
                set attributeName $candidate
                break
            }
        }
        if {$attributeName ne ""} { break }
    }
    if {$attributeName eq ""} {
        catch {set attributeName [hm_attributeidfromname TYPE]}
    }
    if {$attributeName eq ""} {
        error [::HWFlow::txt \
            "当前 OptiStruct 模板中未找到 CONTACT 的 TYPE 属性。" \
            "The CONTACT TYPE attribute was not found in the current OptiStruct template."]
    }

    # OptiStruct's CONTACT_PROP_TYPE is a string enumeration in the HM2019
    # output template.  The generic TYPE dataname also exists but is unrelated
    # to the exported contact type, so writing it silently leaves SLIDE in the
    # solver deck.
    set value $contactType
    set command [list *setvalue groups id=$groupId STATUS=2 ${attributeName}=$value]
    if {[catch {uplevel #0 $command} err]} {
        error [::HWFlow::txt \
            "CONTACT TYPE=$contactType 写入失败：$err" \
            "Failed to set CONTACT TYPE=$contactType: $err"]
    }
    if {[catch {set actual [hm_getvalue groups id=$groupId dataname=$attributeName]}] ||
        ![string equal -nocase $actual $value]} {
        error [::HWFlow::txt \
            "CONTACT TYPE=$contactType 写入后校验失败。" \
            "CONTACT TYPE=$contactType failed verification after assignment."]
    }
}

proc ::ContactSetup::clearGeometryCache {} {
    variable geometryElemNodes
    variable geometryNodeXYZ
    array unset geometryElemNodes
    array unset geometryNodeXYZ
    array set geometryElemNodes {}
    array set geometryNodeXYZ {}
}

# Prime the selected face geometry with two mark-based database queries.  All
# downstream bbox/centroid/normal calculations then stay in Tcl memory.
proc ::ContactSetup::primeGeometryCache {elems} {
    variable geometryElemNodes
    variable geometryNodeXYZ
    ::ContactSetup::clearGeometryCache

    set elems [::ContactSetup::uniq $elems]
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elems}]} {
        error [::HWFlow::txt "公共区域计算无法创建单元 mark。" "Could not create the element mark for common-region detection."]
    }
    set markedElems [hm_getmark elems 1]
    set bulkNodes {}
    catch {set bulkNodes [hm_getvalue elems mark=1 dataname=nodes]}
    if {[llength $markedElems] == 1 && [llength $bulkNodes] >= 3 &&
        [llength [lindex $bulkNodes 0]] == 1} {
        set geometryElemNodes([lindex $markedElems 0]) $bulkNodes
    } elseif {[llength $bulkNodes] == [llength $markedElems]} {
        foreach eid $markedElems nodes $bulkNodes {
            set geometryElemNodes($eid) $nodes
        }
    }

    set allNodes {}
    foreach eid $markedElems {
        if {![info exists geometryElemNodes($eid)]} {
            set nodes {}
            catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}
            set geometryElemNodes($eid) $nodes
        }
        foreach nid $geometryElemNodes($eid) { lappend allNodes $nid }
    }
    set allNodes [::ContactSetup::uniq $allNodes]

    catch {*clearmark nodes 2}
    if {[llength $allNodes] > 0 && ![catch {eval *createmark nodes 2 $allNodes}]} {
        set markedNodes [hm_getmark nodes 2]
        set bulkXYZ {}
        catch {set bulkXYZ [hm_getvalue nodes mark=2 dataname=coordinates]}
        if {[llength $markedNodes] == 1 && [llength $bulkXYZ] >= 3 &&
            [llength [lindex $bulkXYZ 0]] == 1} {
            set geometryNodeXYZ([lindex $markedNodes 0]) [lrange $bulkXYZ 0 2]
        } elseif {[llength $bulkXYZ] == [llength $markedNodes]} {
            foreach nid $markedNodes xyz $bulkXYZ {
                if {[llength $xyz] >= 3} {
                    set geometryNodeXYZ($nid) [lrange $xyz 0 2]
                }
            }
        } elseif {[llength $bulkXYZ] == 3*[llength $markedNodes]} {
            set index 0
            foreach nid $markedNodes {
                set geometryNodeXYZ($nid) [lrange $bulkXYZ $index [expr {$index + 2}]]
                incr index 3
            }
        }
    }
    catch {*clearmark elems 1}
    catch {*clearmark nodes 2}
}

proc ::ContactSetup::createGroup {groupName mainSurfId secSurfId} {
    variable ui
    if {!$ui(try_group)} {
        return ""
    }

    foreach etype {groups group} {
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 "by name only" $groupName}]} {
            if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                catch {*deletemark $etype 2}
                break
            }
        }
    }

    set cardImage CONTACT
    if {[catch {*createentity groups name=$groupName cardimage=$cardImage} err]} {
        error [::HWFlow::txt "创建 $cardImage group 失败：$err" "Failed to create the $cardImage group: $err"]
    }

    set groupId [::HWFlow::entityIdByName {groups group} $groupName]
    if {$groupId eq "" || $groupId == 0} {
        error [::HWFlow::txt "group $groupName 已创建但无法读取 ID。" "Group $groupName was created, but its ID could not be read."]
    }
    # Supplying the typed entity references makes HyperMesh 2019 select
    # definition mode 5 (contact surfaces) automatically.  Writing the
    # definition fields explicitly in the same *setvalue call is rejected by
    # HM2019 with "Value is not modified successfully".
    if {[catch {
        *setvalue groups id=$groupId masterentityids={contactsurfs $mainSurfId}
        *setvalue groups id=$groupId slaveentityids={contactsurfs $secSurfId}
    } err]} {
        error [::HWFlow::txt "group 主从面写入失败：$err" "Failed to assign the group main/secondary surfaces: $err"]
    }
    ::ContactSetup::setContactGroupType $groupId $ui(contact_type)

    set actualMain [::ContactSetup::groupReferenceIds $groupId main]
    set actualSecondary [::ContactSetup::groupReferenceIds $groupId secondary]
    set mainDefinition [::ContactSetup::groupDefinitionMode $groupId main]
    set secondaryDefinition [::ContactSetup::groupDefinitionMode $groupId secondary]
    if {$mainDefinition != 5 || $secondaryDefinition != 5} {
        error [::HWFlow::txt \
            "group $groupName 未正确设为 contact surface 主从定义。" \
            "Group $groupName was not configured to use contact surfaces for its main/secondary definitions."]
    }
    if {[lsearch -exact $actualMain $mainSurfId] < 0 ||
        [lsearch -exact $actualSecondary $secSurfId] < 0} {
        error [::HWFlow::txt \
            "group $groupName 的主从 contact surface 校验失败。" \
            "The main/secondary contact surface references on group $groupName failed verification."]
    }
    return $groupId
}

proc ::ContactSetup::chooseMainSide {compA compB elemsA elemsB} {
    variable ui
    switch -- $ui(main_side) {
        FIRST { return FIRST }
        SECOND { return SECOND }
    }
    if {[llength $elemsB] > [llength $elemsA]} {
        return SECOND
    }
    return FIRST
}

proc ::ContactSetup::writePerformanceReport {values} {
    # Only persist runtime evidence inside a real HyperMesh session.  Plain Tcl
    # unit tests exercise createContact with command stubs and must not replace
    # the latest production timing report with synthetic zero-duration data.
    if {![info exists ::HWFlow::ROOT_DIR] || [llength [info commands hm_info]] == 0} {
        return ""
    }
    set outputDir [file join $::HWFlow::ROOT_DIR runtime tasks contact_setup]
    if {[catch {file mkdir $outputDir}]} {
        return ""
    }
    set path [file join $outputDir performance_latest.txt]
    set lines [list \
        "timestamp=[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}]" \
        "selected_a=[dict get $values selected_a]" \
        "selected_b=[dict get $values selected_b]" \
        "contact_a=[dict get $values contact_a]" \
        "contact_b=[dict get $values contact_b]" \
        "cache_ms=[dict get $values cache_ms]" \
        "geometry_ms=[dict get $values geometry_ms]" \
        "grid_ms=[dict get $values grid_ms]" \
        "match_ms=[dict get $values match_ms]" \
        "surface_a_ms=[dict get $values surface_a_ms]" \
        "surface_b_ms=[dict get $values surface_b_ms]" \
        "group_ms=[dict get $values group_ms]" \
        "refresh_ms=[dict get $values refresh_ms]" \
        "total_ms=[dict get $values total_ms]"]
    if {[catch {::HWFlow::writeTextFile $path [join $lines "\n"]}]} {
        return ""
    }
    return $path
}

proc ::ContactSetup::createContact {} {
    variable ui
    variable last

    set totalStarted [clock milliseconds]
    set progressOpened 0
    set code [catch {
        ::ContactSetup::validatePanel
        ::ContactSetup::saveRules

        if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
            catch {set progressOpened [::HWFlow::progressOpen \
                [::HWFlow::txt "创建接触" "Creating contact"] \
                [::HWFlow::txt "正在准备所选接触面..." "Preparing selected contact faces..."] 0]}
        }

        array unset last
        array set last {}

        # Limit common-region detection to the two face selections.  The old
        # workflow expanded both sides to entire components, which made the
        # same spatial search prohibitively expensive on production models.
        set selectedA [::ContactSetup::uniq $ui(selectedElemsA)]
        set selectedB [::ContactSetup::uniq $ui(selectedElemsB)]
        ::ContactSetup::progress 8.0 \
            [::HWFlow::txt "正在批量读取接触几何" "Reading contact geometry"] \
            "A=[llength $selectedA], B=[llength $selectedB]" 1
        set stageStarted [clock milliseconds]
        ::ContactSetup::primeGeometryCache [concat $selectedA $selectedB]
        set cacheMs [expr {[clock milliseconds] - $stageStarted}]
        ::ContactSetup::progress 25.0 \
            [::HWFlow::txt "正在建立空间索引" "Building spatial index"] \
            [::HWFlow::txt "几何数据已读取" "Geometry data loaded"] 1
        set contactFaces [::ContactSetup::selectNearestContactFaces $selectedA $selectedB]
        set elemsA [dict get $contactFaces elemsA]
        set elemsB [dict get $contactFaces elemsB]
        if {[llength $elemsA] == 0 || [llength $elemsB] == 0} {
            error [::HWFlow::txt \
                "两次选择之间未识别到公共接触区域。" \
                "No common contact region was found between the two selections."]
        }
        set compA [::ContactSetup::componentForElems $elemsA 0]
        set compB [::ContactSetup::componentForElems $elemsB 0]

        set mainSide [::ContactSetup::chooseMainSide $compA $compB $elemsA $elemsB]
        set base [::ContactSetup::baseName $compA $compB]
        set surfA "${base}_A"
        set surfB "${base}_B"
        set groupName "${base}_GROUP"

        set orientations [::ContactSetup::referenceOrientations $elemsA $elemsB]
        set orientElemA [lindex $orientations 0]
        set reverseA [lindex $orientations 1]
        set orientElemB [lindex $orientations 2]
        set reverseB [lindex $orientations 3]
        ::ContactSetup::progress 62.0 \
            [::HWFlow::txt "正在创建第一侧 SURF" "Creating first SURF"] \
            "elements=[llength $elemsA]" 1
        set stageStarted [clock milliseconds]
        set surfAId [::ContactSetup::createContactSurf $surfA $elemsA 13 $orientElemA $reverseA]
        set surfaceAMs [expr {[clock milliseconds] - $stageStarted}]
        ::ContactSetup::progress 74.0 \
            [::HWFlow::txt "正在创建第二侧 SURF" "Creating second SURF"] \
            "elements=[llength $elemsB]" 1
        set stageStarted [clock milliseconds]
        set surfBId [::ContactSetup::createContactSurf $surfB $elemsB 45 $orientElemB $reverseB]
        set surfaceBMs [expr {[clock milliseconds] - $stageStarted}]
        if {$mainSide eq "FIRST"} {
            set mainSurf $surfA
            set mainSurfId $surfAId
            set secSurf $surfB
            set secSurfId $surfBId
        } else {
            set mainSurf $surfB
            set mainSurfId $surfBId
            set secSurf $surfA
            set secSurfId $surfAId
        }
        ::ContactSetup::progress 86.0 \
            [::HWFlow::txt "正在创建 CONTACT 卡片" "Creating CONTACT card"] \
            "$mainSurf -> $secSurf" 1
        set stageStarted [clock milliseconds]
        set groupId [::ContactSetup::createGroup $groupName $mainSurfId $secSurfId]
        set groupMs [expr {[clock milliseconds] - $stageStarted}]

        set last(compA) $compA
        set last(compB) $compB
        set last(elemsA) $elemsA
        set last(elemsB) $elemsB
        set last(allElemsA) $selectedA
        set last(allElemsB) $selectedB
        set last(searchTol) [dict get $contactFaces searchTol]
        set last(orientElemA) $orientElemA
        set last(orientElemB) $orientElemB
        set last(reverseA) $reverseA
        set last(reverseB) $reverseB
        set last(surfA) $surfA
        set last(surfB) $surfB
        set last(surfAId) $surfAId
        set last(surfBId) $surfBId
        set last(mainSurf) $mainSurf
        set last(secSurf) $secSurf
        set last(mainSurfId) $mainSurfId
        set last(secSurfId) $secSurfId
        set last(groupName) $groupName
        set last(groupId) $groupId
        set last(tempA) ""
        set last(tempB) ""
        set last(restoreDisplay) ""

        ::ContactSetup::progress 96.0 \
            [::HWFlow::txt "正在刷新模型浏览器" "Refreshing Model Browser"] "" 1
        set stageStarted [clock milliseconds]
        catch {::HWFlow::refreshBrowser}
        set refreshMs [expr {[clock milliseconds] - $stageStarted}]
        set selectionPerf [dict create geometry_ms 0 grid_ms 0 match_ms 0]
        if {[dict exists $contactFaces perf]} {
            set selectionPerf [dict get $contactFaces perf]
        }
        set totalMs [expr {[clock milliseconds] - $totalStarted}]
        set perf [dict create \
            selected_a [llength $selectedA] \
            selected_b [llength $selectedB] \
            contact_a [llength $elemsA] \
            contact_b [llength $elemsB] \
            cache_ms $cacheMs \
            geometry_ms [dict get $selectionPerf geometry_ms] \
            grid_ms [dict get $selectionPerf grid_ms] \
            match_ms [dict get $selectionPerf match_ms] \
            surface_a_ms $surfaceAMs \
            surface_b_ms $surfaceBMs \
            group_ms $groupMs \
            refresh_ms $refreshMs \
            total_ms $totalMs]
        set last(perf) $perf
        set last(perfReport) [::ContactSetup::writePerformanceReport $perf]
        ::ContactSetup::msg [::HWFlow::txt \
            "接触创建完成：公共区域 A=[llength $elemsA]/[llength $selectedA]，B=[llength $elemsB]/[llength $selectedB]，搜索距离=[format %.6g [dict get $contactFaces searchTol]]，group=$groupName。" \
            "Contact created: common region A=[llength $elemsA]/[llength $selectedA], B=[llength $elemsB]/[llength $selectedB], search=[format %.6g [dict get $contactFaces searchTol]], group=$groupName."]
    } err]
    ::ContactSetup::clearGeometryCache
    if {$code} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "接触创建失败" "Contact creation failed"] 100.0}
        }
        tk_messageBox -icon error -title [::HWFlow::txt "Contact Setup" "Contact Setup"] -message $err
    } elseif {$progressOpened && [llength [info commands ::HWFlow::progressFinish]] > 0} {
        catch {::HWFlow::progressFinish \
            [::HWFlow::txt "接触创建完成" "Contact creation completed"] 100.0}
    }
}

proc ::ContactSetup::displayedComponents {} {
    set comps {}
    foreach etype {comps components} {
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 displayed}]} {
            catch {set comps [hm_getmark $etype 2]}
            if {[llength $comps] > 0} {
                catch {*clearmark $etype 2}
                return $comps
            }
        }
    }
    return $comps
}

proc ::ContactSetup::setAllComponentsDisplay {state} {
    foreach etype {comps components} {
        catch {*clearmark $etype 1}
        if {![catch {*createmark $etype 1 all}]} {
            catch {*displaycollectorsbymark $etype 1 $state 1 1}
            catch {*displaycollectorsallbymark 1 $state 1 1}
            catch {*clearmark $etype 1}
            return 1
        }
    }
    return 0
}

proc ::ContactSetup::setComponentsDisplayByIds {compIds state} {
    set compIds [::ContactSetup::uniq $compIds]
    if {[llength $compIds] == 0} {
        return 0
    }
    foreach etype {comps components} {
        catch {*clearmark $etype 1}
        if {![catch {eval *createmark $etype 1 $compIds}]} {
            catch {*displaycollectorsbymark $etype 1 $state 1 1}
            catch {*displaycollectorsallbymark 1 $state 1 1}
            catch {*clearmark $etype 1}
            return 1
        }
    }
    return 0
}

proc ::ContactSetup::showOnlyLast {} {
    variable last
    if {![info exists last(compA)]} {
        return
    }
    set ids [list $last(compA) $last(compB)]
    foreach tmp [list $last(tempA) $last(tempB)] {
        if {$tmp ne ""} {
            set cid [::HWFlow::componentIdByName $tmp]
            if {$cid ne ""} {
                lappend ids $cid
            }
        }
    }
    ::ContactSetup::setAllComponentsDisplay off
    ::ContactSetup::setComponentsDisplayByIds $ids on
    catch {hm_redraw}
}

proc ::ContactSetup::restoreView {} {
    variable last
    if {![info exists last(restoreDisplay)] || $last(restoreDisplay) eq ""} {
        return
    }
    ::ContactSetup::setAllComponentsDisplay off
    ::ContactSetup::setComponentsDisplayByIds $last(restoreDisplay) on
    set last(restoreDisplay) ""
    catch {hm_redraw}
    ::ContactSetup::msg [::HWFlow::txt "已恢复进入修改模式前的显示状态。" "Restored the display state before trim mode."]
}

proc ::ContactSetup::removeElemsFromSurface {surfName elems} {
    if {$surfName eq "" || [llength $elems] == 0} {
        return 0
    }
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elems}]} {
        return 0
    }
    set ok 0
    foreach cmd [list \
        [list *removeelemsfromcontactsurf $surfName 1] \
        [list *contactsurfremoveelems $surfName 1]] {
        if {![catch {uplevel #0 $cmd}]} {
            set ok 1
            break
        }
    }
    catch {*clearmark elems 1}
    return $ok
}

proc ::ContactSetup::removeElemsFromSurfaceWithUndo {surfName elems historyName} {
    if {$surfName eq "" || [llength $elems] == 0} {
        return 0
    }
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} {
        set historyStarted 1
    }
    set code [catch {::ContactSetup::removeElemsFromSurface $surfName $elems} ok]
    if {$historyStarted} {
        catch {*endnotehistorystate $historyName}
    }
    if {$code || !$ok} {
        if {$historyStarted} {
            catch {*undohistorystate 1}
        }
        return 0
    }
    return 1
}

proc ::ContactSetup::trimContact {} {
    variable last
    if {![info exists last(surfAId)] || ![info exists last(surfBId)]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "Contact Setup" "Contact Setup"] \
            -message [::HWFlow::txt "请先创建一次接触，再进入修改模式。" "Create contact first, then trim it."]
        return
    }
    if {![info exists last(restoreDisplay)] || $last(restoreDisplay) eq ""} {
        set last(restoreDisplay) [::ContactSetup::displayedComponents]
    }
    ::ContactSetup::showOnlyLast
    ::ContactSetup::msg [::HWFlow::txt \
        "连续修改模式：选择要从 contact surface 中移除的单元，中键确认；取消选择/ESC 退出。" \
        "Continuous trim mode: select elements to remove, middle-click to accept; cancel/ESC exits."]

    set totalA 0
    set totalB 0
    while {1} {
        catch {*clearmark elems 1}
        ::HWFlow::nativeMarkPanel elems 1 [::HWFlow::txt \
            "选择要从 contact surface 中移除的单元；取消选择退出连续修改" \
            "Select elements to remove from contact surfaces; cancel to exit continuous trim"]
        set selected {}
        catch {set selected [hm_getmark elems 1]}
        if {[llength $selected] == 0} {
            break
        }

        array unset picked
        array set picked {}
        foreach eid $selected {
            set picked($eid) 1
        }
        set removeA {}
        foreach eid $last(elemsA) {
            if {[info exists picked($eid)]} {
                lappend removeA $eid
            }
        }
        set removeB {}
        foreach eid $last(elemsB) {
            if {[info exists picked($eid)]} {
                lappend removeB $eid
            }
        }
        if {[llength $removeA] == 0 && [llength $removeB] == 0} {
            ::ContactSetup::msg [::HWFlow::txt \
                "所选单元不属于当前 contact surface，请重新选择；取消选择退出。" \
                "Selected elements are not in the current contact surfaces. Select again, or cancel to exit."]
            continue
        }

        set okA [::ContactSetup::removeElemsFromSurfaceWithUndo $last(surfA) $removeA "Trim Contact Surface A"]
        set okB [::ContactSetup::removeElemsFromSurfaceWithUndo $last(surfB) $removeB "Trim Contact Surface B"]
        if {!$okA && !$okB} {
            ::ContactSetup::msg [::HWFlow::txt \
                "本次删除失败并已尝试撤销，请重新选择；取消选择退出。" \
                "This trim failed and was rolled back where possible. Select again, or cancel to exit."]
            continue
        }
        if {$okA} {
            set last(elemsA) [::ContactSetup::listMinus $last(elemsA) $removeA]
            incr totalA [llength $removeA]
        }
        if {$okB} {
            set last(elemsB) [::ContactSetup::listMinus $last(elemsB) $removeB]
            incr totalB [llength $removeB]
        }
        catch {hm_redraw}
        ::ContactSetup::msg [::HWFlow::txt \
            "本次移除 A=[expr {$okA ? [llength $removeA] : 0}]，B=[expr {$okB ? [llength $removeB] : 0}]；可继续选择，取消选择退出。" \
            "Removed A=[expr {$okA ? [llength $removeA] : 0}], B=[expr {$okB ? [llength $removeB] : 0}]. Continue selecting, or cancel to exit."]
    }

    catch {::HWFlow::refreshBrowser}
    ::ContactSetup::msg [::HWFlow::txt \
        "连续修改已退出：累计移除 A=$totalA，B=$totalB。可点击“恢复视图”。" \
        "Continuous trim exited: total removed A=$totalA, B=$totalB. Click Restore View when finished."]
}

proc ::ContactSetup::listMinus {items removed} {
    array set skip {}
    foreach item $removed {
        set skip($item) 1
    }
    set out {}
    foreach item $items {
        if {![info exists skip($item)]} {
            lappend out $item
        }
    }
    return $out
}

proc ::ContactSetup::run {} {
    ::ContactSetup::showPanel
}

proc ::ContactSetup::runAction {} {
    variable cfg
    variable ui

    ::ContactSetup::loadRules
    foreach key [::ContactSetup::stateKeys] {
        set ui($key) $cfg($key)
    }
    set ui(selectedElemsA) ""
    set ui(selectedElemsB) ""
    set ui(selectedText) [::HWFlow::txt "未选择接触面" "No contact faces selected"]
    set ui(status) ""

    ::ContactSetup::pickContactFaces 1
}

proc ::ContactSetup::runSettings {} {
    ::ContactSetup::showPanel 1
}
