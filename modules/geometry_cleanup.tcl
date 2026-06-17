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
        {pocket_keep_inner_loops|1|keep inner pocket loops as trim boundaries when possible}
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
    checkbutton $w.main.opt.inner -text [::HWFlow::txt "沉台补平时保留内部边界线环" "Keep inner boundary loops while filling pocket"] -variable ::GeomCleanup::ui(POCKET_KEEP_INNER_LOOPS)
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
    button $w.btn.start -text [::HWFlow::txt "开始" "Start"] -width 10 -command "::GeomCleanup::acceptPanel"
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
    if {[llength [info commands ::HWFlow::progressAppend]] > 0} {
        catch {::HWFlow::progressAppend "GeomCleanup: $text"}
    }
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
    *createmarkpanel surfs 1 [::HWFlow::txt "请选择一个需要清理的面（倒角面或沉台底面）" "Select one face to clean (chamfer face or recessed pocket floor)"]
    set ids [hm_getmark surfs 1]
    catch {*clearmark surfs 1}
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

proc ::GeomCleanup::copyLineOrEdgeToCurrent {lineId} {
    set before [::GeomCleanup::latestId {lines line}]
    catch {*clearmark lines 1}
    if {[catch {*createmark lines 1 $lineId}]} {
        catch {*clearmark lines 1}
        return ""
    }
    catch {*linefromsurfedgecomp lines 1 1}
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

proc ::GeomCleanup::copyLinesOrEdgesToCurrent {lineIds label} {
    set out {}
    set failed {}
    foreach lineId [::GeomCleanup::uniq $lineIds] {
        set copied [::GeomCleanup::copyLineOrEdgeToCurrent $lineId]
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
    return $newSurfs
}

proc ::GeomCleanup::removePocket {seed} {
    variable ui
    variable stat
    set compId [::GeomCleanup::surfaceComponentId $seed]
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
    foreach loop $innerLoops {
        set innerWalls [::GeomCleanup::wallsFromLoop $loop $seed]
        set keptInnerWalls [concat $keptInnerWalls $innerWalls]
        set fillLines [concat $fillLines [::GeomCleanup::topEdgesFromWallFaces $loop $innerWalls [list $seed]]]
    }
    set keptInnerWalls [::GeomCleanup::uniq $keptInnerWalls]
    set fillLines [::GeomCleanup::uniq $fillLines]
    if {[llength $fillLines] == 0} {
        error [::HWFlow::txt "未找到沉台顶面补平边界线。" "Could not find top boundary lines for pocket fill."]
    }

    set stat(mode) POCKET
    set stat(targetSurfs) $deleteFaces
    set constructionLines [::GeomCleanup::copyLinesOrEdgesToCurrent $fillLines [::HWFlow::txt "沉台补面" "Pocket fill"]]
    ::GeomCleanup::msg [::HWFlow::txt "沉台底面：$seed；删除外圈竖直面：$outerWalls；保留内部竖直面：$keptInnerWalls；补面边界：$fillLines；构造线：$constructionLines" "Pocket floor: $seed; deleting outer walls: $outerWalls; keeping inner walls: $keptInnerWalls; fill edges: $fillLines; construction lines: $constructionLines"]

    set newSurfs {}
    set cleanupLines 1
    set code [catch {
        ::GeomCleanup::deleteSurfaces $deleteFaces
        set newSurfs [::GeomCleanup::createFillSurfaceFromLines $constructionLines]
    } err opts]
    if {$cleanupLines} {
        catch {::GeomCleanup::deleteConstructionLines $constructionLines}
    }
    if {$code} {
        return -options $opts $err
    }
    set stitchSet [::GeomCleanup::uniq [concat $newSurfs $keptInnerWalls]]
    ::GeomCleanup::stitchSurfaces $stitchSet
    set newSolids {}
    set stat(newSurfs) $newSurfs
    set stat(newSolids) $newSolids
    return [dict create mode POCKET deleted_surfs $deleteFaces fill_lines $fillLines new_surfs $newSurfs new_solids $newSolids]
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

proc ::GeomCleanup::main {} {
    variable ui
    variable stat
    if {![::GeomCleanup::showPanel]} {
        catch {hm_usermessage [::HWFlow::txt "几何清理已取消。" "Geometry Cleanup cancelled."]}
        return
    }
    ::GeomCleanup::resetStats

    set progressOpened 0
    if {[llength [info commands ::HWFlow::progressOpen]] > 0} {
        set progressOpened [::HWFlow::progressOpen \
            [::HWFlow::txt "几何清理" "Geometry Cleanup"] \
            [::HWFlow::txt "准备选择待清理面..." "Preparing face selection..."] \
            0]
    }

    set code [catch {
        set seed [::GeomCleanup::selectedSurface]
        ::GeomCleanup::beginPerformanceMode
        set mode $ui(MODE)
        if {$mode eq "AUTO"} {
            set mode [::GeomCleanup::autoModeHint $seed]
        }
        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 25.0 [::HWFlow::txt "正在执行几何清理" "Running geometry cleanup"] [::HWFlow::txt "所选面：$seed；模式：$mode" "Selected surface: $seed; mode: $mode"] 1}
        }

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

        if {$progressOpened} {
            catch {::HWFlow::progressUpdate 90.0 [::HWFlow::txt "正在刷新结果" "Refreshing result"] "" 1}
        }
        ::HWFlow::refreshBrowser
    } err opts]

    ::GeomCleanup::endPerformanceMode
    if {$code} {
        if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
            catch {::HWFlow::progressClose [::HWFlow::txt "几何清理失败。" "Geometry cleanup failed."] 100.0}
        }
        tk_messageBox -icon error -title [::HWFlow::txt "几何清理" "Geometry Cleanup"] -message [::HWFlow::txt "执行失败：\n$err" "Run failed:\n$err"]
        return -options $opts $err
    }

    set msg [::HWFlow::txt "几何清理已完成。\n模式：$stat(mode)\n处理面：$stat(targetSurfs)\n新建/补充 surface：$stat(newSurfs)\n新建/补充 solid：$stat(newSolids)" "Geometry cleanup finished.\nMode: $stat(mode)\nTarget surfaces: $stat(targetSurfs)\nNew/repaired surfaces: $stat(newSurfs)\nNew/repaired solids: $stat(newSolids)"]
    ::GeomCleanup::saveState
    if {$progressOpened && [llength [info commands ::HWFlow::progressClose]] > 0} {
        catch {::HWFlow::progressClose [::HWFlow::txt "几何清理已完成。" "Geometry cleanup finished."] 100.0}
    }
    tk_messageBox -icon info -title [::HWFlow::txt "几何清理" "Geometry Cleanup"] -message $msg
    ::GeomCleanup::msg $msg
}

proc ::GeomCleanup::run {} {
    ::GeomCleanup::main
}
