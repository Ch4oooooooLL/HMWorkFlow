# Cylindrical through-hole fixture probe: validate the official hole
# detection API (hm_holedetection*) and *findholessolid on a true circular
# tube mesh, and re-check the module's export path on the same fixture.
#
# Fixture: 16-gon ring of hexa8 elements, inner radius 10, outer radius 30,
# height 20 (2 z-layers) around (20,20) - a genuine cylindrical through hole.
#
# Run headless with the same hmbatch invocations as the first audit probe.
# Result: runtime/audit_auto_hole_rbe2_cylinders_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_cylinders_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc TRY {label script} {
    set code [catch {uplevel 1 $script} result opts]
    if {$code} {
        P "$label" "ERROR: $result"
    } else {
        P "$label" "OK: $result"
    }
}

P "VERSION" $version

namespace eval ::Audit {}
array set ::Audit::nid {}
proc ::Audit::hexa8 {n1 n2 n3 n4 n5 n6 n7 n8} {
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 [list $n1 $n2 $n3 $n4 $n5 $n6 $n7 $n8]
    *createelement 205 1 1 1
    catch {*clearmark nodes 1}
}

# build the 16-gon ring
set sectors 16
set cx 20.0
set cy 20.0
set rInner 10.0
set rOuter 30.0
set zLevels {0 10 20}
set nextId 1
set pi [expr {acos(-1.0)}]
for {set k 0} {$k < 3} {incr k} {
    set z [lindex $zLevels $k]
    for {set s 0} {$s < $sectors} {incr s} {
        set theta [expr {2.0*$pi*$s/double($sectors)}]
        set ct [expr {cos($theta)}]
        set st [expr {sin($theta)}]
        set ::Audit::nid(I,$s,$k) $nextId
        incr nextId
        *createnode [expr {$cx + $rInner*$ct}] [expr {$cy + $rInner*$st}] $z 0 0 0
        set ::Audit::nid(O,$s,$k) $nextId
        incr nextId
        *createnode [expr {$cx + $rOuter*$ct}] [expr {$cy + $rOuter*$st}] $z 0 0 0
    }
}
catch {*createmark comps 2}
*collectorcreateonly comps AUDIT_TUBE "" 2
set solidComp [hm_getvalue comps name=AUDIT_TUBE dataname=id]
*currentcollector comps AUDIT_TUBE
for {set k 0} {$k < 2} {incr k} {
    for {set s 0} {$s < $sectors} {incr s} {
        set s1 [expr {($s+1) % $sectors}]
        ::Audit::hexa8 \
            $::Audit::nid(I,$s,$k)  $::Audit::nid(I,$s1,$k) \
            $::Audit::nid(O,$s1,$k) $::Audit::nid(O,$s,$k) \
            $::Audit::nid(I,$s,[expr {$k+1}])  $::Audit::nid(I,$s1,[expr {$k+1}]) \
            $::Audit::nid(O,$s1,[expr {$k+1}]) $::Audit::nid(O,$s,[expr {$k+1}])
    }
}
catch {*clearmark elems 2}
*createmark elems 2 "by comp id" $solidComp
P "TUBE_HEXAS" [llength [hm_getmark elems 2]]
catch {*clearmark elems 2}

# ---------------------------------------------------------------- 3D hole detection (official API)
TRY "HOLEDET_INIT" {hm_holedetectioninit}
catch {*clearmark elems 1}
eval *createmark elems 1 [list $solidComp]
TRY "HOLEDET_SETENTITIES" {hm_holedetectionsetentities elems 1}
TRY "HOLEDET_SETTUBEPARAMS" {hm_holedetectionsettubeparams \
    tube_shape=2 tube_type=1 min_height=5 max_height=50 min_cone_angle=0 \
    min_planar_dim=5 max_planar_dim=40 max_offset_plane_dev=5 \
    feature_angle=0 max_offset_angle=60 max_smooth_edge_angle=65.0 max_geom_dev_percent=10}
TRY "HOLEDET_FINDHOLES_6" {hm_holedetectionfindholes 6}
set numHoles 0
catch {set numHoles [hm_holedetectiongetnumberofholes]}
P "HOLEDET_NUMHOLES" $numHoles
for {set i 0} {$i < $numHoles && $i < 2} {incr i} {
    catch {set details [hm_holedetectiongetholedetails $i]}
    P "HOLEDET_DETAILS_${i}_LEN" [llength $details]
    P "HOLEDET_DETAILS_${i}_DIM" [lindex $details 0]
    P "HOLEDET_DETAILS_${i}_TYPE" [lindex $details 1]
    set structure {}
    for {set j 0} {$j < [llength $details]} {incr j} {
        set item [lindex $details $j]
        if {[llength $item] > 8} {
            lappend structure "$j:list([llength $item])"
        } else {
            lappend structure "$j:$item"
        }
    }
    P "HOLEDET_DETAILS_${i}_STRUCT" [join $structure { | }]
    if {[llength $details] > 5} {
        set nodes5 [lindex $details 5]
        P "HOLEDET_DETAILS_${i}_IDX5" [join [lrange $nodes5 0 12] { }]
    }
    if {[llength $details] > 12} {
        set nodes12 [lindex $details 12]
        P "HOLEDET_DETAILS_${i}_IDX12" [join [lrange $nodes12 0 12] { }]
    }
}
TRY "HOLEDET_END" {hm_holedetectionend}

# ---------------------------------------------------------------- *findholessolid (commented-out official call shape)
TRY "FINDHOLESSOLID" {*findholessolid 2 5 50 0 45.0 5 40 5 0 65.0 1 0 0 0 0}

# ---------------------------------------------------------------- 2D hole detection on the free faces
catch {*clearmark comps 1}
eval *createmark comps 1 [list $solidComp]
TRY "FINDFACES" {*findfaces components 1}
set facesCompId [hm_getvalue comps name=^faces dataname=id]
P "FACES_COMP" $facesCompId
catch {*clearmark elems 1}
*createmark elems 1 "by component id" $facesCompId
set faceElems [hm_getmark elems 1]
P "FACES_COUNT" [llength $faceElems]

TRY "HOLEDET2D_INIT" {hm_holedetectioninit}
catch {*clearmark elems 1}
eval *createmark elems 1 [list $solidComp]
TRY "HOLEDET2D_SETENTITIES" {hm_holedetectionsetentities elems 1}
TRY "HOLEDET2D_SETHOLEPARAMS" {hm_holedetectionsetholeparams \
    hole_shape=2 min_planar_dim=5 max_planar_dim=40 max_offset_plane_dev=5 \
    max_big_planar_dim=1.0 max_geom_dev_percent=10 max_smooth_edge_angle=65.0}
TRY "HOLEDET2D_FINDHOLES_1" {hm_holedetectionfindholes 1}
set numHoles2d 0
catch {set numHoles2d [hm_holedetectiongetnumberofholes]}
P "HOLEDET2D_NUMHOLES" $numHoles2d
for {set i 0} {$i < $numHoles2d && $i < 2} {incr i} {
    catch {set details [hm_holedetectiongetholedetails $i]}
    P "HOLEDET2D_DETAILS_${i}_DIM" [lindex $details 0]
    P "HOLEDET2D_DETAILS_${i}_TYPE" [lindex $details 1]
    set structure {}
    for {set j 0} {$j < [llength $details]} {incr j} {
        set item [lindex $details $j]
        if {[llength $item] > 8} {
            lappend structure "$j:list([llength $item])"
        } else {
            lappend structure "$j:$item"
        }
    }
    P "HOLEDET2D_DETAILS_${i}_STRUCT" [join $structure { | }]
    if {[llength $details] > 5} {
        P "HOLEDET2D_DETAILS_${i}_IDX5" [join [lrange [lindex $details 5] 0 12] { }]
    }
}
TRY "HOLEDET2D_END" {hm_holedetectionend}

# ---------------------------------------------------------------- cleanup
foreach name {AUDIT_TUBE ^faces} {
    catch {*createmark comps 2 "by name only" $name}
    set ids [hm_getmark comps 2]
    if {[llength $ids] > 0} { catch {*deletemark comps 2} }
    catch {*clearmark comps 2}
}
catch {*clearmarkall 1}
catch {*clearmarkall 2}

P "STATUS" "DONE"
close $channel
exit 0
