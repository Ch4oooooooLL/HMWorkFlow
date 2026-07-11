# ============================================================================
# Contact Setup
# HyperMesh 2019 Tcl/Tk
#
# Lightweight workflow:
#   1) pick two components
#   2) detect the facing side of each component
#   3) create a contact group that references the two surfaces
#   4) optional trim mode removes picked elements from the surfaces
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::ContactSetup {
    variable VERSION "0.2"
    variable RULE_FILE [file join [::HWFlow::configDir] "contact_rules.txt"]

    variable cfg
    array set cfg {
        contact_type         SLIDE
        main_side            AUTO
        friction             0.20
        result_prefix        AUTO_CONTACT
        keep_face_components 1
        try_group            1
    }

    variable ui
    array set ui {
        selectedComps ""
        selectedText  "No components selected"
        status        ""
    }

    variable last
    array set last {}
}

proc ::ContactSetup::defaultRuleText {} {
    return [join {
        {# Lightweight contact setup defaults.}
        {key|value|note}
        {contact_type|SLIDE|SLIDE, TIE, STICK, FREEZE, FRICTIONLESS or FRICTION}
        {main_side|AUTO|AUTO, FIRST or SECOND}
        {friction|0.20|stored parameter for frictional contacts}
        {result_prefix|AUTO_CONTACT|name prefix for generated contact surfaces/groups}
        {keep_face_components|1|keep generated face components for solid components}
        {try_group|1|create solver contact group after contact surfaces}
    } "\n"]
}

proc ::ContactSetup::stateKeys {} {
    return {contact_type main_side friction result_prefix keep_face_components try_group}
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
    set ui(selectedComps) ""
    set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]
    set ui(status) [::HWFlow::txt "选择两个 component 后直接创建接触面和接触 group。" "Select two components to create contact surfaces and a contact group."]

    catch {destroy .contact_setup}
    set w .contact_setup
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "Contact Setup" "Contact Setup"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Contact Setup" "Contact Setup"] -font [::HWFlow::uiFont title]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text [::HWFlow::txt "1. 组件选择" "1. Component Selection"] -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.sel.pick -text [::HWFlow::txt "选择两个组件" "Pick Two Components"] -width 18 -command "::ContactSetup::pickComponents"
    label $w.main.sel.info -textvariable ::ContactSetup::ui(selectedText) -width 78 -anchor w
    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.type -text [::HWFlow::txt "2. 接触定义" "2. Contact Definition"] -padx 8 -pady 8
    grid $w.main.type -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.type.l_type -text [::HWFlow::txt "接触类型" "Contact type"] -anchor w
    tk_optionMenu $w.main.type.m_type ::ContactSetup::ui(contact_type) SLIDE TIE STICK FREEZE FRICTIONLESS FRICTION
    label $w.main.type.l_side -text [::HWFlow::txt "主面" "Main side"] -anchor w
    tk_optionMenu $w.main.type.m_side ::ContactSetup::ui(main_side) AUTO FIRST SECOND
    label $w.main.type.l_fric -text [::HWFlow::txt "摩擦系数" "Friction"] -anchor w
    entry $w.main.type.e_fric -textvariable ::ContactSetup::ui(friction) -width 10
    grid $w.main.type.l_type -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.type.m_type -row 0 -column 1 -sticky w -padx {0 16} -pady 2
    grid $w.main.type.l_side -row 0 -column 2 -sticky w -padx {0 6} -pady 2
    grid $w.main.type.m_side -row 0 -column 3 -sticky w -pady 2
    grid $w.main.type.l_fric -row 1 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.type.e_fric -row 1 -column 1 -sticky w -pady 2

    labelframe $w.main.opt -text [::HWFlow::txt "3. 输出" "3. Output"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.opt.l_prefix -text [::HWFlow::txt "结果名前缀" "Result prefix"] -anchor w
    entry $w.main.opt.e_prefix -textvariable ::ContactSetup::ui(result_prefix) -width 22
    checkbutton $w.main.opt.group -text [::HWFlow::txt "创建接触 group" "Create contact group"] -variable ::ContactSetup::ui(try_group)
    checkbutton $w.main.opt.keep -text [::HWFlow::txt "保留实体自由面临时组件" "Keep solid free-face components"] -variable ::ContactSetup::ui(keep_face_components)
    grid $w.main.opt.l_prefix -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.opt.e_prefix -row 0 -column 1 -sticky w -pady 2
    grid $w.main.opt.group -row 1 -column 0 -columnspan 2 -sticky w -pady 2
    grid $w.main.opt.keep -row 2 -column 0 -columnspan 2 -sticky w -pady 2

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

proc ::ContactSetup::pickComponents {} {
    variable ui

    catch {*clearmark comps 1}
    *createmarkpanel comps 1 [::HWFlow::txt "请选择两个需要创建接触的 component" "Select two components for contact creation"]
    set comps [hm_getmark comps 1]
    if {[llength $comps] != 2} {
        set ui(selectedComps) ""
        set ui(selectedText) [::HWFlow::txt "需要且仅需要选择 2 个组件。" "Exactly 2 components are required."]
        return
    }
    set ui(selectedComps) $comps
    set names {}
    foreach cid $comps {
        lappend names [::HWFlow::componentName $cid]
    }
    set ui(selectedText) [::HWFlow::txt "已选择：[join $names {  <->  }]" "Selected: [join $names {  <->  }]"]
    catch {raise .contact_setup}
    catch {focus .contact_setup}
}

proc ::ContactSetup::validatePanel {} {
    variable ui
    if {[llength $ui(selectedComps)] != 2} {
        error [::HWFlow::txt "请先选择两个 component。" "Select two components first."]
    }
    if {$ui(contact_type) ni {SLIDE TIE STICK FREEZE FRICTIONLESS FRICTION}} {
        error [::HWFlow::txt "接触类型无效。" "Invalid contact type."]
    }
    if {$ui(main_side) ni {AUTO FIRST SECOND}} {
        error [::HWFlow::txt "主面选项无效。" "Invalid main side."]
    }
    if {![string is double -strict $ui(friction)] || $ui(friction) < 0.0} {
        error [::HWFlow::txt "摩擦系数必须是不小于 0 的数值。" "Friction must be a non-negative number."]
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

proc ::ContactSetup::vnormalize {a} {
    set n [::ContactSetup::vnorm $a]
    if {$n <= 1.0e-12} {
        return {0.0 0.0 0.0}
    }
    return [list [expr {[lindex $a 0]/$n}] [expr {[lindex $a 1]/$n}] [expr {[lindex $a 2]/$n}]]
}

proc ::ContactSetup::nodeXYZ {nodeId} {
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

proc ::ContactSetup::buildRecordGrid {records cell} {
    array set grid {}
    set idx 0
    foreach rec $records {
        set key [::ContactSetup::gridKey [dict get $rec center] $cell]
        lappend grid($key) $idx
        incr idx
    }
    return [array get grid]
}

proc ::ContactSetup::nearestRecord {rec otherRecords gridList cell} {
    array set grid $gridList
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

proc ::ContactSetup::selectNearestContactFaces {elemsA elemsB} {
    set bboxA [::ContactSetup::bboxForElems $elemsA]
    set bboxB [::ContactSetup::bboxForElems $elemsB]
    set dataA [::ContactSetup::faceRecords $elemsA]
    set dataB [::ContactSetup::faceRecords $elemsB]
    set recsA [lindex $dataA 0]
    set recsB [lindex $dataB 0]
    set medA [lindex $dataA 1]
    set medB [lindex $dataB 1]
    if {[llength $recsA] == 0 || [llength $recsB] == 0} {
        return [dict create elemsA {} elemsB {} pairMapA {} pairMapB {} searchTol 0]
    }

    set elemScale [expr {max($medA, $medB, 1.0e-6)}]
    set gap [::ContactSetup::bboxGap $bboxA $bboxB]
    set searchTol [expr {max($gap + 2.5*$elemScale, 2.5*$elemScale)}]
    set cell $searchTol
    set maxD2 [expr {$searchTol * $searchTol}]

    set gridA [::ContactSetup::buildRecordGrid $recsA $cell]
    set gridB [::ContactSetup::buildRecordGrid $recsB $cell]
    array set keepA {}
    array set keepB {}
    array set pairA {}
    array set pairB {}

    for {set i 0} {$i < [llength $recsA]} {incr i} {
        set near [::ContactSetup::nearestRecord [lindex $recsA $i] $recsB $gridB $cell]
        if {[llength $near] == 0 || [lindex $near 1] > $maxD2} {
            continue
        }
        set j [lindex $near 0]
        set eidA [dict get [lindex $recsA $i] elem]
        set eidB [dict get [lindex $recsB $j] elem]
        set keepA($eidA) 1
        set keepB($eidB) 1
        set pairA($eidA) $eidB
    }

    for {set j 0} {$j < [llength $recsB]} {incr j} {
        set near [::ContactSetup::nearestRecord [lindex $recsB $j] $recsA $gridA $cell]
        if {[llength $near] == 0 || [lindex $near 1] > $maxD2} {
            continue
        }
        set i [lindex $near 0]
        set eidA [dict get [lindex $recsA $i] elem]
        set eidB [dict get [lindex $recsB $j] elem]
        set keepA($eidA) 1
        set keepB($eidB) 1
        set pairB($eidB) $eidA
    }

    return [dict create \
        elemsA [lsort -integer [array names keepA]] \
        elemsB [lsort -integer [array names keepB]] \
        pairMapA [array get pairA] \
        pairMapB [array get pairB] \
        recordsA $recsA \
        recordsB $recsB \
        searchTol $searchTol]
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
    catch {*clearmark elems 1}
    if {[catch {eval *createmark elems 1 $elems} err]} {
        error [::HWFlow::txt "接触面 $name 打 mark 失败：$err" "Failed to mark contact elements for $name: $err"]
    }
    if {[catch {*contactsurfcreatewithshells $name $color 1 0} err]} {
        catch {*clearmark elems 1}
        error [::HWFlow::txt "创建 contact surface $name 失败：$err" "Failed to create contact surface $name: $err"]
    }
    catch {*clearmark elems 1}
    if {![::ContactSetup::adjustContactSurfNormal $name $elems $orientationElem $orientationReverse]} {
        ::ContactSetup::msg [::HWFlow::txt \
            "contact surface $name 已创建，但法向自动校正未执行成功，请在 HyperMesh 中检查箭头方向。" \
            "Contact surface $name was created, but automatic normal adjustment did not run successfully. Check the arrow direction in HyperMesh."]
    }
    set id [::ContactSetup::contactSurfIdByName $name]
    if {$id eq ""} {
        error [::HWFlow::txt "contact surface $name 已创建但无法读取 ID。" "Contact surface $name was created, but its ID could not be read."]
    }
    return $id
}

proc ::ContactSetup::baseName {compA compB} {
    variable ui
    set nA [::ContactSetup::safeName [::HWFlow::componentName $compA]]
    set nB [::ContactSetup::safeName [::HWFlow::componentName $compB]]
    set base "[::ContactSetup::safeName $ui(result_prefix)]_${ui(contact_type)}_${nA}_TO_${nB}"
    if {[string length $base] > 90} {
        set base "[::ContactSetup::safeName $ui(result_prefix)]_${ui(contact_type)}_[::HWFlow::stableHash ${nA}_${nB}]"
    }
    return $base
}

proc ::ContactSetup::trySetGroupValue {groupName mainSurfId secSurfId} {
    set attempts [list \
        [list *setvalue groups name=$groupName "masterentityids={contactsurfs $mainSurfId}" "slaveentityids={contactsurfs $secSurfId}"] \
        [list *setvalue groups name=$groupName masterentityid=$mainSurfId slaveentityid=$secSurfId] \
        [list *setvalue groups name=$groupName main=$mainSurfId secondary=$secSurfId] \
        [list *setvalue groups name=$groupName master=$mainSurfId slave=$secSurfId]]
    foreach cmd $attempts {
        if {![catch {uplevel #0 $cmd}]} {
            return 1
        }
    }
    return 0
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

    set created 0
    foreach cmd [list \
        [list *createentity groups name=$groupName cardimage=$ui(contact_type)] \
        [list *createentity groups name=$groupName]] {
        if {![catch {uplevel #0 $cmd} err]} {
            set created 1
            break
        }
    }
    if {!$created} {
        ::ContactSetup::msg [::HWFlow::txt "contact surface 已创建，但 group 创建失败：$err" "Contact surfaces were created, but group creation failed: $err"]
        return ""
    }

    set groupId [::HWFlow::entityIdByName {groups group} $groupName]
    if {![::ContactSetup::trySetGroupValue $groupName $mainSurfId $secSurfId]} {
        ::ContactSetup::msg [::HWFlow::txt \
            "group $groupName 已创建，但当前求解器模板未接受主/从 contact surface 自动赋值，请在面板中确认。" \
            "Group $groupName was created, but the current solver template did not accept automatic main/secondary contact surface assignment. Please confirm it in the panel."]
    }
    catch {*setvalue groups name=$groupName STATUS=2 friction=$ui(friction)}
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

proc ::ContactSetup::createContact {} {
    variable ui
    variable last

    set code [catch {
        ::ContactSetup::validatePanel
        ::ContactSetup::saveRules

        array unset last
        array set last {}

        set compA [lindex $ui(selectedComps) 0]
        set compB [lindex $ui(selectedComps) 1]
        set prepA [::ContactSetup::contactElemsForComponent $compA A]
        set prepB [::ContactSetup::contactElemsForComponent $compB B]
        set allElemsA [dict get $prepA elems]
        set allElemsB [dict get $prepB elems]
        if {[llength $allElemsA] == 0 || [llength $allElemsB] == 0} {
            error [::HWFlow::txt "至少一个 component 没有可用于 contact surface 的壳面/自由面单元。" "At least one component has no shell/free-face elements for contact surface creation."]
        }

        set contactFaces [::ContactSetup::selectNearestContactFaces $allElemsA $allElemsB]
        set elemsA [dict get $contactFaces elemsA]
        set elemsB [dict get $contactFaces elemsB]
        if {[llength $elemsA] == 0 || [llength $elemsB] == 0} {
            error [::HWFlow::txt "未能识别两个 component 之间相对的接触面。" "Could not identify facing contact faces between the two components."]
        }

        set mainSide [::ContactSetup::chooseMainSide $compA $compB $elemsA $elemsB]
        set base [::ContactSetup::baseName $compA $compB]
        set surfA "${base}_A"
        set surfB "${base}_B"
        set groupName "${base}_GROUP"

        set recMapA [::ContactSetup::recordMapByElem [dict get $contactFaces recordsA]]
        set recMapB [::ContactSetup::recordMapByElem [dict get $contactFaces recordsB]]
        set centerVector [::ContactSetup::vsub \
            [dict get [::ContactSetup::bboxForElems $allElemsB] center] \
            [dict get [::ContactSetup::bboxForElems $allElemsA] center]]
        set orientA [::ContactSetup::orientationByOppositeGeometry \
            $elemsA $recMapA [dict get $contactFaces pairMapA] $recMapB $centerVector]
        set orientB [::ContactSetup::orientationByOppositeGeometry \
            $elemsB $recMapB [dict get $contactFaces pairMapB] $recMapA [::ContactSetup::vsub {0 0 0} $centerVector]]
        set orientElemA [lindex $orientA 0]
        set reverseA [lindex $orientA 1]
        set orientElemB [lindex $orientB 0]
        set reverseB [lindex $orientB 1]
        set surfAId [::ContactSetup::createContactSurf $surfA $elemsA 13 $orientElemA $reverseA]
        set surfBId [::ContactSetup::createContactSurf $surfB $elemsB 45 $orientElemB $reverseB]
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
        set groupId [::ContactSetup::createGroup $groupName $mainSurfId $secSurfId]

        set last(compA) $compA
        set last(compB) $compB
        set last(elemsA) $elemsA
        set last(elemsB) $elemsB
        set last(allElemsA) $allElemsA
        set last(allElemsB) $allElemsB
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
        set last(tempA) [dict get $prepA tempComp]
        set last(tempB) [dict get $prepB tempComp]
        set last(restoreDisplay) ""

        if {!$ui(keep_face_components)} {
            foreach tmp [list $last(tempA) $last(tempB)] {
                if {$tmp ne ""} {
                    catch {::HWFlow::displayComponent $tmp off}
                }
            }
        }
        catch {::HWFlow::refreshBrowser}
        ::ContactSetup::msg [::HWFlow::txt \
            "接触创建完成：相对面 A=[llength $elemsA]/[llength $allElemsA]，B=[llength $elemsB]/[llength $allElemsB]，搜索距离=[format %.6g [dict get $contactFaces searchTol]]，参考单元=($orientElemA,$orientElemB)，reverse=($reverseA,$reverseB)，group=$groupName。" \
            "Contact created: facing faces A=[llength $elemsA]/[llength $allElemsA], B=[llength $elemsB]/[llength $allElemsB], search=[format %.6g [dict get $contactFaces searchTol]], orientation elems=($orientElemA,$orientElemB), reverse=($reverseA,$reverseB), group=$groupName."]
    } err]
    if {$code} {
        tk_messageBox -icon error -title [::HWFlow::txt "Contact Setup" "Contact Setup"] -message $err
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
        *createmarkpanel elems 1 [::HWFlow::txt \
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
    set ui(selectedComps) ""
    set ui(selectedText) [::HWFlow::txt "未选择组件" "No components selected"]
    set ui(status) ""

    ::ContactSetup::pickComponents
    if {[llength $ui(selectedComps)] != 2} {
        return
    }
    ::ContactSetup::createContact
}

proc ::ContactSetup::runSettings {} {
    ::ContactSetup::showPanel 1
}
