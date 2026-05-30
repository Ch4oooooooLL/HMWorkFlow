# ======================================================================
# AutoHoleRBE2 v1.0
# HyperMesh 2019 Tcl
#
# 功能：
#   对已完成 3D 实体网格的 component，自动识别表面普通圆柱贯通孔，
#   选取孔壁节点，计算孔中心，创建中心节点，并生成 RBE2 / rigidlink。
#
# 适用：
#   - 普通圆柱贯通螺栓孔
#   - 3D solid 网格表面的孔壁节点
#
# 不建议用于：
#   - 沉台孔、强倒角孔、长圆孔、异形孔、多段复杂孔
#   - 表面拓扑破损、重复自由面严重的模型
#
# 使用：
#   File > Run > Tcl/Tk Script > 选择本脚本
# ======================================================================

namespace eval ::AutoHoleRBE2 {
    variable VERSION "1.0"

    variable cfg
    array set cfg {
        featureAngleDeg      78.0
        loopNormalTolDeg     35.0
        cylFitTol            0.25
        loopRadiusTol        0.35
        minWallNodes         6
        minLoopNodes         4
        minRadius            0.0
        maxRadius            0.0
        dof                  123456
        requireInnerNormal   0
        innerNormalMaxDot   -0.05

        preDeleteOldFaces    1
        deleteTempFaces      1
        saveLog              1

        faceCompName         ^faces
        resultCompName       RBE2_HOLE_AUTO
        eps                  1.0e-9
        logFile              ""
        logChan              ""
    }

    variable ui
    array set ui {
        ok 0
        selectedComps ""
        selectedText "未选择"
    }

    variable stat
    array set stat {}
}

# ----------------------------------------------------------------------
# User Interface
# ----------------------------------------------------------------------

proc ::AutoHoleRBE2::showPanel {} {
    variable cfg
    variable ui
    variable VERSION

    catch {destroy .autoHoleRBE2}

    foreach k [array names cfg] {
        set ui($k) $cfg($k)
    }

    set ui(ok) 0
    set ui(selectedComps) ""
    set ui(selectedText) "未选择"

    set w .autoHoleRBE2
    toplevel $w
    wm title $w "AutoHoleRBE2 v$VERSION"
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1

    label $w.main.title -text "贯通孔自动创建 RBE2" -font {Arial 10 bold}
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.sel -text "1. Component 选择" -padx 8 -pady 8
    grid $w.main.sel -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    button $w.main.sel.pick -text "选择 / 重选 Component" -width 22 -command "::AutoHoleRBE2::pickComponents"
    label $w.main.sel.info -textvariable ::AutoHoleRBE2::ui(selectedText) -width 72 -anchor w

    grid $w.main.sel.pick -row 0 -column 0 -sticky w -padx {0 8}
    grid $w.main.sel.info -row 0 -column 1 -sticky w

    labelframe $w.main.preset -text "2. 参数预设" -padx 8 -pady 8
    grid $w.main.preset -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    button $w.main.preset.normal -text "默认" -width 12 -command "::AutoHoleRBE2::applyPreset normal"
    button $w.main.preset.loose  -text "放宽" -width 12 -command "::AutoHoleRBE2::applyPreset loose"
    button $w.main.preset.strict -text "严格" -width 12 -command "::AutoHoleRBE2::applyPreset strict"

    grid $w.main.preset.normal -row 0 -column 0 -sticky w -padx {0 6}
    grid $w.main.preset.loose  -row 0 -column 1 -sticky w -padx {0 6}
    grid $w.main.preset.strict -row 0 -column 2 -sticky w

    labelframe $w.main.param -text "3. 识别参数" -padx 8 -pady 8
    grid $w.main.param -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    set fields {
        {featureAngleDeg  "平滑面片角度"}
        {cylFitTol        "圆柱拟合容差"}
        {loopRadiusTol    "两端半径差容差"}
        {loopNormalTolDeg "孔口法向容差"}
        {minWallNodes     "孔壁最少节点"}
        {minLoopNodes     "孔口最少节点"}
        {minRadius        "最小孔半径"}
        {maxRadius        "最大孔半径"}
        {dof              "RBE2 自由度"}
        {resultCompName   "结果 Component"}
    }

    set i 0
    foreach item $fields {
        set key  [lindex $item 0]
        set name [lindex $item 1]

        set r [expr {$i / 2}]
        set c [expr {($i % 2) * 2}]

        label $w.main.param.l_$key -text $name -anchor w
        entry $w.main.param.e_$key -textvariable ::AutoHoleRBE2::ui($key) -width 18

        grid $w.main.param.l_$key -row $r -column $c -sticky w -padx {0 6} -pady 2
        grid $w.main.param.e_$key -row $r -column [expr {$c+1}] -sticky w -padx {0 18} -pady 2

        incr i
    }

    labelframe $w.main.opt -text "4. 选项" -padx 8 -pady 8
    grid $w.main.opt -row 4 -column 0 -columnspan 4 -sticky ew -pady {0 8}

    checkbutton $w.main.opt.inner -text "内孔法向判断" \
        -variable ::AutoHoleRBE2::ui(requireInnerNormal)
    checkbutton $w.main.opt.pre -text "运行前清理 ^faces" \
        -variable ::AutoHoleRBE2::ui(preDeleteOldFaces)
    checkbutton $w.main.opt.del -text "运行后清理 ^faces" \
        -variable ::AutoHoleRBE2::ui(deleteTempFaces)
    checkbutton $w.main.opt.log -text "保存日志" \
        -variable ::AutoHoleRBE2::ui(saveLog)

    grid $w.main.opt.inner -row 0 -column 0 -columnspan 2 -sticky w -pady 2
    grid $w.main.opt.pre   -row 1 -column 0 -sticky w -pady 2
    grid $w.main.opt.del   -row 1 -column 1 -sticky w -pady 2
    grid $w.main.opt.log   -row 2 -column 0 -sticky w -pady 2

    frame $w.btn -padx 12 -pady 10
    pack $w.btn -fill x

    button $w.btn.cancel -text "取消" -width 10 -command "set ::AutoHoleRBE2::ui(ok) 0; destroy .autoHoleRBE2"
    button $w.btn.start  -text "开始创建 RBE2" -width 18 -command "::AutoHoleRBE2::acceptPanel"

    pack $w.btn.cancel -side right -padx 4
    pack $w.btn.start  -side right -padx 4

    bind $w <Escape> "set ::AutoHoleRBE2::ui(ok) 0; destroy .autoHoleRBE2"

    update idletasks
    set sw [winfo screenwidth $w]
    set sh [winfo screenheight $w]
    set ww [winfo reqwidth $w]
    set wh [winfo reqheight $w]
    wm geometry $w +[expr {($sw-$ww)/2}]+[expr {($sh-$wh)/2}]

    tkwait window $w
    return $ui(ok)
}

proc ::AutoHoleRBE2::pickComponents {} {
    variable ui

    catch {*clearmark comps 1}
    *createmarkpanel comps 1 "请选择实体网格 Component"
    set comps [hm_getmark comps 1]

    if {[llength $comps] == 0} {
        set ui(selectedComps) ""
        set ui(selectedText) "未选择"
    } else {
        set ui(selectedComps) $comps
        set ui(selectedText) "已选择 [llength $comps] 个 Component"
    }

    catch {raise .autoHoleRBE2}
    catch {focus .autoHoleRBE2}
}

proc ::AutoHoleRBE2::applyPreset {mode} {
    variable ui

    switch -- $mode {
        strict {
            set ui(featureAngleDeg) 60.0
            set ui(cylFitTol) 0.15
            set ui(loopRadiusTol) 0.20
            set ui(loopNormalTolDeg) 30.0
            set ui(minWallNodes) 8
            set ui(minLoopNodes) 6
            set ui(requireInnerNormal) 1
        }
        loose {
            set ui(featureAngleDeg) 88.0
            set ui(cylFitTol) 0.35
            set ui(loopRadiusTol) 0.45
            set ui(loopNormalTolDeg) 45.0
            set ui(minWallNodes) 5
            set ui(minLoopNodes) 4
            set ui(requireInnerNormal) 0
        }
        default {
            set ui(featureAngleDeg) 78.0
            set ui(cylFitTol) 0.25
            set ui(loopRadiusTol) 0.35
            set ui(loopNormalTolDeg) 35.0
            set ui(minWallNodes) 6
            set ui(minLoopNodes) 4
            set ui(requireInnerNormal) 0
        }
    }
}

proc ::AutoHoleRBE2::acceptPanel {} {
    variable cfg
    variable ui

    if {[llength $ui(selectedComps)] == 0} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "请先选择 Component。"
        return
    }

    set doubleKeys {
        featureAngleDeg loopNormalTolDeg cylFitTol loopRadiusTol
        minRadius maxRadius innerNormalMaxDot
    }
    foreach k $doubleKeys {
        if {![string is double -strict $ui($k)]} {
            tk_messageBox -icon warning -title "AutoHoleRBE2" -message "$k 必须是数字。"
            return
        }
    }

    set intKeys {
        minWallNodes minLoopNodes dof requireInnerNormal
        preDeleteOldFaces deleteTempFaces saveLog
    }
    foreach k $intKeys {
        if {![string is integer -strict $ui($k)]} {
            tk_messageBox -icon warning -title "AutoHoleRBE2" -message "$k 必须是整数。"
            return
        }
    }

    if {$ui(featureAngleDeg) <= 0 || $ui(featureAngleDeg) >= 180} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "平滑面片角度需要在 0~180 之间。"
        return
    }

    if {$ui(loopNormalTolDeg) <= 0 || $ui(loopNormalTolDeg) >= 90} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "孔口法向容差需要在 0~90 之间。"
        return
    }

    if {$ui(cylFitTol) < 0 || $ui(loopRadiusTol) < 0} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "容差不能小于 0。"
        return
    }

    if {$ui(minWallNodes) < 3 || $ui(minLoopNodes) < 3} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "节点数量阈值至少为 3。"
        return
    }

    if {$ui(minRadius) < 0 || $ui(maxRadius) < 0} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "半径限制不能小于 0。"
        return
    }

    if {$ui(maxRadius) > 0 && $ui(minRadius) > $ui(maxRadius)} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "最小孔半径不能大于最大孔半径。"
        return
    }

    if {[string trim $ui(resultCompName)] eq ""} {
        tk_messageBox -icon warning -title "AutoHoleRBE2" -message "结果 Component 名称不能为空。"
        return
    }

    foreach k [array names ui] {
        if {$k eq "ok" || $k eq "selectedText" || $k eq "selectedComps"} {
            continue
        }
        set cfg($k) $ui($k)
    }

    set ui(ok) 1
    destroy .autoHoleRBE2
}

# ----------------------------------------------------------------------
# Log
# ----------------------------------------------------------------------

proc ::AutoHoleRBE2::initLog {} {
    variable cfg
    variable VERSION

    set cfg(logChan) ""
    set cfg(logFile) ""

    if {!$cfg(saveLog)} {
        return
    }

    set ts [clock format [clock seconds] -format "%Y%m%d_%H%M%S"]
    set fileName "AutoHoleRBE2_v${VERSION}_${ts}.log"
    set filePath [file normalize [file join [pwd] $fileName]]

    if {[catch {open $filePath w} ch]} {
        puts "WARN: 无法创建日志文件：$ch"
        return
    }

    set cfg(logChan) $ch
    set cfg(logFile) $filePath

    puts $ch "AutoHoleRBE2 v$VERSION"
    puts $ch "Time: [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S"]"
    puts $ch "Working directory: [pwd]"
    puts $ch ""
    puts $ch "Parameters:"
    foreach k [lsort [array names cfg]] {
        if {$k eq "logChan"} {
            continue
        }
        puts $ch "  $k = $cfg($k)"
    }
    puts $ch ""
    flush $ch
}

proc ::AutoHoleRBE2::closeLog {} {
    variable cfg

    if {$cfg(logChan) ne ""} {
        catch {flush $cfg(logChan)}
        catch {close $cfg(logChan)}
        set cfg(logChan) ""
    }
}

proc ::AutoHoleRBE2::log {level msg} {
    variable cfg

    set line "[clock format [clock seconds] -format "%H:%M:%S"] $level $msg"
    puts $line

    if {$cfg(logChan) ne ""} {
        puts $cfg(logChan) $line
        flush $cfg(logChan)
    }
}

proc ::AutoHoleRBE2::message {msg} {
    ::AutoHoleRBE2::log "INFO" $msg
    catch {hm_usermessage $msg}
}

proc ::AutoHoleRBE2::warning {msg} {
    ::AutoHoleRBE2::log "WARN" $msg
    catch {hm_usermessage $msg}
}

# ----------------------------------------------------------------------
# Math / topology helpers
# ----------------------------------------------------------------------

proc ::AutoHoleRBE2::uniq {lst} {
    set out {}
    array set seen {}

    foreach v $lst {
        if {![info exists seen($v)]} {
            set seen($v) 1
            lappend out $v
        }
    }

    return $out
}

proc ::AutoHoleRBE2::edgeKey {a b} {
    if {$a < $b} {
        return "${a}_${b}"
    }
    return "${b}_${a}"
}

proc ::AutoHoleRBE2::edgeNodes {edgeKey} {
    return [split $edgeKey "_"]
}

proc ::AutoHoleRBE2::vdot {a b} {
    return [expr {
        [lindex $a 0]*[lindex $b 0] +
        [lindex $a 1]*[lindex $b 1] +
        [lindex $a 2]*[lindex $b 2]
    }]
}

proc ::AutoHoleRBE2::vcross {a b} {
    set ax [lindex $a 0]
    set ay [lindex $a 1]
    set az [lindex $a 2]
    set bx [lindex $b 0]
    set by [lindex $b 1]
    set bz [lindex $b 2]

    return [list \
        [expr {$ay*$bz - $az*$by}] \
        [expr {$az*$bx - $ax*$bz}] \
        [expr {$ax*$by - $ay*$bx}] \
    ]
}

proc ::AutoHoleRBE2::vadd {a b} {
    return [list \
        [expr {[lindex $a 0] + [lindex $b 0]}] \
        [expr {[lindex $a 1] + [lindex $b 1]}] \
        [expr {[lindex $a 2] + [lindex $b 2]}] \
    ]
}

proc ::AutoHoleRBE2::vsub {a b} {
    return [list \
        [expr {[lindex $a 0] - [lindex $b 0]}] \
        [expr {[lindex $a 1] - [lindex $b 1]}] \
        [expr {[lindex $a 2] - [lindex $b 2]}] \
    ]
}

proc ::AutoHoleRBE2::vscale {a s} {
    return [list \
        [expr {[lindex $a 0] * $s}] \
        [expr {[lindex $a 1] * $s}] \
        [expr {[lindex $a 2] * $s}] \
    ]
}

proc ::AutoHoleRBE2::vnorm {a} {
    return [expr {sqrt([::AutoHoleRBE2::vdot $a $a])}]
}

proc ::AutoHoleRBE2::vnormalize {a} {
    variable cfg

    set n [::AutoHoleRBE2::vnorm $a]
    if {$n < $cfg(eps)} {
        return {0.0 0.0 0.0}
    }

    return [::AutoHoleRBE2::vscale $a [expr {1.0/$n}]]
}

proc ::AutoHoleRBE2::nodeXYZ {nodeId} {
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

    error "无法读取节点 $nodeId 坐标。"
}

proc ::AutoHoleRBE2::elemNodes {elemId} {
    if {![catch {hm_getvalue elems id=$elemId dataname=nodes} nodes]} {
        return $nodes
    }

    if {![catch {hm_nodelist $elemId} nodes]} {
        return $nodes
    }

    error "无法读取单元 $elemId 的节点。"
}

proc ::AutoHoleRBE2::elemConfig {elemId} {
    if {![catch {hm_getvalue elems id=$elemId dataname=config} cfg]} {
        return $cfg
    }
    return ""
}

proc ::AutoHoleRBE2::isSolidElem {elemId} {
    set cfg [::AutoHoleRBE2::elemConfig $elemId]

    if {[lsearch -exact {204 205 206 208 210 213 215 220} $cfg] >= 0} {
        return 1
    }

    set cfgText [string tolower $cfg]
    if {[regexp {(tetra|tet|penta|wedge|hex|hexa|pyramid|solid)} $cfgText]} {
        return 1
    }

    return 0
}

proc ::AutoHoleRBE2::faceEdges {nodes} {
    set edges {}
    set count [llength $nodes]

    for {set i 0} {$i < $count} {incr i} {
        set n1 [lindex $nodes $i]
        set n2 [lindex $nodes [expr {($i+1)%$count}]]
        lappend edges [::AutoHoleRBE2::edgeKey $n1 $n2]
    }

    return $edges
}

proc ::AutoHoleRBE2::faceNormal {nodes} {
    variable cfg

    set p0 [::AutoHoleRBE2::nodeXYZ [lindex $nodes 0]]
    set n [llength $nodes]

    for {set i 1} {$i < [expr {$n-1}]} {incr i} {
        set p1 [::AutoHoleRBE2::nodeXYZ [lindex $nodes $i]]
        set p2 [::AutoHoleRBE2::nodeXYZ [lindex $nodes [expr {$i+1}]]]
        set cr [::AutoHoleRBE2::vcross \
            [::AutoHoleRBE2::vsub $p1 $p0] \
            [::AutoHoleRBE2::vsub $p2 $p0] \
        ]

        if {[::AutoHoleRBE2::vnorm $cr] > $cfg(eps)} {
            return [::AutoHoleRBE2::vnormalize $cr]
        }
    }

    return {0.0 0.0 0.0}
}

proc ::AutoHoleRBE2::centroidNodes {nodes} {
    set sx 0.0
    set sy 0.0
    set sz 0.0
    set n [llength $nodes]

    foreach nodeId $nodes {
        set p [::AutoHoleRBE2::nodeXYZ $nodeId]
        set sx [expr {$sx + [lindex $p 0]}]
        set sy [expr {$sy + [lindex $p 1]}]
        set sz [expr {$sz + [lindex $p 2]}]
    }

    return [list [expr {$sx/double($n)}] [expr {$sy/double($n)}] [expr {$sz/double($n)}]]
}

proc ::AutoHoleRBE2::loopNormal {loopNodes} {
    set nx 0.0
    set ny 0.0
    set nz 0.0
    set n [llength $loopNodes]

    for {set i 0} {$i < $n} {incr i} {
        set p1 [::AutoHoleRBE2::nodeXYZ [lindex $loopNodes $i]]
        set p2 [::AutoHoleRBE2::nodeXYZ [lindex $loopNodes [expr {($i+1)%$n}]]]

        set x1 [lindex $p1 0]
        set y1 [lindex $p1 1]
        set z1 [lindex $p1 2]
        set x2 [lindex $p2 0]
        set y2 [lindex $p2 1]
        set z2 [lindex $p2 2]

        set nx [expr {$nx + ($y1-$y2)*($z1+$z2)}]
        set ny [expr {$ny + ($z1-$z2)*($x1+$x2)}]
        set nz [expr {$nz + ($x1-$x2)*($y1+$y2)}]
    }

    return [::AutoHoleRBE2::vnormalize [list $nx $ny $nz]]
}

proc ::AutoHoleRBE2::projectPointOnLine {p center axis} {
    set v [::AutoHoleRBE2::vsub $p $center]
    set t [::AutoHoleRBE2::vdot $v $axis]
    return [::AutoHoleRBE2::vadd $center [::AutoHoleRBE2::vscale $axis $t]]
}

proc ::AutoHoleRBE2::pointLineDistance {p center axis} {
    set q [::AutoHoleRBE2::projectPointOnLine $p $center $axis]
    return [::AutoHoleRBE2::vnorm [::AutoHoleRBE2::vsub $p $q]]
}

proc ::AutoHoleRBE2::meanRadius {nodes center axis} {
    set sum 0.0
    set n [llength $nodes]

    foreach nodeId $nodes {
        set p [::AutoHoleRBE2::nodeXYZ $nodeId]
        set sum [expr {$sum + [::AutoHoleRBE2::pointLineDistance $p $center $axis]}]
    }

    if {$n == 0} {
        return 0.0
    }

    return [expr {$sum/double($n)}]
}

proc ::AutoHoleRBE2::buildLoopsFromEdges {edges} {
    array set adj {}
    array set unused {}

    foreach edge [::AutoHoleRBE2::uniq $edges] {
        set nodes [::AutoHoleRBE2::edgeNodes $edge]
        set n1 [lindex $nodes 0]
        set n2 [lindex $nodes 1]

        lappend adj($n1) $n2
        lappend adj($n2) $n1
        set unused($edge) 1
    }

    if {[array size unused] == 0} {
        return {}
    }

    foreach nodeId [array names adj] {
        set adj($nodeId) [::AutoHoleRBE2::uniq $adj($nodeId)]
        if {[llength $adj($nodeId)] != 2} {
            return {}
        }
    }

    set loops {}

    while {[array size unused] > 0} {
        set edge [lindex [array names unused] 0]
        set nodes [::AutoHoleRBE2::edgeNodes $edge]
        set start [lindex $nodes 0]
        set prev  [lindex $nodes 0]
        set cur   [lindex $nodes 1]
        set loop [list $start]
        set maxStep [expr {[array size unused] + 5}]

        for {set step 0} {$step < $maxStep} {incr step} {
            lappend loop $cur
            catch {unset unused([::AutoHoleRBE2::edgeKey $prev $cur])}

            if {$cur == $start} {
                break
            }

            set nb $adj($cur)
            set n0 [lindex $nb 0]
            set n1 [lindex $nb 1]

            if {$n0 == $prev} {
                set next $n1
            } else {
                set next $n0
            }

            set nextEdge [::AutoHoleRBE2::edgeKey $cur $next]
            if {![info exists unused($nextEdge)] && $next != $start} {
                if {$next == $n0} {
                    set alt $n1
                } else {
                    set alt $n0
                }

                set altEdge [::AutoHoleRBE2::edgeKey $cur $alt]
                if {[info exists unused($altEdge)] || $alt == $start} {
                    set next $alt
                } else {
                    return {}
                }
            }

            set prev $cur
            set cur $next
        }

        if {[lindex $loop end] != $start} {
            return {}
        }

        set loop [lrange $loop 0 end-1]
        if {[llength $loop] < 3} {
            return {}
        }

        lappend loops $loop
    }

    return $loops
}

proc ::AutoHoleRBE2::boundaryLoops {segment faceNodesName edgeFacesName} {
    upvar 1 $faceNodesName faceNodes
    upvar 1 $edgeFacesName edgeFaces

    array set inSeg {}
    foreach faceId $segment {
        set inSeg($faceId) 1
    }

    set boundaryEdges {}

    foreach faceId $segment {
        foreach edge [::AutoHoleRBE2::faceEdges $faceNodes($faceId)] {
            set usedCount 0

            foreach attachedFace $edgeFaces($edge) {
                if {[info exists inSeg($attachedFace)]} {
                    incr usedCount
                }
            }

            if {$usedCount == 1} {
                lappend boundaryEdges $edge
            }
        }
    }

    return [::AutoHoleRBE2::buildLoopsFromEdges $boundaryEdges]
}

proc ::AutoHoleRBE2::segmentFaces {faceElems faceNodesName faceNormalsName edgeFacesName} {
    variable cfg
    upvar 1 $faceNodesName faceNodes
    upvar 1 $faceNormalsName faceNormals
    upvar 1 $edgeFacesName edgeFaces

    set pi [expr {acos(-1.0)}]
    set cosSmooth [expr {cos($cfg(featureAngleDeg)*$pi/180.0)}]

    array set visited {}
    set segments {}

    foreach faceId $faceElems {
        if {[info exists visited($faceId)]} {
            continue
        }

        set queue [list $faceId]
        set visited($faceId) 1
        set segment {}

        while {[llength $queue] > 0} {
            set currentFace [lindex $queue 0]
            set queue [lrange $queue 1 end]
            lappend segment $currentFace

            foreach edge [::AutoHoleRBE2::faceEdges $faceNodes($currentFace)] {
                foreach nextFace $edgeFaces($edge) {
                    if {$nextFace == $currentFace} {
                        continue
                    }
                    if {[info exists visited($nextFace)]} {
                        continue
                    }

                    set d [expr {abs([::AutoHoleRBE2::vdot $faceNormals($currentFace) $faceNormals($nextFace)])}]
                    if {$d >= $cosSmooth} {
                        set visited($nextFace) 1
                        lappend queue $nextFace
                    }
                }
            }
        }

        lappend segments $segment
    }

    return $segments
}

proc ::AutoHoleRBE2::evaluateHoleSegment {segment faceNodesName faceNormalsName edgeFacesName} {
    variable cfg
    upvar 1 $faceNodesName faceNodes
    upvar 1 $faceNormalsName faceNormals
    upvar 1 $edgeFacesName edgeFaces

    set wallNodes {}

    foreach faceId $segment {
        set wallNodes [concat $wallNodes $faceNodes($faceId)]
    }

    set wallNodes [::AutoHoleRBE2::uniq $wallNodes]

    if {[llength $wallNodes] < $cfg(minWallNodes)} {
        return {}
    }

    set loops [::AutoHoleRBE2::boundaryLoops $segment faceNodes edgeFaces]

    if {[llength $loops] != 2} {
        return {}
    }

    set loop1 [lindex $loops 0]
    set loop2 [lindex $loops 1]

    if {[llength $loop1] < $cfg(minLoopNodes) || [llength $loop2] < $cfg(minLoopNodes)} {
        return {}
    }

    set c1 [::AutoHoleRBE2::centroidNodes $loop1]
    set c2 [::AutoHoleRBE2::centroidNodes $loop2]
    set axisVec [::AutoHoleRBE2::vsub $c2 $c1]
    set holeLength [::AutoHoleRBE2::vnorm $axisVec]

    if {$holeLength < $cfg(eps)} {
        return {}
    }

    set axis [::AutoHoleRBE2::vnormalize $axisVec]
    set center [::AutoHoleRBE2::vscale [::AutoHoleRBE2::vadd $c1 $c2] 0.5]

    set n1 [::AutoHoleRBE2::loopNormal $loop1]
    set n2 [::AutoHoleRBE2::loopNormal $loop2]
    set pi [expr {acos(-1.0)}]
    set cosLoop [expr {cos($cfg(loopNormalTolDeg)*$pi/180.0)}]

    if {[expr {abs([::AutoHoleRBE2::vdot $n1 $axis])}] < $cosLoop} {
        return {}
    }
    if {[expr {abs([::AutoHoleRBE2::vdot $n2 $axis])}] < $cosLoop} {
        return {}
    }

    set r1 [::AutoHoleRBE2::meanRadius $loop1 $center $axis]
    set r2 [::AutoHoleRBE2::meanRadius $loop2 $center $axis]
    set radius [::AutoHoleRBE2::meanRadius $wallNodes $center $axis]

    if {$radius < $cfg(eps)} {
        return {}
    }

    if {$cfg(minRadius) > 0.0 && $radius < $cfg(minRadius)} {
        return {}
    }

    if {$cfg(maxRadius) > 0.0 && $radius > $cfg(maxRadius)} {
        return {}
    }

    if {[expr {abs($r1-$r2)/$radius}] > $cfg(loopRadiusTol)} {
        return {}
    }

    set maxDev 0.0
    foreach nodeId $wallNodes {
        set p [::AutoHoleRBE2::nodeXYZ $nodeId]
        set r [::AutoHoleRBE2::pointLineDistance $p $center $axis]
        set dev [expr {abs($r-$radius)}]
        if {$dev > $maxDev} {
            set maxDev $dev
        }
    }

    if {[expr {$maxDev/$radius}] > $cfg(cylFitTol)} {
        return {}
    }

    if {$cfg(requireInnerNormal)} {
        set signSum 0.0
        set signCount 0

        foreach faceId $segment {
            set faceCenter [::AutoHoleRBE2::centroidNodes $faceNodes($faceId)]
            set q [::AutoHoleRBE2::projectPointOnLine $faceCenter $center $axis]
            set radial [::AutoHoleRBE2::vnormalize [::AutoHoleRBE2::vsub $faceCenter $q]]

            if {[::AutoHoleRBE2::vnorm $radial] < $cfg(eps)} {
                continue
            }

            set signSum [expr {$signSum + [::AutoHoleRBE2::vdot $faceNormals($faceId) $radial]}]
            incr signCount
        }

        if {$signCount > 0} {
            set meanSign [expr {$signSum/double($signCount)}]
            if {$meanSign > $cfg(innerNormalMaxDot)} {
                return {}
            }
        }
    }

    return [list $wallNodes $center $radius $holeLength]
}

# ----------------------------------------------------------------------
# HyperMesh operations
# ----------------------------------------------------------------------

proc ::AutoHoleRBE2::deleteComponentByName {compName} {
    catch {*createmark comps 2 "by name" $compName}
    set ids {}
    catch {set ids [hm_getmark comps 2]}

    if {[llength $ids] > 0} {
        catch {*deletemark comps 2}
        return 1
    }

    return 0
}

proc ::AutoHoleRBE2::ensureComponent {compName} {
    catch {*createmark comps 2 "by name" $compName}
    set ids {}
    catch {set ids [hm_getmark comps 2]}

    if {[llength $ids] == 0} {
        catch {*collectorcreateonly components $compName "" 11}
    }

    catch {*currentcollector component $compName}
    catch {*currentcollector components $compName}
}

proc ::AutoHoleRBE2::createRBE2 {wallNodes center} {
    variable cfg

    set x [lindex $center 0]
    set y [lindex $center 1]
    set z [lindex $center 2]

    *createnode $x $y $z 0 0 0
    set centerNode [hm_latestentityid nodes]

    eval *createmark nodes 2 $wallNodes
    *rigidlink $centerNode 2 $cfg(dof)

    return $centerNode
}

proc ::AutoHoleRBE2::clearMarks {} {
    catch {*clearmarkall 1}
    catch {*clearmarkall 2}
}

# ----------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------

proc ::AutoHoleRBE2::runCore {} {
    variable cfg
    variable ui
    variable stat

    array set stat {
        sourceElems 0
        freeFaces 0
        validFaces 0
        segments 0
        created 0
    }

    set comps $ui(selectedComps)

    ::AutoHoleRBE2::message "已选择 [llength $comps] 个 Component。"

    ::AutoHoleRBE2::clearMarks
    eval *createmark comps 1 $comps

    catch {*createmark elems 1 "by comps on mark" 1}
    set sourceElems [hm_getmark elems 1]
    set stat(sourceElems) [llength $sourceElems]

    if {$stat(sourceElems) == 0} {
        error "所选 Component 内没有元素。"
    }

    foreach elemId $sourceElems {
        if {![::AutoHoleRBE2::isSolidElem $elemId]} {
            error "所选 Component 包含非 3D solid 单元。示例：elem=$elemId, config=[::AutoHoleRBE2::elemConfig $elemId]"
        }
    }

    if {$cfg(preDeleteOldFaces)} {
        if {[::AutoHoleRBE2::deleteComponentByName $cfg(faceCompName)]} {
            ::AutoHoleRBE2::message "已删除旧的临时自由面：$cfg(faceCompName)"
        }
    }

    ::AutoHoleRBE2::message "正在生成自由面..."
    ::AutoHoleRBE2::clearMarks
    eval *createmark comps 1 $comps
    *findfaces components 1

    catch {*createmark elems 1 "by comp name" $cfg(faceCompName)}
    set faceElems [hm_getmark elems 1]
    set stat(freeFaces) [llength $faceElems]

    if {$stat(freeFaces) == 0} {
        error "未生成自由面。请确认所选 Component 是有效实体网格。"
    }

    ::AutoHoleRBE2::message "正在分析自由面..."
    array set faceNodes {}
    array set faceNormals {}
    array set edgeFaces {}

    foreach faceId $faceElems {
        set nodes [::AutoHoleRBE2::uniq [::AutoHoleRBE2::elemNodes $faceId]]

        if {[llength $nodes] < 3} {
            continue
        }

        set faceNodes($faceId) $nodes
        set faceNormals($faceId) [::AutoHoleRBE2::faceNormal $nodes]

        foreach edge [::AutoHoleRBE2::faceEdges $nodes] {
            lappend edgeFaces($edge) $faceId
        }
    }

    set validFaces [array names faceNodes]
    set stat(validFaces) [llength $validFaces]

    if {$stat(validFaces) == 0} {
        error "自由面读取失败。"
    }

    ::AutoHoleRBE2::message "正在识别平滑面片..."
    set segments [::AutoHoleRBE2::segmentFaces $validFaces faceNodes faceNormals edgeFaces]
    set stat(segments) [llength $segments]

    ::AutoHoleRBE2::ensureComponent $cfg(resultCompName)

    ::AutoHoleRBE2::message "正在识别孔并创建 RBE2..."
    foreach segment $segments {
        set result [::AutoHoleRBE2::evaluateHoleSegment $segment faceNodes faceNormals edgeFaces]

        if {[llength $result] == 0} {
            continue
        }

        set wallNodes  [lindex $result 0]
        set center     [lindex $result 1]
        set radius     [lindex $result 2]
        set holeLength [lindex $result 3]

        set centerNode [::AutoHoleRBE2::createRBE2 $wallNodes $center]
        incr stat(created)

        ::AutoHoleRBE2::log "MAKE" "centerNode=$centerNode wallNodes=[llength $wallNodes] radius=$radius length=$holeLength center=$center"
    }

    if {$cfg(deleteTempFaces)} {
        if {[::AutoHoleRBE2::deleteComponentByName $cfg(faceCompName)]} {
            ::AutoHoleRBE2::message "已清理临时自由面：$cfg(faceCompName)"
        }
    }

    ::AutoHoleRBE2::clearMarks
}

proc ::AutoHoleRBE2::run {} {
    variable cfg
    variable stat
    variable VERSION

    if {![::AutoHoleRBE2::showPanel]} {
        catch {hm_usermessage "AutoHoleRBE2 已取消。"}
        return
    }

    ::AutoHoleRBE2::initLog
    ::AutoHoleRBE2::message "AutoHoleRBE2 v$VERSION 启动。"

    set failed 0
    set errMsg ""

    if {[catch {::AutoHoleRBE2::runCore} err]} {
        set failed 1
        set errMsg $err
        ::AutoHoleRBE2::warning $err

        if {$cfg(deleteTempFaces)} {
            catch {::AutoHoleRBE2::deleteComponentByName $cfg(faceCompName)}
        }

        ::AutoHoleRBE2::clearMarks
    }

    if {!$failed} {
        set msg "AutoHoleRBE2 v$VERSION 完成。\n\n源元素：$stat(sourceElems)\n自由面：$stat(freeFaces)\n有效自由面：$stat(validFaces)\n平滑面片：$stat(segments)\n创建 RBE2：$stat(created)"

        if {$cfg(logFile) ne ""} {
            append msg "\n\n日志：$cfg(logFile)"
        }

        ::AutoHoleRBE2::message "完成：创建 RBE2 $stat(created) 个。"
        catch {tk_messageBox -icon info -title "AutoHoleRBE2 v$VERSION" -message $msg}
    } else {
        set msg "AutoHoleRBE2 v$VERSION 运行失败：\n\n$errMsg"

        if {$cfg(logFile) ne ""} {
            append msg "\n\n日志：$cfg(logFile)"
        }

        catch {tk_messageBox -icon warning -title "AutoHoleRBE2 v$VERSION" -message $msg}
    }

    ::AutoHoleRBE2::closeLog
}
