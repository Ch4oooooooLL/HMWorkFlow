# ============================================================================
# Geometry Cleanup Workflow
# HyperMesh 2019 Tcl/Tk
#
# One-face entry for local CAD cleanup:
#   - remove chamfer / small fillet faces by extending adjacent surfaces
#   - fill a small recessed pocket back to surrounding face height using surfaces only
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::GeomCleanup {
    variable VERSION "0.1"
    variable CONFIG_KEY "geometry_cleanup"
    variable RULE_FILE [file join [::HWFlow::configDir] "geometry_cleanup_rules.txt"]

    variable DEFAULTS
    array set DEFAULTS {
        MODE AUTO
        FILLET_MIN_R 0.0
        FILLET_MAX_R 5.0
        CHAIN_BY_FILLET 1
        CHAIN_BY_SMALL_AREA 1
        MAX_CHAIN_DEPTH 6
        AREA_GROWTH_RATIO 2.5
        STITCH_TOLERANCE 0.2
        POCKET_FILL_METHOD SPLINE
        POCKET_KEEP_INNER_LOOPS 1
        CREATE_SOLID_FROM_CHAMFER_BOUNDS 1
        PERFORMANCE_MODE 1
        VERBOSE 1
    }

    variable ui
    array set ui {}
    variable stat
    array set stat {}
}

proc ::GeomCleanup::defaultRulesText {} {
    return [join {
        {# Geometry cleanup defaults.}
        {# MODE: AUTO, CHAMFER, or POCKET. AUTO tries chamfer/fillet first, then recessed pocket fill.}
        {key|value|note}
        {mode|AUTO|AUTO CHAMFER POCKET}
        {fillet_min_r|0.0|min radius used by HyperMesh fillet-face query}
        {fillet_max_r|5.0|max radius used by HyperMesh fillet-face query and fillet fallback}
        {chain_by_fillet|1|expand selected face through hm_getfilletfacesfrommark when possible}
        {chain_by_small_area|1|fallback chain expansion through adjacent small faces}
        {max_chain_depth|6|max adjacency depth when growing a chamfer/pocket side chain}
        {area_growth_ratio|2.5|neighbor face area <= selected area * this ratio can join fallback chain}
        {stitch_tolerance|0.2|topology stitch tolerance after cleanup}
        {pocket_fill_method|SPLINE|SPLINE first, then pinhole fallback}
        {pocket_keep_inner_loops|1|trim the fill at inner loops and extend inner walls to form continuous through holes}
        {create_solid_from_chamfer_bounds|1|attempt *solids_create_from_surfaces only after chamfer cleanup}
        {performance_mode|1|block redraw/browser updates while running}
        {verbose|1|write status lines to Tcl console and HM status bar}
    } "\n"]
}

proc ::GeomCleanup::stateKeys {} {
    return {
        MODE FILLET_MIN_R FILLET_MAX_R CHAIN_BY_FILLET CHAIN_BY_SMALL_AREA
        MAX_CHAIN_DEPTH AREA_GROWTH_RATIO STITCH_TOLERANCE POCKET_FILL_METHOD
        POCKET_KEEP_INNER_LOOPS CREATE_SOLID_FROM_CHAMFER_BOUNDS PERFORMANCE_MODE VERBOSE
    }
}

proc ::GeomCleanup::ensureConfigFiles {} {
    variable RULE_FILE
    if {![file exists $RULE_FILE]} {
        ::HWFlow::writeTextFile $RULE_FILE [::GeomCleanup::defaultRulesText]
    }
}

proc ::GeomCleanup::normalizeMode {value} {
    set v [string toupper [string trim $value]]
    switch -- $v {
        CHAMFER -
        FILLET {
            return CHAMFER
        }
        POCKET -
        RECESS {
            return POCKET
        }
        default {
            return AUTO
        }
    }
}

proc ::GeomCleanup::normalizeFillMethod {value} {
    set v [string toupper [string trim $value]]
    switch -- $v {
        PINHOLE {
            return PINHOLE
        }
        default {
            return SPLINE
        }
    }
}

proc ::GeomCleanup::loadRuleFile {} {
    variable RULE_FILE
    variable ui
    if {![file exists $RULE_FILE]} {
        return
    }
    foreach raw [split [::HWFlow::readTextFile $RULE_FILE] "\n"] {
        set line [string trim $raw]
        if {$line eq "" || [string index $line 0] eq "#"} { continue }
        set cols [split $line "|"]
        if {[llength $cols] < 2} { continue }
        set key [string tolower [string trim [lindex $cols 0]]]
        set val [string trim [lindex $cols 1]]
        switch -- $key {
            mode { set ui(MODE) [::GeomCleanup::normalizeMode $val] }
            fillet_min_r { set ui(FILLET_MIN_R) $val }
            fillet_max_r { set ui(FILLET_MAX_R) $val }
            chain_by_fillet { set ui(CHAIN_BY_FILLET) $val }
            chain_by_small_area { set ui(CHAIN_BY_SMALL_AREA) $val }
            max_chain_depth { set ui(MAX_CHAIN_DEPTH) $val }
            area_growth_ratio { set ui(AREA_GROWTH_RATIO) $val }
            stitch_tolerance { set ui(STITCH_TOLERANCE) $val }
            pocket_fill_method { set ui(POCKET_FILL_METHOD) [::GeomCleanup::normalizeFillMethod $val] }
            pocket_keep_inner_loops { set ui(POCKET_KEEP_INNER_LOOPS) $val }
            create_solid_from_bounds { set ui(CREATE_SOLID_FROM_CHAMFER_BOUNDS) $val }
            create_solid_from_chamfer_bounds { set ui(CREATE_SOLID_FROM_CHAMFER_BOUNDS) $val }
            performance_mode { set ui(PERFORMANCE_MODE) $val }
            verbose { set ui(VERBOSE) $val }
        }
    }
}

proc ::GeomCleanup::loadState {} {
    variable DEFAULTS
    variable ui
    ::GeomCleanup::ensureConfigFiles
    foreach key [::GeomCleanup::stateKeys] {
        set ui($key) $DEFAULTS($key)
    }
    ::GeomCleanup::loadRuleFile
    set state [::HWFlow::loadState geometry_cleanup]
    foreach key [::GeomCleanup::stateKeys] {
        if {[dict exists $state $key]} {
            set ui($key) [dict get $state $key]
        }
    }
    set ui(MODE) [::GeomCleanup::normalizeMode $ui(MODE)]
    set ui(POCKET_FILL_METHOD) [::GeomCleanup::normalizeFillMethod $ui(POCKET_FILL_METHOD)]
}

proc ::GeomCleanup::saveState {} {
    variable ui
    set state [dict create]
    foreach key [::GeomCleanup::stateKeys] {
        if {[info exists ui($key)]} {
            dict set state $key $ui($key)
        }
    }
    ::HWFlow::saveState geometry_cleanup $state
}

proc ::GeomCleanup::savePanelState {} {
    ::GeomCleanup::saveState
}

proc ::GeomCleanup::showRules {} {
    variable RULE_FILE
    ::GeomCleanup::ensureConfigFiles
    set msg [::HWFlow::txt "当前几何清理参数文件：\n$RULE_FILE\n\n[::HWFlow::readTextFile $RULE_FILE]" "Current geometry cleanup rule file:\n$RULE_FILE\n\n[::HWFlow::readTextFile $RULE_FILE]"]
    tk_messageBox -icon info -title [::HWFlow::txt "几何清理参数" "Geometry Cleanup Rules"] -message $msg
}

proc ::GeomCleanup::centerWindow {w} {
    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw - $ww) / 2}]+[expr {($sh - $wh) / 2}]
}

proc ::GeomCleanup::backToHome {w} {
    if {[llength [info commands ::HWFlow::backToHome]] > 0} {
        ::HWFlow::backToHome $w
    } else {
        catch {destroy $w}
    }
}

proc ::GeomCleanup::showPanel {} {
    variable ui
    variable VERSION
    ::GeomCleanup::loadState
    set ui(ok) 0
    set ui(status) ""

    catch {destroy .geometry_cleanup}
    set w .geometry_cleanup
    toplevel $w
    wm title $w "[::HWFlow::txt "Geometry Cleanup" "Geometry Cleanup"] v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text [::HWFlow::txt "Geometry Cleanup" "Geometry Cleanup"] -font [::HWFlow::uiFont heading]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.mode -text [::HWFlow::txt "1. 判断模式" "1. Detection Mode"] -padx 8 -pady 8
    grid $w.main.mode -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    radiobutton $w.main.mode.auto -text [::HWFlow::txt "自动：先尝试倒角/圆角，失败后按沉台补平" "Auto: try chamfer/fillet first, then recess fill"] -variable ::GeomCleanup::ui(MODE) -value AUTO
    radiobutton $w.main.mode.chamfer -text [::HWFlow::txt "强制清除倒角/圆角" "Force chamfer/fillet removal"] -variable ::GeomCleanup::ui(MODE) -value CHAMFER
    radiobutton $w.main.mode.pocket -text [::HWFlow::txt "强制清理沉台" "Force recessed pocket fill"] -variable ::GeomCleanup::ui(MODE) -value POCKET
    grid $w.main.mode.auto -row 0 -column 0 -sticky w -pady 2
    grid $w.main.mode.chamfer -row 1 -column 0 -sticky w -pady 2
    grid $w.main.mode.pocket -row 2 -column 0 -sticky w -pady 2

    labelframe $w.main.param -text [::HWFlow::txt "2. 参数" "2. Parameters"] -padx 8 -pady 8
    grid $w.main.param -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    set fields {
        {FILLET_MIN_R "圆角最小 R" "Min fillet R"}
        {FILLET_MAX_R "圆角/倒角最大 R" "Max fillet/chamfer R"}
        {MAX_CHAIN_DEPTH "邻接扩展层数" "Adjacency chain depth"}
        {AREA_GROWTH_RATIO "小面面积倍率" "Small-face area ratio"}
        {STITCH_TOLERANCE "缝合容差" "Stitch tolerance"}
    }
    set i 0
    foreach item $fields {
        set key [lindex $item 0]
        set label [::HWFlow::txt [lindex $item 1] [lindex $item 2]]
        set r [expr {$i / 2}]
        set c [expr {($i % 2) * 2}]
        label $w.main.param.l_$key -text $label -anchor w
        entry $w.main.param.e_$key -textvariable ::GeomCleanup::ui($key) -width 16
        grid $w.main.param.l_$key -row $r -column $c -sticky w -padx {0 6} -pady 2
        grid $w.main.param.e_$key -row $r -column [expr {$c + 1}] -sticky w -padx {0 18} -pady 2
        incr i
    }
    label $w.main.param.l_fill -text [::HWFlow::txt "沉台补面" "Pocket fill"] -anchor w
    tk_optionMenu $w.main.param.fill ::GeomCleanup::ui(POCKET_FILL_METHOD) SPLINE PINHOLE
    grid $w.main.param.l_fill -row 3 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.param.fill -row 3 -column 1 -sticky w -pady 2

    labelframe $w.main.opt -text [::HWFlow::txt "3. 选项" "3. Options"] -padx 8 -pady 8
    grid $w.main.opt -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    checkbutton $w.main.opt.filchain -text [::HWFlow::txt "用 HyperMesh 圆角识别扩展倒角/圆角链" "Grow chamfer/fillet chain by HyperMesh fillet query"] -variable ::GeomCleanup::ui(CHAIN_BY_FILLET)
    checkbutton $w.main.opt.areachain -text [::HWFlow::txt "圆角识别失败时，按相邻小面继续扩展" "Fallback grow chain through adjacent small faces"] -variable ::GeomCleanup::ui(CHAIN_BY_SMALL_AREA)
    checkbutton $w.main.opt.inner -text [::HWFlow::txt "延伸沉台内壁并保留贯通孔" "Extend inner walls and preserve through holes"] -variable ::GeomCleanup::ui(POCKET_KEEP_INNER_LOOPS)
    checkbutton $w.main.opt.solid -text [::HWFlow::txt "倒角清理后尝试从封闭 surface 重建/补充 solid" "After chamfer cleanup, try creating solids from closed surface bounds"] -variable ::GeomCleanup::ui(CREATE_SOLID_FROM_CHAMFER_BOUNDS)
    checkbutton $w.main.opt.perf -text [::HWFlow::txt "执行时减少刷新以提升速度" "Reduce redraw/browser refresh while running"] -variable ::GeomCleanup::ui(PERFORMANCE_MODE)
    grid $w.main.opt.filchain -row 0 -column 0 -sticky w -pady 2
    grid $w.main.opt.areachain -row 1 -column 0 -sticky w -pady 2
    grid $w.main.opt.inner -row 2 -column 0 -sticky w -pady 2
    grid $w.main.opt.solid -row 3 -column 0 -sticky w -pady 2
    grid $w.main.opt.perf -row 4 -column 0 -sticky w -pady 2

    label $w.main.status -textvariable ::GeomCleanup::ui(status) -width 78 -anchor w
    grid $w.main.status -row 4 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x
    button $w.btn.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 -command "::GeomCleanup::savePanelState; set ::GeomCleanup::ui(ok) 0; ::GeomCleanup::backToHome .geometry_cleanup"
    button $w.btn.rules -text [::HWFlow::txt "查看参数" "Show Rules"] -width 12 -command "::GeomCleanup::showRules"
    button $w.btn.start -text [::HWFlow::txt "进入连续清洗" "Start Continuous Cleanup"] -width 16 -command "::GeomCleanup::acceptPanel"
    pack $w.btn.back -side right -padx 4
    pack $w.btn.start -side right -padx 4
    pack $w.btn.rules -side right -padx 4

    bind $w <Escape> "::GeomCleanup::savePanelState; set ::GeomCleanup::ui(ok) 0; destroy .geometry_cleanup"
    wm protocol $w WM_DELETE_WINDOW "::GeomCleanup::savePanelState; set ::GeomCleanup::ui(ok) 0; destroy .geometry_cleanup"
    ::GeomCleanup::centerWindow $w
    tkwait window $w
    return $ui(ok)
}

proc ::GeomCleanup::acceptPanel {} {
    variable ui
    set ui(MODE) [::GeomCleanup::normalizeMode $ui(MODE)]
    set ui(POCKET_FILL_METHOD) [::GeomCleanup::normalizeFillMethod $ui(POCKET_FILL_METHOD)]
    foreach key {FILLET_MIN_R FILLET_MAX_R AREA_GROWTH_RATIO STITCH_TOLERANCE} {
        if {![string is double -strict $ui($key)] || $ui($key) < 0} {
            tk_messageBox -icon warning -title [::HWFlow::txt "几何清理" "Geometry Cleanup"] -message [::HWFlow::txt "$key 必须为非负数值。" "$key must be a non-negative number."]
            return
        }
    }
    if {$ui(FILLET_MAX_R) < $ui(FILLET_MIN_R)} {
        tk_messageBox -icon warning -title [::HWFlow::txt "几何清理" "Geometry Cleanup"] -message [::HWFlow::txt "圆角 R 范围无效。" "Invalid fillet radius range."]
        return
    }
    if {![string is integer -strict $ui(MAX_CHAIN_DEPTH)] || $ui(MAX_CHAIN_DEPTH) < 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "几何清理" "Geometry Cleanup"] -message [::HWFlow::txt "邻接扩展层数必须为非负整数。" "Adjacency chain depth must be a non-negative integer."]
        return
    }
    ::GeomCleanup::saveState
    set ui(ok) 1
    destroy .geometry_cleanup
}

proc ::GeomCleanup::msg {text} {
    variable ui
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] GeomCleanup: $text"
    if {![info exists ui(VERBOSE)] || $ui(VERBOSE)} {
        puts $line
    }
    catch {hm_usermessage $text}
}

proc ::GeomCleanup::beginPerformanceMode {} {
    variable ui
    if {![info exists ui(PERFORMANCE_MODE)] || !$ui(PERFORMANCE_MODE)} {
        return
    }
    catch {hm_blockredraw 1}
    catch {hm_blockmessages 1}
    catch {hm_blockerrormessages 1}
    catch {*setoption block_redraw=1}
    catch {*setoption block_messages=1}
    catch {hwbrowsermanager view flush false}
    catch {hmbr_signals buffer start}
}

proc ::GeomCleanup::endPerformanceMode {} {
    variable ui
    if {![info exists ui(PERFORMANCE_MODE)] || !$ui(PERFORMANCE_MODE)} {
        return
    }
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {*setoption block_redraw=0}
    catch {*setoption block_messages=0}
    catch {hm_blockredraw 0}
    catch {hm_blockmessages 0}
    catch {hm_blockerrormessages 0}
}

proc ::GeomCleanup::uniq {lst} {
    set out {}
    array set seen {}
    foreach v $lst {
        if {$v eq ""} { continue }
        if {![info exists seen($v)]} {
            set seen($v) 1
            lappend out $v
        }
    }
    if {[catch {set out [lsort -integer $out]}]} {
        set out [lsort $out]
    }
    return $out
}

proc ::GeomCleanup::contains {lst value} {
    return [expr {[lsearch -exact $lst $value] >= 0}]
}

proc ::GeomCleanup::markList {entityTypes markId ids} {
    foreach etype $entityTypes {
        catch {*clearmark $etype $markId}
    }
    if {[llength $ids] == 0} {
        return ""
    }
    foreach etype $entityTypes {
        if {![catch {eval *createmark $etype $markId $ids}]} {
            if {![catch {set got [hm_getmark $etype $markId]}] && [llength $got] > 0} {
                return $etype
            }
        }
    }
    return ""
}

proc ::GeomCleanup::selectedSurface {} {
    catch {*clearmark surfs 1}
    *createmarkpanel surfs 1 [::HWFlow::txt "选择一个待清理面，中键执行；取消选择退出连续清洗" "Select one face and middle-click to execute; cancel to exit continuous cleanup"]
    set ids [hm_getmark surfs 1]
    catch {*clearmark surfs 1}
    if {[llength $ids] == 0} {
        return ""
    }
    if {[llength $ids] != 1} {
        error [::HWFlow::txt "需要且仅需要选择一个面，当前选择数量：[llength $ids]。" "Exactly one surface is required. Selected: [llength $ids]."]
    }
    return [lindex $ids 0]
}

proc ::GeomCleanup::surfaceLoops {surfId} {
    if {[catch {set loops [hm_getsurfaceedges $surfId]}]} {
        return {}
    }
    return $loops
}

proc ::GeomCleanup::surfaceEdges {surfId} {
    set edges {}
    foreach loop [::GeomCleanup::surfaceLoops $surfId] {
        foreach edge $loop {
            lappend edges $edge
        }
    }
    return [::GeomCleanup::uniq $edges]
}

proc ::GeomCleanup::pointXYZ {pointId} {
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

proc ::GeomCleanup::dist3 {p q} {
    set dx [expr {[lindex $p 0] - [lindex $q 0]}]
    set dy [expr {[lindex $p 1] - [lindex $q 1]}]
    set dz [expr {[lindex $p 2] - [lindex $q 2]}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}

proc ::GeomCleanup::edgeEndPoints {edgeId} {
    if {![catch {set pts [hm_getverticesfromedge $edgeId]}] && [llength $pts] >= 2} {
        set p0 [::GeomCleanup::pointXYZ [lindex $pts 0]]
        set p1 [::GeomCleanup::pointXYZ [lindex $pts 1]]
        if {$p0 ne "" && $p1 ne ""} {
            return [list $p0 $p1]
        }
    }
    if {![catch {set coords [hm_getcoordinatesofpointsonline $edgeId [list 0.0 1.0]]}]} {
        if {[llength $coords] >= 2} {
            return [list [lrange [lindex $coords 0] 0 2] [lrange [lindex $coords 1] 0 2]]
        }
    }
    return ""
}

proc ::GeomCleanup::edgeLength {edgeId} {
    set ep [::GeomCleanup::edgeEndPoints $edgeId]
    if {$ep eq ""} {
        return 0.0
    }
    return [::GeomCleanup::dist3 [lindex $ep 0] [lindex $ep 1]]
}

proc ::GeomCleanup::loopPerimeter {loop} {
    set total 0.0
    foreach edge $loop {
        set total [expr {$total + [::GeomCleanup::edgeLength $edge]}]
    }
    return $total
}

proc ::GeomCleanup::sortLoopsByPerimeter {loops} {
    set rows {}
    foreach loop $loops {
        lappend rows [list [::GeomCleanup::loopPerimeter $loop] $loop]
    }
    set rows [lsort -real -decreasing -index 0 $rows]
    set out {}
    foreach row $rows {
        lappend out [lindex $row 1]
    }
    return $out
}

proc ::GeomCleanup::edgeOwnerSurfaces {edgeId} {
    set out {}
    foreach cmd [list [list hm_getsurfacesfromedge $edgeId] [list hm_getsurfacesfromline $edgeId]] {
        if {![catch {set ids [eval $cmd]}] && [llength $ids] > 0} {
            set out [concat $out $ids]
        }
    }
    return [::GeomCleanup::uniq $out]
}

proc ::GeomCleanup::surfaceComponentId {surfId} {
    foreach dn {collector.id component.id componentid component collector} {
        if {![catch {set v [hm_getvalue surfs id=$surfId dataname=$dn]}] && $v ne ""} {
            if {[string is integer -strict $v]} { return $v }
            set id [::HWFlow::componentIdByName $v]
            if {$id ne ""} { return $id }
        }
        if {![catch {set v [hm_getentityvalue surfs $surfId $dn 0]}] && $v ne ""} {
            if {[string is integer -strict $v]} { return $v }
            set id [::HWFlow::componentIdByName $v]
            if {$id ne ""} { return $id }
        }
    }
    return ""
}

proc ::GeomCleanup::componentSurfaces {compId} {
    if {$compId eq ""} {
        return {}
    }
    foreach dn {surfaces surfs} {
        if {![catch {set ids [hm_getvalue comps id=$compId dataname=$dn]}] && [llength $ids] > 0} {
            return [::GeomCleanup::uniq $ids]
        }
    }
    catch {*clearmark surfs 2}
    if {![catch {*createmark surfs 2 "by comp id" $compId}]} {
        if {![catch {set ids [hm_getmark surfs 2]}] && [llength $ids] > 0} {
            catch {*clearmark surfs 2}
            return [::GeomCleanup::uniq $ids]
        }
    }
    catch {*clearmark surfs 2}
    return {}
}

proc ::GeomCleanup::surfaceArea {surfId} {
    foreach cmd [list [list hm_getareaofsurface surfs $surfId] [list hm_getvalue surfs id=$surfId dataname=area] [list hm_getentityvalue surfs $surfId area 0]] {
        if {![catch {set v [eval $cmd]}] && $v ne "" && [string is double -strict $v]} {
            return [expr {double($v)}]
        }
    }
    return 0.0
}

proc ::GeomCleanup::filletCandidatesForSelected {surfId} {
    variable ui
    set compId [::GeomCleanup::surfaceComponentId $surfId]
    set candidates {}
    if {$compId ne ""} {
        catch {*clearmark comps 1}
        if {![catch {*createmark comps 1 $compId}]} {
            if {![catch {set candidates [hm_getfilletfacesfrommark comps 1 $ui(FILLET_MIN_R) $ui(FILLET_MAX_R)]}]} {
                set candidates [::GeomCleanup::uniq $candidates]
            }
        }
        catch {*clearmark comps 1}
    }
    if {[llength $candidates] == 0} {
        catch {*clearmark surfs 1}
        if {![catch {*createmark surfs 1 $surfId}]} {
            catch {set candidates [hm_getfilletfacesfrommark surfs 1 $ui(FILLET_MIN_R) $ui(FILLET_MAX_R)]}
        }
        catch {*clearmark surfs 1}
    }
    return [::GeomCleanup::uniq $candidates]
}

proc ::GeomCleanup::connectedChain {seed candidates maxDepth} {
    set candidates [::GeomCleanup::uniq $candidates]
    if {![::GeomCleanup::contains $candidates $seed]} {
        lappend candidates $seed
    }
    set out [list $seed]
    set queue [list [list $seed 0]]
    while {[llength $queue] > 0} {
        set item [lindex $queue 0]
        set queue [lrange $queue 1 end]
        set surf [lindex $item 0]
        set depth [lindex $item 1]
        if {$depth >= $maxDepth} {
            continue
        }
        foreach edge [::GeomCleanup::surfaceEdges $surf] {
            foreach nb [::GeomCleanup::edgeOwnerSurfaces $edge] {
                if {$nb eq $surf} { continue }
                if {![::GeomCleanup::contains $candidates $nb]} { continue }
                if {[::GeomCleanup::contains $out $nb]} { continue }
                lappend out $nb
                lappend queue [list $nb [expr {$depth + 1}]]
            }
        }
    }
    return [::GeomCleanup::uniq $out]
}

proc ::GeomCleanup::smallAdjacentChain {seed} {
    variable ui
    set seedArea [::GeomCleanup::surfaceArea $seed]
    if {$seedArea <= 0.0} {
        return [list $seed]
    }
    set limit [expr {$seedArea * double($ui(AREA_GROWTH_RATIO))}]
    set compId [::GeomCleanup::surfaceComponentId $seed]
    set compSurfs [::GeomCleanup::componentSurfaces $compId]
    set candidates {}
    foreach sid $compSurfs {
        set area [::GeomCleanup::surfaceArea $sid]
        if {$area > 0.0 && $area <= $limit} {
            lappend candidates $sid
        }
    }
    return [::GeomCleanup::connectedChain $seed $candidates $ui(MAX_CHAIN_DEPTH)]
}

proc ::GeomCleanup::chamferChain {seed} {
    variable ui
    set chain {}
    if {$ui(CHAIN_BY_FILLET)} {
        set fillets [::GeomCleanup::filletCandidatesForSelected $seed]
        if {[llength $fillets] > 0 && [::GeomCleanup::contains $fillets $seed]} {
            set chain [::GeomCleanup::connectedChain $seed $fillets $ui(MAX_CHAIN_DEPTH)]
        }
    }
    if {[llength $chain] == 0 && $ui(CHAIN_BY_SMALL_AREA)} {
        set chain [::GeomCleanup::smallAdjacentChain $seed]
    }
    if {[llength $chain] == 0} {
        set chain [list $seed]
    }
    return [::GeomCleanup::uniq $chain]
}

proc ::GeomCleanup::latestId {entityTypes} {
    foreach etype $entityTypes {
        if {![catch {set id [hm_latestentityid $etype]}] && $id ne "" && $id != 0} {
            return $id
        }
    }
    return 0
}

proc ::GeomCleanup::entityExistsById {etype id} {
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

proc ::GeomCleanup::idsCreatedAfter {entityTypes beforeId afterId} {
    set out {}
    if {$afterId eq "" || $afterId == 0 || $afterId <= $beforeId} {
        return $out
    }
    for {set id [expr {$beforeId + 1}]} {$id <= $afterId} {incr id} {
        foreach etype $entityTypes {
            if {[::GeomCleanup::entityExistsById $etype $id]} {
                lappend out $id
                break
            }
        }
    }
    return [::GeomCleanup::uniq $out]
}

proc ::GeomCleanup::deleteSurfaces {surfs} {
    set surfs [::GeomCleanup::uniq $surfs]
    if {[llength $surfs] == 0} {
        return 0
    }
    set markType [::GeomCleanup::markList {surfs surfaces} 1 $surfs]
    if {$markType eq ""} {
        error [::HWFlow::txt "无法标记需要删除的 surface。" "Could not mark surfaces to delete."]
    }
    if {[catch {*deletemark $markType 1} err]} {
        catch {*clearmark $markType 1}
        error [::HWFlow::txt "删除 surface 失败：$err" "Deleting surfaces failed: $err"]
    }
    catch {*clearmark $markType 1}
    return [llength $surfs]
}

proc ::GeomCleanup::copyLineOrEdgeToSourceComponent {lineId} {
    set before [::GeomCleanup::latestId {lines line}]
    catch {*clearmark lines 1}
    if {[catch {*createmark lines 1 $lineId}]} {
        catch {*clearmark lines 1}
        return ""
    }
    # Keep construction geometry with the source surface instead of placing it
    # in whichever component happens to be current.
    catch {*linefromsurfedgecomp lines 1 0}
    set after [::GeomCleanup::latestId {lines line}]
    set created [::GeomCleanup::idsCreatedAfter {lines line} $before $after]
    if {[llength $created] == 0 && $after == $before} {
        catch {*linefromsurfedge lines 1}
        catch {*linefromsurfedge 1}
    }
    catch {*clearmark lines 1}
    set after [::GeomCleanup::latestId {lines line}]
    set created [::GeomCleanup::idsCreatedAfter {lines line} $before $after]
    if {[llength $created] == 0 && $after != $before} {
        set created [list $after]
    }
    if {[llength $created] > 0} {
        return [lindex $created end]
    }
    return ""
}

proc ::GeomCleanup::copyLinesOrEdgesToSourceComponent {lineIds label} {
    set out {}
    set failed {}
    foreach lineId [::GeomCleanup::uniq $lineIds] {
        set copied [::GeomCleanup::copyLineOrEdgeToSourceComponent $lineId]
        if {$copied eq ""} {
            lappend failed $lineId
        } else {
            lappend out $copied
        }
    }
    if {[llength $failed] > 0} {
        if {[llength $out] > 0} {
            ::GeomCleanup::deleteConstructionLines $out
        }
        error [::HWFlow::txt "$label 边界线复制失败：$failed。未删除任何沉台 surface。" "$label boundary copy failed: $failed. No pocket surfaces were deleted."]
    }
    if {[llength $out] == 0} {
        error [::HWFlow::txt "$label 未生成可用于补面的独立构造线。未删除任何沉台 surface。" "$label did not produce independent construction lines for filling. No pocket surfaces were deleted."]
    }
    return [::GeomCleanup::uniq $out]
}

proc ::GeomCleanup::organizeSurfacesToComponent {surfs compId} {
    set surfs [::GeomCleanup::uniq $surfs]
    if {[llength $surfs] == 0} {
        return 0
    }
    if {$compId eq ""} {
        error [::HWFlow::txt "无法读取沉台所属 component，不能归集新补面。" "Could not determine the pocket component, so the new fill surface cannot be organized."]
    }
    set compName [::HWFlow::componentName $compId]
    set markType [::GeomCleanup::markList {surfs surfaces} 1 $surfs]
    if {$markType eq ""} {
        error [::HWFlow::txt "无法标记新建沉台补面。" "Could not mark the newly created pocket fill surfaces."]
    }
    if {[catch {*movemark $markType 1 $compName} err]} {
        catch {*clearmark $markType 1}
        error [::HWFlow::txt "无法将新建沉台补面归集到 component $compName：$err" "Could not organize the new pocket fill surfaces into component $compName: $err"]
    }
    catch {*clearmark $markType 1}
    return [llength $surfs]
}

proc ::GeomCleanup::deleteConstructionLines {lineIds} {
    set lineIds [::GeomCleanup::uniq $lineIds]
    if {[llength $lineIds] == 0} {
        return 0
    }
    set markType [::GeomCleanup::markList {lines line} 1 $lineIds]
    if {$markType ne ""} {
        catch {*deletemark $markType 1}
        catch {*clearmark $markType 1}
    }
    return [llength $lineIds]
}

proc ::GeomCleanup::stitchSurfaces {surfs} {
    variable ui
    set surfs [::GeomCleanup::uniq $surfs]
    if {[llength $surfs] < 2} {
        return 0
    }
    set markType [::GeomCleanup::markList {surfs surfaces} 1 $surfs]
    if {$markType eq ""} {
        return 0
    }
    set ok 0
    foreach mode {130 2} {
        if {![catch {*selfstitchcombine 1 $mode $ui(STITCH_TOLERANCE) $ui(STITCH_TOLERANCE)}]} {
            set ok 1
            break
        }
    }
    catch {*clearmark $markType 1}
    return $ok
}

proc ::GeomCleanup::createSolidsFromComponent {compId} {
    variable ui
    if {!$ui(CREATE_SOLID_FROM_CHAMFER_BOUNDS)} {
        return {}
    }
    set surfs [::GeomCleanup::componentSurfaces $compId]
    if {[llength $surfs] == 0} {
        return {}
    }
    set before [::GeomCleanup::latestId {solids solid}]
    set markType [::GeomCleanup::markList {surfs surfaces} 1 $surfs]
    if {$markType eq ""} {
        return {}
    }
    set bounds ""
    catch {set bounds [hm_getsolidboundsforsurfaces mark=1 exclude_solids=1 find_baffles=0]}
    if {$bounds eq ""} {
        set bounds [list $surfs]
    }
    foreach bound $bounds {
        if {[llength $bound] == 0} { continue }
        set mt [::GeomCleanup::markList {surfs surfaces} 1 $bound]
        if {$mt eq ""} { continue }
        catch {*solids_create_from_surfaces 1 4 0 2}
    }
    catch {*clearmark surfs 1}
    set after [::GeomCleanup::latestId {solids solid}]
    return [::GeomCleanup::idsCreatedAfter {solids solid} $before $after]
}

proc ::GeomCleanup::createSolidsFromComponentBounds {surfId} {
    set compId [::GeomCleanup::surfaceComponentId $surfId]
    return [::GeomCleanup::createSolidsFromComponent $compId]
}

proc ::GeomCleanup::removeChamfer {seed} {
    variable ui
    variable stat
    set compId [::GeomCleanup::surfaceComponentId $seed]
    set chain [::GeomCleanup::chamferChain $seed]
    set stat(mode) CHAMFER
    set stat(targetSurfs) $chain
    ::GeomCleanup::msg [::HWFlow::txt "倒角/圆角清理面链：$chain" "Chamfer/fillet cleanup surface chain: $chain"]

    set beforeSurf [::GeomCleanup::latestId {surfs surfaces}]
    set beforeSolid [::GeomCleanup::latestId {solids solid}]
    set markType [::GeomCleanup::markList {surfs surfaces} 1 $chain]
    if {$markType eq ""} {
        error [::HWFlow::txt "无法标记倒角面。" "Could not mark chamfer surfaces."]
    }
    catch {*clearmark lines 1}
    catch {*clearmark lines 2}

    set err1 ""
    if {[catch {*surfacefilletremove 1 1 2} err1]} {
        ::GeomCleanup::msg [::HWFlow::txt "surfacefilletremove 未完成：$err1；尝试 line fillet 回退。" "surfacefilletremove did not finish: $err1; trying line-fillet fallback."]
        if {[catch {*surfacemarkremovelinefillets 1 $ui(FILLET_MIN_R) $ui(FILLET_MAX_R) 0 1 0} err2]} {
            catch {*clearmark $markType 1}
            error [::HWFlow::txt "倒角/圆角清理失败：surfacefilletremove=$err1；linefillets=$err2" "Chamfer/fillet cleanup failed: surfacefilletremove=$err1; linefillets=$err2"]
        }
    }
    catch {*clearmark $markType 1}
    set afterSurf [::GeomCleanup::latestId {surfs surfaces}]
    set afterSolid [::GeomCleanup::latestId {solids solid}]
    set newSurfs [::GeomCleanup::idsCreatedAfter {surfs surfaces} $beforeSurf $afterSurf]
    set newSolids [::GeomCleanup::idsCreatedAfter {solids solid} $beforeSolid $afterSolid]
    set extraSolids [::GeomCleanup::createSolidsFromComponent $compId]
    set stat(newSurfs) $newSurfs
    set stat(newSolids) [::GeomCleanup::uniq [concat $newSolids $extraSolids]]
    return [dict create mode CHAMFER target_surfs $chain new_surfs $newSurfs new_solids $stat(newSolids)]
}

proc ::GeomCleanup::topEdgesFromWallFaces {floorEdges wallFaces deletedFaces} {
    set floorEdges [::GeomCleanup::uniq $floorEdges]
    set wallFaces [::GeomCleanup::uniq $wallFaces]
    set deletedFaces [::GeomCleanup::uniq $deletedFaces]
    set out {}
    foreach wall $wallFaces {
        foreach edge [::GeomCleanup::surfaceEdges $wall] {
            if {[::GeomCleanup::contains $floorEdges $edge]} {
                continue
            }
            set owners [::GeomCleanup::edgeOwnerSurfaces $edge]
            set hasOutside 0
            foreach owner $owners {
                if {![::GeomCleanup::contains $deletedFaces $owner]} {
                    set hasOutside 1
                    break
                }
            }
            if {$hasOutside} {
                lappend out $edge
            }
        }
    }
    return [::GeomCleanup::uniq $out]
}

proc ::GeomCleanup::outsideSurfacesFromEdges {edges excludedFaces} {
    set out {}
    set excludedFaces [::GeomCleanup::uniq $excludedFaces]
    foreach edge [::GeomCleanup::uniq $edges] {
        foreach owner [::GeomCleanup::edgeOwnerSurfaces $edge] {
            if {![::GeomCleanup::contains $excludedFaces $owner]} {
                lappend out $owner
            }
        }
    }
    return [::GeomCleanup::uniq $out]
}

proc ::GeomCleanup::existingSurfaces {surfs} {
    set out {}
    foreach surf [::GeomCleanup::uniq $surfs] {
        if {[::GeomCleanup::entityExistsById surfs $surf] || [::GeomCleanup::entityExistsById surfaces $surf]} {
            lappend out $surf
        }
    }
    return [::GeomCleanup::uniq $out]
}

proc ::GeomCleanup::pointDistanceToSurfaces {point surfs} {
    foreach {x y z} $point {}
    set best ""
    foreach surf [::GeomCleanup::uniq $surfs] {
        set distance ""
        if {![catch {set vals [hm_findclosestpointonsurface $x $y $z $surf]}] && [llength $vals] >= 4} {
            set distance [lindex $vals 3]
        } elseif {![catch {set vals [hm_getcoordinatesfromnearestsurface $x $y $z [list $surf]]}] && [llength $vals] >= 3} {
            set distance [::GeomCleanup::dist3 $point [lrange $vals 0 2]]
        }
        if {$distance ne "" && ($best eq "" || $distance < $best)} {
            set best $distance
        }
    }
    return $best
}

proc ::GeomCleanup::loopMaxDistanceToSurfaces {loop surfs} {
    set maximum ""
    foreach edge [::GeomCleanup::uniq $loop] {
        if {[catch {set coords [hm_getcoordinatesofpointsonline $edge {0.0 0.25 0.5 0.75 1.0}]}]} {
            set coords [::GeomCleanup::edgeEndPoints $edge]
        }
        foreach point $coords {
            if {[llength $point] < 3} { continue }
            set distance [::GeomCleanup::pointDistanceToSurfaces [lrange $point 0 2] $surfs]
            if {$distance ne "" && ($maximum eq "" || $distance > $maximum)} {
                set maximum $distance
            }
        }
    }
    if {$maximum eq ""} {
        error [::HWFlow::txt "无法计算沉台内圈到补面的距离。" "Could not calculate the distance from the pocket inner loop to the fill surface."]
    }
    return $maximum
}

proc ::GeomCleanup::loopCenter {loop} {
    set mins {}
    set maxs {}
    foreach edge [::GeomCleanup::uniq $loop] {
        if {[catch {set coords [hm_getcoordinatesofpointsonline $edge {0.0 0.125 0.25 0.375 0.5 0.625 0.75 0.875}]}]} {
            set coords [::GeomCleanup::edgeEndPoints $edge]
        }
        foreach point $coords {
            if {[llength $point] < 3} { continue }
            if {[llength $mins] == 0} {
                set mins [lrange $point 0 2]
                set maxs [lrange $point 0 2]
                continue
            }
            for {set axis 0} {$axis < 3} {incr axis} {
                set value [lindex $point $axis]
                if {$value < [lindex $mins $axis]} {
                    lset mins $axis $value
                }
                if {$value > [lindex $maxs $axis]} {
                    lset maxs $axis $value
                }
            }
        }
    }
    if {[llength $mins] == 0} {
        error [::HWFlow::txt "无法计算沉台内圈中心。" "Could not calculate the pocket inner-loop center."]
    }
    set center {}
    for {set axis 0} {$axis < 3} {incr axis} {
        lappend center [expr {([lindex $mins $axis] + [lindex $maxs $axis]) * 0.5}]
    }
    return $center
}

proc ::GeomCleanup::extendInnerWallsToFill {innerWalls innerLoop fillSurfs} {
    variable ui
    set innerWalls [::GeomCleanup::uniq $innerWalls]
    set innerLoop [::GeomCleanup::uniq $innerLoop]
    set fillSurfs [::GeomCleanup::uniq $fillSurfs]
    if {[llength $innerWalls] == 0 || [llength $innerLoop] == 0 || [llength $fillSurfs] == 0} {
        error [::HWFlow::txt "沉台贯通孔延伸缺少内壁、内圈或目标补面。" "Pocket through-hole extension is missing inner walls, inner-loop edges, or target fill surfaces."]
    }
    set gap [::GeomCleanup::loopMaxDistanceToSurfaces $innerLoop $fillSurfs]
    set maxExtend [expr {max(1.0, $gap * 2.0, $ui(STITCH_TOLERANCE) * 10.0)}]
    ::GeomCleanup::msg [::HWFlow::txt "贯通孔内壁延伸：内壁=$innerWalls，内圈=$innerLoop，目标补面=$fillSurfs，间距=$gap，最大延伸=$maxExtend" "Through-hole wall extension: walls=$innerWalls, inner loop=$innerLoop, target fill=$fillSurfs, gap=$gap, max extension=$maxExtend"]

    catch {*clearmark lines 2}
    catch {*clearmark line 2}
    set sourceType [::GeomCleanup::markList {surfs surfaces} 1 $innerWalls]
    set targetType [::GeomCleanup::markList {surfs surfaces} 2 $fillSurfs]
    set edgeType [::GeomCleanup::markList {lines line} 1 $innerLoop]
    if {$sourceType eq "" || $targetType eq "" || $edgeType eq ""} {
        error [::HWFlow::txt "无法标记沉台内壁延伸所需的内壁、补面或内圈边。" "Could not mark the inner walls, fill surfaces, or inner-loop edges for pocket extension."]
    }

    # Extend mode 3 extends only over the explicitly marked inner-loop edges
    # until the target fill surface is reached. Trim mode 1 trims the extended
    # source walls at the target. Advanced option 0 modifies the original walls
    # and keeps them in their original component.
    set before [::GeomCleanup::latestId {surfs surfaces}]
    set code [catch {
        *connect_surfaces_11 1 2 3 1 0.0 0.1 179.9 1 0 2 $maxExtend 0 0
    } err]
    catch {*clearmark $sourceType 1}
    catch {*clearmark $targetType 2}
    catch {*clearmark $edgeType 1}
    if {$code} {
        error [::HWFlow::txt "沉台内壁延伸到补面失败：$err" "Failed to extend the pocket inner walls to the fill surface: $err"]
    }
    set after [::GeomCleanup::latestId {surfs surfaces}]
    set created [::GeomCleanup::idsCreatedAfter {surfs surfaces} $before $after]
    set result [::GeomCleanup::existingSurfaces [concat $innerWalls $created]]
    if {[llength $result] == 0} {
        error [::HWFlow::txt "内壁延伸命令完成，但无法捕获延伸后的 surface。" "The inner-wall extension completed, but no resulting surfaces could be captured."]
    }
    return $result
}

proc ::GeomCleanup::trimFillWithInnerWalls {fillSurfs innerWalls innerCenter} {
    set fillSurfs [::GeomCleanup::uniq $fillSurfs]
    set innerWalls [::GeomCleanup::uniq $innerWalls]
    set initialCount [llength [::GeomCleanup::existingSurfaces $fillSurfs]]
    set before [::GeomCleanup::latestId {surfs surfaces}]
    set fillType [::GeomCleanup::markList {surfs surfaces} 1 $fillSurfs]
    set wallType [::GeomCleanup::markList {surfs surfaces} 2 $innerWalls]
    if {$fillType eq "" || $wallType eq ""} {
        error [::HWFlow::txt "无法标记贯通孔切割所需的补面或延伸内壁。" "Could not mark the fill surfaces or extended inner walls for through-hole trimming."]
    }
    set code [catch {*surfmark_trim_by_surfmark 1 2 0} err]
    catch {*clearmark $fillType 1}
    catch {*clearmark $wallType 2}
    if {$code} {
        error [::HWFlow::txt "使用延伸内壁切割补面失败：$err" "Failed to trim the fill surfaces with the extended inner walls: $err"]
    }

    set after [::GeomCleanup::latestId {surfs surfaces}]
    set created [::GeomCleanup::idsCreatedAfter {surfs surfaces} $before $after]
    set candidates {}
    foreach surf [::GeomCleanup::uniq [concat $fillSurfs $created]] {
        set candidates [concat $candidates [::GeomCleanup::existingSurfaces [list $surf]]]
    }
    set candidates [::GeomCleanup::uniq $candidates]
    if {[llength $candidates] <= $initialCount} {
        error [::HWFlow::txt "延伸内壁没有把补面分成孔内小面和外部保留面。" "The extended inner walls did not split the fill into an inner patch and an outer retained surface."]
    }

    set holePatch ""
    set holeDistance ""
    set holeArea ""
    foreach surf $candidates {
        set distance [::GeomCleanup::pointDistanceToSurfaces $innerCenter [list $surf]]
        set area [::GeomCleanup::surfaceArea $surf]
        if {$distance eq "" || $area <= 0.0} {
            continue
        }
        if {$holePatch eq "" || $distance < $holeDistance - 1.0e-8 || \
                (abs($distance - $holeDistance) <= 1.0e-8 && $area < $holeArea)} {
            set holePatch $surf
            set holeDistance $distance
            set holeArea $area
        }
    }
    if {$holePatch eq ""} {
        error [::HWFlow::txt "切割后无法识别需要删除的孔内小面。" "Could not identify the inner patch to delete after trimming the fill surface."]
    }
    ::GeomCleanup::deleteSurfaces [list $holePatch]
    set candidates [lsearch -all -inline -not -exact $candidates $holePatch]
    if {[llength $candidates] == 0} {
        error [::HWFlow::txt "删除孔内小面后没有剩余补面。" "No retained fill surface remained after deleting the inner patch."]
    }
    ::GeomCleanup::msg [::HWFlow::txt "贯通孔补面切割：删除孔内小面=$holePatch，保留补面=$candidates" "Through-hole fill trim: deleted inner patch=$holePatch, retained fill surfaces=$candidates"]
    return [::GeomCleanup::uniq $candidates]
}

proc ::GeomCleanup::assertNoFreeEdges {surfs label} {
    set surfs [::GeomCleanup::existingSurfaces $surfs]
    if {[llength $surfs] == 0} {
        error [::HWFlow::txt "$label 在缝合后没有可验证的有效 surface。" "$label has no valid surfaces available for verification after stitching."]
    }
    set freeEdges {}
    foreach surf $surfs {
        foreach edge [::GeomCleanup::surfaceEdges $surf] {
            if {[llength [::GeomCleanup::edgeOwnerSurfaces $edge]] < 2} {
                lappend freeEdges $edge
            }
        }
    }
    set freeEdges [::GeomCleanup::uniq $freeEdges]
    if {[llength $freeEdges] > 0} {
        error [::HWFlow::txt "$label 仍存在自由边：$freeEdges" "$label still contains free edges: $freeEdges"]
    }
    return 1
}

proc ::GeomCleanup::wallsFromLoop {loop seed} {
    set walls {}
    foreach edge $loop {
        foreach owner [::GeomCleanup::edgeOwnerSurfaces $edge] {
            if {$owner ne $seed} {
                lappend walls $owner
            }
        }
    }
    return [::GeomCleanup::uniq $walls]
}

proc ::GeomCleanup::createFillSurfaceFromLines {lineIds} {
    variable ui
    set lineIds [::GeomCleanup::uniq $lineIds]
    if {[llength $lineIds] == 0} {
        error [::HWFlow::txt "未找到可用于补面的边界线。" "No boundary lines found for fill surface."]
    }
    set before [::GeomCleanup::latestId {surfs surfaces}]
    set markType [::GeomCleanup::markList {lines line} 1 $lineIds]
    if {$markType eq ""} {
        error [::HWFlow::txt "无法标记补面边界线。" "Could not mark fill boundary lines."]
    }

    set errSpline ""
    set errPatch ""
    set errPinhole ""
    if {$ui(POCKET_FILL_METHOD) eq "SPLINE"} {
        catch {*surfacemode 4}
        catch {*createplane 1 0.0 0.0 1.0 0.0 0.0 0.0}
        if {[catch {*splinesurface lines 1 0 1 1} errSpline]} {
            if {[catch {*surface_patch line_mark=1 tangency=best_fit stitch=1 solid_stitch=1 dest_component=original} errPatch]} {
                if {[catch {*linemarkremovepinholes 1 1} errPinhole]} {
                    catch {*clearmark $markType 1}
                    error [::HWFlow::txt "沉台补面失败：spline=$errSpline；patch=$errPatch；pinhole=$errPinhole" "Pocket fill failed: spline=$errSpline; patch=$errPatch; pinhole=$errPinhole"]
                }
            }
        }
    } else {
        if {[catch {*linemarkremovepinholes 1 1} errPinhole]} {
            catch {*surfacemode 4}
            catch {*createplane 1 0.0 0.0 1.0 0.0 0.0 0.0}
            if {[catch {*splinesurface lines 1 0 1 1} errSpline]} {
                catch {*clearmark $markType 1}
                error [::HWFlow::txt "沉台补面失败：pinhole=$errPinhole；spline=$errSpline" "Pocket fill failed: pinhole=$errPinhole; spline=$errSpline"]
            }
        }
    }
    catch {*clearmark $markType 1}

    set after [::GeomCleanup::latestId {surfs surfaces}]
    set newSurfs [::GeomCleanup::idsCreatedAfter {surfs surfaces} $before $after]
    if {[llength $newSurfs] == 0 && $after > $before} {
        set newSurfs [list $after]
    }
    if {[llength $newSurfs] == 0} {
        error [::HWFlow::txt "补面命令未返回新建 surface。" "The fill operation did not produce a new surface."]
    }
    return $newSurfs
}

proc ::GeomCleanup::removePocket {seed} {
    variable ui
    variable stat
    set compId [::GeomCleanup::surfaceComponentId $seed]
    if {$compId eq ""} {
        error [::HWFlow::txt "无法读取沉台底面所属 component。" "Could not determine the component of the pocket floor."]
    }
    set loops [::GeomCleanup::sortLoopsByPerimeter [::GeomCleanup::surfaceLoops $seed]]
    if {[llength $loops] == 0} {
        error [::HWFlow::txt "所选沉台面没有可读取的边界线。" "Selected pocket face has no readable boundary edges."]
    }
    set outerLoop [lindex $loops 0]
    set innerLoops [lrange $loops 1 end]
    if {!$ui(POCKET_KEEP_INNER_LOOPS)} {
        set innerLoops {}
    }

    set outerWalls [::GeomCleanup::wallsFromLoop $outerLoop $seed]
    if {[llength $outerWalls] == 0} {
        error [::HWFlow::txt "未找到沉台底面与周围正常面的竖直连接面。" "Could not find wall surfaces between pocket floor and surrounding face."]
    }

    set floorEdges $outerLoop
    set deleteFaces [::GeomCleanup::uniq [concat [list $seed] $outerWalls]]
    set fillLines [::GeomCleanup::topEdgesFromWallFaces $floorEdges $outerWalls $deleteFaces]

    set keptInnerWalls {}
    set innerWallGroups {}
    foreach loop $innerLoops {
        set innerWalls [::GeomCleanup::wallsFromLoop $loop $seed]
        if {[llength $innerWalls] == 0} {
            error [::HWFlow::txt "未找到沉台内圈对应的贯通孔内壁。" "Could not find the through-hole inner walls attached to a pocket inner loop."]
        }
        lappend innerWallGroups $innerWalls
        set keptInnerWalls [concat $keptInnerWalls $innerWalls]
    }
    set keptInnerWalls [::GeomCleanup::uniq $keptInnerWalls]
    set fillLines [::GeomCleanup::uniq $fillLines]
    if {[llength $fillLines] == 0} {
        error [::HWFlow::txt "未找到沉台顶面补平边界线。" "Could not find top boundary lines for pocket fill."]
    }
    set surroundingSurfs [::GeomCleanup::outsideSurfacesFromEdges $fillLines $deleteFaces]
    if {[llength $surroundingSurfs] == 0} {
        error [::HWFlow::txt "未找到与沉台顶边相邻的周围承接面。" "Could not find surrounding surfaces adjacent to the pocket top boundary."]
    }

    set stat(mode) POCKET
    set stat(targetSurfs) $deleteFaces
    set constructionLines [::GeomCleanup::copyLinesOrEdgesToSourceComponent $fillLines [::HWFlow::txt "沉台补面" "Pocket fill"]]
    ::GeomCleanup::msg [::HWFlow::txt "沉台底面：$seed；删除外圈竖直面：$outerWalls；待延伸内部竖直面：$keptInnerWalls；补面边界：$fillLines；周围承接面：$surroundingSurfs；构造线：$constructionLines" "Pocket floor: $seed; deleting outer walls: $outerWalls; inner walls to extend: $keptInnerWalls; fill edges: $fillLines; surrounding surfaces: $surroundingSurfs; construction lines: $constructionLines"]

    set newSurfs {}
    set cleanupLines 1
    set code [catch {
        ::GeomCleanup::deleteSurfaces $deleteFaces
        set newSurfs [::GeomCleanup::createFillSurfaceFromLines $constructionLines]
        ::GeomCleanup::organizeSurfacesToComponent $newSurfs $compId
    } err opts]
    if {$cleanupLines} {
        catch {::GeomCleanup::deleteConstructionLines $constructionLines}
    }
    if {$code} {
        return -options $opts $err
    }
    set extendedInnerWalls {}
    for {set i 0} {$i < [llength $innerLoops]} {incr i} {
        set loop [lindex $innerLoops $i]
        set loopWalls [lindex $innerWallGroups $i]
        set loopWalls [::GeomCleanup::existingSurfaces $loopWalls]
        if {[llength $loopWalls] == 0} {
            error [::HWFlow::txt "删除沉台后，贯通孔内壁 surface 已失效。" "The through-hole inner-wall surfaces became invalid after deleting the pocket."]
        }
        set innerCenter [::GeomCleanup::loopCenter $loop]
        set loopWalls [::GeomCleanup::extendInnerWallsToFill $loopWalls $loop $newSurfs]
        if {[llength $loopWalls] == 0} {
            error [::HWFlow::txt "沉台内壁延伸后没有保留有效 surface。" "No valid inner-wall surfaces remained after pocket extension."]
        }
        set newSurfs [::GeomCleanup::trimFillWithInnerWalls $newSurfs $loopWalls $innerCenter]
        set extendedInnerWalls [concat $extendedInnerWalls $loopWalls]
    }
    set extendedInnerWalls [::GeomCleanup::uniq $extendedInnerWalls]
    ::GeomCleanup::organizeSurfacesToComponent $newSurfs $compId
    set stitchSet [::GeomCleanup::uniq [concat $newSurfs $surroundingSurfs $keptInnerWalls $extendedInnerWalls]]
    if {![::GeomCleanup::stitchSurfaces $stitchSet]} {
        error [::HWFlow::txt "沉台贯通孔最终缝合失败。" "Final stitching of the repaired pocket through-hole failed."]
    }
    if {[llength $extendedInnerWalls] > 0} {
        ::GeomCleanup::assertNoFreeEdges $extendedInnerWalls [::HWFlow::txt "沉台贯通孔内壁" "Pocket through-hole wall"]
    }
    ::GeomCleanup::msg [::HWFlow::txt "贯通孔修复：原内壁已延伸到补面并切除孔内小面；延伸内壁=$extendedInnerWalls，最终缝合集合=$stitchSet" "Through-hole repair: original inner walls were extended to the fill and the inner patches were removed; extended inner walls=$extendedInnerWalls, final stitch set=$stitchSet"]
    set newSolids {}
    set stat(newSurfs) $newSurfs
    set stat(newSolids) $newSolids
    return [dict create mode POCKET deleted_surfs $deleteFaces fill_lines $fillLines new_surfs $stat(newSurfs) new_solids $newSolids]
}

proc ::GeomCleanup::autoModeHint {seed} {
    set fillets [::GeomCleanup::filletCandidatesForSelected $seed]
    if {[::GeomCleanup::contains $fillets $seed]} {
        return CHAMFER
    }
    set loops [::GeomCleanup::surfaceLoops $seed]
    if {[llength $loops] >= 2} {
        return POCKET
    }
    return CHAMFER
}

proc ::GeomCleanup::resetStats {} {
    variable stat
    catch {array unset stat}
    array set stat {
        mode ""
        targetSurfs {}
        newSurfs {}
        newSolids {}
    }
}

proc ::GeomCleanup::processSurface {seed} {
    variable ui
    variable stat
    ::GeomCleanup::resetStats
    set historyName "Geometry Cleanup Surface $seed"
    set historyStarted 0
    if {![catch {*startnotehistorystate $historyName}]} {
        set historyStarted 1
    }
    set code [catch {
        ::GeomCleanup::beginPerformanceMode
        set mode $ui(MODE)
        if {$mode eq "AUTO"} {
            set mode [::GeomCleanup::autoModeHint $seed]
        }
        ::GeomCleanup::msg [::HWFlow::txt "开始处理面 $seed，模式：$mode。" "Processing surface $seed in $mode mode."]

        if {$ui(MODE) eq "AUTO"} {
            if {$mode eq "CHAMFER"} {
                set errChamfer ""
                if {[catch {set result [::GeomCleanup::removeChamfer $seed]} errChamfer]} {
                    ::GeomCleanup::msg [::HWFlow::txt "自动倒角清理未成功：$errChamfer；改用沉台补平流程。" "Auto chamfer cleanup did not succeed: $errChamfer; trying pocket fill."]
                    set result [::GeomCleanup::removePocket $seed]
                }
            } else {
                set result [::GeomCleanup::removePocket $seed]
            }
        } elseif {$mode eq "CHAMFER"} {
            set result [::GeomCleanup::removeChamfer $seed]
        } else {
            set result [::GeomCleanup::removePocket $seed]
        }
        ::HWFlow::refreshBrowser
    } err opts]

    ::GeomCleanup::endPerformanceMode
    if {$historyStarted} {
        catch {*endnotehistorystate $historyName}
    }
    if {$code} {
        if {$historyStarted} {
            catch {*undohistorystate 1}
            catch {::HWFlow::refreshBrowser}
        }
        return -options $opts $err
    }

    set msg [::HWFlow::txt "面 $seed 清理完成：模式=$stat(mode)，处理面=$stat(targetSurfs)，新建/补充 surface=$stat(newSurfs)，新建/补充 solid=$stat(newSolids)。请继续选择下一个面。" "Surface $seed cleaned: mode=$stat(mode), target surfaces=$stat(targetSurfs), new/repaired surfaces=$stat(newSurfs), new/repaired solids=$stat(newSolids). Select the next face."]
    ::GeomCleanup::msg $msg
    return $result
}

proc ::GeomCleanup::continuousCleanup {} {
    variable ui
    set completed 0
    set failed 0
    catch {hm_usermessage [::HWFlow::txt "连续几何清洗已启动：选择一个面并按中键执行；取消选择即可退出。" "Continuous geometry cleanup started: select one face and middle-click; cancel selection to exit."]}

    while {1} {
        set selectCode [catch {set seed [::GeomCleanup::selectedSurface]} selectErr]
        if {$selectCode} {
            incr failed
            ::GeomCleanup::msg [::HWFlow::txt "选择无效：$selectErr；请重新选择一个面。" "Invalid selection: $selectErr; select one face again."]
            continue
        }
        if {$seed eq ""} {
            break
        }

        set runCode [catch {::GeomCleanup::processSurface $seed} runErr]
        if {$runCode} {
            incr failed
            ::GeomCleanup::msg [::HWFlow::txt "面 $seed 执行失败：$runErr；已继续等待下一次选面。" "Surface $seed failed: $runErr; waiting for the next selection."]
        } else {
            incr completed
        }
    }

    ::GeomCleanup::saveState
    ::HWFlow::refreshBrowser
    catch {hm_usermessage [::HWFlow::txt "连续几何清洗已退出：完成 $completed 次，失败 $failed 次。" "Continuous geometry cleanup exited: $completed completed, $failed failed."]}
    ::GeomCleanup::msg [::HWFlow::txt "连续清洗退出：完成=$completed，失败=$failed。" "Continuous cleanup exited: completed=$completed, failed=$failed."]
}

proc ::GeomCleanup::main {} {
    if {![::GeomCleanup::showPanel]} {
        catch {hm_usermessage [::HWFlow::txt "几何清理已取消。" "Geometry Cleanup cancelled."]}
        return
    }
    ::GeomCleanup::continuousCleanup
}

proc ::GeomCleanup::run {} {
    ::GeomCleanup::main
}
