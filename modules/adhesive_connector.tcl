# ============================================================================
# Adhesive Area Connector
# HyperMesh 2019 / OptiStruct
#
# Creates and realizes an Area / adhesives connector from element locations.
# Location elements are cleaned before model modification: an element is kept
# only if its face samples project inside every target component's shell
# footprint within the tolerance.  The check is pure geometry; HyperMesh's
# hm_findprojected ("Find Projected" panel) rejects every call outside its
# panel context on the supported builds (2019.0.0.70 / 2022.0.0.33), so it is
# never used here.
# ============================================================================

if {![namespace exists ::HWFlow]} {
    source -encoding utf-8 [file join [file dirname [file normalize [info script]]] "workflow_common.tcl"]
}

namespace eval ::AdhesiveConnector {
    variable VERSION "1.2"

    variable cfg
    array set cfg {
        tolerance       50.0
        coats           1
        thickness_type  CONST_THICKNESS
        const_thickness 1.0
    }

    variable ui
    array set ui {
        selectedElems ""
        selectedComps ""
        selectionText "No entities selected"
        status        ""
        tolerance       50.0
        coats           1
        thickness_type  CONST_THICKNESS
        const_thickness 1.0
        cleaningActive  0
    }

    variable geometryElemNodes
    variable geometryElemConfig
    variable geometryNodeXYZ
    variable componentElemCache
    array set geometryElemNodes {}
    array set geometryElemConfig {}
    array set geometryNodeXYZ {}
    array set componentElemCache {}
}

proc ::AdhesiveConnector::uniq {values} {
    set result {}
    array set seen {}
    foreach value $values {
        if {$value eq "" || [info exists seen($value)]} { continue }
        set seen($value) 1
        lappend result $value
    }
    return $result
}

proc ::AdhesiveConnector::stateKeys {} {
    return {tolerance coats thickness_type const_thickness}
}

proc ::AdhesiveConnector::loadState {} {
    variable cfg
    variable ui
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray adhesive_connector ::AdhesiveConnector::cfg [::AdhesiveConnector::stateKeys]
    }
    foreach key [::AdhesiveConnector::stateKeys] { set ui($key) $cfg($key) }
}

proc ::AdhesiveConnector::saveState {} {
    variable cfg
    variable ui
    foreach key [::AdhesiveConnector::stateKeys] { set cfg($key) $ui($key) }
    if {[llength [info commands ::HWFlow::saveArrayState]] > 0} {
        ::HWFlow::saveArrayState adhesive_connector ::AdhesiveConnector::cfg
    }
}

proc ::AdhesiveConnector::savePanelState {} { catch {::AdhesiveConnector::saveState} }

proc ::AdhesiveConnector::message {text} {
    variable ui
    set ui(status) $text
    catch {hm_usermessage $text}
    catch {puts "AdhesiveConnector: $text"}
    catch {update idletasks}
}

proc ::AdhesiveConnector::responsiveCheckpoint {} {
    catch {update}
}

proc ::AdhesiveConnector::pickInputs {} {
    variable ui
    if {$ui(cleaningActive)} { return 0 }
    set requests [list \
        [list elems 1 [::HWFlow::txt \
            "选择打胶区域单元（中键确认）" \
            "Select adhesive location elements (middle-click to accept)"] 1 6] \
        [list comps 2 [::HWFlow::txt \
            "选择需要连接的组件（中键确认）" \
            "Select components to connect (middle-click to accept)"]]]
    if {[catch {set selections [::HWFlow::nativeMarkPanelSequence $requests]} err]} {
        tk_messageBox -icon error -title [::HWFlow::txt "打胶连接" "Adhesive Connector"] -message $err
        return 0
    }
    set ui(selectedElems) [::AdhesiveConnector::uniq [lindex $selections 0]]
    set ui(selectedComps) [::AdhesiveConnector::uniq [lindex $selections 1]]
    if {[llength $ui(selectedElems)] == 0 || [llength $ui(selectedComps)] < 2} {
        set ui(selectionText) [::HWFlow::txt "请选择 location 单元和至少两个目标组件" "Select location elements and at least two link components"]
        return 0
    }
    set ui(selectionText) [::HWFlow::txt \
        "Location：[llength $ui(selectedElems)] 个单元；Links：[llength $ui(selectedComps)] 个组件" \
        "Location: [llength $ui(selectedElems)] elems; Links: [llength $ui(selectedComps)] comps"]
    return 1
}

proc ::AdhesiveConnector::elementNodes {elementId} {
    variable geometryElemNodes
    if {[info exists geometryElemNodes($elementId)]} { return $geometryElemNodes($elementId) }
    foreach dataName {nodes nodeids} {
        if {![catch {set values [hm_getvalue elems id=$elementId dataname=$dataName]}] && [llength $values] >= 3} {
            return $values
        }
    }
    error "Cannot read nodes for element $elementId"
}

proc ::AdhesiveConnector::nodeXYZ {nodeId} {
    variable geometryNodeXYZ
    if {[info exists geometryNodeXYZ($nodeId)]} { return $geometryNodeXYZ($nodeId) }
    set xyz {}
    foreach dataName {x y z} {
        if {[catch {set value [hm_getvalue nodes id=$nodeId dataname=$dataName]}] ||
            ![string is double -strict $value]} {
            set xyz {}
            break
        }
        lappend xyz [expr {double($value)}]
    }
    if {[llength $xyz] == 3} { return $xyz }
    if {![catch {set xyz [hm_nodevalue $nodeId]}] && [llength $xyz] >= 3} {
        return [lrange $xyz 0 2]
    }
    error "Cannot read coordinates for node $nodeId"
}

proc ::AdhesiveConnector::elementComponentId {elementId} {
    foreach dataName {collector.id component.id comp.id} {
        if {![catch {set value [hm_getvalue elems id=$elementId dataname=$dataName]}] &&
            [string is integer -strict $value] && $value > 0} {
            return $value
        }
    }
    return ""
}

proc ::AdhesiveConnector::isShellElement {elementId} {
    variable geometryElemConfig
    set config ""
    if {[info exists geometryElemConfig($elementId)]} {
        set config $geometryElemConfig($elementId)
    } else {
        catch {set config [hm_getvalue elems id=$elementId dataname=config]}
    }
    set normalized [string toupper [string trim $config]]
    if {$normalized ne ""} {
        if {$normalized in {103 104 106 108 TRIA3 CTRIA3 QUAD4 CQUAD4}} { return 1 }
        if {[regexp {(SHELL|C?TRIA|C?QUAD)} $normalized]} { return 1 }
        return 0
    }
    set nodeCount [llength [::AdhesiveConnector::elementNodes $elementId]]
    return [expr {$nodeCount >= 3 && $nodeCount <= 4}]
}

proc ::AdhesiveConnector::componentElements {componentId} {
    variable componentElemCache
    if {[info exists componentElemCache($componentId)]} { return $componentElemCache($componentId) }
    catch {*clearmark elems 1}
    *createmark elems 1 "by comp id" $componentId
    return [hm_getmark elems 1]
}

proc ::AdhesiveConnector::primeGeometryCache {selectedElems componentIds {includeCoordinates 1}} {
    variable geometryElemNodes
    variable geometryElemConfig
    variable geometryNodeXYZ
    variable componentElemCache
    array unset geometryElemNodes *
    array unset geometryElemConfig *
    array unset geometryNodeXYZ *
    array unset componentElemCache *

    set allElems $selectedElems
    foreach componentId $componentIds {
        catch {*clearmark elems 1}
        *createmark elems 1 "by comp id" $componentId
        set componentElemCache($componentId) [hm_getmark elems 1]
        set allElems [concat $allElems $componentElemCache($componentId)]
    }
    set allElems [::AdhesiveConnector::uniq $allElems]
    if {[llength $allElems] == 0} { return }

    # hm_getvalue ... mark=N returns rows ordered by entity ID, not in mark
    # creation order (verified headless on 2019.0.0.70 and 2022.0.0.33).
    # Sort so the row index maps back onto the right element.
    set allElems [lsort -integer $allElems]
    catch {*clearmark elems 1}
    eval *createmark elems 1 $allElems
    foreach elementId $allElems { set geometryElemConfig($elementId) "" }
    if {![catch {set configRows [hm_getvalue elems mark=1 dataname=config]}] &&
        [llength $configRows] == [llength $allElems]} {
        for {set index 0} {$index < [llength $allElems]} {incr index} {
            set geometryElemConfig([lindex $allElems $index]) [lindex $configRows $index]
        }
    }
    if {[catch {set nodeRows [hm_getvalue elems mark=1 dataname=nodes]}] ||
        [llength $nodeRows] != [llength $allElems]} {
        return
    }
    set allNodes {}
    for {set index 0} {$index < [llength $allElems]} {incr index} {
        set elementId [lindex $allElems $index]
        set geometryElemNodes($elementId) [lindex $nodeRows $index]
        lappend allNodes {*}$geometryElemNodes($elementId)
    }
    set allNodes [lsort -unique -integer $allNodes]
    if {!$includeCoordinates} { return }
    catch {*clearmark nodes 2}
    eval *createmark nodes 2 $allNodes
    if {[catch {set coordinateRows [hm_getvalue nodes mark=2 dataname=coordinates]}] ||
        [llength $coordinateRows] != [llength $allNodes]} {
        return
    }
    for {set index 0} {$index < [llength $allNodes]} {incr index} {
        set geometryNodeXYZ([lindex $allNodes $index]) [lindex $coordinateRows $index]
    }
}

proc ::AdhesiveConnector::vsub {a b} {
    return [list \
        [expr {double([lindex $a 0]) - double([lindex $b 0])}] \
        [expr {double([lindex $a 1]) - double([lindex $b 1])}] \
        [expr {double([lindex $a 2]) - double([lindex $b 2])}]]
}

proc ::AdhesiveConnector::vaddScaled {a b scale} {
    return [list \
        [expr {double([lindex $a 0]) + $scale*double([lindex $b 0])}] \
        [expr {double([lindex $a 1]) + $scale*double([lindex $b 1])}] \
        [expr {double([lindex $a 2]) + $scale*double([lindex $b 2])}]]
}

proc ::AdhesiveConnector::dot {a b} {
    return [expr {
        double([lindex $a 0])*double([lindex $b 0]) +
        double([lindex $a 1])*double([lindex $b 1]) +
        double([lindex $a 2])*double([lindex $b 2])}]
}

proc ::AdhesiveConnector::cross {a b} {
    lassign $a ax ay az
    lassign $b bx by bz
    return [list \
        [expr {$ay*$bz-$az*$by}] \
        [expr {$az*$bx-$ax*$bz}] \
        [expr {$ax*$by-$ay*$bx}]]
}

proc ::AdhesiveConnector::normalized {value} {
    set length [expr {sqrt([::AdhesiveConnector::dot $value $value])}]
    if {$length <= 1.0e-12} { return "" }
    return [list \
        [expr {[lindex $value 0]/$length}] \
        [expr {[lindex $value 1]/$length}] \
        [expr {[lindex $value 2]/$length}]]
}

proc ::AdhesiveConnector::polygonNormal {points} {
    if {[llength $points] < 3} { return "" }
    set origin [lindex $points 0]
    for {set index 1} {$index < [llength $points]-1} {incr index} {
        set a [::AdhesiveConnector::vsub [lindex $points $index] $origin]
        set b [::AdhesiveConnector::vsub [lindex $points [expr {$index+1}]] $origin]
        set normal [::AdhesiveConnector::normalized [::AdhesiveConnector::cross $a $b]]
        if {$normal ne ""} { return $normal }
    }
    return ""
}

proc ::AdhesiveConnector::pointInTriangle {point a b c} {
    set v0 [::AdhesiveConnector::vsub $c $a]
    set v1 [::AdhesiveConnector::vsub $b $a]
    set v2 [::AdhesiveConnector::vsub $point $a]
    set dot00 [::AdhesiveConnector::dot $v0 $v0]
    set dot01 [::AdhesiveConnector::dot $v0 $v1]
    set dot02 [::AdhesiveConnector::dot $v0 $v2]
    set dot11 [::AdhesiveConnector::dot $v1 $v1]
    set dot12 [::AdhesiveConnector::dot $v1 $v2]
    set denominator [expr {$dot00*$dot11-$dot01*$dot01}]
    if {abs($denominator) <= 1.0e-14} { return 0 }
    set u [expr {($dot11*$dot02-$dot01*$dot12)/$denominator}]
    set v [expr {($dot00*$dot12-$dot01*$dot02)/$denominator}]
    set epsilon 1.0e-7
    return [expr {$u >= -$epsilon && $v >= -$epsilon && $u+$v <= 1.0+$epsilon}]
}

proc ::AdhesiveConnector::pointInPolygon {point points} {
    set origin [lindex $points 0]
    for {set index 1} {$index < [llength $points]-1} {incr index} {
        if {[::AdhesiveConnector::pointInTriangle $point $origin \
            [lindex $points $index] [lindex $points [expr {$index+1}]]]} {
            return 1
        }
    }
    return 0
}

proc ::AdhesiveConnector::polygonBounds {points} {
    if {[llength $points] == 0} { return [list {0 0 0} {0 0 0}] }
    set minimum [lindex $points 0]
    set maximum $minimum
    foreach point [lrange $points 1 end] {
        for {set axis 0} {$axis < 3} {incr axis} {
            set value [lindex $point $axis]
            if {$value < [lindex $minimum $axis]} { lset minimum $axis $value }
            if {$value > [lindex $maximum $axis]} { lset maximum $axis $value }
        }
    }
    return [list $minimum $maximum]
}

proc ::AdhesiveConnector::gridCoordinate {value cellSize} {
    return [expr {int(floor(double($value)/double($cellSize)))}]
}

proc ::AdhesiveConnector::normalAxis {normal} {
    # The dominant axis of a polygon normal: the projection direction in
    # which the polygon is "thin".  The grid expands only this axis by the
    # tolerance, so a projected sample (offset <= tolerance from the face)
    # always lands in an expanded layer while the in-plane axes keep the
    # cell population at the local mesh density.
    set axis 0
    set best [expr {abs([lindex $normal 0])}]
    for {set candidate 1} {$candidate < 3} {incr candidate} {
        set magnitude [expr {abs([lindex $normal $candidate])}]
        if {$magnitude > $best} { set axis $candidate; set best $magnitude }
    }
    return $axis
}

proc ::AdhesiveConnector::buildPolygonGrid {polygons tolerance} {
    set sampled 0
    set spanSum 0.0
    foreach polygon [lrange $polygons 0 99] {
        lassign [::AdhesiveConnector::polygonBounds [dict get $polygon points]] minimum maximum
        set axisN [::AdhesiveConnector::normalAxis [dict get $polygon normal]]
        set span 0.0
        for {set axis 0} {$axis < 3} {incr axis} {
            if {$axis == $axisN} { continue }
            set axisSpan [expr {double([lindex $maximum $axis]) - double([lindex $minimum $axis])}]
            if {$axisSpan > $span} { set span $axisSpan }
        }
        if {$span > 1.0e-9} { set spanSum [expr {$spanSum+$span}]; incr sampled }
    }
    set typicalSpan [expr {$sampled > 0 ? $spanSum/double($sampled) : 0.0}]
    # The cell follows the mesh density, not the tolerance: a large
    # tolerance must only widen the normal-axis layers, otherwise a coarse
    # tolerance collapses the whole component into one cell and every sample
    # point scans every polygon.
    set cellSize [expr {max(2.0*$typicalSpan, 1.0e-6)}]
    set grid [dict create __cell_size__ $cellSize]
    set polygonIndex 0
    foreach polygon $polygons {
        lassign [::AdhesiveConnector::polygonBounds [dict get $polygon points]] minimum maximum
        set axisN [::AdhesiveConnector::normalAxis [dict get $polygon normal]]
        set ranges {}
        for {set axis 0} {$axis < 3} {incr axis} {
            # The normal axis expands by the tolerance (a projected sample
            # sits up to `tolerance` off the face); the in-plane axes get a
            # one-cell margin so a slightly oblique projection (offset less
            # than one cell) still finds its polygon.
            set margin [expr {$axis == $axisN ? double($tolerance) : $cellSize}]
            set first [::AdhesiveConnector::gridCoordinate \
                [expr {double([lindex $minimum $axis])-$margin}] $cellSize]
            set last [::AdhesiveConnector::gridCoordinate \
                [expr {double([lindex $maximum $axis])+$margin}] $cellSize]
            lappend ranges [list $first $last]
        }
        lassign [lindex $ranges 0] x0 x1
        lassign [lindex $ranges 1] y0 y1
        lassign [lindex $ranges 2] z0 z1
        for {set ix $x0} {$ix <= $x1} {incr ix} {
            for {set iy $y0} {$iy <= $y1} {incr iy} {
                for {set iz $z0} {$iz <= $z1} {incr iz} {
                    dict lappend grid "$ix,$iy,$iz" $polygonIndex
                }
            }
        }
        incr polygonIndex
        if {$polygonIndex % 500 == 0} { ::AdhesiveConnector::responsiveCheckpoint }
    }
    return $grid
}

proc ::AdhesiveConnector::nearbyPolygonIndices {point grid} {
    if {![dict exists $grid __cell_size__]} { return {} }
    set cellSize [dict get $grid __cell_size__]
    set key "[::AdhesiveConnector::gridCoordinate [lindex $point 0] $cellSize],[::AdhesiveConnector::gridCoordinate [lindex $point 1] $cellSize],[::AdhesiveConnector::gridCoordinate [lindex $point 2] $cellSize]"
    if {![dict exists $grid $key]} { return {} }
    return [dict get $grid $key]
}

proc ::AdhesiveConnector::projectionHitsPolygon {point direction polygon tolerance} {
    set points [dict get $polygon points]
    set normal [dict get $polygon normal]
    set denominator [::AdhesiveConnector::dot $direction $normal]
    if {abs($denominator) <= 1.0e-10} { return 0 }
    set distance [expr {[::AdhesiveConnector::dot \
        [::AdhesiveConnector::vsub [lindex $points 0] $point] $normal]/$denominator}]
    if {abs($distance) > double($tolerance)+1.0e-7} { return 0 }
    set projected [::AdhesiveConnector::vaddScaled $point $direction $distance]
    return [::AdhesiveConnector::pointInPolygon $projected $points]
}

proc ::AdhesiveConnector::elementPoints {elementId} {
    set result {}
    foreach nodeId [::AdhesiveConnector::elementNodes $elementId] {
        lappend result [::AdhesiveConnector::nodeXYZ $nodeId]
    }
    return $result
}

proc ::AdhesiveConnector::samplePoints {points} {
    set samples $points
    set count [llength $points]
    set center {0.0 0.0 0.0}
    for {set index 0} {$index < $count} {incr index} {
        set a [lindex $points $index]
        set b [lindex $points [expr {($index+1)%$count}]]
        lappend samples [::AdhesiveConnector::vaddScaled $a [::AdhesiveConnector::vsub $b $a] 0.5]
        set center [::AdhesiveConnector::vaddScaled $center $a [expr {1.0/$count}]]
    }
    lappend samples $center
    return $samples
}

proc ::AdhesiveConnector::componentPolygons {componentId} {
    set result {}
    set processed 0
    foreach elementId [::AdhesiveConnector::componentElements $componentId] {
        incr processed
        if {$processed % 500 == 0} { ::AdhesiveConnector::responsiveCheckpoint }
        if {![::AdhesiveConnector::isShellElement $elementId]} { continue }
        if {[catch {set points [::AdhesiveConnector::elementPoints $elementId]}]} { continue }
        # Adhesive footprints are shell faces.  A solid element node list is
        # not a surface polygon and must never be accepted as one implicitly.
        if {[llength $points] < 3 || [llength $points] > 4} { continue }
        set normal [::AdhesiveConnector::polygonNormal $points]
        if {$normal eq ""} { continue }
        lappend result [dict create elem $elementId points $points normal $normal]
    }
    return $result
}

proc ::AdhesiveConnector::pointsProjectInside {samples direction polygons polygonGrid tolerance} {
    foreach point $samples {
        set hit 0
        foreach polygonIndex [::AdhesiveConnector::nearbyPolygonIndices $point $polygonGrid] {
            set polygon [lindex $polygons $polygonIndex]
            if {[::AdhesiveConnector::projectionHitsPolygon $point $direction $polygon $tolerance]} {
                set hit 1
                break
            }
        }
        if {!$hit} { return 0 }
    }
    return 1
}

proc ::AdhesiveConnector::cleanLocationElemsFallback {elementIds componentIds tolerance} {
    set componentIds [::AdhesiveConnector::uniq $componentIds]
    set elementIds [::AdhesiveConnector::uniq $elementIds]
    array set sourceComponentByElement {}
    set sourceComponents {}
    foreach elementId $elementIds {
        if {[catch {set sourceComponent [::AdhesiveConnector::elementComponentId $elementId]}]} {
            set sourceComponent ""
        }
        set sourceComponentByElement($elementId) $sourceComponent
        if {$sourceComponent ne ""} { lappend sourceComponents $sourceComponent }
    }
    set sourceComponents [::AdhesiveConnector::uniq $sourceComponents]
    set commonSourceComponent ""
    if {[llength $sourceComponents] == 1} {
        set commonSourceComponent [lindex $sourceComponents 0]
    }

    array set polygonsByComponent {}
    array set polygonGridByComponent {}
    foreach componentId $componentIds {
        if {$componentId eq $commonSourceComponent} {
            set polygonsByComponent($componentId) {}
            set polygonGridByComponent($componentId) [dict create __cell_size__ [expr {max(double($tolerance), 1.0e-6)}]]
            continue
        }
        set polygonsByComponent($componentId) [::AdhesiveConnector::componentPolygons $componentId]
        set polygonGridByComponent($componentId) [::AdhesiveConnector::buildPolygonGrid \
            $polygonsByComponent($componentId) $tolerance]
    }

    set kept {}
    set rejected {}
    foreach elementId $elementIds {
        if {[catch {set isShell [::AdhesiveConnector::isShellElement $elementId]}] || !$isShell} {
            lappend rejected $elementId
            continue
        }
        if {[catch {
            set points [::AdhesiveConnector::elementPoints $elementId]
            set direction [::AdhesiveConnector::polygonNormal $points]
            set sourceComponent $sourceComponentByElement($elementId)
        }] || [llength $points] < 3 || [llength $points] > 4 || $direction eq ""} {
            lappend rejected $elementId
            continue
        }
        set samples [::AdhesiveConnector::samplePoints $points]
        set checkedTargets 0
        set accepted 1
        foreach componentId $componentIds {
            if {$componentId eq $sourceComponent} { continue }
            incr checkedTargets
            if {[llength $polygonsByComponent($componentId)] == 0 ||
                ![::AdhesiveConnector::pointsProjectInside $samples $direction \
                    $polygonsByComponent($componentId) $polygonGridByComponent($componentId) $tolerance]} {
                set accepted 0
                break
            }
        }
        if {$checkedTargets == 0} { set accepted 0 }
        if {$accepted} { lappend kept $elementId } else { lappend rejected $elementId }
        if {([llength $kept]+[llength $rejected]) % 100 == 0} { ::AdhesiveConnector::responsiveCheckpoint }
    }
    return [dict create kept $kept rejected $rejected]
}

proc ::AdhesiveConnector::cleanLocationElems {elementIds componentIds tolerance} {
    # Geometry-only cleaning.  The "native" fast path (hm_findprojected, the
    # Find Projected panel command) is not usable on the supported builds
    # (2019.0.0.70 / 2022.0.0.33): outside its panel context every call - even
    # the exact shape recorded by HyperForm - returns a usage error, so the
    # projected-node mark is always empty and every location element would be
    # rejected.  cleanLocationElemsFallback performs the same footprint check
    # in pure Tcl (face samples projected onto each target component's shell
    # polygons within the tolerance) and is verified offline and headless.
    if {[llength [info commands *createmark]] > 0} {
        ::AdhesiveConnector::primeGeometryCache $elementIds $componentIds
    }
    return [::AdhesiveConnector::cleanLocationElemsFallback $elementIds $componentIds $tolerance]
}

proc ::AdhesiveConnector::adhesivesFeType {feConfigPath} {
    if {![file isfile $feConfigPath]} { error "Connector configuration not found: $feConfigPath" }
    set channel [open $feConfigPath r]
    set text [read $channel]
    close $channel
    foreach raw [split $text "\n"] {
        set line [string trim $raw]
        if {[regexp -nocase {^CFG[ \t]+optistruct[ \t]+([0-9]+)[ \t]+"?adhesives"?([ \t]|$)} $line -> typeId]} {
            return $typeId
        }
    }
    error "OptiStruct Area realization type 'adhesives' was not found in $feConfigPath"
}

proc ::AdhesiveConnector::realizationOptions {tolerance coats constThickness feConfigPath} {
    return [list \
        "link_elems_geom=elems" \
        "link_rule=now" \
        "relink_rule=none" \
        "tol_flag=1" \
        "tol=[format %.6f $tolerance]" \
        "seam_area_group=0" \
        "ce_areathicknesstype=3" \
        "ce_areaconstthickness=[format %.6f $constThickness]" \
        "ce_areastacksize=$coats" \
        "ce_prop_opt=1" \
        "ce_propertyid=0" \
        "ce_propertyscript=" \
        "ce_configfile=$feConfigPath"]
}

proc ::AdhesiveConnector::snapshotConnectors {} {
    catch {*clearmark connectors 1}
    *createmark connectors 1 all
    return [hm_getmark connectors 1]
}

proc ::AdhesiveConnector::newIds {before after} {
    set result {}
    foreach value $after {
        if {[lsearch -exact $before $value] < 0} { lappend result $value }
    }
    return $result
}

proc ::AdhesiveConnector::validateParameters {} {
    variable ui
    if {![string is double -strict $ui(tolerance)] || double($ui(tolerance)) <= 0.0} {
        error [::HWFlow::txt "Tolerance 必须大于 0。" "Tolerance must be greater than zero."]
    }
    if {![string is integer -strict $ui(coats)] || $ui(coats) < 1} {
        error [::HWFlow::txt "Coats 必须是大于等于 1 的整数。" "Coats must be an integer of at least 1."]
    }
    if {$ui(thickness_type) ne "CONST_THICKNESS"} {
        error [::HWFlow::txt "当前模块仅支持 const_thickness。" "This module currently supports const_thickness only."]
    }
    if {![string is double -strict $ui(const_thickness)] || double($ui(const_thickness)) <= 0.0} {
        error [::HWFlow::txt "Const thickness 必须大于 0。" "Const thickness must be greater than zero."]
    }
}

proc ::AdhesiveConnector::createAdhesive {} {
    variable ui
    if {$ui(cleaningActive)} { return 0 }
    if {[catch {::AdhesiveConnector::validateParameters} err]} {
        tk_messageBox -icon warning -title [::HWFlow::txt "打胶连接" "Adhesive Connector"] -message $err
        return 0
    }
    if {[llength $ui(selectedElems)] == 0 || [llength $ui(selectedComps)] < 2} {
        tk_messageBox -icon warning -title [::HWFlow::txt "打胶连接" "Adhesive Connector"] \
            -message [::HWFlow::txt "请先选择 location 单元和至少两个目标组件。" "Select location elements and at least two link components first."]
        return 0
    }

    ::AdhesiveConnector::message [::HWFlow::txt "正在清洗超出目标组件投影范围的单元..." "Removing elements outside the target-component projection footprint..."]
    set ui(cleaningActive) 1
    set cleanCode [catch {
        set cleanResult [::AdhesiveConnector::cleanLocationElems \
            $ui(selectedElems) $ui(selectedComps) $ui(tolerance)]
    } err]
    set ui(cleaningActive) 0
    if {$cleanCode} {
        tk_messageBox -icon error -title [::HWFlow::txt "打胶连接" "Adhesive Connector"] -message $err
        return 0
    }
    set cleanedElems [dict get $cleanResult kept]
    set rejectedElems [dict get $cleanResult rejected]
    if {[llength $cleanedElems] == 0} {
        tk_messageBox -icon warning -title [::HWFlow::txt "打胶连接" "Adhesive Connector"] -message [::HWFlow::txt \
            "清洗后没有可用单元。所选单元必须完整投影在每个目标组件范围内。" \
            "No elements remain after cleaning. Each selected element must project completely inside every target component."]
        return 0
    }

    if {[catch {
        set executableDir [hm_info -appinfo EXECUTABLEDIR]
        set feConfigPath [file join $executableDir feconfig.cfg]
        set feType [::AdhesiveConnector::adhesivesFeType $feConfigPath]
        set options [::AdhesiveConnector::realizationOptions \
            $ui(tolerance) $ui(coats) $ui(const_thickness) $feConfigPath]
        set beforeConnectors [::AdhesiveConnector::snapshotConnectors]

        eval *createmark elems 1 $cleanedElems
        eval *createmark comps 2 $ui(selectedComps)
        eval *createstringarray [llength $options] $options
        set numLinks [llength $ui(selectedComps)]
        *CE_ConnectorCreateByMarkAndRealizeWithDetails elems 1 area $numLinks comps 2 optistruct 1001 $feType $ui(tolerance) 1 [llength $options]

        set afterConnectors [::AdhesiveConnector::snapshotConnectors]
        set connectorIds [::AdhesiveConnector::newIds $beforeConnectors $afterConnectors]
        if {[llength $connectorIds] == 0} { error "HyperMesh created no Area connector" }
        foreach connectorId $connectorIds {
            if {[catch {set state [string toupper [hm_ce_state $connectorId]]}] || $state ne "REALIZED"} {
                error "Area connector $connectorId is not REALIZED"
            }
        }
    } err]} {
        tk_messageBox -icon error -title [::HWFlow::txt "打胶连接" "Adhesive Connector"] -message $err
        return 0
    }

    ::AdhesiveConnector::saveState
    set ui(selectedElems) $cleanedElems
    set ui(selectionText) [::HWFlow::txt \
        "已创建 [llength $connectorIds] 个连接；保留 [llength $cleanedElems] 个 location 单元；清洗 [llength $rejectedElems] 个" \
        "Created [llength $connectorIds] connector(s); kept [llength $cleanedElems] location elems; removed [llength $rejectedElems]"]
    ::AdhesiveConnector::message $ui(selectionText)
    tk_messageBox -icon info -title [::HWFlow::txt "打胶连接" "Adhesive Connector"] -message $ui(selectionText)
    return 1
}

proc ::AdhesiveConnector::runAction {} { ::AdhesiveConnector::showPanel 0 }
proc ::AdhesiveConnector::runSettings {} { ::AdhesiveConnector::showPanel 1 }

proc ::AdhesiveConnector::showPanel {{settingsOnly 0}} {
    variable VERSION
    variable ui
    ::AdhesiveConnector::loadState
    set ui(status) [::HWFlow::txt \
        "先选 elems 作为 location，再选 comps 作为连接目标；创建前会自动清洗越界单元。" \
        "Pick elems as location, then comps as links. Out-of-footprint elements are removed before creation."]

    catch {destroy .adhesive_connector}
    set w .adhesive_connector
    ::HWFlow::createTopLevel $w
    wm title $w [::HWFlow::windowTitle "[::HWFlow::txt "打胶连接" "Adhesive Connector"] v$VERSION" "Adhesive Connector v$VERSION"]
    wm resizable $w 0 0

    frame $w.main -padx 12 -pady 10
    pack $w.main -fill both -expand 1
    label $w.main.title -text [::HWFlow::txt "Area Adhesives 打胶" "Area Adhesives Connector"] -font [::HWFlow::uiFont title]
    grid $w.main.title -row 0 -column 0 -columnspan 4 -sticky w -pady {0 8}

    labelframe $w.main.selection -text [::HWFlow::txt "1. 选择" "1. Selection"] -padx 8 -pady 8
    grid $w.main.selection -row 1 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    button $w.main.selection.pick -text [::HWFlow::txt "选择 elems + comps" "Pick elems + comps"] -width 20 -command ::AdhesiveConnector::pickInputs
    label $w.main.selection.info -textvariable ::AdhesiveConnector::ui(selectionText) -width 66 -anchor w
    grid $w.main.selection.pick -row 0 -column 0 -padx {0 8}
    grid $w.main.selection.info -row 0 -column 1 -sticky w

    labelframe $w.main.parameters -text [::HWFlow::txt "2. Adhesives 参数" "2. Adhesives Parameters"] -padx 8 -pady 8
    grid $w.main.parameters -row 2 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.parameters.lt -text "Tolerance"
    entry $w.main.parameters.et -textvariable ::AdhesiveConnector::ui(tolerance) -width 12
    label $w.main.parameters.lc -text "Coats"
    entry $w.main.parameters.ec -textvariable ::AdhesiveConnector::ui(coats) -width 12
    label $w.main.parameters.ltt -text [::HWFlow::txt "厚度类型" "Thickness type"]
    tk_optionMenu $w.main.parameters.mtt ::AdhesiveConnector::ui(thickness_type) CONST_THICKNESS
    label $w.main.parameters.lct -text "Const thickness"
    entry $w.main.parameters.ect -textvariable ::AdhesiveConnector::ui(const_thickness) -width 12
    grid $w.main.parameters.lt -row 0 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.parameters.et -row 0 -column 1 -sticky w -padx {0 18} -pady 2
    grid $w.main.parameters.lc -row 0 -column 2 -sticky w -padx {0 6} -pady 2
    grid $w.main.parameters.ec -row 0 -column 3 -sticky w -pady 2
    grid $w.main.parameters.ltt -row 1 -column 0 -sticky w -padx {0 6} -pady 2
    grid $w.main.parameters.mtt -row 1 -column 1 -sticky w -padx {0 18} -pady 2
    grid $w.main.parameters.lct -row 1 -column 2 -sticky w -padx {0 6} -pady 2
    grid $w.main.parameters.ect -row 1 -column 3 -sticky w -pady 2

    label $w.main.note -text [::HWFlow::txt \
        "固定流程：1D Connector Area / adhesives / no-skip post script。越界 location elems 不会传给 HyperMesh。" \
        "Fixed flow: 1D Connector Area / adhesives / no-skip post script. Out-of-footprint location elems are never submitted."] -justify left -anchor w
    grid $w.main.note -row 3 -column 0 -columnspan 4 -sticky ew -pady {0 8}
    label $w.main.status -textvariable ::AdhesiveConnector::ui(status) -width 92 -anchor w
    grid $w.main.status -row 4 -column 0 -columnspan 4 -sticky ew

    frame $w.buttons -padx 12 -pady 10
    pack $w.buttons -fill x
    button $w.buttons.back -text [::HWFlow::txt "返回主页" "Back to Home"] -width 14 \
        -command "::AdhesiveConnector::savePanelState; ::HWFlow::backToHome .adhesive_connector"
    button $w.buttons.save -text [::HWFlow::txt "保存参数" "Save Parameters"] -width 14 -command ::AdhesiveConnector::saveState
    pack $w.buttons.back -side right -padx 4
    if {!$settingsOnly} {
        button $w.buttons.create -text [::HWFlow::txt "创建打胶" "Create Adhesive"] -width 14 -command ::AdhesiveConnector::createAdhesive
        pack $w.buttons.create -side right -padx 4
    }
    pack $w.buttons.save -side right -padx 4

    bind $w <Escape> "::AdhesiveConnector::savePanelState; destroy .adhesive_connector"
    wm protocol $w WM_DELETE_WINDOW "::AdhesiveConnector::savePanelState; destroy .adhesive_connector"
    tkwait window $w
}
