# ============================================================================
# Seam Surface Creation v1.0
# HyperMesh 2019 Tcl/Tk
#
# Continuous line-surface / line-line seam creation.
# The two seam boundaries are synchronized by explicit geometric feature pairs.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::SeamSurf {
    variable VERSION "1.0"
    variable RULE_FILE [file join [::HWFlow::configDir] "seam_rules.txt"]

    variable cfg
    array set cfg {
        stitch_tolerance     0.2
        default_mode         LINE_SURFACE
        component_mode       by_thickness
        line_sync_divisions  24
        feature_angle        12.0
        thickness_format     "%.3g"
    }

    variable ui
    array set ui {
        ok              0
        stop            0
        mode            LINE_SURFACE
        status          ""
        promptOk        0
        promptValue     ""
    }

    variable stat
    array set stat {}
}

proc ::SeamSurf::normalizeMode {mode} {
    if {$mode eq "LINE_LINE"} {
        return LINE_LINE
    }
    return LINE_SURFACE
}

proc ::SeamSurf::defaultRuleText {} {
    return [join {
        {# Seam surface workflow defaults.}
        {key|value|note}
        {stitch_tolerance|0.2|surface equivalence tolerance}
        {default_mode|LINE_SURFACE|LINE_SURFACE or LINE_LINE}
        {component_mode|by_thickness|by_thickness or per_seam}
        {line_sync_divisions|24|base sampling divisions for feature detection and projection}
        {feature_angle|12.0|minimum direction change in degrees treated as a feature point}
        {thickness_format|%.3g|T value format used in SEAM_Tx component names}
    } "\n"]
}

proc ::SeamSurf::ensureRuleFile {} {
    variable RULE_FILE
    if {![file exists $RULE_FILE]} {
        ::HWFlow::writeTextFile $RULE_FILE [::SeamSurf::defaultRuleText]
    }
}

proc ::SeamSurf::loadRules {} {
    variable RULE_FILE
    variable cfg

    ::SeamSurf::ensureRuleFile
    foreach raw [split [::HWFlow::readTextFile $RULE_FILE] "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} {
            continue
        }
        set cols [split $line "|"]
        set key [string trim [lindex $cols 0]]
        if {$key eq "key" || ![info exists cfg($key)]} {
            continue
        }
        set value [string trim [lindex $cols 1]]
        if {$key eq "default_mode"} {
            set value [::SeamSurf::normalizeMode $value]
        }
        set cfg($key) $value
    }
}

proc ::SeamSurf::saveRules {} {
    variable RULE_FILE
    variable cfg
    variable ui

    foreach key [array names cfg] {
        if {[info exists ui($key)]} {
            set cfg($key) $ui($key)
        }
    }
    set cfg(default_mode) [::SeamSurf::normalizeMode $ui(mode)]
    set rows [list \
        "# Seam surface workflow defaults." \
        "key|value|note" \
        "stitch_tolerance|$cfg(stitch_tolerance)|surface equivalence tolerance" \
        "default_mode|$cfg(default_mode)|LINE_SURFACE or LINE_LINE" \
        "component_mode|$cfg(component_mode)|by_thickness or per_seam" \
        "line_sync_divisions|$cfg(line_sync_divisions)|base sampling divisions for feature detection and projection" \
        "feature_angle|$cfg(feature_angle)|minimum direction change in degrees treated as a feature point" \
        "thickness_format|$cfg(thickness_format)|T value format used in SEAM_Tx component names"]
    ::HWFlow::writeTextFile $RULE_FILE [join $rows "\n"]
}

proc ::SeamSurf::savePanelState {} {
    variable ui
    if {[winfo exists .seam_surface]} {
        catch {::SeamSurf::saveRules}
    }
}

proc ::SeamSurf::centerWindow {w} {
    update idletasks
    set x [expr {([winfo screenwidth $w] - [winfo reqwidth $w]) / 2}]
    set y [expr {([winfo screenheight $w] - [winfo reqheight $w]) / 2}]
    wm geometry $w +$x+$y
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
    foreach key [array names cfg] {
        set ui($key) $cfg($key)
    }
    set ui(mode) [::SeamSurf::normalizeMode $cfg(default_mode)]
    set ui(ok) 0
    set ui(stop) 0
    set ui(status) [::HWFlow::txt \
        "开始后连续创建焊缝；在任一选择面板按 ESC 退出。" \
        "After starting, seams are created continuously; press ESC in any selection panel to exit."]

    catch {destroy .seam_surface}
    set w .seam_surface
    ::HWFlow::createTopLevel $w
    wm title $w "[::HWFlow::txt "焊缝面创建" "Seam Surface Creation"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "焊缝面创建" "Seam Surface Creation"] -font [::HWFlow::uiFont title]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.mode -text [::HWFlow::txt "1. 创建方式" "1. Creation Mode"] -padx 8 -pady 8
    grid $w.main.mode -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    radiobutton $w.main.mode.ls \
        -text [::HWFlow::txt "线-面：选择一条线，再选择投影目标面" "Line-Surface: select one line, then its projection surface"] \
        -variable ::SeamSurf::ui(mode) -value LINE_SURFACE
    radiobutton $w.main.mode.ll \
        -text [::HWFlow::txt "线-线：依次选择两条焊缝边界线" "Line-Line: select the two seam boundary lines in order"] \
        -variable ::SeamSurf::ui(mode) -value LINE_LINE
    grid $w.main.mode.ls -row 0 -column 0 -sticky w -pady 2
    grid $w.main.mode.ll -row 1 -column 0 -sticky w -pady 2

    labelframe $w.main.param -text [::HWFlow::txt "2. 几何参数" "2. Geometry Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    set fields {
        {stitch_tolerance "Equivalence 容差" "Equivalence tolerance"}
        {line_sync_divisions "基础采样分段数" "Base sampling divisions"}
        {feature_angle "特征转角（度）" "Feature angle (degrees)"}
        {thickness_format "厚度格式" "Thickness format"}
    }
    set row 0
    foreach field $fields {
        set key [lindex $field 0]
        label $w.main.param.l_$key -text [::HWFlow::txt [lindex $field 1] [lindex $field 2]] -anchor w
        entry $w.main.param.e_$key -textvariable ::SeamSurf::ui($key) -width 16
        grid $w.main.param.l_$key -row $row -column 0 -sticky w -padx {0 8} -pady 2
        grid $w.main.param.e_$key -row $row -column 1 -sticky w -padx {0 20} -pady 2
        incr row
    }

    label $w.main.param.l_component -text [::HWFlow::txt "组件模式" "Component mode"] -anchor w
    tk_optionMenu $w.main.param.m_component ::SeamSurf::ui(component_mode) by_thickness per_seam
    grid $w.main.param.l_component -row 0 -column 2 -sticky w -padx {0 8} -pady 2
    grid $w.main.param.m_component -row 0 -column 3 -sticky w -pady 2

    message $w.main.note -width 620 -text [::HWFlow::txt \
        "每次创建都会先在对应特征点切分两侧完整曲线，再对每对曲线段逐段 ruled。完成后强制验证焊缝面与两侧接触面的 equivalence；失败时撤销本次创建。" \
        "Each complete boundary curve is split at corresponding feature points, then every curve-segment pair is ruled. Equivalence to both contacting sides is verified; failure rolls back the operation."]
    grid $w.main.note -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    label $w.main.status -textvariable ::SeamSurf::ui(status) -width 82 -anchor w
    grid $w.main.status -row 4 -column 0 -columnspan 4 -sticky ew

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 \
        -command "::SeamSurf::savePanelState; set ::SeamSurf::ui(ok) 0; ::SeamSurf::backToHome .seam_surface"
    button $w.btn.save -text [::HWFlow::txt "保存参数" "Save Parameters"] -width 12 \
        -command "::SeamSurf::saveRules"
    button $w.btn.start -text [::HWFlow::txt "进入连续创建" "Start Continuous Creation"] -width 16 \
        -command "::SeamSurf::acceptPanel"
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

    foreach key {stitch_tolerance feature_angle} {
        if {![string is double -strict $ui($key)] || $ui($key) <= 0.0} {
            tk_messageBox -icon warning -title [::HWFlow::txt "焊缝面创建" "Seam Surface Creation"] \
                -message [::HWFlow::txt "$key 必须为大于 0 的数值。" "$key must be greater than zero."]
            return
        }
    }
    if {![string is integer -strict $ui(line_sync_divisions)] || $ui(line_sync_divisions) < 4} {
        tk_messageBox -icon warning -title [::HWFlow::txt "焊缝面创建" "Seam Surface Creation"] \
            -message [::HWFlow::txt "line_sync_divisions 必须为不小于 4 的整数。" "line_sync_divisions must be an integer of at least 4."]
        return
    }
    if {$ui(component_mode) ni {by_thickness per_seam}} {
        tk_messageBox -icon warning -title [::HWFlow::txt "焊缝面创建" "Seam Surface Creation"] \
            -message [::HWFlow::txt "component_mode 必须为 by_thickness 或 per_seam。" "component_mode must be by_thickness or per_seam."]
        return
    }
    if {[string trim $ui(thickness_format)] eq ""} {
        tk_messageBox -icon warning -title [::HWFlow::txt "焊缝面创建" "Seam Surface Creation"] \
            -message [::HWFlow::txt "thickness_format 不能为空。" "thickness_format cannot be empty."]
        return
    }

    set ui(mode) [::SeamSurf::normalizeMode $ui(mode)]
    foreach key [array names cfg] {
        if {[info exists ui($key)]} {
            set cfg($key) $ui($key)
        }
    }
    set cfg(default_mode) $ui(mode)
    ::SeamSurf::saveRules
    set ui(ok) 1
    destroy .seam_surface
}

proc ::SeamSurf::msg {text} {
    catch {hm_usermessage $text}
    catch {puts $text}
}

proc ::SeamSurf::unique {values} {
    set out {}
    array set seen {}
    foreach value $values {
        if {$value eq "" || [info exists seen($value)]} {
            continue
        }
        set seen($value) 1
        lappend out $value
    }
    return $out
}

proc ::SeamSurf::selectOne {entityType prompt} {
    variable ui

    catch {*clearmark $entityType 1}
    *createmarkpanel $entityType 1 $prompt
    set ids {}
    catch {set ids [hm_getmark $entityType 1]}
    catch {*clearmark $entityType 1}
    if {[llength $ids] == 0} {
        set ui(stop) 1
        return ""
    }
    if {[llength $ids] != 1} {
        error [::HWFlow::txt \
            "需要且仅需要选择一个实体，当前选择数量：[llength $ids]。" \
            "Exactly one entity is required. Selected: [llength $ids]."]
    }
    return [lindex $ids 0]
}

proc ::SeamSurf::selectLine {prompt} {
    return [::SeamSurf::selectOne lines $prompt]
}

proc ::SeamSurf::selectSurface {prompt} {
    return [::SeamSurf::selectOne surfs $prompt]
}

proc ::SeamSurf::allEntityIds {entityType {markId 2}} {
    catch {*clearmark $entityType $markId}
    set ids {}
    if {![catch {*createmark $entityType $markId all}]} {
        catch {set ids [hm_getmark $entityType $markId]}
    }
    catch {*clearmark $entityType $markId}
    return $ids
}

proc ::SeamSurf::latestEntityId {entityTypes} {
    foreach entityType $entityTypes {
        if {![catch {set id [hm_latestentityid $entityType]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return 0
}

proc ::SeamSurf::newIds {before after} {
    array set old {}
    foreach id $before {
        set old($id) 1
    }
    set out {}
    foreach id $after {
        if {![info exists old($id)]} {
            lappend out $id
        }
    }
    return [lsort -integer -unique $out]
}

proc ::SeamSurf::distance {a b} {
    set dx [expr {[lindex $a 0] - [lindex $b 0]}]
    set dy [expr {[lindex $a 1] - [lindex $b 1]}]
    set dz [expr {[lindex $a 2] - [lindex $b 2]}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}

proc ::SeamSurf::linePoint {lineId t} {
    if {$t < 0.0} {
        set t 0.0
    } elseif {$t > 1.0} {
        set t 1.0
    }
    if {![catch {set points [hm_getcoordinatesofpointsonline $lineId [list $t]]}]} {
        set point [lindex $points 0]
        if {[llength $point] >= 3} {
            return [lrange $point 0 2]
        }
    }
    error [::HWFlow::txt "无法读取线 $lineId 在参数 $t 处的坐标。" "Cannot read line $lineId at parameter $t."]
}

proc ::SeamSurf::lineSamples {lineId divisions} {
    set samples {}
    for {set i 0} {$i <= $divisions} {incr i} {
        set t [expr {$i / double($divisions)}]
        lappend samples [list $t [::SeamSurf::linePoint $lineId $t]]
    }
    return $samples
}

proc ::SeamSurf::vectorBetween {a b} {
    return [list \
        [expr {[lindex $b 0] - [lindex $a 0]}] \
        [expr {[lindex $b 1] - [lindex $a 1]}] \
        [expr {[lindex $b 2] - [lindex $a 2]}]]
}

proc ::SeamSurf::vectorAngle {u v} {
    set ux [lindex $u 0]
    set uy [lindex $u 1]
    set uz [lindex $u 2]
    set vx [lindex $v 0]
    set vy [lindex $v 1]
    set vz [lindex $v 2]
    set un [expr {sqrt($ux*$ux + $uy*$uy + $uz*$uz)}]
    set vn [expr {sqrt($vx*$vx + $vy*$vy + $vz*$vz)}]
    if {$un <= 1.0e-12 || $vn <= 1.0e-12} {
        return 0.0
    }
    set cosine [expr {($ux*$vx + $uy*$vy + $uz*$vz) / ($un*$vn)}]
    if {$cosine > 1.0} {
        set cosine 1.0
    } elseif {$cosine < -1.0} {
        set cosine -1.0
    }
    return [expr {acos($cosine) * 180.0 / acos(-1.0)}]
}

proc ::SeamSurf::featureParametersFromSamples {samples} {
    variable cfg

    set count [llength $samples]
    if {$count < 2} {
        error [::HWFlow::txt "线采样点不足，无法识别几何特征。" "Insufficient line samples for feature detection."]
    }
    set params [list [lindex [lindex $samples 0] 0]]
    set referenceDirection [::SeamSurf::vectorBetween \
        [lindex [lindex $samples 0] 1] \
        [lindex [lindex $samples 1] 1]]
    for {set i 1} {$i < $count - 1} {incr i} {
        set currentDirection [::SeamSurf::vectorBetween \
            [lindex [lindex $samples $i] 1] \
            [lindex [lindex $samples [expr {$i + 1}]] 1]]
        if {[::SeamSurf::vectorAngle $referenceDirection $currentDirection] >= $cfg(feature_angle)} {
            lappend params [lindex [lindex $samples $i] 0]
            set referenceDirection $currentDirection
        }
    }
    lappend params [lindex [lindex $samples end] 0]
    return [::SeamSurf::uniqueSortedParams $params]
}

proc ::SeamSurf::uniqueSortedParams {params} {
    set sorted [lsort -real $params]
    set out {}
    foreach value $sorted {
        if {[llength $out] == 0 || abs($value - [lindex $out end]) > 1.0e-7} {
            lappend out $value
        }
    }
    return $out
}

proc ::SeamSurf::nearestSurfacePoint {surfId point} {
    foreach {x y z} $point {}
    if {![catch {set result [hm_findclosestpointonsurface $x $y $z $surfId]}] && [llength $result] >= 4} {
        return [list [lrange $result 0 2] [lindex $result 3]]
    }
    if {![catch {set result [hm_getcoordinatesfromnearestsurface $x $y $z [list $surfId]]}] && [llength $result] >= 3} {
        set closest [lrange $result 0 2]
        return [list $closest [::SeamSurf::distance $point $closest]]
    }
    error [::HWFlow::txt "无法计算点到曲面 $surfId 的投影。" "Cannot project a point onto surface $surfId."]
}

proc ::SeamSurf::projectSamplesToSurface {samples surfId} {
    set projected {}
    set maxDistance 0.0
    foreach sample $samples {
        set source [lindex $sample 1]
        set result [::SeamSurf::nearestSurfacePoint $surfId $source]
        set target [lindex $result 0]
        set gap [lindex $result 1]
        if {$gap > $maxDistance} {
            set maxDistance $gap
        }
        lappend projected [list [lindex $sample 0] $source $target $gap]
    }
    return [list $projected $maxDistance]
}

proc ::SeamSurf::nearestLinePoint {lineId point} {
    foreach {x y z} $point {}
    if {![catch {set result [hm_findclosestpointonline $x $y $z $lineId 1]}] && [llength $result] >= 4} {
        return [list [lrange $result 0 2] [lindex $result 3] [::SeamSurf::distance $point [lrange $result 0 2]]]
    }
    error [::HWFlow::txt "无法计算点到线 $lineId 的最近点。" "Cannot find the closest point on line $lineId."]
}

proc ::SeamSurf::linePairOrientation {lineA lineB} {
    set a0 [::SeamSurf::linePoint $lineA 0.0]
    set a1 [::SeamSurf::linePoint $lineA 1.0]
    set b0 [::SeamSurf::linePoint $lineB 0.0]
    set b1 [::SeamSurf::linePoint $lineB 1.0]
    set same [expr {[::SeamSurf::distance $a0 $b0] + [::SeamSurf::distance $a1 $b1]}]
    set reverse [expr {[::SeamSurf::distance $a0 $b1] + [::SeamSurf::distance $a1 $b0]}]
    return [expr {$reverse < $same}]
}

proc ::SeamSurf::lineLineFeaturePairs {lineA lineB} {
    variable cfg

    set divisions $cfg(line_sync_divisions)
    set samplesA [::SeamSurf::lineSamples $lineA $divisions]
    set samplesB [::SeamSurf::lineSamples $lineB $divisions]
    set reverseB [::SeamSurf::linePairOrientation $lineA $lineB]
    set records {}
    set endB0 0.0
    set endB1 1.0
    if {$reverseB} {
        set endB0 1.0
        set endB1 0.0
    }
    lappend records [list 0.0 0.0 $endB0]
    lappend records [list 1.0 1.0 $endB1]

    # Map every feature on A to its closest point on B.
    foreach tA [::SeamSurf::featureParametersFromSamples $samplesA] {
        if {$tA <= 1.0e-7 || $tA >= 1.0 - 1.0e-7} {
            continue
        }
        set pointA [::SeamSurf::linePoint $lineA $tA]
        set nearest [::SeamSurf::nearestLinePoint $lineB $pointA]
        set rawB [lindex $nearest 1]
        set orientedB $rawB
        if {$reverseB} {
            set orientedB [expr {1.0 - $rawB}]
        }
        lappend records [list $tA $orientedB $rawB]
    }

    # Map every feature on B back to A so features that only exist on B are
    # also represented in the final one-to-one correspondence.
    foreach rawB [::SeamSurf::featureParametersFromSamples $samplesB] {
        if {$rawB <= 1.0e-7 || $rawB >= 1.0 - 1.0e-7} {
            continue
        }
        set pointB [::SeamSurf::linePoint $lineB $rawB]
        set nearest [::SeamSurf::nearestLinePoint $lineA $pointB]
        set tA [lindex $nearest 1]
        set orientedB $rawB
        if {$reverseB} {
            set orientedB [expr {1.0 - $rawB}]
        }
        lappend records [list $tA $orientedB $rawB]
    }

    # Ruled links must remain monotonic on both boundaries. Sort by A and
    # discard duplicate or crossing matches while retaining both end pairs.
    set records [lsort -real -index 0 $records]
    set monotonic {}
    set lastA -1.0
    set lastB -1.0
    foreach record $records {
        set tA [lindex $record 0]
        set orientedB [lindex $record 1]
        if {[llength $monotonic] > 0 &&
            ($tA <= $lastA + 1.0e-7 || $orientedB <= $lastB + 1.0e-7)} {
            continue
        }
        lappend monotonic $record
        set lastA $tA
        set lastB $orientedB
    }
    if {[llength $monotonic] < 2} {
        error [::HWFlow::txt \
            "两条线之间无法建立单调的特征点对应关系。" \
            "A monotonic feature correspondence could not be established between the two lines."]
    }

    set pairs {}
    set maxDistance 0.0
    foreach record $monotonic {
        set a [::SeamSurf::linePoint $lineA [lindex $record 0]]
        set b [::SeamSurf::linePoint $lineB [lindex $record 2]]
        set gap [::SeamSurf::distance $a $b]
        if {$gap > $maxDistance} {
            set maxDistance $gap
        }
        lappend pairs [list $a $b]
    }
    return [list $pairs $maxDistance $reverseB $monotonic]
}

proc ::SeamSurf::lineSurfaceFeaturePairs {sourceLine targetSurf} {
    variable cfg

    set samples [::SeamSurf::lineSamples $sourceLine $cfg(line_sync_divisions)]
    set projection [::SeamSurf::projectSamplesToSurface $samples $targetSurf]
    set projected [lindex $projection 0]
    set maxDistance [lindex $projection 1]

    set params [::SeamSurf::featureParametersFromSamples $samples]
    set targetSamples {}
    foreach item $projected {
        lappend targetSamples [list [lindex $item 0] [lindex $item 2]]
    }
    foreach t [::SeamSurf::featureParametersFromSamples $targetSamples] {
        lappend params $t
    }
    set params [::SeamSurf::uniqueSortedParams $params]

    set pairs {}
    foreach t $params {
        set source [::SeamSurf::linePoint $sourceLine $t]
        set target [lindex [::SeamSurf::nearestSurfacePoint $targetSurf $source] 0]
        lappend pairs [list $source $target]
    }
    return [list $pairs $projected $maxDistance $params]
}

proc ::SeamSurf::createTempNode {point} {
    set before [::SeamSurf::latestEntityId {nodes node}]
    foreach {x y z} $point {}
    *createnode $x $y $z 0 0 0
    set after [::SeamSurf::latestEntityId {nodes node}]
    if {$after eq "" || $after == 0 || $after == $before} {
        error [::HWFlow::txt "临时节点创建失败。" "Failed to create a temporary node."]
    }
    return $after
}

proc ::SeamSurf::deleteNodes {nodeIds} {
    set nodeIds [::SeamSurf::unique $nodeIds]
    if {[llength $nodeIds] == 0} {
        return
    }
    catch {*clearmark nodes 2}
    if {![catch {eval *createmark nodes 2 $nodeIds}]} {
        catch {*deletemark nodes 2}
    }
    catch {*clearmark nodes 2}
}

proc ::SeamSurf::createLineFromCoords {coords {surfaceId ""}} {
    set clean {}
    foreach point $coords {
        if {[llength $clean] == 0 || [::SeamSurf::distance [lindex $clean end] $point] > 1.0e-8} {
            lappend clean $point
        }
    }
    if {[llength $clean] < 2} {
        error [::HWFlow::txt "构造线至少需要两个不同坐标点。" "A construction line requires at least two distinct coordinates."]
    }

    set before [::SeamSurf::allEntityIds lines 2]
    set nodes {}
    foreach point $clean {
        lappend nodes [::SeamSurf::createTempNode $point]
    }
    set code [catch {
        eval *createlist nodes 1 $nodes
        if {$surfaceId eq ""} {
            *linecreatefromnodes 1 0 150 5 179
        } else {
            set created 0
            foreach option {1 0} {
                if {![catch {*linecreatefromnodesonsurface surfs $surfaceId nodes 1 0 $option}]} {
                    set created 1
                    break
                }
            }
            if {!$created} {
                error [::HWFlow::txt "无法在曲面 $surfaceId 上创建投影线。" "Cannot create a projected line on surface $surfaceId."]
            }
        }
    } err opts]
    ::SeamSurf::deleteNodes $nodes
    if {$code} {
        return -options $opts $err
    }

    set created [::SeamSurf::newIds $before [::SeamSurf::allEntityIds lines 2]]
    if {[llength $created] == 0} {
        error [::HWFlow::txt "HyperMesh 未返回新建构造线。" "HyperMesh did not return the new construction line."]
    }
    return [lindex $created end]
}

proc ::SeamSurf::projectedCoords {projectedSamples} {
    set coords {}
    foreach item $projectedSamples {
        lappend coords [lindex $item 2]
    }
    return $coords
}

proc ::SeamSurf::trimSurfaceWithProjectedLine {targetSurf projectedCoords} {
    set trimLine [::SeamSurf::createLineFromCoords $projectedCoords $targetSurf]
    set beforeSurfs [::SeamSurf::allEntityIds surfs 2]
    catch {*clearmark surfs 1}
    catch {*clearmark lines 2}
    *createmark surfs 1 $targetSurf
    *createmark lines 2 $trimLine
    *createvector 1 0.0 0.0 1.0
    set code [catch {
        # Bit0 sweeps through the whole surface and Bit2 projects normal.
        # Bit3 remains clear, so no temporary fixed points are left behind.
        *surfacemarksplitwithlines 1 2 1 5 0.0
    } err opts]
    catch {*clearmark surfs 1}
    catch {*clearmark lines 2}
    if {$code} {
        return -options $opts $err
    }
    set newSurfs [::SeamSurf::newIds $beforeSurfs [::SeamSurf::allEntityIds surfs 2]]
    return [list $trimLine [::SeamSurf::unique [concat [list $targetSurf] $newSurfs]]]
}

proc ::SeamSurf::createRuledSurfaceBetweenSegments {lineA lineB} {
    set before [::SeamSurf::allEntityIds surfs 2]
    set beforeLatest [::SeamSurf::latestEntityId {surfs surfaces}]
    catch {*surfacemode 4}
    catch {*createlist lines 1}
    *createlist lines 1 $lineA $lineB
    catch {*clearmark lines 2}
    set code [catch {
        *surfacecreateruled 1 1 0 2 1 0 0
    } err opts]
    catch {*clearmark lines 2}
    if {$code} {
        return -options $opts $err
    }
    set created [::SeamSurf::newIds $before [::SeamSurf::allEntityIds surfs 2]]
    if {[llength $created] == 0} {
        set afterLatest [::SeamSurf::latestEntityId {surfs surfaces}]
        if {$afterLatest ne "" && $afterLatest != 0 && $afterLatest != $beforeLatest} {
            set created [list $afterLatest]
        }
    }
    if {[llength $created] == 0} {
        error [::HWFlow::txt \
            "线段 $lineA 与 $lineB 之间的 ruled 未创建焊缝面。" \
            "Ruled did not create a seam between segments $lineA and $lineB."]
    }
    return [lindex $created end]
}

proc ::SeamSurf::lineEndCoords {lineId} {
    return [list [::SeamSurf::linePoint $lineId 0.0] [::SeamSurf::linePoint $lineId 1.0]]
}

proc ::SeamSurf::closestLineToPoint {lineIds point} {
    set bestLine ""
    set bestDistance ""
    foreach lineId $lineIds {
        if {[catch {set nearest [::SeamSurf::nearestLinePoint $lineId $point]}]} {
            continue
        }
        set distance [lindex $nearest 2]
        if {$bestLine eq "" || $distance < $bestDistance} {
            set bestLine $lineId
            set bestDistance $distance
        }
    }
    if {$bestLine eq ""} {
        error [::HWFlow::txt "找不到包含切分点的构造线。" "No construction line contains the split point."]
    }
    return $bestLine
}

proc ::SeamSurf::orderLineChain {lineIds startPoint} {
    set remaining [::SeamSurf::unique $lineIds]
    set ordered {}
    set current $startPoint
    while {[llength $remaining] > 0} {
        set bestIndex -1
        set bestDistance ""
        set bestEnd ""
        for {set i 0} {$i < [llength $remaining]} {incr i} {
            set lineId [lindex $remaining $i]
            set ends [::SeamSurf::lineEndCoords $lineId]
            set d0 [::SeamSurf::distance $current [lindex $ends 0]]
            set d1 [::SeamSurf::distance $current [lindex $ends 1]]
            if {$d0 <= $d1} {
                set distance $d0
                set nextEnd [lindex $ends 1]
            } else {
                set distance $d1
                set nextEnd [lindex $ends 0]
            }
            if {$bestIndex < 0 || $distance < $bestDistance} {
                set bestIndex $i
                set bestDistance $distance
                set bestEnd $nextEnd
            }
        }
        lappend ordered [lindex $remaining $bestIndex]
        set remaining [lreplace $remaining $bestIndex $bestIndex]
        set current $bestEnd
    }
    return $ordered
}

proc ::SeamSurf::splitLineAtCoords {lineId splitCoords startPoint} {
    set candidates [list $lineId]
    foreach point $splitCoords {
        set splitLine [::SeamSurf::closestLineToPoint $candidates $point]
        set before [::SeamSurf::allEntityIds lines 2]
        set nodeId [::SeamSurf::createTempNode $point]
        set code [catch {*linesplitatpoint $splitLine $nodeId} err opts]
        ::SeamSurf::deleteNodes [list $nodeId]
        if {$code} {
            return -options $opts $err
        }
        set allLines [::SeamSurf::allEntityIds lines 2]
        set candidates [::SeamSurf::unique [concat $candidates [::SeamSurf::newIds $before $allLines]]]
        catch {array unset exists}
        array set exists {}
        foreach id $allLines {
            set exists($id) 1
        }
        set valid {}
        foreach id $candidates {
            if {[info exists exists($id)]} {
                lappend valid $id
            }
        }
        set candidates $valid
    }
    return [::SeamSurf::orderLineChain $candidates $startPoint]
}

proc ::SeamSurf::createSegmentedRuledFromCurves {coordsA coordsB featurePairs} {
    if {[llength $featurePairs] < 2} {
        error [::HWFlow::txt "至少需要两组对应点。" "At least two correspondence pairs are required."]
    }
    set fullLineA [::SeamSurf::createLineFromCoords $coordsA]
    set fullLineB [::SeamSurf::createLineFromCoords $coordsB]
    set splitA {}
    set splitB {}
    foreach pair [lrange $featurePairs 1 end-1] {
        lappend splitA [lindex $pair 0]
        lappend splitB [lindex $pair 1]
    }
    set segmentsA [::SeamSurf::splitLineAtCoords $fullLineA $splitA [lindex $coordsA 0]]
    set segmentsB [::SeamSurf::splitLineAtCoords $fullLineB $splitB [lindex $coordsB 0]]
    if {[llength $segmentsA] != [llength $segmentsB]} {
        error [::HWFlow::txt \
            "两侧曲线切分数量不一致：A=[llength $segmentsA]，B=[llength $segmentsB]。" \
            "The split counts differ: A=[llength $segmentsA], B=[llength $segmentsB]."]
    }
    set seamSurfs {}
    for {set i 0} {$i < [llength $segmentsA]} {incr i} {
        lappend seamSurfs [::SeamSurf::createRuledSurfaceBetweenSegments \
            [lindex $segmentsA $i] [lindex $segmentsB $i]]
    }
    return [list $seamSurfs [concat $segmentsA $segmentsB]]
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
    return [::SeamSurf::unique $edges]
}

proc ::SeamSurf::seamExternalOwnerSurfaces {seamSurfs} {
    array set isSeam {}
    foreach surf $seamSurfs {
        set isSeam($surf) 1
    }
    set external {}
    foreach surf $seamSurfs {
        foreach edge [::SeamSurf::surfaceEdges $surf] {
            foreach owner [::SeamSurf::lineOwnerSurfaces $edge] {
                if {![info exists isSeam($owner)]} {
                    lappend external $owner
                }
            }
        }
    }
    return [::SeamSurf::unique $external]
}

proc ::SeamSurf::equivalence {seamSurfs sourceSurfs targetSurfs} {
    variable cfg

    array set exists {}
    foreach id [::SeamSurf::allEntityIds surfs 2] {
        set exists($id) 1
    }
    set allSurfs {}
    foreach id [::SeamSurf::unique [concat $seamSurfs $sourceSurfs $targetSurfs]] {
        if {[info exists exists($id)]} {
            lappend allSurfs $id
        }
    }
    if {[llength $allSurfs] < 3} {
        error [::HWFlow::txt \
            "equivalence 需要焊缝面及两侧接触面，当前有效曲面不足。" \
            "Equivalence requires the seam and both contacting sides; too few valid surfaces were found."]
    }
    catch {*clearmark surfs 1}
    eval *createmark surfs 1 $allSurfs
    set code [catch {*selfstitchcombine 1 130 $cfg(stitch_tolerance) $cfg(stitch_tolerance)} err opts]
    if {!$code && [llength [::SeamSurf::seamExternalOwnerSurfaces $seamSurfs]] < 2} {
        # HyperMesh can return success when no candidate edges were changed.
        # Retry the documented basic cross-surface mode before declaring failure.
        set code [catch {*selfstitchcombine 1 2 $cfg(stitch_tolerance) $cfg(stitch_tolerance)} err opts]
    }
    catch {*clearmark surfs 1}
    if {$code} {
        return -options $opts $err
    }
    set externalOwners [::SeamSurf::seamExternalOwnerSurfaces $seamSurfs]
    if {[llength $externalOwners] < 2} {
        error [::HWFlow::txt \
            "equivalence 命令未报错，但焊缝边仍未与两侧曲面形成共享拓扑。" \
            "The equivalence command returned successfully, but the seam edges still do not share topology with both sides."]
    }
    return [llength $externalOwners]
}

proc ::SeamSurf::lineOwnerSurfaces {lineId} {
    set result {}
    foreach command [list [list hm_getsurfacesfromedge $lineId] [list hm_getsurfacesfromline $lineId]] {
        if {![catch {set ids [eval $command]}] && [llength $ids] > 0} {
            set result [concat $result $ids]
        }
    }
    return [::SeamSurf::unique $result]
}

proc ::SeamSurf::surfaceComponentId {surfId} {
    foreach type {surfs surfaces} {
        foreach dataname {collector.id component.id componentid component collector} {
            if {![catch {set value [hm_getvalue $type id=$surfId dataname=$dataname]}] && $value ne ""} {
                if {[string is integer -strict $value] && $value > 0} {
                    return $value
                }
                set compId [::HWFlow::componentIdByName $value]
                if {$compId ne ""} {
                    return $compId
                }
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
    return ""
}

proc ::SeamSurf::parseThickness {name} {
    if {[regexp {(^|_)T([0-9]+([.][0-9]+)?)(_|$)} $name -> prefix value fraction suffix]} {
        return $value
    }
    return ""
}

proc ::SeamSurf::askThickness {surfaceId} {
    variable ui

    catch {destroy .seam_thickness}
    set ui(promptOk) 0
    set ui(promptValue) ""
    set w .seam_thickness
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::txt "输入板厚" "Input Thickness"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    message $w.main.msg -width 420 -text [::HWFlow::txt \
        "无法从曲面 $surfaceId 的组件名称读取 _T 厚度，请输入板厚。" \
        "No _T thickness token was found for surface $surfaceId. Enter its thickness."]
    entry $w.main.value -textvariable ::SeamSurf::ui(promptValue) -width 18
    pack $w.main.msg -fill x -pady {0 8}
    pack $w.main.value -anchor w

    frame $w.btn -padx 12 -pady 8
    pack $w.btn -fill x
    button $w.btn.cancel -text [::HWFlow::txt "退出" "Exit"] -width 10 \
        -command "set ::SeamSurf::ui(promptOk) -1; destroy .seam_thickness"
    button $w.btn.ok -text [::HWFlow::txt "确定" "OK"] -width 10 \
        -command "::SeamSurf::acceptThickness"
    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.ok -side right -padx 4
    bind $w <Return> "::SeamSurf::acceptThickness"
    bind $w <Escape> "set ::SeamSurf::ui(promptOk) -1; destroy .seam_thickness"
    ::SeamSurf::centerWindow $w
    tkwait window $w

    if {$ui(promptOk) < 0} {
        set ui(stop) 1
        return ""
    }
    return $ui(promptValue)
}

proc ::SeamSurf::acceptThickness {} {
    variable ui
    set value [string trim $ui(promptValue)]
    if {![string is double -strict $value] || $value <= 0.0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "输入板厚" "Input Thickness"] \
            -message [::HWFlow::txt "板厚必须为大于 0 的数值。" "Thickness must be greater than zero."]
        return
    }
    set ui(promptValue) $value
    set ui(promptOk) 1
    destroy .seam_thickness
}

proc ::SeamSurf::surfaceThickness {surfId} {
    set value [::SeamSurf::parseThickness [::SeamSurf::surfaceComponentName $surfId]]
    if {$value ne ""} {
        return $value
    }
    return [::SeamSurf::askThickness $surfId]
}

proc ::SeamSurf::minimumThickness {a b} {
    if {$a <= $b} {
        return $a
    }
    return $b
}

proc ::SeamSurf::formatThickness {value} {
    variable cfg
    set formatString [string trim $cfg(thickness_format)]
    if {[catch {set text [format $formatString $value]}]} {
        set text [format "%.3g" $value]
    }
    return [::HWFlow::sanitizeToken $text UNKNOWN]
}

proc ::SeamSurf::uniqueComponentName {base} {
    if {[::HWFlow::componentIdByName $base] eq ""} {
        return $base
    }
    for {set i 1} {$i <= 999} {incr i} {
        set candidate [format "%s_%02d" $base $i]
        if {[::HWFlow::componentIdByName $candidate] eq ""} {
            return $candidate
        }
    }
    return "${base}_[clock seconds]"
}

proc ::SeamSurf::ensureSeamComponent {thickness} {
    variable cfg

    set base "SEAM_T[::SeamSurf::formatThickness $thickness]"
    set name $base
    if {$cfg(component_mode) eq "per_seam"} {
        set name [::SeamSurf::uniqueComponentName $base]
    }
    set compId [::HWFlow::createComponent $name 11]
    catch {*currentcollector component $name}
    catch {*currentcollector components $name}
    if {$compId ne ""} {
        ::HWFlow::addComponentsToAssembly SEAM [list $compId] 11
    }
    catch {::HWFlow::activateAndShowComponent $name 0}
    return [list $name $compId]
}

proc ::SeamSurf::resolveOwnerSurface {lineId label {avoidSurf ""}} {
    variable ui

    set owners [::SeamSurf::lineOwnerSurfaces $lineId]
    if {$avoidSurf ne ""} {
        set filtered {}
        foreach surf $owners {
            if {$surf != $avoidSurf} {
                lappend filtered $surf
            }
        }
        if {[llength $filtered] > 0} {
            set owners $filtered
        }
    }
    if {[llength $owners] == 1} {
        return [lindex $owners 0]
    }
    foreach surf $owners {
        if {[::SeamSurf::parseThickness [::SeamSurf::surfaceComponentName $surf]] ne ""} {
            return $surf
        }
    }
    if {[llength $owners] > 0} {
        return [lindex $owners 0]
    }

    set surf [::SeamSurf::selectSurface [::HWFlow::txt \
        "线 $lineId 无所属面：请选择其 $label 接触面；ESC 退出" \
        "Line $lineId has no owner: select its $label contacting surface; ESC exits"]]
    if {$surf eq ""} {
        set ui(stop) 1
    }
    return $surf
}

proc ::SeamSurf::deleteLines {lineIds} {
    set lineIds [::SeamSurf::unique $lineIds]
    if {[llength $lineIds] == 0} {
        return
    }
    catch {*clearmark lines 1}
    if {![catch {eval *createmark lines 1 $lineIds}]} {
        catch {*deletemark lines 1}
    }
    catch {*clearmark lines 1}
}

proc ::SeamSurf::performLineSurface {sourceLine targetSurf sourceSurf thickness} {
    variable stat

    set featureData [::SeamSurf::lineSurfaceFeaturePairs $sourceLine $targetSurf]
    set pairs [lindex $featureData 0]
    set projectedSamples [lindex $featureData 1]
    set maxGap [lindex $featureData 2]
    set sourceCoords {}
    set projectedCoords [::SeamSurf::projectedCoords $projectedSamples]
    foreach sample $projectedSamples {
        lappend sourceCoords [lindex $sample 1]
    }

    set component [::SeamSurf::ensureSeamComponent $thickness]
    set compName [lindex $component 0]
    set trimInfo [::SeamSurf::trimSurfaceWithProjectedLine $targetSurf $projectedCoords]
    set trimLine [lindex $trimInfo 0]
    set targetSurfs [lindex $trimInfo 1]

    # Build each side as one complete smooth curve, split both curves at the
    # corresponding feature points, then ruled each resulting curve pair.
    set ruledResult [::SeamSurf::createSegmentedRuledFromCurves \
        $sourceCoords $projectedCoords $pairs]
    set seamSurfs [lindex $ruledResult 0]
    set constructionLines [lindex $ruledResult 1]
    set connectedSides [::SeamSurf::equivalence $seamSurfs [list $sourceSurf] $targetSurfs]
    ::SeamSurf::deleteLines [concat [list $trimLine] $constructionLines]
    catch {::HWFlow::activateAndShowComponent $compName 0}

    incr stat(createdOperations)
    incr stat(createdSurfaces) [llength $seamSurfs]
    incr stat(equivalenced)
    ::SeamSurf::msg [::HWFlow::txt \
        "线-面焊缝完成：分段=[llength $seamSurfs]，特征对应=[llength $pairs]，已连接侧面=$connectedSides，最大投影距离=[format %.6g $maxGap]。请继续选择下一条线。" \
        "Line-Surface seam completed: segments=[llength $seamSurfs], feature pairs=[llength $pairs], connected sides=$connectedSides, maximum projection distance=[format %.6g $maxGap]. Select the next line."]
    return $seamSurfs
}

proc ::SeamSurf::performLineLine {lineA lineB surfA surfB thickness} {
    variable stat
    variable cfg

    set featureData [::SeamSurf::lineLineFeaturePairs $lineA $lineB]
    set pairs [lindex $featureData 0]
    set maxGap [lindex $featureData 1]
    set reverseB [lindex $featureData 2]
    set coordsA {}
    set coordsB {}
    foreach sample [::SeamSurf::lineSamples $lineA $cfg(line_sync_divisions)] {
        lappend coordsA [lindex $sample 1]
    }
    set samplesB [::SeamSurf::lineSamples $lineB $cfg(line_sync_divisions)]
    if {$reverseB} {
        set samplesB [lreverse $samplesB]
    }
    foreach sample $samplesB {
        lappend coordsB [lindex $sample 1]
    }
    set component [::SeamSurf::ensureSeamComponent $thickness]
    set compName [lindex $component 0]
    set ruledResult [::SeamSurf::createSegmentedRuledFromCurves $coordsA $coordsB $pairs]
    set seamSurfs [lindex $ruledResult 0]
    set constructionLines [lindex $ruledResult 1]
    set connectedSides [::SeamSurf::equivalence $seamSurfs [list $surfA] [list $surfB]]
    ::SeamSurf::deleteLines $constructionLines
    catch {::HWFlow::activateAndShowComponent $compName 0}

    incr stat(createdOperations)
    incr stat(createdSurfaces) [llength $seamSurfs]
    incr stat(equivalenced)
    ::SeamSurf::msg [::HWFlow::txt \
        "线-线焊缝完成：分段=[llength $seamSurfs]，特征对应=[llength $pairs]，已连接侧面=$connectedSides，最大距离=[format %.6g $maxGap]，第二条线反向=$reverseB。请继续选择下一组线。" \
        "Line-Line seam completed: segments=[llength $seamSurfs], feature pairs=[llength $pairs], connected sides=$connectedSides, maximum distance=[format %.6g $maxGap], second line reversed=$reverseB. Select the next line pair."]
    return $seamSurfs
}

proc ::SeamSurf::processLineSurfaceSelection {} {
    variable ui

    set sourceLine [::SeamSurf::selectLine [::HWFlow::txt \
        "选择焊缝源线，中键确认；ESC 退出连续创建" \
        "Select the seam source line and middle-click; ESC exits"]]
    if {$sourceLine eq ""} {
        return ""
    }
    set targetSurf [::SeamSurf::selectSurface [::HWFlow::txt \
        "选择源线的投影目标面，中键确认；ESC 退出连续创建" \
        "Select the projection target surface and middle-click; ESC exits"]]
    if {$targetSurf eq ""} {
        return ""
    }
    set sourceSurf [::SeamSurf::resolveOwnerSurface $sourceLine [::HWFlow::txt "源侧" "source-side"] $targetSurf]
    if {$sourceSurf eq ""} {
        return ""
    }
    if {$sourceSurf == $targetSurf} {
        error [::HWFlow::txt "源线所属面与投影目标面不能是同一个面。" "The source owner and projection target cannot be the same surface."]
    }

    set t1 [::SeamSurf::surfaceThickness $sourceSurf]
    if {$ui(stop)} {
        return ""
    }
    set t2 [::SeamSurf::surfaceThickness $targetSurf]
    if {$ui(stop)} {
        return ""
    }
    set thickness [::SeamSurf::minimumThickness $t1 $t2]
    return [::SeamSurf::runWithUndo \
        "Create Line-Surface Seam" \
        [list ::SeamSurf::performLineSurface $sourceLine $targetSurf $sourceSurf $thickness]]
}

proc ::SeamSurf::processLineLineSelection {} {
    variable ui

    set lineA [::SeamSurf::selectLine [::HWFlow::txt \
        "选择第一条焊缝边界线，中键确认；ESC 退出连续创建" \
        "Select the first seam boundary and middle-click; ESC exits"]]
    if {$lineA eq ""} {
        return ""
    }
    set lineB [::SeamSurf::selectLine [::HWFlow::txt \
        "选择第二条焊缝边界线，中键确认；ESC 退出连续创建" \
        "Select the second seam boundary and middle-click; ESC exits"]]
    if {$lineB eq ""} {
        return ""
    }
    if {$lineA == $lineB} {
        error [::HWFlow::txt "两条焊缝边界线必须不同。" "The two seam boundaries must be different."]
    }

    set surfA [::SeamSurf::resolveOwnerSurface $lineA [::HWFlow::txt "第一侧" "first-side"]]
    if {$surfA eq ""} {
        return ""
    }
    set surfB [::SeamSurf::resolveOwnerSurface $lineB [::HWFlow::txt "第二侧" "second-side"] $surfA]
    if {$surfB eq ""} {
        return ""
    }
    if {$surfA == $surfB} {
        error [::HWFlow::txt "两条边界线的接触面必须不同。" "The two boundary lines must contact different surfaces."]
    }

    set t1 [::SeamSurf::surfaceThickness $surfA]
    if {$ui(stop)} {
        return ""
    }
    set t2 [::SeamSurf::surfaceThickness $surfB]
    if {$ui(stop)} {
        return ""
    }
    set thickness [::SeamSurf::minimumThickness $t1 $t2]
    return [::SeamSurf::runWithUndo \
        "Create Line-Line Seam" \
        [list ::SeamSurf::performLineLine $lineA $lineB $surfA $surfB $thickness]]
}

proc ::SeamSurf::runWithUndo {historyName command} {
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} {
        set historyStarted 1
    }
    set code [catch {uplevel #0 $command} result opts]
    if {$historyStarted} {
        catch {*endnotehistorystate $historyName}
    }
    if {$code} {
        if {$historyStarted} {
            catch {*undohistorystate 1}
            catch {::HWFlow::refreshBrowser}
        }
        return -options $opts $result
    }
    return $result
}

proc ::SeamSurf::continuousCreation {} {
    variable ui
    variable stat

    set ui(stop) 0
    catch {hm_usermessage [::HWFlow::txt \
        "连续焊缝创建已启动；完成一次后可继续选择，按 ESC 退出。" \
        "Continuous seam creation started; continue selecting after each operation, or press ESC to exit."]}

    while {!$ui(stop)} {
        set code [catch {
            switch -- [::SeamSurf::normalizeMode $ui(mode)] {
                LINE_SURFACE {
                    ::SeamSurf::processLineSurfaceSelection
                }
                LINE_LINE {
                    ::SeamSurf::processLineLineSelection
                }
            }
        } err]
        if {$ui(stop)} {
            break
        }
        if {$code} {
            incr stat(failed)
            ::SeamSurf::msg [::HWFlow::txt \
                "本次焊缝创建失败并已撤销：$err。请重新选择；按 ESC 退出。" \
                "This seam failed and was rolled back: $err. Select again, or press ESC to exit."]
        }
        catch {::HWFlow::refreshBrowser}
        catch {hm_redraw}
        catch {update idletasks}
    }

    catch {::HWFlow::refreshBrowser}
    catch {hm_redraw}
    set summary [::HWFlow::txt \
        "连续焊缝创建已退出：完成 $stat(createdOperations) 次，创建 $stat(createdSurfaces) 个焊缝面，equivalence $stat(equivalenced) 次，失败 $stat(failed) 次。" \
        "Continuous seam creation exited: $stat(createdOperations) operations, $stat(createdSurfaces) seam surfaces, $stat(equivalenced) equivalence operations, $stat(failed) failures."]
    catch {hm_usermessage $summary}
    ::SeamSurf::msg $summary
}

proc ::SeamSurf::run {} {
    variable stat

    if {![::SeamSurf::showPanel]} {
        catch {hm_usermessage [::HWFlow::txt "焊缝面创建已取消。" "Seam Surface Creation cancelled."]}
        return
    }
    array unset stat
    array set stat {
        createdOperations 0
        createdSurfaces   0
        equivalenced     0
        failed           0
    }
    ::SeamSurf::continuousCreation
}
