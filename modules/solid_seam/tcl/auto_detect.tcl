# Pure-Tcl seam auto detection for the solid seam module.
#
# Replaces the Python detection pipeline in the main flow: the user picks two
# components, this file finds the junction node chain between them, classifies
# the joint (T / LAP / BUTT / ANGLED), and derives realization parameters
# (mesh size, thickness, width/spacing default 6, adaptive tolerance).
#
# Only HyperMesh mark slots 1/2/3 are used (both 2019 and 2022 accept only
# those).  All geometry queries use hm_getvalue on nodes/elems.

namespace eval ::SolidSeam {}
source -encoding utf-8 [file join [file dirname [info script]] spatial_index.tcl]
source -encoding utf-8 [file join [file dirname [info script]] closed_boundary.tcl]
source -encoding utf-8 [file join [file dirname [info script]] automatic_mode.tcl]
source -encoding utf-8 [file join [file dirname [info script]] boundary_refinement.tcl]

# Internal selection marks must not survive a query, including on failure.
proc ::SolidSeam::queryMarkedIds {entityType slot args} {
    catch {*clearmark $entityType $slot}
    set code [catch {
        *createmark $entityType $slot {*}$args
        hm_getmark $entityType $slot
    } result opts]
    catch {*clearmark $entityType $slot}
    if {$code} { return -options $opts $result }
    return $result
}

# ---------------------------------------------------------------------------
# Native surface/boundary extraction
# ---------------------------------------------------------------------------
# HyperMesh can materialize just the free edges/free faces of a component in
# the temporary ^edges/^faces collectors.  Prefer that indexed native path to
# rebuilding topology by reading every source element in Tcl.  The helpers are
# deliberately best-effort: unsupported profiles and command failures return
# an empty dict and the callers retain the topology fallback below.
proc ::SolidSeam::nativeComponentIdByName {name} {
    if {[llength [info commands ::HWFlow::componentIdByName]] > 0} {
        if {![catch {set componentId [::HWFlow::componentIdByName $name]}]} {
            return $componentId
        }
    }
    return ""
}

proc ::SolidSeam::nativeRenameComponent {componentId newName} {
    set oldName [hm_getvalue comps id=$componentId dataname=name]
    if {$oldName eq $newName} { return }
    set lastError ""
    foreach entityType {component components comps} {
        if {![catch {*renamecollector $entityType $oldName $newName} renameError]} { return }
        set lastError $renameError
    }
    error "could not rename temporary component $oldName: $lastError"
}

proc ::SolidSeam::nativeDeleteComponent {componentId} {
    if {$componentId eq ""} { return }
    set lastError ""
    foreach entityType {components comps} {
        catch {*clearmark $entityType 2}
        if {[catch {*createmark $entityType 2 $componentId} markError]} {
            set lastError $markError
            continue
        }
        set marked {}
        catch {set marked [hm_getmark $entityType 2]}
        if {[lsearch -exact $marked $componentId] >= 0} {
            if {[catch {*deletemark $entityType 2} deleteError]} {
                set lastError $deleteError
                continue
            }
            catch {*clearmark $entityType 2}
            return
        }
    }
    error "could not delete temporary component $componentId: $lastError"
}

proc ::SolidSeam::nativeBoundaryData {componentId kind {withEdges 0}} {
    variable detectionCacheActive
    variable detectionReadCache
    if {![info exists detectionCacheActive] || !$detectionCacheActive} {
        return [::SolidSeam::nativeBoundaryDataImpl $componentId $kind $withEdges]
    }
    set key [list nativeBoundary $componentId $kind]
    if {[info exists detectionReadCache($key)]} { return $detectionReadCache($key) }
    # Read edge connectivity during the first extraction, so node-only and
    # graph callers share one native temporary collector. Never cache failure.
    set result [::SolidSeam::nativeBoundaryDataImpl $componentId $kind 1]
    if {$result ne ""} { set detectionReadCache($key) $result }
    return $result
}

proc ::SolidSeam::nativeBoundaryDataImpl {componentId kind {withEdges 0}} {
    if {$kind eq "edges"} {
        set commandName *findedges
        set collectorName ^edges
    } elseif {$kind eq "faces"} {
        set commandName *findfaces
        set collectorName ^faces
    } else {
        return {}
    }
    if {[llength [info commands $commandName]] == 0 ||
        [llength [info commands ::HWFlow::componentIdByName]] == 0} {
        return {}
    }

    set existingId [::SolidSeam::nativeComponentIdByName $collectorName]
    set keepName ""
    set temporaryId ""
    set result {}
    set code [catch {
        if {$existingId ne ""} {
            set keepName "${collectorName}_SOLID_SEAM_KEEP_[expr {abs([clock clicks])}]"
            ::SolidSeam::nativeRenameComponent $existingId $keepName
        }
        catch {*clearmark comps 1}
        *createmark comps 1 $componentId
        if {$kind eq "edges"} {
            *findedges comps 1 0
        } else {
            *findfaces components 1
        }
        set temporaryId [::SolidSeam::nativeComponentIdByName $collectorName]
        if {$temporaryId eq "" || $temporaryId eq $existingId} {
            error "HyperMesh did not create $collectorName"
        }
        set nodeIds [lsort -integer -unique [::SolidSeam::componentNodeIds $temporaryId]]
        set faces {}
        set edges {}
        if {$kind eq "edges" && $withEdges} {
            foreach elementId [::SolidSeam::componentElementIds $temporaryId] {
                set a [hm_getvalue elems id=$elementId dataname=node1]
                set b [hm_getvalue elems id=$elementId dataname=node2]
                if {$a > 0 && $b > 0 && $a != $b} { lappend edges [list $a $b] }
            }
        }
        if {$kind eq "faces"} {
            foreach elementId [::SolidSeam::componentElementIds $temporaryId] {
                set ring [::SolidSeam::elementNodes $elementId]
                if {[llength $ring] >= 3} { lappend faces $ring }
            }
        }
        if {[llength $nodeIds] == 0} { error "$collectorName contains no nodes" }
        set result [dict create node_ids $nodeIds faces $faces edges $edges]
    } nativeError]

    catch {*clearmark comps 1}
    catch {*clearmark nodes 2}
    catch {*clearmark elems 2}
    if {$temporaryId ne "" && $temporaryId ne $existingId} {
        catch {::SolidSeam::nativeDeleteComponent $temporaryId}
    }
    set strandedId [::SolidSeam::nativeComponentIdByName $collectorName]
    if {$strandedId ne "" && $strandedId ne $existingId} {
        catch {::SolidSeam::nativeDeleteComponent $strandedId}
    }
    if {$keepName ne ""} {
        if {[catch {::SolidSeam::nativeRenameComponent $existingId $collectorName} restoreError]} {
            set code 1
            append nativeError "; failed to restore existing $collectorName: $restoreError"
        }
    }
    if {$code} {
        if {[llength [info commands ::SolidSeam::log]] > 0} {
            catch {::SolidSeam::log WARN "native $kind extraction fallback component=$componentId error=$nativeError"}
        }
        return {}
    }
    return $result
}

proc ::SolidSeam::surfaceNodeIdsOfComponent {componentId isSolid} {
    if {$isSolid} {
        set native [::SolidSeam::nativeBoundaryData $componentId faces]
        if {$native ne ""} { return [dict get $native node_ids] }
    }
    return [::SolidSeam::componentNodeIds $componentId]
}

# ---------------------------------------------------------------------------
# Node helpers
# ---------------------------------------------------------------------------
proc ::SolidSeam::componentNodeIds {componentId} {
    return [::SolidSeam::detectionComponentValue $componentId nodes]
}

# Only source/target IDs are stable during detection. Native extraction creates
# and deletes temporary collectors, whose IDs can be reused within the call.
proc ::SolidSeam::detectionComponentValue {componentId field} {
    variable detectionCacheActive; variable detectionComponents; variable detectionReadCache
    set cache [expr {[info exists detectionCacheActive] && $detectionCacheActive &&
        [info exists detectionComponents] && $componentId in $detectionComponents}]
    set key [list component $componentId $field]
    if {$cache && [info exists detectionReadCache($key)]} { return $detectionReadCache($key) }
    set result [hm_getvalue comps id=$componentId dataname=$field]
    if {$cache} { set detectionReadCache($key) $result }
    return $result
}

proc ::SolidSeam::nodeXYZ {nodeId} {
    variable detectionCacheActive
    variable detectionCoordinates
    if {[info exists detectionCacheActive] && $detectionCacheActive && [info exists detectionCoordinates($nodeId)]} {
        return $detectionCoordinates($nodeId)
    }
    set x [hm_getvalue nodes id=$nodeId dataname=x]
    set y [hm_getvalue nodes id=$nodeId dataname=y]
    set z [hm_getvalue nodes id=$nodeId dataname=z]
    set xyz [list $x $y $z]
    if {[info exists detectionCacheActive] && $detectionCacheActive} { set detectionCoordinates($nodeId) $xyz }
    return $xyz
}

proc ::SolidSeam::nodeDistance {p q} {
    set dx [expr {[lindex $p 0] - [lindex $q 0]}]
    set dy [expr {[lindex $p 1] - [lindex $q 1]}]
    set dz [expr {[lindex $p 2] - [lindex $q 2]}]
    return [expr {sqrt($dx * $dx + $dy * $dy + $dz * $dz)}]
}

# Median of a numeric list (ties rounded down like the Python version).
proc ::SolidSeam::median {values} {
    if {[llength $values] == 0} { return 0.0 }
    set sorted [lsort -real $values]
    set mid [expr {[llength $sorted] / 2}]
    return [lindex $sorted $mid]
}

proc ::SolidSeam::clamp {value lower upper} {
    return [expr {$value < $lower ? $lower : ($value > $upper ? $upper : $value)}]
}

# ---------------------------------------------------------------------------
# Element topology helpers
# ---------------------------------------------------------------------------
proc ::SolidSeam::componentElementIds {componentId} {
    # Supported in HM2019: reading connectivity must not select the component.
    return [::SolidSeam::detectionComponentValue $componentId elements]
}

proc ::SolidSeam::elementConfig {elementId} {
    set config {}
    catch {set config [hm_getvalue elems id=$elementId dataname=config]}
    return [string trim $config]
}

proc ::SolidSeam::elementNodes {elementId} {
    set nodes {}
    for {set i 1} {$i <= 20} {incr i} {
        set rc [catch {set n [hm_getvalue elems id=$elementId dataname=node$i]}]
        set n [string trim $n]
        if {$rc || $n eq "" || $n eq "0"} { break }
        lappend nodes $n
    }
    return $nodes
}

# Is the component made of solid (3D) elements?  Config ids verified on the
# real machine (HM2019 / HM2022 OptiStruct template, hm_getvalue dataname=config):
#   204 tetra4, 205 pyramid5, 206 penta6, 208 hex8,
#   210 tetra10, 213 pyra13, 215 penta15, 220 hex20
# Shells (never solids): 103 tria3, 104 quad4, 106 tria6, 108 quad8.
proc ::SolidSeam::componentIsSolid {componentId} {
    variable detectionCacheActive; variable detectionReadCache
    set key [list solid $componentId]
    set cache [expr {[info exists detectionCacheActive] && $detectionCacheActive}]
    if {$cache && [info exists detectionReadCache($key)]} { return $detectionReadCache($key) }
    set result [::SolidSeam::componentIsSolidImpl $componentId]
    if {$cache} { set detectionReadCache($key) $result }
    return $result
}

proc ::SolidSeam::componentIsSolidImpl {componentId} {
    set elementIds [::SolidSeam::componentElementIds $componentId]
    # Bulk config query avoids one host API call per shell element before
    # reaching *findedges. Keep compatibility with profiles lacking arrays.
    if {![catch {set configs [hm_getvalue elems "user_ids=$elementIds" dataname=config]}] && [llength $configs] == [llength $elementIds]} {
        foreach config $configs {
            if {$config in {204 205 206 208 210 213 215 220}} { return 1 }
        }
        return 0
    }
    foreach elementId $elementIds {
        if {[::SolidSeam::elementConfig $elementId] in {204 205 206 208 210 213 215 220}} {
            return 1
        }
    }
    return 0
}

# Face node sets of an element: shells contribute their single face (the node
# ring, corners then edge mids), solids contribute each boundary face with
# the ring in edge order (corner, mid, corner, ...) so consecutive pairs are
# the real element edges.  The quadratic layouts were verified on the real
# machine with *findfaces: hex20 keeps the Nastran edge-mid numbering for the
# bottom face (9-12) but stores the TOP face mids as 17-20 and the vertical
# edge mids as 13-16 (opposite of Nastran).
proc ::SolidSeam::elementFaces {elementId} {
    set nodes [::SolidSeam::elementNodes $elementId]
    set config [::SolidSeam::elementConfig $elementId]
    set faces {}
    switch -- $config {
        103 - 104 - 106 - 108 { ;# tri3 / quad4 / tria6 / quad8 shell
            lappend faces $nodes
        }
        204 { ;# tetra4: 4 triangular faces
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 2] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 3]]
        }
        205 { ;# pyramid5: base quad nodes 1-4 + 4 tri side faces (apex node 5)
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 3] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 0] [lindex $nodes 4]]
        }
        206 { ;# penta6: 2 tri + 3 quad
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 4] [lindex $nodes 5]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 4] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 5] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 0] [lindex $nodes 3] [lindex $nodes 5]]
        }
        208 { ;# hex8: 6 quad faces
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 3]]
            lappend faces [list [lindex $nodes 4] [lindex $nodes 5] [lindex $nodes 6] [lindex $nodes 7]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 1] [lindex $nodes 5] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 2] [lindex $nodes 6] [lindex $nodes 5]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 3] [lindex $nodes 7] [lindex $nodes 6]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 0] [lindex $nodes 4] [lindex $nodes 7]]
        }
        210 { ;# tetra10: 4 tri faces, mids 5-7 on face 1 then 8-10 on edges
            ;# to the opposite corner (5=12, 6=23, 7=31, 8=14, 9=24, 10=34)
            lappend faces [list [lindex $nodes 0] [lindex $nodes 4] [lindex $nodes 1] [lindex $nodes 5] [lindex $nodes 2] [lindex $nodes 6]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 7] [lindex $nodes 3] [lindex $nodes 8] [lindex $nodes 1] [lindex $nodes 4]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 8] [lindex $nodes 3] [lindex $nodes 9] [lindex $nodes 2] [lindex $nodes 5]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 9] [lindex $nodes 3] [lindex $nodes 7] [lindex $nodes 0] [lindex $nodes 6]]
        }
        213 { ;# pyra13: base quad 1-4 + mids 6-9, apex 5 + edge mids 10-13
            lappend faces [list [lindex $nodes 0] [lindex $nodes 5] [lindex $nodes 1] [lindex $nodes 6] [lindex $nodes 2] [lindex $nodes 7] [lindex $nodes 3] [lindex $nodes 8]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 9] [lindex $nodes 4] [lindex $nodes 10] [lindex $nodes 1] [lindex $nodes 5]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 10] [lindex $nodes 4] [lindex $nodes 11] [lindex $nodes 2] [lindex $nodes 6]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 11] [lindex $nodes 4] [lindex $nodes 12] [lindex $nodes 3] [lindex $nodes 7]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 12] [lindex $nodes 4] [lindex $nodes 9] [lindex $nodes 0] [lindex $nodes 8]]
        }
        215 { ;# penta15: 2 tri + 3 quad with mids (7-9 bottom, 10-12 vertical,
            ;# 13-15 top: 7=12, 8=23, 9=31, 10=14, 11=25, 12=36, 13=45, 14=56,
            ;# 15=64)
            lappend faces [list [lindex $nodes 0] [lindex $nodes 6] [lindex $nodes 1] [lindex $nodes 7] [lindex $nodes 2] [lindex $nodes 8]]
            lappend faces [list [lindex $nodes 3] [lindex $nodes 12] [lindex $nodes 4] [lindex $nodes 13] [lindex $nodes 5] [lindex $nodes 14]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 9] [lindex $nodes 3] [lindex $nodes 12] [lindex $nodes 4] [lindex $nodes 10] [lindex $nodes 1] [lindex $nodes 6]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 10] [lindex $nodes 4] [lindex $nodes 13] [lindex $nodes 5] [lindex $nodes 11] [lindex $nodes 2] [lindex $nodes 7]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 11] [lindex $nodes 5] [lindex $nodes 14] [lindex $nodes 3] [lindex $nodes 9] [lindex $nodes 0] [lindex $nodes 8]]
        }
        220 { ;# hex20: 6 quad faces, 8 nodes each; bottom mids 9-12 on face 6,
            ;# vertical mids 13-16, top mids 17-20 (machine-verified layout)
            lappend faces [list [lindex $nodes 3] [lindex $nodes 15] [lindex $nodes 7] [lindex $nodes 19] [lindex $nodes 4] [lindex $nodes 12] [lindex $nodes 0] [lindex $nodes 11]]
            lappend faces [list [lindex $nodes 2] [lindex $nodes 14] [lindex $nodes 6] [lindex $nodes 18] [lindex $nodes 7] [lindex $nodes 15] [lindex $nodes 3] [lindex $nodes 10]]
            lappend faces [list [lindex $nodes 1] [lindex $nodes 13] [lindex $nodes 5] [lindex $nodes 17] [lindex $nodes 6] [lindex $nodes 14] [lindex $nodes 2] [lindex $nodes 9]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 12] [lindex $nodes 4] [lindex $nodes 16] [lindex $nodes 5] [lindex $nodes 13] [lindex $nodes 1] [lindex $nodes 8]]
            lappend faces [list [lindex $nodes 4] [lindex $nodes 16] [lindex $nodes 5] [lindex $nodes 17] [lindex $nodes 6] [lindex $nodes 18] [lindex $nodes 7] [lindex $nodes 19]]
            lappend faces [list [lindex $nodes 0] [lindex $nodes 8] [lindex $nodes 1] [lindex $nodes 9] [lindex $nodes 2] [lindex $nodes 10] [lindex $nodes 3] [lindex $nodes 11]]
        }
        default {
            ;# unsupported config: fall back to the node list as a single face
            lappend faces $nodes
        }
    }
    return $faces
}

# Face key: sorted node ids joined by a separator (order independent).
proc ::SolidSeam::faceKey {face} {
    return [join [lsort -integer $face] {,}]
}

# Boundary (free edge) node ids of a component.
# - shells: nodes on edges used by exactly one element (free edges)
# - solids: nodes on the edges of the outer surface that are not shared with
#   a second element.  An edge of a solid element belongs to two of its own
#   faces, so free edges of the body are counted exactly twice while interior
#   edges are counted by two elements (four face incidences).
proc ::SolidSeam::boundaryNodesOfComponent {componentId} {
    set solid [::SolidSeam::componentIsSolid $componentId]
    if {!$solid} {
        set native [::SolidSeam::nativeBoundaryData $componentId edges]
        if {$native ne ""} { return [dict get $native node_ids] }
    }
    set elementIds [::SolidSeam::componentElementIds $componentId]
    array set edgeCount {}
    foreach elementId $elementIds {
        set nodes [::SolidSeam::elementNodes $elementId]
        if {$solid} {
            # count face edges of the solid surface
            foreach face [::SolidSeam::elementFaces $elementId] {
                set n [llength $face]
                for {set i 0} {$i < $n} {incr i} {
                    set a [lindex $face $i]
                    set b [lindex $face [expr {($i + 1) % $n}]]
                    set key [expr {$a < $b ? "$a,$b" : "$b,$a"}]
                    incr edgeCount($key)
                }
            }
        } else {
            # shell: edges from the ordered node ring
            set n [llength $nodes]
            for {set i 0} {$i < $n} {incr i} {
                set a [lindex $nodes $i]
                set b [lindex $nodes [expr {($i + 1) % $n}]]
                set key [expr {$a < $b ? "$a,$b" : "$b,$a"}]
                incr edgeCount($key)
            }
        }
    }
    set boundary {}
    # Shell: a free edge is used by exactly one element (limit 1).
    # Solid: each owning element contributes two faces per edge, so a surface
    # edge is used by 2 faces (single element) or 4 faces (two elements
    # meeting along the edge, e.g. a tetra plate's perimeter edge owned by
    # the bottom and side tets).  Interior edges are used by 6+ faces
    # (3+ elements).  "<= 4" keeps every surface node while excluding the
    # interior; for hexa/penta/pyra meshes surface edges are 2 and interior
    # are 8+, so the bound is exact there too.
    if {$solid} {
        foreach key [array names edgeCount] {
            if {$edgeCount($key) <= 4} {
                foreach nodeId [split $key ,] { lappend boundary $nodeId }
            }
        }
    } else {
        foreach key [array names edgeCount] {
            if {$edgeCount($key) == 1} {
                foreach nodeId [split $key ,] { lappend boundary $nodeId }
            }
        }
    }
    return [lsort -integer -unique $boundary]
}

# For a solid component: the face(s) of the outer surface that face the
# target component (minimum face-centroid to target-node distance).  Returns
# the node ids of the outline of the facing region: all outer faces whose
# centroid is within a small multiple of the closest gap are collected, and
# their shared outline (edges used by exactly one of these faces) forms the
# weld boundary.
proc ::SolidSeam::faceUnitNormal {face} {
    # Newell's method also works for the alternating corner/midside rings of
    # quadratic faces.  Sign is intentionally ignored by the facing test.
    set nx 0.0; set ny 0.0; set nz 0.0
    set count [llength $face]
    for {set i 0} {$i < $count} {incr i} {
        set p [::SolidSeam::nodeXYZ [lindex $face $i]]
        set q [::SolidSeam::nodeXYZ [lindex $face [expr {($i + 1) % $count}]]]
        set nx [expr {$nx + ([lindex $p 1] - [lindex $q 1]) * ([lindex $p 2] + [lindex $q 2])}]
        set ny [expr {$ny + ([lindex $p 2] - [lindex $q 2]) * ([lindex $p 0] + [lindex $q 0])}]
        set nz [expr {$nz + ([lindex $p 0] - [lindex $q 0]) * ([lindex $p 1] + [lindex $q 1])}]
    }
    set length [expr {sqrt($nx*$nx + $ny*$ny + $nz*$nz)}]
    if {$length <= 1.0e-12} { return {0.0 0.0 0.0} }
    return [list [expr {$nx/$length}] [expr {$ny/$length}] [expr {$nz/$length}]]
}

proc ::SolidSeam::solidFacingBoundaryNodes {componentId targetComponentId {targetNodes ""}} {
    if {$targetNodes eq ""} {
        set targetSolid [::SolidSeam::componentIsSolid $targetComponentId]
        set targetNodes [::SolidSeam::surfaceNodeIdsOfComponent $targetComponentId $targetSolid]
    }
    if {[llength $targetNodes] == 0} { return {} }
    set targetIndex [::SolidSeam::spatialIndex $targetNodes]
    set elementIds {}
    set nativeFaces [::SolidSeam::nativeBoundaryData $componentId faces]
    set nativeSurface [expr {$nativeFaces ne "" && [llength [dict get $nativeFaces faces]] > 0}]
    # count face usage to find the outer surface (used exactly once).  Keep
    # the first ring order seen for each face key: the outline and edge
    # lengths below use the real element edges, while the sorted key alone
    # would turn quad diagonals into pseudo edges and leak interior rows
    # into the outline.
    array set faceCount {}; array set faceRing {}; array set faceOwner {}
    if {$nativeSurface} {
        set outerFaces [dict get $nativeFaces faces]
    } else {
        set elementIds [::SolidSeam::componentElementIds $componentId]
        foreach elementId $elementIds {
            foreach face [::SolidSeam::elementFaces $elementId] {
                set key [::SolidSeam::faceKey $face]
                incr faceCount($key)
                if {![info exists faceRing($key)]} {
                    set faceRing($key) $face
                    set faceOwner($key) $elementId
                }
            }
        }
        set outerFaces {}
        foreach key [array names faceCount] {
            if {$faceCount($key) == 1} { lappend outerFaces $faceRing($key) }
        }
    }
    if {[llength $outerFaces] == 0} { return {} }
    # element centroids: the outward direction of a face is face-centroid
    # minus its owning element centroid (the ring winding is not reliably
    # outward across element types/configs)
    array set elementCentroid {}
    foreach elementId $elementIds {
        set sx 0.0; set sy 0.0; set sz 0.0
        set n 0
        foreach nodeId [::SolidSeam::elementNodes $elementId] {
            set p [::SolidSeam::nodeXYZ $nodeId]
            set sx [expr {$sx + [lindex $p 0]}]
            set sy [expr {$sy + [lindex $p 1]}]
            set sz [expr {$sz + [lindex $p 2]}]
            incr n
        }
        if {$n > 0} { set elementCentroid($elementId) [list [expr {$sx / $n}] [expr {$sy / $n}] [expr {$sz / $n}]] }
    }
    # mesh pitch from the outer face edges (median edge length); the
    # facing-layer bands below are scaled with it so a curved contact face
    # (whose gap to the target varies along the arc) keeps its whole outline
    # while side faces stay excluded
    set edgeLengths {}
    foreach face $outerFaces {
        set n [llength $face]
        for {set i 0} {$i < $n} {incr i} {
            set a [lindex $face $i]
            set b [lindex $face [expr {($i + 1) % $n}]]
            set d [::SolidSeam::nodeDistance [::SolidSeam::nodeXYZ $a] [::SolidSeam::nodeXYZ $b]]
            if {$d > 1.0e-8} { lappend edgeLengths $d }
        }
    }
    set pitch [::SolidSeam::median $edgeLengths]
    if {$pitch <= 0.0} { set pitch 10.0 }
    # For every outer face: its centroid distance to the nearest target node,
    # the unit direction from the face centroid to that node (the face's own
    # view of the target), and the outward unit normal of the face.  The
    # direction is per-face, not global: a side face's nearest target node
    # lies in the contact plane, so the direction to it is nearly
    # perpendicular to the side normal and the facing test below excludes
    # the side face no matter how the source/target centroids are offset
    # from each other.
    set faceDistances {}
    foreach face $outerFaces {
        set cx 0.0; set cy 0.0; set cz 0.0
        foreach nodeId $face {
            set p [::SolidSeam::nodeXYZ $nodeId]
            set cx [expr {$cx + [lindex $p 0]}]
            set cy [expr {$cy + [lindex $p 1]}]
            set cz [expr {$cz + [lindex $p 2]}]
        }
        set n [llength $face]
        set centroid [list [expr {$cx / $n}] [expr {$cy / $n}] [expr {$cz / $n}]]
        lassign [::SolidSeam::nearestNode $targetIndex $centroid] targetNode nearest
        lassign [::SolidSeam::nodeXYZ $targetNode] tx ty tz
        set dx [expr {$tx - [lindex $centroid 0]}]
        set dy [expr {$ty - [lindex $centroid 1]}]
        set dz [expr {$tz - [lindex $centroid 2]}]
        set dlen [expr {sqrt($dx * $dx + $dy * $dy + $dz * $dz)}]
        if {$dlen > 1.0e-12} {
            set dx [expr {$dx / $dlen}]; set dy [expr {$dy / $dlen}]; set dz [expr {$dz / $dlen}]
        } else {
            set dx 0.0; set dy 0.0; set dz 0.0
        }
        if {$nativeSurface} {
            lassign [::SolidSeam::faceUnitNormal $face] ox oy oz
        } else {
            set owner [expr {$faceOwner([::SolidSeam::faceKey $face])}]
            set ec $elementCentroid($owner)
            set ox [expr {[lindex $centroid 0] - [lindex $ec 0]}]
            set oy [expr {[lindex $centroid 1] - [lindex $ec 1]}]
            set oz [expr {[lindex $centroid 2] - [lindex $ec 2]}]
            set olen [expr {sqrt($ox * $ox + $oy * $oy + $oz * $oz)}]
            if {$olen > 1.0e-12} {
                set ox [expr {$ox / $olen}]; set oy [expr {$oy / $olen}]; set oz [expr {$oz / $olen}]
            } else {
                set ox 0.0; set oy 0.0; set oz 0.0
            }
        }
        lappend faceDistances [list $nearest $face $dx $dy $dz $ox $oy $oz]
    }
    set sortedFaces [lsort -real -index 0 $faceDistances]
    set minDistance [lindex [lindex $sortedFaces 0] 0]
    # Only the closest outer surface layer faces the target (the user's
    # manual node list follows the single contact face).  A band of half a
    # mesh pitch would also pull in side faces whose corners come close to
    # the target, so keep the band tight: faces within 0.3 pitch of the
    # closest one (a curved contact face's own centroid distances vary less
    # than that along the arc, e.g. 3.0-5.3 mm on a 10 mm mesh).  In
    # addition the face must point at the target: dot(outward, direction to
    # the face's own nearest target node) above 0.25.  A contact face angled
    # up to ~75 deg still qualifies while perpendicular side faces (dot ~ 0)
    # do not.
    set faceBand [expr {max(0.01, 0.3 * $pitch)}]
    set facingFaces {}
    foreach item $sortedFaces {
        set dist [lindex $item 0]
        if {$dist > $minDistance + $faceBand} { break }
        set face [lindex $item 1]
        set dot [expr {[lindex $item 2] * [lindex $item 5] + [lindex $item 3] * [lindex $item 6] + [lindex $item 4] * [lindex $item 7]}]
        if {$nativeSurface} { set dot [expr {abs($dot)}] }
        if {$dot > 0.25} { lappend facingFaces $face }
    }
    if {[llength $facingFaces] == 0} { return {} }
    # outline of the facing region: edges used by exactly one facing face
    array set edgeCount {}
    foreach face $facingFaces {
        set n [llength $face]
        for {set i 0} {$i < $n} {incr i} {
            set a [lindex $face $i]
            set b [lindex $face [expr {($i + 1) % $n}]]
            set key [expr {$a < $b ? "$a,$b" : "$b,$a"}]
            incr edgeCount($key)
        }
    }
    set boundary {}
    foreach key [array names edgeCount] {
        if {$edgeCount($key) == 1} {
            foreach nodeId [split $key ,] { lappend boundary $nodeId }
        }
    }
    set boundary [lsort -integer -unique $boundary]
    # The facing layer may contain a middle row that is farther from the
    # target (e.g. a plate whose contact edge runs along its two outer rows
    # while the centre row overhangs the gap).  Keep only the nodes on the
    # closest contact band so the weld follows the actual contact edge.
    set nodeDistances {}
    foreach nodeId $boundary {
        set p [::SolidSeam::nodeXYZ $nodeId]
        lassign [::SolidSeam::nearestNode $targetIndex $p] targetNode nearest
        lappend nodeDistances [list $nearest $nodeId]
    }
    set sortedNodes [lsort -real -index 0 $nodeDistances]
    set minNodeDistance [lindex [lindex $sortedNodes 0] 0]
    # the band scales with the mesh pitch: on a curved seam the contact
    # edge's own gap varies along the arc (3.0-5.3 mm on the F03 case) while
    # the next row is a full pitch away, so 0.35 pitch keeps the whole
    # contact edge without pulling in the farther row
    set nodeBand [expr {max(1.0, 0.35 * $pitch)}]
    set kept {}
    foreach item $sortedNodes {
        if {[lindex $item 0] <= $minNodeDistance + $nodeBand} {
            lappend kept [lindex $item 1]
        }
    }
    return $kept
}

# ---------------------------------------------------------------------------
# Junction detection: nodes of compA that lie within searchDistance of a node
# of compB, with the closest partner recorded.
#
# Weld node rules (user contract):
#   1. the node list always comes from the FIRST component's boundary;
#   2. a shell parallel to the target keeps ALL its free-edge nodes;
#   3. a shell at an angle to the target keeps only the nodes of the free
#      edge(s) closest to the target;
#   4. a solid keeps the boundary of the outer face closest to the target;
#   5. nodes never belong to the second component - guaranteed structurally,
#      every candidate below is built from the source's own elements only,
#      so a target-exclusive node can never appear in the list.
# ---------------------------------------------------------------------------
proc ::SolidSeam::detectJunctionNodes {sourceComponentId targetComponentId searchDistance} {
    # Only boundary nodes of the FIRST component are weld candidates: shells
    # use their free-edge nodes; solids use the boundary of the outer face
    # that faces the target component.  Interior nodes can never be weld
    # locations and would only distort the chain.
    set sourceSolid [::SolidSeam::componentIsSolid $sourceComponentId]
    set targetSolid [::SolidSeam::componentIsSolid $targetComponentId]
    set targetNodes [::SolidSeam::surfaceNodeIdsOfComponent $targetComponentId $targetSolid]
    if {$sourceSolid} {
        # Do not first rebuild the entire solid boundary: the native free-face
        # path normally returns the exact facing outline directly.
        set sourceNodes [::SolidSeam::solidFacingBoundaryNodes \
            $sourceComponentId $targetComponentId $targetNodes]
        if {[llength $sourceNodes] == 0} {
            set sourceNodes [::SolidSeam::boundaryNodesOfComponent $sourceComponentId]
        }
    } else {
        set sourceNodes [::SolidSeam::boundaryNodesOfComponent $sourceComponentId]
    }
    array set sourceXYZ {}
    foreach nodeId $sourceNodes {
        set sourceXYZ($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set targetIndex [::SolidSeam::spatialIndex $targetNodes]

    # nearest compB node for every compA node inside the search distance
    set pairs {}
    foreach sourceNode $sourceNodes {
        set p $sourceXYZ($sourceNode)
        lassign [::SolidSeam::nearestNode $targetIndex $p $searchDistance] bestTarget bestDistance
        if {$bestTarget ne ""} {
            lappend pairs [list $sourceNode $bestTarget $bestDistance]
        }
    }
    if {[llength $pairs] == 0} { return {} }

    # A shell parallel to the target keeps ALL its boundary nodes within the
    # search distance (rule 2): the whole outline is the weld line, so no
    # closest-layer cut applies.
    set sourceParallel [expr {!$sourceSolid && [::SolidSeam::normalsParallel \
        [::SolidSeam::componentAverageNormal $sourceComponentId] \
        [::SolidSeam::componentAverageNormal $targetComponentId]]}]
    if {$sourceParallel} { return $pairs }

    # closest-layer filter: keep only the edge(s) at the minimum gap.  This
    # is rule 3 for angled shells (the free edge closest to the target) and
    # the final refinement of rule 4 for solids (the contact band of the
    # closest face).  The search distance may cover several parallel edges of
    # the source face (e.g. a plate edge plus an inner row); the weld belongs
    # on the row that is actually closest to the target.  A curved seam's gap
    # to the target varies along the arc (3.0-5.3 mm on the F03 case) while
    # the next row is a full mesh pitch away (13 mm), so split by the largest
    # distance gap: keep the near side of the biggest jump.  A fallback 1.5x
    # floor guards against a single outlier creating a tiny gap.
    set sortedPairs [lsort -real -index 2 $pairs]
    set firstDistance [lindex [lindex $sortedPairs 0] 2]
    set splitDistance [expr {$firstDistance * 1.5 + 0.5}]
    set biggestGap 0.0
    for {set i 0} {$i < [llength $sortedPairs] - 1} {incr i} {
        set gap [expr {[lindex [lindex $sortedPairs [expr {$i + 1}]] 2] - [lindex [lindex $sortedPairs $i] 2]}]
        if {$gap > $biggestGap} {
            set biggestGap $gap
            set splitDistance [expr {0.5 * ([lindex [lindex $sortedPairs [expr {$i + 1}]] 2] + [lindex [lindex $sortedPairs $i] 2])}]
        }
    }
    # A real layer boundary must be a jump of at least half a mesh pitch.
    # The seam's own gap variation along a curved edge is smaller than that
    # (F03: 3.0-5.3 mm within one layer, 13 mm to the next row), so when the
    # biggest gap is sub-pitch the whole set is one layer and nothing is cut.
    set meshPitch [::SolidSeam::median [::SolidSeam::chainSpacings [::SolidSeam::pairSourceIds $pairs]]]
    if {$meshPitch <= 0.0} { set meshPitch 10.0 }
    if {$biggestGap < 0.5 * $meshPitch} {
        set splitDistance 1.0e12
    }
    set closest {}
    foreach pair $pairs {
        if {[lindex $pair 2] <= $splitDistance} { lappend closest $pair }
    }
    if {!$sourceSolid && [llength $closest] < [llength $pairs]} {
        set closest [::SolidSeam::retainBoundaryInteriors $sourceComponentId $pairs $closest]
    }
    return $closest
}

# Are two component normals parallel (closest angle within 20 deg, same
# tolerance as classifyJoint)?  A zero/undefined normal is not parallel: the
# closest-edge rule then applies, which is the safe default for closed shell
# boxes and cylindrical shells.
proc ::SolidSeam::normalsParallel {a b} {
    if {[llength $a] != 3 || [llength $b] != 3} { return 0 }
    if {$a eq {0 0 0} || $b eq {0 0 0}} { return 0 }
    set rawAngle [::SolidSeam::angleDeg $a $b]
    set closest [expr {$rawAngle <= 90.0 ? $rawAngle : 180.0 - $rawAngle}]
    return [expr {$closest <= 20.0}]
}

# Median spacing between consecutive nodes of a chain (used by the layer
# filter to distinguish intra-arc variation from a real layer jump).
proc ::SolidSeam::pairSourceIds {pairs} {
    set ids {}
    foreach pair $pairs { lappend ids [lindex $pair 0] }
    return $ids
}

proc ::SolidSeam::chainSpacings {nodeIds} {
    array set coords {}
    foreach nodeId $nodeIds {
        set coords($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set spacings {}
    for {set i 0} {$i < [llength $nodeIds] - 1} {incr i} {
        set d [::SolidSeam::nodeDistance $coords([lindex $nodeIds $i]) $coords([lindex $nodeIds [expr {$i + 1}]])]
        if {$d > 1.0e-8} { lappend spacings $d }
    }
    return $spacings
}

# ---------------------------------------------------------------------------
# Chain building: order the junction source nodes into a continuous path.
# Each chain is a list of node ids ordered head-to-tail; a new chain starts
# when the nearest unvisited node is farther than gapJumpLimit.  Once a chain
# has two nodes its direction is known, so extension prefers candidates that
# continue straight ahead (smallest turn) over merely closest ones; this
# keeps parallel rows of a solid face from zig-zagging into each other.
# ---------------------------------------------------------------------------
proc ::SolidSeam::buildChains {nodeIds gapJumpLimit} {
    array set coords {}
    foreach nodeId $nodeIds {
        set coords($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set unvisited [lsort -integer -unique $nodeIds]
    set chains {}
    while {[llength $unvisited] > 0} {
        set chain [list [lindex $unvisited 0]]
        set unvisited [lrange $unvisited 1 end]
        set extended 1
        while {$extended} {
            set extended 0
            set tail [lindex $chain end]
            set head [lindex $chain 0]
            # The distance gate is the gap limit alone; the turn penalty only
            # ranks candidates below it.  Mixing the two (score > gap rejects
            # a 90 deg step even though the step is within the limit) used to
            # split a ring-shaped seam into several stub chains.
            set bestTail 0; set bestTailScore 1.0e12
            set bestHead 0; set bestHeadScore 1.0e12
            # chain direction (tail extension): vector from the previous node
            # to the tail, if the chain is long enough
            set tailDir {}
            if {[llength $chain] >= 2} {
                set prev [lindex $chain end-1]
                set tailDir [list \
                    [expr {[lindex $coords($tail) 0] - [lindex $coords($prev) 0]}] \
                    [expr {[lindex $coords($tail) 1] - [lindex $coords($prev) 1]}] \
                    [expr {[lindex $coords($tail) 2] - [lindex $coords($prev) 2]}]]
            }
            set headDir {}
            if {[llength $chain] >= 2} {
                set next [lindex $chain 1]
                set headDir [list \
                    [expr {[lindex $coords($head) 0] - [lindex $coords($next) 0]}] \
                    [expr {[lindex $coords($head) 1] - [lindex $coords($next) 1]}] \
                    [expr {[lindex $coords($head) 2] - [lindex $coords($next) 2]}]]
            }
            foreach candidate $unvisited {
                set dTail [::SolidSeam::nodeDistance $coords($tail) $coords($candidate)]
                set dHead [::SolidSeam::nodeDistance $coords($head) $coords($candidate)]
                # score: distance, plus a straightness penalty when a
                # direction is known (turn > 60deg adds 0.5 * gap)
                if {$dTail <= $gapJumpLimit} {
                    set score $dTail
                    if {$tailDir ne ""} {
                        set v [list \
                            [expr {[lindex $coords($candidate) 0] - [lindex $coords($tail) 0]}] \
                            [expr {[lindex $coords($candidate) 1] - [lindex $coords($tail) 1]}] \
                            [expr {[lindex $coords($candidate) 2] - [lindex $coords($tail) 2]}]]
                        set turn [::SolidSeam::angleBetween $tailDir $v]
                        if {$turn > 60.0} { set score [expr {$dTail + 0.5 * $gapJumpLimit}] }
                    }
                    if {$score < $bestTailScore} {
                        set bestTailScore $score
                        set bestTail $candidate
                    }
                }
                if {$dHead <= $gapJumpLimit} {
                    set score $dHead
                    if {$headDir ne ""} {
                        set v [list \
                            [expr {[lindex $coords($candidate) 0] - [lindex $coords($head) 0]}] \
                            [expr {[lindex $coords($candidate) 1] - [lindex $coords($head) 1]}] \
                            [expr {[lindex $coords($candidate) 2] - [lindex $coords($head) 2]}]]
                        set turn [::SolidSeam::angleBetween $headDir $v]
                        if {$turn > 60.0} { set score [expr {$dHead + 0.5 * $gapJumpLimit}] }
                    }
                    if {$score < $bestHeadScore} {
                        set bestHeadScore $score
                        set bestHead $candidate
                    }
                }
            }
            if {$bestTail != 0 && $bestTailScore <= $bestHeadScore} {
                lappend chain $bestTail
                set unvisited [lsearch -all -inline -not -exact $unvisited $bestTail]
                set extended 1
            } elseif {$bestHead != 0} {
                set chain [linsert $chain 0 $bestHead]
                set unvisited [lsearch -all -inline -not -exact $unvisited $bestHead]
                set extended 1
            }
        }
        lappend chains $chain
    }
    return $chains
}

# Angle in degrees between two 3D vectors.
proc ::SolidSeam::angleBetween {a b} {
    set dot [expr {[lindex $a 0] * [lindex $b 0] + [lindex $a 1] * [lindex $b 1] + [lindex $a 2] * [lindex $b 2]}]
    set lenA [expr {sqrt([lindex $a 0] * [lindex $a 0] + [lindex $a 1] * [lindex $a 1] + [lindex $a 2] * [lindex $a 2])}]
    set lenB [expr {sqrt([lindex $b 0] * [lindex $b 0] + [lindex $b 1] * [lindex $b 1] + [lindex $b 2] * [lindex $b 2])}]
    if {$lenA <= 1.0e-12 || $lenB <= 1.0e-12} { return 0.0 }
    set cosine [::SolidSeam::clamp [expr {$dot / ($lenA * $lenB)}] -1.0 1.0]
    return [expr {acos($cosine) * 180.0 / 3.141592653589793}]
}

# ---------------------------------------------------------------------------
# Unit normals of the elements of a component (element face normals from the
# first three nodes, averaged and aligned).
# ---------------------------------------------------------------------------
proc ::SolidSeam::componentAverageNormal {componentId} {
    set elementIds [::SolidSeam::componentElementIds $componentId]
    variable detectionAutoMode
    if {[info exists detectionAutoMode] && $detectionAutoMode} {
        set elementIds [::SolidSeam::sampleEvenly $elementIds 128]
    }
    set normals {}
    foreach elementId $elementIds {
        catch {
            set n1 [hm_getvalue elems id=$elementId dataname=node1]
            set n2 [hm_getvalue elems id=$elementId dataname=node2]
            set n3 [hm_getvalue elems id=$elementId dataname=node3]
            set p1 [::SolidSeam::nodeXYZ $n1]
            set p2 [::SolidSeam::nodeXYZ $n2]
            set p3 [::SolidSeam::nodeXYZ $n3]
            set ux [expr {[lindex $p2 0] - [lindex $p1 0]}]
            set uy [expr {[lindex $p2 1] - [lindex $p1 1]}]
            set uz [expr {[lindex $p2 2] - [lindex $p1 2]}]
            set vx [expr {[lindex $p3 0] - [lindex $p1 0]}]
            set vy [expr {[lindex $p3 1] - [lindex $p1 1]}]
            set vz [expr {[lindex $p3 2] - [lindex $p1 2]}]
            set nx [expr {$uy * $vz - $uz * $vy}]
            set ny [expr {$uz * $vx - $ux * $vz}]
            set nz [expr {$ux * $vy - $uy * $vx}]
            set len [expr {sqrt($nx * $nx + $ny * $ny + $nz * $nz)}]
            if {$len > 1.0e-12} { lappend normals [list [expr {$nx / $len}] [expr {$ny / $len}] [expr {$nz / $len}]] }
        }
    }
    if {[llength $normals] == 0} { return {0 0 0} }
    set reference [lindex $normals 0]
    set sumX 0.0; set sumY 0.0; set sumZ 0.0
    foreach normal $normals {
        set dot [expr {[lindex $normal 0] * [lindex $reference 0] + [lindex $normal 1] * [lindex $reference 1] + [lindex $normal 2] * [lindex $reference 2]}]
        set factor [expr {$dot >= 0.0 ? 1.0 : -1.0}]
        set sumX [expr {$sumX + $factor * [lindex $normal 0]}]
        set sumY [expr {$sumY + $factor * [lindex $normal 1]}]
        set sumZ [expr {$sumZ + $factor * [lindex $normal 2]}]
    }
    set len [expr {sqrt($sumX * $sumX + $sumY * $sumY + $sumZ * $sumZ)}]
    if {$len < 1.0e-12} { return {0 0 0} }
    return [list [expr {$sumX / $len}] [expr {$sumY / $len}] [expr {$sumZ / $len}]]
}

proc ::SolidSeam::angleDeg {a b} {
    set dot [expr {[lindex $a 0] * [lindex $b 0] + [lindex $a 1] * [lindex $b 1] + [lindex $a 2] * [lindex $b 2]}]
    set dot [::SolidSeam::clamp $dot -1.0 1.0]
    set radians [expr {acos($dot)}]
    return [expr {$radians * 180.0 / 3.141592653589793}]
}

# ---------------------------------------------------------------------------
# Joint classification (mirrors the legacy Python joint_classifier rules):
#   perpendicular (normal vs normal ~90deg) -> T_JOINT  -> PENTA_MIG_T
#   parallel with high boundary ratio        -> BUTT_JOINT -> PENTA_MIG_B
#   parallel otherwise                       -> LAP_JOINT -> PENTA_MIG_L
#   angled (<=40deg)                         -> ANGLED_JOINT -> PENTA_MIG
#   otherwise                                -> UNKNOWN -> PENTA_MIG
# ---------------------------------------------------------------------------
proc ::SolidSeam::classifyJoint {sourceNormal targetNormal} {
    if {$sourceNormal eq {0 0 0} || $targetNormal eq {0 0 0}} {
        return [dict create joint_type UNKNOWN realization PENTA_MIG confidence 0.3]
    }
    set rawAngle [::SolidSeam::angleDeg $sourceNormal $targetNormal]
    set closest [expr {$rawAngle <= 90.0 ? $rawAngle : 180.0 - $rawAngle}]
    set perpendicular [expr {abs($closest - 90.0)}]
    if {$perpendicular <= 20.0} {
        return [dict create joint_type T_JOINT realization PENTA_MIG_T confidence 0.95]
    } elseif {$closest <= 20.0} {
        return [dict create joint_type LAP_JOINT realization PENTA_MIG_L confidence 0.85]
    } elseif {$closest <= 40.0} {
        return [dict create joint_type ANGLED_JOINT realization PENTA_MIG confidence 0.65]
    }
    return [dict create joint_type UNKNOWN realization PENTA_MIG confidence 0.4]
}

# ---------------------------------------------------------------------------
# Parameter derivation:
#   mesh_size  = median spacing of the chain nodes
#   width      = 6.0 by default, clamped into [0.25, 0.8] * mesh_size so the
#                weld section stays compatible with the local mesh
#   spacing    = 6.0 by default, clamped into [0.5*mesh, 0.65*width, 1.15*width]
#   tolerance  = max(gap + 1.25*width, 1.5*mesh_size, 6.0) so the native
#                realization search always covers the joint
# ---------------------------------------------------------------------------
proc ::SolidSeam::deriveParameters {chainNodeIds pairs defaultWidth defaultSpacing} {
    array set coords {}
    foreach nodeId $chainNodeIds {
        set coords($nodeId) [::SolidSeam::nodeXYZ $nodeId]
    }
    set segments {}
    for {set i 0} {$i < [llength $chainNodeIds] - 1} {incr i} {
        set d [::SolidSeam::nodeDistance $coords([lindex $chainNodeIds $i]) $coords([lindex $chainNodeIds [expr {$i + 1}]])]
        if {$d > 1.0e-8} { lappend segments $d }
    }
    set meshSize [::SolidSeam::median $segments]
    if {$meshSize <= 0.0} { set meshSize 10.0 }

    set maximumGap 0.0
    foreach pair $pairs {
        set gap [lindex $pair 2]
        if {$gap > $maximumGap} { set maximumGap $gap }
    }

    set width [::SolidSeam::clamp $defaultWidth [expr {0.25 * $meshSize}] [expr {0.8 * $meshSize}]]
    set spacing [::SolidSeam::clamp $defaultSpacing [expr {0.5 * $meshSize}] [expr {1.15 * $width}]]
    if {$spacing < [expr {0.65 * $width}]} { set spacing [expr {0.65 * $width}] }
    set tolerance [expr {max($maximumGap + 1.25 * $width, 1.5 * $meshSize, 6.0)}]

    return [dict create \
        mesh_size [format %.6f $meshSize] \
        maximum_gap [format %.6f $maximumGap] \
        weld_width [format %.6f $width] \
        line_spacing [format %.6f $spacing] \
        realization_tolerance [format %.6f $tolerance] \
        source_thickness [format %.6f $meshSize] \
        side_mode POSITIVE \
        right_angled false \
        orientation_reversed false \
        parameter_strategy ADAPTIVE_GEOMETRY_TCL_V1]
}

# ---------------------------------------------------------------------------
# Public entry: detect all seam candidates between two components.
# Returns a list of candidate dicts compatible with the existing
# createOneCandidate / validateBeforeCreate / validateAfterCreate flow.
# ---------------------------------------------------------------------------
proc ::SolidSeam::autoDetectSeams {sourceComponentId targetComponentId settings} {
    variable detectionCacheActive
    variable detectionCoordinates
    variable autoNormalCache
    variable detectionAutoMode
    variable detectionReadCache; variable detectionComponents
    array unset detectionReadCache
    set detectionComponents [list $sourceComponentId $targetComponentId]
    set detectionAutoMode [expr {[dict exists $settings automatic] && [dict get $settings automatic]}]
    array unset autoNormalCache
    set detectionCacheActive 1
    array unset detectionCoordinates
    set code [catch {::SolidSeam::detectSeamsImpl $sourceComponentId $targetComponentId $settings} result opts]
    set detectionCacheActive 0
    set detectionAutoMode 0
    array unset detectionCoordinates
    array unset autoNormalCache
    array unset detectionReadCache
    set detectionComponents {}
    if {$code} { return -options $opts $result }
    return $result
}

proc ::SolidSeam::detectSeamsImpl {sourceComponentId targetComponentId settings} {
    set searchDistance [dict get $settings search_distance]
    set maxSearchDistance [dict get $settings max_search_distance]
    set minWeldLength [dict get $settings min_weld_length]
    set gapJumpLimit [dict get $settings gap_jump_limit]
    set defaultWidth [dict get $settings default_width]
    set defaultSpacing [dict get $settings default_spacing]
    set sourceName ""
    catch {set sourceName [hm_getvalue comps id=$sourceComponentId dataname=name]}
    set targetName ""
    catch {set targetName [hm_getvalue comps id=$targetComponentId dataname=name]}

    # The weld node list always comes from the FIRST selected component (the
    # user's manual 1D connector seam flow picks the weld nodes on one side
    # and links both components).  detectJunctionNodes already restricts the
    # source to its boundary nodes: free-edge nodes for shells, the boundary
    # of the outer face that faces the target for solids.
    set pairs [::SolidSeam::detectJunctionNodes $sourceComponentId $targetComponentId $searchDistance]
    set sourceNodeIds {}
    set sourceSeen [dict create]
    foreach pair $pairs {
        set node [lindex $pair 0]
        if {![dict exists $sourceSeen $node]} {
            dict set sourceSeen $node 1
            lappend sourceNodeIds $node
        }
    }
    if {[llength $sourceNodeIds] == 0} { return {} }

    # Estimate the local node spacing from the junction nodes themselves so
    # the chain gap limit is always >= the mesh pitch: with a 10 mm mesh the
    # default gap_jump_limit of 5 would otherwise split every chain into
    # single-node pieces.
    set spacingValues {}
    set sourceIndex [::SolidSeam::spatialIndex $sourceNodeIds]
    foreach nodeId $sourceNodeIds {
        lassign [::SolidSeam::nearestNode $sourceIndex [::SolidSeam::nodeXYZ $nodeId] 1.0e100 $nodeId] partner nearest
        if {$partner ne ""} { lappend spacingValues $nearest }
    }
    set localSpacing [::SolidSeam::median $spacingValues]
    if {$localSpacing <= 0.0} { set localSpacing 10.0 }
    set chainGap [expr {max($gapJumpLimit, 1.5 * $localSpacing)}]

    set automatic [expr {[dict exists $settings automatic] && [dict get $settings automatic]}]
    set pathRecords {}
    if {![::SolidSeam::componentIsSolid $sourceComponentId]} {
        set graph [::SolidSeam::freeBoundaryGraph $sourceComponentId]
        # Filter the complete contour before applying the distance mask: a
        # notch bottom may already have fallen outside the search radius.
        set outlines [::SolidSeam::automaticBoundaryPaths [dict keys $graph] $graph 1]
        set outlines [::SolidSeam::excludeBoundaryNotches $outlines $sourceComponentId $localSpacing]
        set allowed [dict create]
        foreach outline $outlines {
            set path [dict get $outline node_ids]
            if {[dict get $outline is_closed]} { lappend path [lindex $path 0] }
            for {set i 1} {$i < [llength $path]} {incr i} {
                set a [lindex $path [expr {$i-1}]]; set b [lindex $path $i]
                dict lappend allowed $a $b; dict lappend allowed $b $a
            }
        }
        set retained {}
        foreach node $sourceNodeIds { if {[dict exists $allowed $node]} { lappend retained $node } }
        set pathRecords [::SolidSeam::automaticBoundaryPaths $retained $allowed 1]
    } else {
        foreach chain [::SolidSeam::buildChains $sourceNodeIds $chainGap] {
            lappend pathRecords [dict create node_ids $chain is_closed 0]
        }
    }
    set sourceNormal {0 0 0}; set targetNormal {0 0 0}
    if {!$automatic} {
        set sourceNormal [::SolidSeam::componentAverageNormal $sourceComponentId]
        set targetNormal [::SolidSeam::componentAverageNormal $targetComponentId]
    }

    set candidates {}
    set index 0
    foreach record $pathRecords {
        set chainNodeIds [dict get $record node_ids]
        incr index
        if {[llength $chainNodeIds] < 2} { continue }
        set members [dict create]
        foreach node $chainNodeIds { dict set members $node 1 }
        set chainPairs {}
        foreach pair $pairs { if {[dict exists $members [lindex $pair 0]]} { lappend chainPairs $pair } }
        set parameters [::SolidSeam::deriveParameters $chainNodeIds $chainPairs $defaultWidth $defaultSpacing]
        if {[dict get $parameters mesh_size] <= 0.0} { continue }
        set chainLength 0.0
        for {set i 0} {$i < [llength $chainNodeIds] - 1} {incr i} {
            set p [::SolidSeam::nodeXYZ [lindex $chainNodeIds $i]]
            set q [::SolidSeam::nodeXYZ [lindex $chainNodeIds [expr {$i + 1}]]]
            set chainLength [expr {$chainLength + [::SolidSeam::nodeDistance $p $q]}]
        }
        if {$chainLength < $minWeldLength} { continue }
        set classification [::SolidSeam::classifyJoint $sourceNormal $targetNormal]
        set candidateId "AUTO_${sourceComponentId}_${targetComponentId}_${index}"
        set candidate [dict create \
            candidate_id $candidateId \
            source_component_id $sourceComponentId \
            target_component_id $targetComponentId \
            source_component_name $sourceName \
            target_component_name $targetName \
            node_ids $chainNodeIds \
            status PENDING \
            suggested_realization [dict get $classification realization] \
            joint_type [dict get $classification joint_type] \
            confidence [dict get $classification confidence] \
            confidence_level [expr {[dict get $classification confidence] >= 0.8 ? "HIGH" : "MEDIUM"}] \
            duplicate_state NONE \
            warnings {} \
            chain_length [format %.3f $chainLength] \
        ]
        set candidate [dict merge $candidate $parameters]
        dict set candidate is_closed [dict get $record is_closed]
        if {$automatic} {
            set candidate [::SolidSeam::applyAutomaticParameters $candidate $chainPairs]
        }
        lappend candidates $candidate
    }
    return $candidates
}
