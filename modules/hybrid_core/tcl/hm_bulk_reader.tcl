proc ::HybridCore::cooperativeYield {} {
    variable cooperativeYieldSequence
    if {![info exists cooperativeYieldSequence]} { set cooperativeYieldSequence 0 }
    incr cooperativeYieldSequence
    set variableName ::HybridCore::cooperativeYieldDone_$cooperativeYieldSequence
    set $variableName 0
    after 0 [list set $variableName 1]
    vwait $variableName
    unset -nocomplain $variableName
}

proc ::HybridCore::validCoordinateTriple {coordinates} {
    if {[llength $coordinates] < 3} { return 0 }
    foreach value [lrange $coordinates 0 2] {
        if {![string is double -strict $value]} { return 0 }
    }
    return 1
}

proc ::HybridCore::readNodeCoordinatesBulk {nodeIds fallbackCommand {markId 2}} {
    set nodeIds [lsort -integer -unique $nodeIds]
    set result [dict create]
    if {[llength $nodeIds] == 0} { return $result }

    catch [list *clearmark nodes $markId]
    if {![catch {eval *createmark nodes $markId $nodeIds}]} {
        set markedNodes {}
        catch {set markedNodes [hm_getmark nodes $markId]}
        set bulkCoordinates {}
        if {![catch {set bulkCoordinates [hm_getvalue nodes mark=$markId dataname=coordinates]}]} {
            set nodeCount [llength $markedNodes]
            if {$nodeCount == 1 && [::HybridCore::validCoordinateTriple $bulkCoordinates]} {
                dict set result [lindex $markedNodes 0] [lrange $bulkCoordinates 0 2]
            } elseif {[llength $bulkCoordinates] == $nodeCount} {
                foreach nodeId $markedNodes coordinates $bulkCoordinates {
                    if {[::HybridCore::validCoordinateTriple $coordinates]} {
                        dict set result $nodeId [lrange $coordinates 0 2]
                    }
                }
            } elseif {[llength $bulkCoordinates] == 3*$nodeCount} {
                set coordinateIndex 0
                foreach nodeId $markedNodes {
                    set coordinates [lrange $bulkCoordinates $coordinateIndex [expr {$coordinateIndex+2}]]
                    if {[::HybridCore::validCoordinateTriple $coordinates]} {
                        dict set result $nodeId $coordinates
                    }
                    incr coordinateIndex 3
                }
            }
        }
    }
    catch [list *clearmark nodes $markId]

    set index 0
    foreach nodeId $nodeIds {
        incr index
        if {![dict exists $result $nodeId]} {
            set coordinates [uplevel #0 [linsert $fallbackCommand end $nodeId]]
            if {![::HybridCore::validCoordinateTriple $coordinates]} {
                error "Could not read coordinates for node $nodeId"
            }
            dict set result $nodeId [lrange $coordinates 0 2]
        }
        if {$index % 4096 == 0} { ::HybridCore::cooperativeYield }
    }
    return $result
}
