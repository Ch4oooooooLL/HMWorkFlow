# HyperMesh 2019 real-kernel probe for disconnected solids in one component.

set root [file dirname [file dirname [file normalize [info script]]]]
source -encoding utf-8 [file join $root modules midsurf.tcl]
set reportPath [file join $root runtime "audit_midsurf_multibody_[hm_info -appinfo VERSION].log"]
set channel [open $reportPath w]
proc P {key value} {
    global channel
    puts $channel "${key}=[regsub -all {\s+} [string trim $value] { }]"
    flush $channel
}

proc markIds {etype markId ids} {
    catch {*clearmark $etype $markId}
    eval *createmark $etype $markId $ids
}

proc createPointAt {x y z} {
    *createpoint $x $y $z 0
    catch {*clearmark points 2}
    *createmark points 2 -1
    return [lindex [hm_getmark points 2] 0]
}

proc createBox {x0 y0 z0 dx dy dz} {
    set p {}
    foreach xyz [list \
        [list $x0 $y0 $z0] \
        [list $x0 [expr {$y0+$dy}] $z0] \
        [list [expr {$x0+$dx}] [expr {$y0+$dy}] $z0] \
        [list [expr {$x0+$dx}] $y0 $z0] \
        [list $x0 $y0 [expr {$z0+$dz}]] \
        [list $x0 [expr {$y0+$dy}] [expr {$z0+$dz}]] \
        [list [expr {$x0+$dx}] [expr {$y0+$dy}] [expr {$z0+$dz}]] \
        [list [expr {$x0+$dx}] $y0 [expr {$z0+$dz}]]] {
        lappend p [createPointAt {*}$xyz]
    }
    set createdSurfs {}
    foreach face {{0 1 2 3} {4 5 6 7} {0 4 7 3} {1 5 6 2} {0 1 5 4} {3 7 6 2}} {
        set facePoints {}
        foreach index $face { lappend facePoints [lindex $p $index] }
        markIds points 1 $facePoints
        *surfaceprimitivefrompoints points 1 1 0 0
        catch {*clearmark surfs 2}
        *createmark surfs 2 -1
        lappend createdSurfs [lindex [hm_getmark surfs 2] 0]
    }
    markIds surfs 1 $createdSurfs
    *selfstitchcombine 1 3 0.01 0.01
    *solids_create_from_surfaces 1 0 1 1
    catch {*clearmark solids 2}
    *createmark solids 2 -1
    return [lindex [hm_getmark solids 2] 0]
}

proc createSurfaceBox {x0 y0 z0 dx dy dz} {
    set p {}
    foreach xyz [list \
        [list $x0 $y0 $z0] \
        [list $x0 [expr {$y0+$dy}] $z0] \
        [list [expr {$x0+$dx}] [expr {$y0+$dy}] $z0] \
        [list [expr {$x0+$dx}] $y0 $z0] \
        [list $x0 $y0 [expr {$z0+$dz}]] \
        [list $x0 [expr {$y0+$dy}] [expr {$z0+$dz}]] \
        [list [expr {$x0+$dx}] [expr {$y0+$dy}] [expr {$z0+$dz}]] \
        [list [expr {$x0+$dx}] $y0 [expr {$z0+$dz}]]] {
        lappend p [createPointAt {*}$xyz]
    }
    set createdSurfs {}
    foreach face {{0 1 2 3} {4 5 6 7} {0 4 7 3} {1 5 6 2} {0 1 5 4} {3 7 6 2}} {
        set facePoints {}
        foreach index $face { lappend facePoints [lindex $p $index] }
        markIds points 1 $facePoints
        *surfaceprimitivefrompoints points 1 1 0 0
        catch {*clearmark surfs 2}
        *createmark surfs 2 -1
        lappend createdSurfs [lindex [hm_getmark surfs 2] 0]
    }
    markIds surfs 1 $createdSurfs
    *selfstitchcombine 1 3 0.01 0.01
    return $createdSurfs
}

proc allIds {etype} {
    catch {*clearmark $etype 2}
    *createmark $etype 2 all
    set ids [hm_getmark $etype 2]
    catch {*clearmark $etype 2}
    return $ids
}

proc diffIds {before after} {
    array set seen {}
    foreach id $before { set seen($id) 1 }
    set out {}
    foreach id $after { if {![info exists seen($id)]} { lappend out $id } }
    return $out
}

proc runCase {caseName extractByComp} {
    *collectorcreateonly components $caseName "" 1
    *currentcollector component $caseName
    set solid1 [createBox 0 0 0 20 20 2]
    set solid2 [createBox 50 0 0 20 20 2]
    P "${caseName}_SOLIDS" "$solid1 $solid2"

    markIds solids 1 [list $solid1]
    set attachedCode [catch {*appendmark solids 1 "by attached"} attachedResult attachedOptions]
    P "${caseName}_SOLIDS_ATTACHED_CODE" $attachedCode
    P "${caseName}_SOLIDS_ATTACHED_RESULT" $attachedResult
    P "${caseName}_SOLIDS_ATTACHED_OPTIONS" $attachedOptions
    P "${caseName}_SOLIDS_ATTACHED_MARK" [hm_getmark solids 1]

    # This is the production v0.3 pattern: one solid from a multi-solid
    # component is marked, then midsurface_extract_10 is invoked.
    markIds solids 1 [list $solid1]
    set before [allIds surfs]
    set cmd [list *midsurface_extract_10 solids 1 3 0 1 $extractByComp 9 0 2.0 0 0 10.0 0 0 0.5 undefined 0 0 1]
    set code [catch {eval $cmd} result options]
    set after [allIds surfs]
    P "${caseName}_CATCH_CODE" $code
    P "${caseName}_RESULT" $result
    P "${caseName}_OPTIONS" $options
    P "${caseName}_NEW_SURFS" [diffIds $before $after]
    catch {P "${caseName}_MIDCOMP" [hm_getmidsurfcomp]}
    if {![catch {set midId [hm_entityinfo id comps "Middle Surface" -byname]}]} {
        catch {*clearmark comps 2}
        *createmark comps 2 $midId
        *deletemark comps 2
    }
}

proc runEmptyCurrentCase {} {
    set caseName CASE_EMPTY_CURRENT
    set sourceName ${caseName}_SOURCE
    *collectorcreateonly components $sourceName "" 1
    *currentcollector component $sourceName
    set solid1 [createBox 0 50 0 20 20 2]
    set solid2 [createBox 50 50 0 20 20 2]
    *collectorcreateonly components ${caseName}_TMP "" 2
    *currentcollector component ${caseName}_TMP
    markIds solids 1 [list $solid1]
    set before [allIds surfs]
    set cmd [list *midsurface_extract_10 solids 1 3 0 1 1 9 0 2.0 0 0 10.0 0 0 0.5 undefined 0 0 1]
    set code [catch {eval $cmd} result options]
    set after [allIds surfs]
    P "${caseName}_SOLIDS" "$solid1 $solid2"
    P "${caseName}_CATCH_CODE" $code
    P "${caseName}_RESULT" $result
    P "${caseName}_OPTIONS" $options
    P "${caseName}_NEW_SURFS" [diffIds $before $after]
    catch {P "${caseName}_MIDCOMP" [hm_getmidsurfcomp]}
}

proc runProductionCase {} {
    set caseName PROD_MULTI_T2
    catch {::MidSurf::deleteComponentByName "Middle Surface"}
    *collectorcreateonly components $caseName "" 3
    *currentcollector component $caseName
    set solid1 [createBox 0 100 0 20 20 2]
    set solid2 [createBox 50 100 0 20 20 2]
    set compId [hm_entityinfo id comps $caseName -byname]
    set productionInput [::MidSurf::markInputGeometry $compId]
    P PROD_INPUT_TYPE [lindex $productionInput 0]
    P PROD_INPUT_ENTITY_COUNT [llength [lindex $productionInput 1]]
    P PROD_INPUT_GROUP_COUNT [llength [::MidSurf::inputGeometryGroups [lindex $productionInput 0] [lindex $productionInput 1]]]
    set code [catch {::MidSurf::processComponent $compId} result options]
    P PROD_CODE $code
    P PROD_RESULT $result
    P PROD_OPTIONS $options
    P PROD_SOURCE_SOLIDS [hm_getvalue comps id=$compId dataname=solids]
    if {!$code} {
        set outputIndex 0
        foreach record $result {
            incr outputIndex
            set outName [lindex $record 0]
            set outId [hm_entityinfo id comps $outName -byname]
            P "PROD_OUTPUT_NAME_${outputIndex}" $outName
            P "PROD_OUTPUT_SURFS_${outputIndex}" [hm_getvalue comps id=$outId dataname=surfaces]
        }
    }
}

proc runProductionSurfaceCase {} {
    set caseName PROD_SURF_MULTI_T2
    catch {::MidSurf::deleteComponentByName "Middle Surface"}
    *collectorcreateonly components $caseName "" 4
    *currentcollector component $caseName
    createSurfaceBox 0 150 0 20 20 2
    createSurfaceBox 50 150 0 20 20 2
    set compId [hm_entityinfo id comps $caseName -byname]
    set sourceSurfs [hm_getvalue comps id=$compId dataname=surfaces]
    set groups [::MidSurf::inputGeometryGroups surfaces $sourceSurfs]
    P PROD_SURF_INPUT_SURFS $sourceSurfs
    P PROD_SURF_GROUP_COUNT [llength $groups]
    P PROD_SURF_GROUPS $groups
    set code [catch {::MidSurf::processComponent $compId} result options]
    P PROD_SURF_CODE $code
    P PROD_SURF_RESULT $result
    P PROD_SURF_OPTIONS $options
    P PROD_SURF_SOURCE_SURFS [hm_getvalue comps id=$compId dataname=surfaces]
    if {!$code} {
        set outputIndex 0
        foreach record $result {
            incr outputIndex
            set outName [lindex $record 0]
            set outId [hm_entityinfo id comps $outName -byname]
            P "PROD_SURF_OUTPUT_NAME_${outputIndex}" $outName
            P "PROD_SURF_OUTPUT_SURFS_${outputIndex}" [hm_getvalue comps id=$outId dataname=surfaces]
        }
    }
}

set fatalCode [catch {
    runCase CASE_BY_COMP_1 1
    runCase CASE_BY_COMP_0 0
    runEmptyCurrentCase
    runProductionCase
    runProductionSurfaceCase
} fatal options]
P FATAL_CODE $fatalCode
P FATAL_RESULT $fatal
P FATAL_OPTIONS $options
close $channel
exit 0
