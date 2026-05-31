# ============================================================================
# shell_washer_hole_rbe2_release_v1_2_safe.tcl
# Version : Release 1.2 Safe
# Purpose : For shell components with standard washer mesh around bolt holes,
#           identify circular inner free-edge hole loops, verify the first
#           washer ring, tie the inner free-edge loop + first outer washer
#           node loop, create a center node, and create an RBE2/rigidlink.
# Target  : HyperMesh 2019 Tcl style
# Usage   : File > Run > Tcl/Tk Script, then select one or more shell components.
#
# Main behavior:
#   1) Only holes with diameter 6~30 in model units are processed.
#   2) Holes without a valid washer ring are skipped.
#   3) For each selected source component, output RBE2 elements are organized
#      into AUTO_RBE2_<source component name>[_NN].
#   4) Large-model performance optimization: node coordinate cache, reduced UI
#      redraw/logging, component-level batch organization of RBE2 elements.
#   5) The lower-left status area shows throttled overall progress.
#   6) Safety logic: before processing a selected component, if an existing
#      RBE2/rigidlink is found in the source component or in an existing
#      AUTO_RBE2_<source component name> output component, that source component
#      is skipped and reported to the user.
#   7) The script does not call *movemark on nodes; only created RBE2 elements
#      are explicitly moved to the output component.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::RB2W {
    variable VERSION "Release-1.2-Safe"

    # ---------------- Hole / washer parameters ----------------
    variable MIN_HOLE_DIAMETER           6.0
    variable MAX_HOLE_DIAMETER           30.0
    variable CIRCULARITY_TOL             0.08
    variable MIN_HOLE_EDGE_NODES         8
    variable MAX_HOLE_EDGE_NODES         200
    variable INNER_WASHER_NODE_LOOPS     2
    variable OUTER_RING_CIRCULARITY_TOL  0.20
    variable CENTER_OFFSET_TOL           0.20
    variable MIN_WASHER_WIDTH_ABS        0.30
    variable MIN_WASHER_WIDTH_RATIO      0.05
    variable WASHER_ELEM_COUNT_TOL       0.50
    variable MIN_OUTER_NODE_RATIO        0.50
    variable MAX_OUTER_NODE_RATIO        2.50

    # ---------------- RBE2 / output parameters ----------------
    variable RBE2_DOF                    123456
    variable RBE2_COMPONENT_PREFIX       "AUTO_RBE2"
    variable BATCH_ORGANIZE_RBE2         1
    variable ORGANIZE_BATCH_SIZE         500
    variable SHOW_OUTPUT_COMPONENTS      1
    variable FORCE_BROWSER_REFRESH       1

    # Safety check.  Keep both enabled by default to prevent duplicate RBE2.
    variable SKIP_COMPONENT_IF_EXISTING_RBE2            1
    variable CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2   1
    variable CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2   1
    variable OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT         999

    # ---------------- Logging / progress / performance ----------------
    variable VERBOSE                     1
    variable LOG_EACH_CREATED            0
    variable LOG_EACH_SKIPPED            0
    variable PERFORMANCE_MODE            1
    variable USE_NODE_XYZ_CACHE          1
    variable USE_STATUS_PROGRESS         1
    variable PROGRESS_LOOP_STEP          50
    variable UI_UPDATE_STEP              100
    variable FORCE_STATUS_UPDATE         1
    variable STATUS_PERCENT_STEP         1.0
    variable STATUS_MIN_INTERVAL_MS      500
    variable statusLastPercent           -100.0
    variable statusLastTime              0

    # ---------------- Internal arrays / state ----------------
    variable elemNodes
    variable edgeElems
    variable nodeAdj
    variable elemNbrs
    variable outputCompBySource
    variable nodeXYZCache
    variable currentComponentName ""
}

proc ::RB2W::log {msg} {
    variable VERBOSE
    if {$VERBOSE} {
        puts "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] RB2W: $msg"
    }
}

proc ::RB2W::status {msg {force 0}} {
    variable USE_STATUS_PROGRESS
    variable FORCE_STATUS_UPDATE
    if {!$USE_STATUS_PROGRESS} { return }
    catch {hm_usermessage $msg}
    if {$FORCE_STATUS_UPDATE || $force} { catch {update idletasks} }
}

proc ::RB2W::resetOverallProgress {} {
    variable statusLastPercent
    variable statusLastTime
    set statusLastPercent -100.0
    set statusLastTime 0
}

proc ::RB2W::stateKeys {} {
    return {
        MIN_HOLE_DIAMETER MAX_HOLE_DIAMETER CIRCULARITY_TOL
        MIN_HOLE_EDGE_NODES MAX_HOLE_EDGE_NODES INNER_WASHER_NODE_LOOPS
        OUTER_RING_CIRCULARITY_TOL CENTER_OFFSET_TOL
        MIN_WASHER_WIDTH_ABS MIN_WASHER_WIDTH_RATIO WASHER_ELEM_COUNT_TOL
        MIN_OUTER_NODE_RATIO MAX_OUTER_NODE_RATIO
        RBE2_DOF RBE2_COMPONENT_PREFIX BATCH_ORGANIZE_RBE2 ORGANIZE_BATCH_SIZE
        SHOW_OUTPUT_COMPONENTS FORCE_BROWSER_REFRESH
        SKIP_COMPONENT_IF_EXISTING_RBE2 CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2
        CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2 OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT
        VERBOSE LOG_EACH_CREATED LOG_EACH_SKIPPED PERFORMANCE_MODE USE_NODE_XYZ_CACHE
        USE_STATUS_PROGRESS PROGRESS_LOOP_STEP UI_UPDATE_STEP FORCE_STATUS_UPDATE
        STATUS_PERCENT_STEP STATUS_MIN_INTERVAL_MS
    }
}

proc ::RB2W::loadState {} {
    if {[llength [info commands ::HWFlow::loadState]] == 0} {
        return
    }
    set state [::HWFlow::loadState shell_washer_hole_rbe2]
    foreach key [::RB2W::stateKeys] {
        if {[dict exists $state $key]} {
            upvar #0 ::RB2W::$key v
            set v [dict get $state $key]
        }
    }
}

proc ::RB2W::saveState {} {
    if {[llength [info commands ::HWFlow::saveState]] == 0} {
        return
    }
    set state [dict create]
    foreach key [::RB2W::stateKeys] {
        upvar #0 ::RB2W::$key v
        if {[info exists v]} {
            dict set state $key $v
        }
    }
    ::HWFlow::saveState shell_washer_hole_rbe2 $state
}

proc ::RB2W::overallStatus {overallPct compIndex compTotal compName loopIndex loopTotal candidateHoles created skipped {force 0}} {
    variable STATUS_PERCENT_STEP
    variable STATUS_MIN_INTERVAL_MS
    variable statusLastPercent
    variable statusLastTime

    if {$overallPct < 0.0} { set overallPct 0.0 }
    if {$overallPct > 100.0} { set overallPct 100.0 }
    set now [clock milliseconds]
    if {!$force && $STATUS_PERCENT_STEP > 0 && ($overallPct - $statusLastPercent) < $STATUS_PERCENT_STEP} { return }
    if {!$force && $STATUS_MIN_INTERVAL_MS > 0 && ($now - $statusLastTime) < $STATUS_MIN_INTERVAL_MS} { return }

    set statusLastPercent $overallPct
    set statusLastTime $now
    set pctText [format %.1f $overallPct]
    set msg "RB2W overall ${pctText}% | comp $compIndex/$compTotal: $compName | loop $loopIndex/$loopTotal | created=$created skipped=$skipped candidates=$candidateHoles"
    RB2W::status $msg $force
}

proc ::RB2W::beginPerformanceMode {} {
    variable PERFORMANCE_MODE
    variable USE_STATUS_PROGRESS
    if {!$PERFORMANCE_MODE} { return }
    RB2W::log "Performance mode ON."
    catch {*setoption entity_highlighting=0}
    if {$USE_STATUS_PROGRESS} {
        catch {*setoption block_messages=0}
        catch {hm_blockmessages 0}
    } else {
        catch {*setoption block_messages=1}
        catch {hm_blockmessages 1}
    }
    catch {*setoption block_redraw=1}
    catch {hm_blockredraw 1}
    catch {hwbrowsermanager view flush false}
    catch {hmbr_signals buffer start}
}

proc ::RB2W::enableInteractiveBrowserUpdates {} {
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {*setoption block_redraw=0}
    catch {*setoption block_messages=0}
    catch {hm_blockredraw 0}
    catch {hm_blockmessages 0}
    catch {hm_blockerrormessages 0}
    catch {hm_commandfilestate 1}
    catch {hm_setmouse 1}
    catch {update idletasks}
}

proc ::RB2W::resumePerformanceModeAfterBrowserUpdate {} {
    variable PERFORMANCE_MODE
    variable USE_STATUS_PROGRESS
    if {!$PERFORMANCE_MODE} { return }

    if {$USE_STATUS_PROGRESS} {
        catch {*setoption block_messages=0}
        catch {hm_blockmessages 0}
    } else {
        catch {*setoption block_messages=1}
        catch {hm_blockmessages 1}
    }
    catch {*setoption block_redraw=1}
    catch {hm_blockredraw 1}
}

proc ::RB2W::endPerformanceMode {} {
    variable PERFORMANCE_MODE
    if {$PERFORMANCE_MODE} {
        catch {*setoption block_redraw=0}
        catch {*setoption block_messages=0}
        catch {*setoption entity_highlighting=1}
        catch {hm_blockredraw 0}
        catch {hm_blockmessages 0}
    }
    RB2W::enableInteractiveBrowserUpdates
    catch {hwbrowsermanager view flush true}
    RB2W::showAllOutputComponents
    RB2W::refreshBrowsersAndGraphics 1
    if {$PERFORMANCE_MODE} {
        RB2W::log "Performance mode OFF."
    }
}

proc ::RB2W::clearNodeXYZCache {} {
    variable nodeXYZCache
    catch {array unset nodeXYZCache}
    array set nodeXYZCache {}
}

proc ::RB2W::clearComponentElemCache {} {
    variable componentElemsCache
    catch {array unset componentElemsCache}
    array set componentElemsCache {}
}

proc ::RB2W::uniq {lst} {
    array set seen {}
    foreach x $lst { if {$x ne ""} { set seen($x) 1 } }
    set out [array names seen]
    if {[llength $out] == 0} { return {} }
    if {[catch {set out [lsort -integer $out]}]} { set out [lsort $out] }
    return $out
}

proc ::RB2W::edgeKey {a b} {
    if {$a < $b} { return "${a}:${b}" }
    return "${b}:${a}"
}

proc ::RB2W::addUniqueToArrayList {arrayName key value} {
    upvar $arrayName arr
    if {![info exists arr($key)]} {
        set arr($key) [list $value]
    } elseif {[lsearch -exact $arr($key) $value] < 0} {
        lappend arr($key) $value
    }
}

proc ::RB2W::bumpReason {arrayName reason} {
    upvar $arrayName arr
    if {![info exists arr($reason)]} { set arr($reason) 1 } else { incr arr($reason) }
}

proc ::RB2W::formatReasonStats {arrayName} {
    upvar $arrayName arr
    set parts {}
    foreach k [lsort [array names arr]] { lappend parts "$k=$arr($k)" }
    if {[llength $parts] == 0} { return "none" }
    return [join $parts "; "]
}

proc ::RB2W::getElemNodes {eid} {
    set nodes {}
    if {![catch {set nodes [hm_getvalue elems id=$eid dataname=nodes]}] && [llength $nodes] >= 3} { return $nodes }
    if {![catch {set nodes [hm_nodelist $eid]}] && [llength $nodes] >= 3} { return $nodes }
    set nodes {}
    for {set i 1} {$i <= 8} {incr i} {
        if {![catch {set n [hm_getvalue elems id=$eid dataname=node${i}.id]}] && $n ne "" && $n != 0} { lappend nodes $n }
    }
    return $nodes
}

proc ::RB2W::getNodeXYZRaw {nid} {
    set ok 1
    if {[catch {set x [hm_getvalue nodes id=$nid dataname=x]}]} { set ok 0 }
    if {[catch {set y [hm_getvalue nodes id=$nid dataname=y]}]} { set ok 0 }
    if {[catch {set z [hm_getvalue nodes id=$nid dataname=z]}]} { set ok 0 }
    if {$ok} { return [list $x $y $z] }

    set ok 1
    if {[catch {set x [hm_getvalue nodes id=$nid dataname=globalx]}]} { set ok 0 }
    if {[catch {set y [hm_getvalue nodes id=$nid dataname=globaly]}]} { set ok 0 }
    if {[catch {set z [hm_getvalue nodes id=$nid dataname=globalz]}]} { set ok 0 }
    if {$ok} { return [list $x $y $z] }

    if {![catch {set xyz [join [hm_nodevalue $nid]]}] && [llength $xyz] >= 3} { return [lrange $xyz 0 2] }
    error "Cannot read coordinates of node $nid"
}

proc ::RB2W::getNodeXYZ {nid} {
    variable USE_NODE_XYZ_CACHE
    variable nodeXYZCache
    if {$USE_NODE_XYZ_CACHE && [info exists nodeXYZCache($nid)]} { return $nodeXYZCache($nid) }
    set xyz [RB2W::getNodeXYZRaw $nid]
    if {$USE_NODE_XYZ_CACHE} { set nodeXYZCache($nid) $xyz }
    return $xyz
}

proc ::RB2W::distance3 {p q} {
    set dx [expr {[lindex $p 0] - [lindex $q 0]}]
    set dy [expr {[lindex $p 1] - [lindex $q 1]}]
    set dz [expr {[lindex $p 2] - [lindex $q 2]}]
    return [expr {sqrt($dx*$dx + $dy*$dy + $dz*$dz)}]
}

proc ::RB2W::loopGeometry {nodes} {
    set n [llength $nodes]
    if {$n == 0} { error "empty loop" }
    set sx 0.0; set sy 0.0; set sz 0.0
    set xyzList {}
    foreach nid $nodes {
        set xyz [RB2W::getNodeXYZ $nid]
        foreach {x y z} $xyz {}
        lappend xyzList $xyz
        set sx [expr {$sx + $x}]
        set sy [expr {$sy + $y}]
        set sz [expr {$sz + $z}]
    }
    set center [list [expr {$sx / double($n)}] [expr {$sy / double($n)}] [expr {$sz / double($n)}]]
    set sr 0.0; set minr 1.0e99; set maxr -1.0; set radii {}
    foreach xyz $xyzList {
        set r [RB2W::distance3 $xyz $center]
        lappend radii $r
        set sr [expr {$sr + $r}]
        if {$r < $minr} { set minr $r }
        if {$r > $maxr} { set maxr $r }
    }
    set meanr [expr {$sr / double($n)}]
    set ss 0.0
    foreach r $radii { set dr [expr {$r - $meanr}]; set ss [expr {$ss + $dr*$dr}] }
    set rms [expr {sqrt($ss / double($n))}]
    if {$meanr <= 1.0e-12} { set rel 999.0 } else { set rel [expr {$rms / $meanr}] }
    return [list $center $meanr $rel $minr $maxr]
}

proc ::RB2W::getElemsByComp {compId} {
    variable componentElemsCache
    if {[info exists componentElemsCache($compId)]} {
        return $componentElemsCache($compId)
    }

    *clearmark elems 1
    set elems {}
    if {![catch {*createmark elems 1 "by comp id" $compId}]} { set elems [hm_getmark elems 1] }
    if {[llength $elems] == 0} {
        catch {*clearmark elems 1}
        if {![catch {*createmark elems 1 "by collector id" $compId}]} { set elems [hm_getmark elems 1] }
    }
    catch {*clearmark elems 1}
    set elems [RB2W::uniq $elems]
    set componentElemsCache($compId) $elems
    return $elems
}

proc ::RB2W::buildGraph {elems} {
    variable elemNodes
    variable edgeElems
    variable nodeAdj
    variable elemNbrs
    catch {array unset elemNodes}; catch {array unset edgeElems}; catch {array unset nodeAdj}; catch {array unset elemNbrs}
    array set elemNodes {}; array set edgeElems {}; array set nodeAdj {}; array set elemNbrs {}

    foreach eid $elems {
        set ns [RB2W::getElemNodes $eid]
        set nn [llength $ns]
        if {$nn < 3} { continue }
        set elemNodes($eid) $ns
        for {set i 0} {$i < $nn} {incr i} {
            set n1 [lindex $ns $i]
            set n2 [lindex $ns [expr {($i + 1) % $nn}]]
            if {$n1 eq "" || $n2 eq "" || $n1 == $n2} { continue }
            set key [RB2W::edgeKey $n1 $n2]
            lappend edgeElems($key) $eid
            RB2W::addUniqueToArrayList nodeAdj $n1 $n2
            RB2W::addUniqueToArrayList nodeAdj $n2 $n1
        }
    }

    foreach key [array names edgeElems] {
        set el [RB2W::uniq $edgeElems($key)]
        set edgeElems($key) $el
        if {[llength $el] == 2} {
            set e1 [lindex $el 0]
            set e2 [lindex $el 1]
            RB2W::addUniqueToArrayList elemNbrs $e1 $e2
            RB2W::addUniqueToArrayList elemNbrs $e2 $e1
        }
    }
}

proc ::RB2W::findFreeEdgeLoops {} {
    variable edgeElems
    array set freeAdj {}
    array set freeEdgesByNodePair {}
    foreach key [array names edgeElems] {
        if {[llength $edgeElems($key)] == 1} {
            foreach {a b} [split $key ":"] {}
            RB2W::addUniqueToArrayList freeAdj $a $b
            RB2W::addUniqueToArrayList freeAdj $b $a
            set freeEdgesByNodePair($key) 1
        }
    }

    array set visited {}
    set loops {}
    foreach start [array names freeAdj] {
        if {[info exists visited($start)]} { continue }
        set queue [list $start]
        set nodes {}
        set closed 1
        set qi 0
        set visited($start) 1
        while {$qi < [llength $queue]} {
            set n [lindex $queue $qi]
            incr qi
            lappend nodes $n
            if {![info exists freeAdj($n)] || [llength $freeAdj($n)] != 2} { set closed 0 }
            foreach nb $freeAdj($n) {
                if {![info exists visited($nb)]} { set visited($nb) 1; lappend queue $nb }
            }
        }
        set edgeKeys {}
        foreach n $nodes {
            foreach nb $freeAdj($n) {
                set k [RB2W::edgeKey $n $nb]
                if {[info exists freeEdgesByNodePair($k)]} { lappend edgeKeys $k }
            }
        }
        set edgeKeys [RB2W::uniq $edgeKeys]
        if {[llength $edgeKeys] != [llength $nodes]} { set closed 0 }
        lappend loops [dict create nodes [RB2W::uniq $nodes] edges $edgeKeys closed $closed]
    }
    return $loops
}

proc ::RB2W::seedElemsFromLoop {edgeKeys} {
    variable edgeElems
    set seeds {}
    foreach k $edgeKeys {
        if {[info exists edgeElems($k)] && [llength $edgeElems($k)] == 1} { lappend seeds [lindex $edgeElems($k) 0] }
    }
    return [RB2W::uniq $seeds]
}

proc ::RB2W::expandElementLayers {seedElems layerCount} {
    variable elemNbrs
    if {$layerCount <= 1} { return [RB2W::uniq $seedElems] }
    array set selected {}
    set frontier [RB2W::uniq $seedElems]
    foreach e $frontier { set selected($e) 1 }
    for {set layer 2} {$layer <= $layerCount} {incr layer} {
        set next {}
        foreach e $frontier {
            if {![info exists elemNbrs($e)]} { continue }
            foreach nb $elemNbrs($e) {
                if {![info exists selected($nb)]} { set selected($nb) 1; lappend next $nb }
            }
        }
        set frontier [RB2W::uniq $next]
        if {[llength $frontier] == 0} { break }
    }
    return [RB2W::uniq [array names selected]]
}

proc ::RB2W::nodesFromElems {elems} {
    variable elemNodes
    set ns {}
    foreach e $elems { if {[info exists elemNodes($e)]} { foreach n $elemNodes($e) { lappend ns $n } } }
    return [RB2W::uniq $ns]
}

proc ::RB2W::listSubtract {all remove} {
    array set rm {}
    foreach n $remove { set rm($n) 1 }
    set out {}
    foreach n $all { if {![info exists rm($n)]} { lappend out $n } }
    return [RB2W::uniq $out]
}

proc ::RB2W::componentExistsByName {compName} {
    if {![catch {set exists [hm_entityinfo exist components $compName -byname]}]} { return $exists }
    if {![catch {set cid [hm_entityinfo id components $compName -byname]}] && $cid ne "" && $cid != 0} { return 1 }
    return 0
}

proc ::RB2W::componentIdByName {compName} {
    foreach etype {components comps component} {
        if {![catch {set cid [hm_entityinfo id $etype $compName -byname]}] && $cid ne "" && $cid != 0} { return $cid }
    }
    foreach etype {components comps} {
        catch {*clearmark $etype 2}
        if {![catch {*createmark $etype 2 "by name only" $compName}]} {
            if {![catch {set ids [hm_getmark $etype 2]}] && [llength $ids] > 0} {
                catch {*clearmark $etype 2}
                return [lindex $ids 0]
            }
        }
    }
    return ""
}

proc ::RB2W::getComponentName {compId} {
    foreach etype {comps components component} {
        if {![catch {set n [hm_getcollectorname $etype $compId]}] && $n ne ""} { return $n }
    }
    foreach etype {comps components component} {
        if {![catch {set n [hm_entityinfo name $etype $compId -byid]}] && $n ne ""} { return $n }
    }
    if {![catch {set n [hm_getvalue comps id=$compId dataname=name]}] && $n ne ""} { return $n }
    return "comp_$compId"
}

proc ::RB2W::sanitizeNamePart {raw fallback} {
    set s [string trim $raw]
    if {$s eq ""} { set s $fallback }
    regsub -all {[^[:alnum:]_.-]+} $s "_" s
    regsub -all {_+} $s "_" s
    set s [string trim $s "_"]
    if {$s eq ""} { set s $fallback }
    if {[string length $s] > 48} { set s [string range $s 0 47] }
    return $s
}

proc ::RB2W::sourceOutputBaseName {sourceCompId} {
    variable RBE2_COMPONENT_PREFIX
    set srcName [RB2W::getComponentName $sourceCompId]
    set safeSrc [RB2W::sanitizeNamePart $srcName "comp_$sourceCompId"]
    return "${RBE2_COMPONENT_PREFIX}_${safeSrc}"
}

proc ::RB2W::uniqueComponentName {baseName} {
    set base [RB2W::sanitizeNamePart $baseName "AUTO_RBE2"]
    if {![RB2W::componentExistsByName $base]} { return $base }
    for {set i 1} {$i <= 999} {incr i} {
        set cand [format "%s_%02d" $base $i]
        if {![RB2W::componentExistsByName $cand]} { return $cand }
    }
    return [format "%s_%s" $base [clock seconds]]
}

proc ::RB2W::setCurrentComponent {compName} {
    variable currentComponentName
    if {[info exists currentComponentName] && $currentComponentName eq $compName} { return }
    if {[catch {*currentcollector component $compName} err1]} {
        if {[catch {*currentcollector(component,$compName)} err2]} {
            error "Cannot set current component to $compName: $err1 / $err2"
        }
    }
    set currentComponentName $compName
}

proc ::RB2W::createComponentByName {compName} {
    variable PERFORMANCE_MODE
    if {[RB2W::componentExistsByName $compName]} {
        RB2W::setCurrentComponent $compName
        return
    }

    if {!$PERFORMANCE_MODE} {
        RB2W::enableInteractiveBrowserUpdates
    }
    set histName "Created Component $compName"
    set histStarted 0
    catch {*startnotehistorystate $histName}
    set histStarted 1

    set createCode [catch {*collectorcreateonly comps $compName "" 11} err1]
    if {$createCode} {
        set createCode [catch {*collectorcreateonly components $compName "" 11} err1]
    }
    if {$createCode} {
        if {[catch {*createentity comps name=$compName} err2]} {
            if {$histStarted} { catch {*endnotehistorystate $histName} }
            if {!$PERFORMANCE_MODE} {
                RB2W::resumePerformanceModeAfterBrowserUpdate
            }
            error "Cannot create output component $compName: $err1 / $err2"
        }
    }
    if {$histStarted} { catch {*endnotehistorystate $histName} }

    RB2W::setCurrentComponent $compName
    if {!$PERFORMANCE_MODE} {
        RB2W::showOutputComponent $compName 1
        RB2W::resumePerformanceModeAfterBrowserUpdate
    }
}

proc ::RB2W::ensureOutputComponent {sourceCompId} {
    variable outputCompBySource
    variable PERFORMANCE_MODE
    if {[info exists outputCompBySource($sourceCompId)]} {
        set outName $outputCompBySource($sourceCompId)
        RB2W::setCurrentComponent $outName
        return $outName
    }
    set srcName [RB2W::getComponentName $sourceCompId]
    set baseName [RB2W::sourceOutputBaseName $sourceCompId]
    set outName [RB2W::uniqueComponentName $baseName]
    RB2W::createComponentByName $outName
    set outputCompBySource($sourceCompId) $outName
    if {!$PERFORMANCE_MODE} {
        RB2W::showOutputComponent $outName 0
    }
    RB2W::log "Output component created for source component $sourceCompId ($srcName): $outName"
    return $outName
}

proc ::RB2W::markComponentByName {compName markId} {
    foreach etype {components comps} {
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId "by name only" $compName}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return $etype }
        }
    }
    set cid [RB2W::componentIdByName $compName]
    if {$cid ne ""} {
        foreach etype {components comps} {
            catch {*clearmark $etype $markId}
            if {![catch {*createmark $etype $markId "by id only" $cid}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return $etype }
            }
        }
    }
    return ""
}

proc ::RB2W::showOutputComponent {compName {refreshNow 0}} {
    variable SHOW_OUTPUT_COMPONENTS
    if {!$SHOW_OUTPUT_COMPONENTS} { return }
    set compId [RB2W::componentIdByName $compName]
    set markType [RB2W::markComponentByName $compName 2]
    if {$markType ne ""} {
        catch {*marksuppressactive $markType 2 0}
        catch {*marksuppressoutput $markType 2 0}
        catch {*displaycollectorsbymark $markType 2 on 1 1}
        catch {*displaycollectorsbymark components 2 on 1 1}
        catch {*displaycollectorsbymark comps 2 on 1 1}
        catch {*displaycollectorsallbymark 2 on 1 1}
        catch {*clearmark $markType 2}
    }
    catch {*displaycollector component on $compName 1 1}
    catch {*displaycollector components on $compName 1 1}
    catch {*displaycollectorwithfilter component on $compName 1 1}
    catch {*displaycollectorwithfilter components on $compName 1 1}
    if {$compId ne ""} {
        catch {*showentity comps "by id" $compId}
        catch {*showentity components "by id" $compId}
    }
    if {$refreshNow} { RB2W::refreshBrowsersAndGraphics }
}

proc ::RB2W::showAllOutputComponents {} {
    variable outputCompBySource
    if {![array exists outputCompBySource]} { return }
    foreach k [array names outputCompBySource] { RB2W::showOutputComponent $outputCompBySource($k) 0 }
}

proc ::RB2W::refreshBrowsersAndGraphics {{force 0}} {
    variable FORCE_BROWSER_REFRESH
    if {!$FORCE_BROWSER_REFRESH && !$force} { return }
    catch {hmbr_signals buffer stop}
    catch {hwbrowsermanager view flush true}
    catch {hm_redraw}
    catch {update idletasks}
    catch {update}
}

proc ::RB2W::countEntitiesInComponent {compName entityType} {
    set compId [RB2W::componentIdByName $compName]
    foreach ctype {components comps} {
        if {![catch {set n [hm_entityincollector $ctype $compName $entityType 0 0 -byname]}] && $n ne ""} {
            return $n
        }
        if {$compId ne "" && ![catch {set n [hm_entityincollector $ctype $compId $entityType 0 0 -byid]}] && $n ne ""} {
            return $n
        }
    }

    catch {*clearmark $entityType 1}
    if {$compId ne "" && ![catch {*createmark $entityType 1 "by comp id" $compId}]} {
        if {![catch {set ids [hm_getmark $entityType 1]}]} {
            catch {*clearmark $entityType 1}
            return [llength $ids]
        }
    }
    if {![catch {*createmark $entityType 1 "by comp name" $compName}]} {
        if {![catch {set ids [hm_getmark $entityType 1]}]} {
            catch {*clearmark $entityType 1}
            return [llength $ids]
        }
    }
    catch {*clearmark $entityType 1}
    return "?"
}

proc ::RB2W::outputComponentSummary {} {
    variable outputCompBySource
    if {![array exists outputCompBySource]} { return "" }

    set lines {}
    foreach sourceId [lsort -integer [array names outputCompBySource]] {
        set compName $outputCompBySource($sourceId)
        set compId [RB2W::componentIdByName $compName]
        set elemCount [RB2W::countEntitiesInComponent $compName elems]
        set nodeCount [RB2W::countEntitiesInComponent $compName nodes]
        lappend lines "$compName  id=$compId  elems=$elemCount  nodes=$nodeCount"
    }
    return [join $lines \n]
}

proc ::RB2W::moveMarkToComponent {entityTypes markId compName} {
    foreach etype $entityTypes {
        if {![catch {*movemark $etype $markId $compName} err]} { return 1 }
    }
    return 0
}

proc ::RB2W::listChunks {lst chunkSize} {
    if {$chunkSize <= 0} { set chunkSize 500 }
    set out {}
    set n [llength $lst]
    for {set i 0} {$i < $n} {incr i $chunkSize} {
        set j [expr {$i + $chunkSize - 1}]
        if {$j >= $n} { set j [expr {$n - 1}] }
        lappend out [lrange $lst $i $j]
    }
    return $out
}

proc ::RB2W::organizeCreatedRBE2Elements {elemIds outComp} {
    variable ORGANIZE_BATCH_SIZE
    set elemIds [RB2W::uniq $elemIds]
    set total [llength $elemIds]
    if {$total == 0} { return 0 }
    set moved 0
    foreach chunk [RB2W::listChunks $elemIds $ORGANIZE_BATCH_SIZE] {
        catch {*clearmark elems 1}
        if {[catch {eval *createmark elems 1 $chunk} errMark]} {
            RB2W::log "Warning: could not mark RBE2 batch for $outComp: $errMark"
            continue
        }
        if {![RB2W::moveMarkToComponent {elems elements} 1 $outComp]} {
            RB2W::log "Warning: could not batch-organize [llength $chunk] RBE2 element(s) into $outComp."
        } else {
            set moved [expr {$moved + [llength $chunk]}]
        }
        catch {*clearmark elems 1}
    }
    return $moved
}

proc ::RB2W::getLastCreatedOnMark {entityTypes markId} {
    foreach etype $entityTypes {
        if {![catch {set latest [hm_latestentityid $etype]}] && $latest ne "" && $latest != 0} {
            catch {*clearmark $etype $markId}
            if {![catch {*createmark $etype $markId $latest}]} {
                if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return [list $etype $ids] }
            }
        }
        catch {*clearmark $etype $markId}
        if {![catch {*createmark $etype $markId -1}]} {
            if {![catch {set ids [hm_getmark $etype $markId]}] && [llength $ids] > 0} { return [list $etype $ids] }
        }
    }
    return [list "" {}]
}

# ---------------- Existing RBE2 safety detection ----------------
proc ::RB2W::elemConfigLooksLikePlainShell {cfg} {
    set u [string toupper [string trim "$cfg"]]
    if {$u eq ""} { return 0 }
    if {[string first "RBE2" $u] >= 0 || [string first "RIGID" $u] >= 0} { return 0 }
    if {[regexp {(SHELL|TRIA|QUAD|CQUAD|CTRIA)} $u]} { return 1 }
    if {[regexp {^[0-9]+$} $u] && [lsearch -exact {103 104 106 108} $u] >= 0} { return 1 }
    return 0
}

proc ::RB2W::elemLooksLikeRBE2 {eid} {
    if {![catch {set cfg [hm_getvalue elems id=$eid dataname=config]}] && $cfg ne ""} {
        set u [string toupper "$cfg"]
        if {[string first "RBE2" $u] >= 0 || [string first "RIGIDLINK" $u] >= 0} { return 1 }
        if {[RB2W::elemConfigLooksLikePlainShell $cfg]} { return 0 }
    }

    # Fast/fuzzy string checks from common element data names.
    foreach dn {typename solverkeyword solvername cardimage} {
        if {![catch {set v [hm_getvalue elems id=$eid dataname=$dn]}] && $v ne ""} {
            set u [string toupper "$v"]
            if {[string first "RBE2" $u] >= 0 || [string first "RIGIDLINK" $u] >= 0} { return 1 }
        }
    }

    # Rigidlink-specific data name fallback.  Shell elements normally do not
    # expose dependentnodesmax; rigidlink/RBE2 elements do.
    if {![catch {set depmax [hm_getvalue elems id=$eid dataname=dependentnodesmax]}] && $depmax ne ""} {
        if {[catch {expr {$depmax > 0}} ok] == 0 && $ok} { return 1 }
    }
    return 0
}

proc ::RB2W::componentHasRBE2 {compId} {
    set elems [RB2W::getElemsByComp $compId]
    foreach e $elems {
        if {[RB2W::elemLooksLikeRBE2 $e]} { return [list 1 $e] }
    }
    return [list 0 ""]
}

proc ::RB2W::outputComponentCandidatesForSource {sourceCompId} {
    variable OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT
    set base [RB2W::sourceOutputBaseName $sourceCompId]
    set out {}
    if {[RB2W::componentExistsByName $base]} { lappend out $base } else { return $out }
    for {set i 1} {$i <= $OUTPUT_COMPONENT_SUFFIX_SCAN_LIMIT} {incr i} {
        set cand [format "%s_%02d" $base $i]
        if {![RB2W::componentExistsByName $cand]} { break }
        lappend out $cand
    }
    return $out
}

proc ::RB2W::existingRBE2CheckForSource {sourceCompId} {
    variable CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2
    variable CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2

    set srcName [RB2W::getComponentName $sourceCompId]

    if {$CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2} {
        foreach outName [RB2W::outputComponentCandidatesForSource $sourceCompId] {
            set outId [RB2W::componentIdByName $outName]
            if {$outId ne ""} {
                set chk [RB2W::componentHasRBE2 $outId]
                if {[lindex $chk 0]} {
                    return [list 1 "existing output component $outName contains RBE2 element [lindex $chk 1]"]
                }
            }
        }
    }

    if {$CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2} {
        set chk [RB2W::componentHasRBE2 $sourceCompId]
        if {[lindex $chk 0]} {
            return [list 1 "selected source component $srcName contains RBE2 element [lindex $chk 1]"]
        }
    }
    return [list 0 ""]
}

proc ::RB2W::createCenterNode {center outComp} {
    foreach {x y z} $center {}
    RB2W::setCurrentComponent $outComp
    catch {*clearmark nodes 1}
    *createnode $x $y $z 0 0 0
    set lastInfo [RB2W::getLastCreatedOnMark {nodes} 1]
    set newNodes [lindex $lastInfo 1]
    catch {*clearmark nodes 1}
    if {[llength $newNodes] == 0} { error "Center node was not created." }
    return [lindex $newNodes 0]
}

proc ::RB2W::createRigidLink {centerNode depNodes outComp} {
    variable RBE2_DOF
    set depNodes [RB2W::uniq $depNodes]
    if {[llength $depNodes] < 3} { error "Too few dependent nodes." }
    set idx [lsearch -exact $depNodes $centerNode]
    if {$idx >= 0} { set depNodes [lreplace $depNodes $idx $idx] }
    RB2W::setCurrentComponent $outComp
    set beforeElem ""
    catch {set beforeElem [hm_latestentityid elems]}
    catch {*clearmark nodes 2}
    eval *createmark nodes 2 $depNodes
    *rigidlink $centerNode 2 $RBE2_DOF
    catch {*clearmark nodes 2}
    set lastInfo [RB2W::getLastCreatedOnMark {elems elements} 1]
    set newElems [lindex $lastInfo 1]
    if {[llength $newElems] == 0} {
        set latestElem ""
        if {![catch {set latestElem [hm_latestentityid elems]}] && $latestElem ne "" && $latestElem != 0 && $latestElem ne $beforeElem} {
            set newElems [list $latestElem]
        }
    }
    if {[llength $newElems] == 0} {
        RB2W::log "Warning: created rigidlink for center node $centerNode, but could not capture the new element id for batch organization."
        return {}
    }
    return $newElems
}

proc ::RB2W::isValidHoleLoop {loopDict} {
    variable MIN_HOLE_DIAMETER
    variable MAX_HOLE_DIAMETER
    variable CIRCULARITY_TOL
    variable MIN_HOLE_EDGE_NODES
    variable MAX_HOLE_EDGE_NODES

    if {![dict get $loopDict closed]} { return [list 0 "open/free-edge branch"] }
    set nodes [dict get $loopDict nodes]
    set n [llength $nodes]
    if {$n < $MIN_HOLE_EDGE_NODES} { return [list 0 "too few edge nodes"] }
    if {$n > $MAX_HOLE_EDGE_NODES} { return [list 0 "too many edge nodes"] }
    if {[catch {set g [RB2W::loopGeometry $nodes]} err]} { return [list 0 "geometry error: $err"] }
    set r [lindex $g 1]
    set rel [lindex $g 2]
    set minr [lindex $g 3]
    set maxr [lindex $g 4]
    set dia [expr {2.0 * $r}]
    if {$dia < $MIN_HOLE_DIAMETER || $dia > $MAX_HOLE_DIAMETER} { return [list 0 [format "diameter %.3f out of range" $dia]] }
    if {$rel > $CIRCULARITY_TOL} { return [list 0 [format "poor circularity %.4f" $rel]] }
    if {$minr <= 1.0e-12 || ($maxr / $minr) > (1.0 + 3.0*$CIRCULARITY_TOL)} { return [list 0 [format "large radius ratio %.4f" [expr {$maxr / $minr}]]] }
    return [list 1 $g]
}

proc ::RB2W::validateWasherAndGetDepNodes {loopDict seedElems geom} {
    variable INNER_WASHER_NODE_LOOPS
    variable OUTER_RING_CIRCULARITY_TOL
    variable CENTER_OFFSET_TOL
    variable MIN_WASHER_WIDTH_ABS
    variable MIN_WASHER_WIDTH_RATIO
    variable WASHER_ELEM_COUNT_TOL
    variable MIN_OUTER_NODE_RATIO
    variable MAX_OUTER_NODE_RATIO
    variable MIN_HOLE_EDGE_NODES

    set innerNodes [dict get $loopDict nodes]
    set innerCount [llength $innerNodes]
    set edgeCount [llength [dict get $loopDict edges]]
    set center [lindex $geom 0]
    set innerR [lindex $geom 1]

    if {$INNER_WASHER_NODE_LOOPS < 2} { return [list 0 "invalid parameter: INNER_WASHER_NODE_LOOPS < 2" {}] }
    if {[llength $seedElems] == 0} { return [list 0 "no adjacent shell elements" {}] }
    set minSeedElems [expr {int(ceil($edgeCount * (1.0 - $WASHER_ELEM_COUNT_TOL)))}]
    if {$minSeedElems < 1} { set minSeedElems 1 }
    if {[llength $seedElems] < $minSeedElems} { return [list 0 "incomplete first washer ring" {}] }

    set elemLayerCount [expr {$INNER_WASHER_NODE_LOOPS - 1}]
    set tieElems [RB2W::expandElementLayers $seedElems $elemLayerCount]
    set depNodes [RB2W::nodesFromElems $tieElems]
    set outerNodes [RB2W::listSubtract $depNodes $innerNodes]
    set outerCount [llength $outerNodes]
    if {$outerCount < $MIN_HOLE_EDGE_NODES} { return [list 0 "no valid outer washer node loop" {}] }
    set outerRatio [expr {$outerCount / double($innerCount)}]
    if {$outerRatio < $MIN_OUTER_NODE_RATIO || $outerRatio > $MAX_OUTER_NODE_RATIO} { return [list 0 [format "outer node count abnormal %.2f" $outerRatio] {}] }
    if {[catch {set og [RB2W::loopGeometry $outerNodes]} err]} { return [list 0 "outer washer geometry error: $err" {}] }
    set outerCenter [lindex $og 0]
    set outerR [lindex $og 1]
    set outerRel [lindex $og 2]
    set centerDev [RB2W::distance3 $center $outerCenter]
    if {$outerR <= ($innerR + $MIN_WASHER_WIDTH_ABS) && $outerR <= ($innerR * (1.0 + $MIN_WASHER_WIDTH_RATIO))} { return [list 0 [format "washer width too small inner=%.3f outer=%.3f" $innerR $outerR] {}] }
    if {$outerRel > $OUTER_RING_CIRCULARITY_TOL} { return [list 0 [format "outer ring not washer-like %.4f" $outerRel] {}] }
    if {$innerR > 1.0e-12 && ($centerDev / $innerR) > $CENTER_OFFSET_TOL} { return [list 0 [format "outer ring center offset %.4f" [expr {$centerDev / $innerR}]] {}] }
    if {[llength $depNodes] <= [llength $innerNodes]} { return [list 0 "only inner free-edge nodes" {}] }
    set info [dict create depNodes $depNodes tieElems $tieElems outerNodes $outerNodes outerR $outerR outerRel $outerRel outerCount $outerCount]
    return [list 1 "ok" $info]
}

proc ::RB2W::processComponent {compId {compIndex 1} {compTotal 1}} {
    variable LOG_EACH_CREATED
    variable LOG_EACH_SKIPPED
    variable PROGRESS_LOOP_STEP
    variable UI_UPDATE_STEP
    variable BATCH_ORGANIZE_RBE2
    variable PERFORMANCE_MODE

    RB2W::clearNodeXYZCache
    array set reasons {}
    set elems [RB2W::getElemsByComp $compId]
    if {[llength $elems] == 0} {
        RB2W::log "Component $compId: no elements found, skipped."
        return [list 0 0 0 0]
    }

    set t0 [clock milliseconds]
    RB2W::buildGraph $elems
    set loops [RB2W::findFreeEdgeLoops]
    set tGraph [expr {[clock milliseconds] - $t0}]

    set created 0; set skipped 0; set candidateHoles 0
    set createdRBE2Elems {}
    set outComp ""
    set compName [RB2W::getComponentName $compId]
    set loopTotal [llength $loops]
    RB2W::log "Component $compId ($compName): elems=[llength $elems], freeEdgeLoops=$loopTotal, graphTime=${tGraph}ms"
    set overallPct0 [expr {100.0 * (($compIndex - 1) / double($compTotal))}]
    RB2W::overallStatus $overallPct0 $compIndex $compTotal $compName 0 $loopTotal $candidateHoles $created $skipped 1

    set loopIndex 0
    foreach loop $loops {
        incr loopIndex
        if {$loopIndex == 1 || ($PROGRESS_LOOP_STEP > 0 && ($loopIndex % $PROGRESS_LOOP_STEP) == 0) || $loopIndex == $loopTotal} {
            if {$loopTotal > 0} { set compFrac [expr {$loopIndex / double($loopTotal)}] } else { set compFrac 1.0 }
            set overallPct [expr {100.0 * (($compIndex - 1 + $compFrac) / double($compTotal))}]
            RB2W::overallStatus $overallPct $compIndex $compTotal $compName $loopIndex $loopTotal $candidateHoles $created $skipped [expr {$loopIndex == $loopTotal}]
        }
        if {$UI_UPDATE_STEP > 0 && ($loopIndex % $UI_UPDATE_STEP) == 0} { catch {update} }

        set validInfo [RB2W::isValidHoleLoop $loop]
        if {![lindex $validInfo 0]} {
            incr skipped
            RB2W::bumpReason reasons [lindex $validInfo 1]
            if {$LOG_EACH_SKIPPED} { RB2W::log "Component $compId: skipped loop, reason=[lindex $validInfo 1]" }
            continue
        }
        incr candidateHoles
        set geom [lindex $validInfo 1]
        set center [lindex $geom 0]
        set radius [lindex $geom 1]
        set rel [lindex $geom 2]
        set seedElems [RB2W::seedElemsFromLoop [dict get $loop edges]]
        set washerInfo [RB2W::validateWasherAndGetDepNodes $loop $seedElems $geom]
        if {![lindex $washerInfo 0]} {
            incr skipped
            RB2W::bumpReason reasons [lindex $washerInfo 1]
            if {$LOG_EACH_SKIPPED} { RB2W::log "Component $compId: skipped candidate hole D=[format %.3f [expr {2.0*$radius}]], reason=[lindex $washerInfo 1]" }
            continue
        }
        set wdict [lindex $washerInfo 2]
        set depNodes [dict get $wdict depNodes]
        set outerR [dict get $wdict outerR]
        set outerRel [dict get $wdict outerRel]
        set outerCount [dict get $wdict outerCount]

        if {$outComp eq ""} { set outComp [RB2W::ensureOutputComponent $compId] }
        if {[catch {
            set cnode [RB2W::createCenterNode $center $outComp]
            set rbeElems [RB2W::createRigidLink $cnode $depNodes $outComp]
            if {$BATCH_ORGANIZE_RBE2} {
                foreach re $rbeElems { lappend createdRBE2Elems $re }
            } else {
                catch {*clearmark elems 1}
                if {[llength $rbeElems] > 0} {
                    eval *createmark elems 1 $rbeElems
                    RB2W::moveMarkToComponent {elems elements} 1 $outComp
                    catch {*clearmark elems 1}
                }
            }
        } err]} {
            incr skipped
            RB2W::bumpReason reasons "create RBE2 failed"
            RB2W::log "Component $compId: failed at D=[format %.3f [expr {2.0*$radius}]], reason=$err"
            continue
        }

        incr created
        if {$LOG_EACH_CREATED} {
            RB2W::log "Component $compId: RBE2 #$created created in $outComp, centerNode=$cnode, rbeElems=$rbeElems, depNodes=[llength $depNodes], innerNodes=[llength [dict get $loop nodes]], outerNodes=$outerCount, innerD=[format %.3f [expr {2.0*$radius}]], outerD=[format %.3f [expr {2.0*$outerR}]], innerCirc=[format %.4f $rel], outerCirc=[format %.4f $outerRel]"
        }
    }

    set organizeMoved 0; set tOrganize 0
    if {$BATCH_ORGANIZE_RBE2 && [llength $createdRBE2Elems] > 0 && $outComp ne ""} {
        set tOrg0 [clock milliseconds]
        set organizeMoved [RB2W::organizeCreatedRBE2Elements $createdRBE2Elems $outComp]
        set tOrganize [expr {[clock milliseconds] - $tOrg0}]
        set needMove [llength [RB2W::uniq $createdRBE2Elems]]
        if {$organizeMoved < $needMove} { RB2W::log "Warning: component $compId batch-organized $organizeMoved/$needMove RBE2 element(s) into $outComp." }
    }
    if {!$PERFORMANCE_MODE && $outComp ne "" && $created > 0} {
        RB2W::showOutputComponent $outComp 0
    }

    set totalTime [expr {[clock milliseconds] - $t0}]
    set overallDone [expr {100.0 * ($compIndex / double($compTotal))}]
    RB2W::overallStatus $overallDone $compIndex $compTotal $compName $loopTotal $loopTotal $candidateHoles $created $skipped 1
    RB2W::log "Component $compId ($compName) summary: candidates=$candidateHoles, created=$created, skipped=$skipped, organizedRBE2=$organizeMoved, organizeTime=${tOrganize}ms, totalTime=${totalTime}ms, skipReasons={[RB2W::formatReasonStats reasons]}"
    RB2W::clearNodeXYZCache
    return [list $created $skipped $candidateHoles $organizeMoved]
}

proc ::RB2W::printParameterLog {} {
    variable VERSION
    variable MIN_HOLE_DIAMETER; variable MAX_HOLE_DIAMETER; variable CIRCULARITY_TOL
    variable MIN_HOLE_EDGE_NODES; variable MAX_HOLE_EDGE_NODES; variable INNER_WASHER_NODE_LOOPS
    variable OUTER_RING_CIRCULARITY_TOL; variable CENTER_OFFSET_TOL
    variable MIN_WASHER_WIDTH_ABS; variable MIN_WASHER_WIDTH_RATIO; variable WASHER_ELEM_COUNT_TOL
    variable RBE2_DOF; variable RBE2_COMPONENT_PREFIX
    variable BATCH_ORGANIZE_RBE2; variable ORGANIZE_BATCH_SIZE
    variable SHOW_OUTPUT_COMPONENTS; variable FORCE_BROWSER_REFRESH
    variable SKIP_COMPONENT_IF_EXISTING_RBE2; variable CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2; variable CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2
    variable PERFORMANCE_MODE; variable USE_NODE_XYZ_CACHE; variable USE_STATUS_PROGRESS
    variable PROGRESS_LOOP_STEP; variable UI_UPDATE_STEP; variable FORCE_STATUS_UPDATE
    variable STATUS_PERCENT_STEP; variable STATUS_MIN_INTERVAL_MS
    variable LOG_EACH_CREATED; variable LOG_EACH_SKIPPED

    RB2W::log "Version=$VERSION"
    RB2W::log "Parameters: diameter=${MIN_HOLE_DIAMETER}~${MAX_HOLE_DIAMETER}, innerCircTol=$CIRCULARITY_TOL, edgeNodes=${MIN_HOLE_EDGE_NODES}~${MAX_HOLE_EDGE_NODES}, innerWasherNodeLoops=$INNER_WASHER_NODE_LOOPS, outerCircTol=$OUTER_RING_CIRCULARITY_TOL, centerOffsetTol=$CENTER_OFFSET_TOL, minWasherWidthAbs=$MIN_WASHER_WIDTH_ABS, minWasherWidthRatio=$MIN_WASHER_WIDTH_RATIO, washerElemCountTol=$WASHER_ELEM_COUNT_TOL, dof=$RBE2_DOF, outputPrefix=$RBE2_COMPONENT_PREFIX, batchOrganizeRBE2=$BATCH_ORGANIZE_RBE2, organizeBatchSize=$ORGANIZE_BATCH_SIZE, showOutputComponents=$SHOW_OUTPUT_COMPONENTS, browserRefresh=$FORCE_BROWSER_REFRESH"
    RB2W::log "Safety: skipIfExistingRBE2=$SKIP_COMPONENT_IF_EXISTING_RBE2, checkSource=$CHECK_SOURCE_COMPONENT_FOR_EXISTING_RBE2, checkOutput=$CHECK_OUTPUT_COMPONENT_FOR_EXISTING_RBE2"
    RB2W::log "Performance: performanceMode=$PERFORMANCE_MODE, nodeXYZCache=$USE_NODE_XYZ_CACHE, statusProgress=$USE_STATUS_PROGRESS, progressStep=$PROGRESS_LOOP_STEP, uiUpdateStep=$UI_UPDATE_STEP, forceStatusUpdate=$FORCE_STATUS_UPDATE, statusPercentStep=$STATUS_PERCENT_STEP, statusMinIntervalMs=$STATUS_MIN_INTERVAL_MS, logEachCreated=$LOG_EACH_CREATED, logEachSkipped=$LOG_EACH_SKIPPED"
}

proc ::RB2W::main {} {
    variable outputCompBySource
    variable currentComponentName
    variable SKIP_COMPONENT_IF_EXISTING_RBE2
    variable PERFORMANCE_MODE
    RB2W::loadState
    set currentComponentName ""
    catch {array unset outputCompBySource}
    array set outputCompBySource {}
    RB2W::clearComponentElemCache

    set runStart [clock milliseconds]
    RB2W::log "==== Shell washer-hole RBE2 creation started ===="
    RB2W::printParameterLog
    RB2W::log "Select shell component(s) with standard washer mesh around bolt holes."

    catch {*clearmark comps 1}
    *createmarkpanel comps 1 "Select shell component(s) for washer-hole RBE2 creation"
    set comps [hm_getmark comps 1]
    catch {*clearmark comps 1}
    if {[llength $comps] == 0} {
        tk_messageBox -icon info -title "RB2W" -message "No component selected."
        RB2W::log "No component selected. Finished."
        RB2W::saveState
        return
    }

    set comps [RB2W::uniq $comps]
    RB2W::log "Selected components=[llength $comps]: $comps"

    set totalCreated 0; set totalSkipped 0; set totalCandidates 0; set totalOrganized 0
    set safetySkipped 0
    set safetyMessages {}

    RB2W::beginPerformanceMode
    RB2W::resetOverallProgress
    set procCode [catch {
        set compTotal [llength $comps]
        set compIndex 0
        foreach c $comps {
            incr compIndex
            set cname [RB2W::getComponentName $c]
            if {$SKIP_COMPONENT_IF_EXISTING_RBE2} {
                set check [RB2W::existingRBE2CheckForSource $c]
                if {[lindex $check 0]} {
                    incr safetySkipped
                    set reason [lindex $check 1]
                    lappend safetyMessages "$cname: $reason"
                    RB2W::log "Safety skip: source component $c ($cname) skipped because $reason."
                    set overallDone [expr {100.0 * ($compIndex / double($compTotal))}]
                    RB2W::overallStatus $overallDone $compIndex $compTotal $cname 0 0 0 0 0 1
                    continue
                }
            }
            set result [RB2W::processComponent $c $compIndex $compTotal]
            set totalCreated [expr {$totalCreated + [lindex $result 0]}]
            set totalSkipped [expr {$totalSkipped + [lindex $result 1]}]
            set totalCandidates [expr {$totalCandidates + [lindex $result 2]}]
            set totalOrganized [expr {$totalOrganized + [lindex $result 3]}]
            if {!$PERFORMANCE_MODE} { catch {update} }
        }
    } procErr procOpts]
    RB2W::endPerformanceMode

    if {$procCode} {
        set runMs [expr {[clock milliseconds] - $runStart}]
        RB2W::log "ERROR after ${runMs}ms: $procErr"
        tk_messageBox -icon error -title "RB2W" -message "Script stopped because of an error:\n$procErr"
        return -options $procOpts $procErr
    }

    set runMs [expr {[clock milliseconds] - $runStart}]
    set msg "Washer-hole RBE2 creation finished.\nSelected components: [llength $comps]\nSafety skipped components: $safetySkipped\nCandidate holes: $totalCandidates\nCreated RBE2: $totalCreated\nOrganized RBE2 elements: $totalOrganized\nSkipped loops/candidates: $totalSkipped\nRun time: ${runMs} ms"
    set outSummary [RB2W::outputComponentSummary]
    if {$outSummary ne ""} {
        append msg "\n\nOutput components:\n$outSummary"
    }
    if {$safetySkipped > 0} {
        set shown [lrange $safetyMessages 0 4]
        append msg "\n\nSafety skipped examples:\n[join $shown \n]"
        if {[llength $safetyMessages] > 5} { append msg "\n..." }
    }
    RB2W::status "RB2W overall 100.0% | finished | components=[llength $comps] | created=$totalCreated safetySkipped=$safetySkipped skipped=$totalSkipped candidates=$totalCandidates" 1
    RB2W::log "==== Finished: components=[llength $comps], safetySkipped=$safetySkipped, candidates=$totalCandidates, created=$totalCreated, organized=$totalOrganized, skipped=$totalSkipped, runtime=${runMs}ms ===="
    RB2W::saveState
    tk_messageBox -icon info -title "RB2W" -message $msg
}

proc ::RB2W::run {} {
    ::RB2W::main
}
