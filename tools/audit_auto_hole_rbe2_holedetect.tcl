# Follow-up audit probe for auto_hole_rbe2:
#  1. *feoutput_select vs *feoutputwithdata export variants (empty-deck issue)
#  2. *elementtype mapping without a loaded template (does it fix types?)
#  3. RBE3 element dataname semantics (module validation path)
#  4. official hm_holedetection* API on a solid through-hole ring (alternative
#     to the Python free-face segmentation)
#
# Run headless with the same hmbatch invocations as the first audit probe.
# Result: runtime/audit_auto_hole_rbe2_holedetect_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_holedetect_${version}.log"]
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
proc countInFile {path regexp} {
    if {![file isfile $path]} { return -1 }
    set fd [open $path r]
    set content [read $fd]
    close $fd
    return [regexp -all $regexp $content]
}

P "VERSION" $version

# ---------------------------------------------------------------- fixture (same ring as first probe)
namespace eval ::Audit {}
array set ::Audit::nid {}
proc ::Audit::hexa8 {n1 n2 n3 n4 n5 n6 n7 n8} {
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 [list $n1 $n2 $n3 $n4 $n5 $n6 $n7 $n8]
    *createelement 205 1 1 1
    catch {*clearmark nodes 1}
}
set nextId 1
for {set k 0} {$k < 3} {incr k} {
    for {set j 0} {$j < 5} {incr j} {
        for {set i 0} {$i < 5} {incr i} {
            set ::Audit::nid($i,$j,$k) $nextId
            incr nextId
            *createnode [expr {10*$i}] [expr {10*$j}] [expr {10*$k}] 0 0 0
        }
    }
}
catch {*createmark comps 2}
*collectorcreateonly comps AUDIT_SOLID "" 2
set solidComp [hm_getvalue comps name=AUDIT_SOLID dataname=id]
*currentcollector comps AUDIT_SOLID
for {set k 0} {$k < 2} {incr k} {
    for {set j 0} {$j < 4} {incr j} {
        for {set i 0} {$i < 4} {incr i} {
            if {$i >= 1 && $i <= 2 && $j >= 1 && $j <= 2} { continue }
            ::Audit::hexa8 \
                $::Audit::nid($i,$j,$k) $::Audit::nid([expr {$i+1}],$j,$k) \
                $::Audit::nid([expr {$i+1}],[expr {$j+1}],$k) $::Audit::nid($i,[expr {$j+1}],$k) \
                $::Audit::nid($i,$j,[expr {$k+1}]) $::Audit::nid([expr {$i+1}],$j,[expr {$k+1}]) \
                $::Audit::nid([expr {$i+1}],[expr {$j+1}],[expr {$k+1}]) $::Audit::nid($i,[expr {$j+1}],[expr {$k+1}])
        }
    }
}
P "TEMPLATE_FRESH" [string trim [hm_info templatetype]]

# ---------------------------------------------------------------- *elementtype WITHOUT template
catch {*clearmark comps 1}
eval *createmark comps 1 [list $solidComp]
TRY "FINDFACES" {*findfaces components 1}
set facesCompId [hm_getvalue comps name=^faces dataname=id]
P "FACES_COMP" $facesCompId
catch {*clearmark elems 1}
*createmark elems 1 "by component id" $facesCompId
set faceElems [hm_getmark elems 1]
P "FACES_COUNT" [llength $faceElems]
set triaSample ""; set quadSample ""
foreach eid $faceElems {
    set c [hm_getvalue elems id=$eid dataname=config]
    if {$c eq "103" && $triaSample eq ""} { set triaSample $eid }
    if {$c eq "104" && $quadSample eq ""} { set quadSample $eid }
}
P "TRIA_SAMPLE" $triaSample
P "QUAD_SAMPLE" $quadSample
P "TRIA_TYPENAME_BEFORE" [hm_getvalue elems id=$triaSample dataname=typename]
P "QUAD_TYPENAME_BEFORE" [hm_getvalue elems id=$quadSample dataname=typename]
TRY "ELEMENTTYPE_2_1" {*elementtype 2 1}
TRY "ELEMENTTYPE_104_1" {*elementtype 104 1}
TRY "ELEMENTSETTYPES_1" {*elementsettypes 1}
P "TRIA_TYPENAME_AFTER" [hm_getvalue elems id=$triaSample dataname=typename]
P "QUAD_TYPENAME_AFTER" [hm_getvalue elems id=$quadSample dataname=typename]
P "TRIA_CONFIG_AFTER" [hm_getvalue elems id=$triaSample dataname=config]
P "QUAD_CONFIG_AFTER" [hm_getvalue elems id=$quadSample dataname=config]

# load the OptiStruct template for the export tests
set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
TRY "TEMPLATE_SET" {*templatefileset $templatePath}
P "TEMPLATE_NOW" [string trim [hm_info templatetype]]

# ---------------------------------------------------------------- export variants
set base [file join $outputDir "audit_fe_${version}"]
proc exportCounts {label path} {
    P "${label}_BYTES" [expr {[file isfile $path] ? [file size $path] : -1}]
    P "${label}_GRID" [countInFile $path {^GRID}]
    P "${label}_CQUAD4" [countInFile $path {CQUAD4}]
    P "${label}_CTRIA3" [countInFile $path {CTRIA3}]
    P "${label}_HEXA" [countInFile $path {CHEXA}]
}

# A: module exact sequence (elems mark 1 then nodes mark 1 clobber) - feoutput_select 1 0 0
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 "by component id" $facesCompId
*createmark nodes 1 "by component id" $facesCompId
set pathA "${base}_A_module_exact.fem"
TRY "A_FEOUTPUT_SELECT" {*feoutput_select $templatePath $pathA 1 0 0}
exportCounts "A_MODULE_EXACT" $pathA
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# B: elems mark 1 + nodes mark 2, flags 1 1 0
catch {*clearmark elems 1}
catch {*clearmark nodes 2}
*createmark elems 1 "by component id" $facesCompId
*createmark nodes 2 "by component id" $facesCompId
set pathB "${base}_B_marks_110.fem"
TRY "B_FEOUTPUT_SELECT_110" {*feoutput_select $templatePath $pathB 1 1 0}
exportCounts "B_MARKS_110" $pathB
catch {*clearmark elems 1}
catch {*clearmark nodes 2}

# C: elems mark 1 only, flags 1 0 0
catch {*clearmark elems 1}
*createmark elems 1 "by component id" $facesCompId
set pathC "${base}_C_elems_100.fem"
TRY "C_FEOUTPUT_SELECT_ELEMS" {*feoutput_select $templatePath $pathC 1 0 0}
exportCounts "C_ELEMS_100" $pathC
catch {*clearmark elems 1}

# D: feoutputwithdata, batch_mesher style (custom component output 2, suppress others)
catch {*clearmark comps 1}
*createmark comps 1 "by name only" ^faces
catch {*allsuppressoutput 1}
catch {*marksuppressoutput comps 1 0}
set pathD "${base}_D_withdata_2.fem"
TRY "D_FEOUTPUTWITHDATA_2" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathD] 0 0 2 1 0}
exportCounts "D_WITHDATA_2" $pathD
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark comps 1}

# E: feoutputwithdata, contact_setup style (1 1 0) with elems mark 1
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 "by component id" $facesCompId
*createmark nodes 1 "by component id" $facesCompId
set pathE "${base}_E_withdata_110.fem"
TRY "E_FEOUTPUTWITHDATA_110" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathE] 0 0 1 1 0}
exportCounts "E_WITHDATA_110" $pathE
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# F: feoutputwithdata, no marks at all (whole model)
set pathF "${base}_F_withdata_nomark.fem"
TRY "F_FEOUTPUTWITHDATA_NOMARK" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathF] 0 0 1 1 0}
exportCounts "F_WITHDATA_NOMARK" $pathF

# ---------------------------------------------------------------- RBE3 dataname semantics
set wallNodes [list \
    $::Audit::nid(1,1,0) $::Audit::nid(1,2,0) $::Audit::nid(1,3,0) $::Audit::nid(2,1,0) \
    $::Audit::nid(2,3,0) $::Audit::nid(3,1,0) $::Audit::nid(3,2,0) $::Audit::nid(3,3,0)]
set count [llength $wallNodes]
TRY "CREATENODE" {*createnode 20 20 5 0 0 0}
set centerNode [hm_latestentityid nodes]
catch {*clearmark nodes 2}
eval *createmark nodes 2 $wallNodes
set dofs {}; set weights {}
foreach n $wallNodes { lappend dofs 123456; lappend weights 1.0 }
eval *createarray $count $dofs
eval *createdoublearray $count $weights
TRY "RBE3" {*rbe3 2 1 $count 1 $count $centerNode 123456 1.0}
set rbe3Elem [hm_latestentityid elems]
P "RBE3_ELEM" $rbe3Elem
if {$rbe3Elem ne ""} {
    foreach dn {independentnode.id dependentnode.id dependentnodesmax dependentnodes config typename} {
        TRY "RBE3_DATANAME $dn" {hm_getvalue elems id=$rbe3Elem dataname=$dn}
    }
    set refByDep [hm_getvalue elems id=$rbe3Elem dataname=dependentnode.id]
    P "RBE3_MODULE_VALIDATION_WOULD_PASS" [expr {$refByDep == $centerNode ? 1 : 0}]
}
catch {*clearmark nodes 2}
catch {*clearmark elems 2}

# ---------------------------------------------------------------- official hole detection API
TRY "HOLEDET_INIT" {hm_holedetectioninit}
catch {*clearmark elems 1}
eval *createmark elems 1 [list $solidComp]
TRY "HOLEDET_SETENTITIES" {hm_holedetectionsetentities elems 1}
TRY "HOLEDET_SETTUBEPARAMS" {hm_holedetectionsettubeparams \
    tube_shape=2 tube_type=1 min_height=5 max_height=50 min_cone_angle=0 \
    min_planar_dim=1 max_planar_dim=40 max_offset_plane_dev=5 \
    feature_angle=0 max_offset_angle=60 max_smooth_edge_angle=65.0 max_geom_dev_percent=10}
TRY "HOLEDET_FINDHOLES" {hm_holedetectionfindholes 6}
TRY "HOLEDET_NUMHOLES" {hm_holedetectiongetnumberofholes}
set numHoles 0
catch {set numHoles [hm_holedetectiongetnumberofholes]}
P "HOLEDET_NUMHOLES_VALUE" $numHoles
for {set i 0} {$i < $numHoles && $i < 3} {incr i} {
    TRY "HOLEDET_DETAILS_$i" {hm_holedetectiongetholedetails $i}
    catch {set details [hm_holedetectiongetholedetails $i]}
    if {[llength $details] > 0} {
        P "HOLEDET_DETAILS_${i}_LEN" [llength $details]
        set dim [lindex $details 0]
        set type [lindex $details 1]
        P "HOLEDET_DETAILS_${i}_DIM" $dim
        P "HOLEDET_DETAILS_${i}_TYPE" $type
        # circular (type 2): dim0 list at index 5, dim1 list at index 12
        if {[llength $details] > 5} {
            P "HOLEDET_DETAILS_${i}_IDX5" [join [lindex $details 5] { }]
        }
        if {[llength $details] > 12} {
            P "HOLEDET_DETAILS_${i}_IDX12" [join [lindex $details 12] { }]
        }
        # dump a compact structural view of every top-level element
        set structure {}
        for {set j 0} {$j < [llength $details]} {incr j} {
            set item [lindex $details $j]
            if {[llength $item] > 8} {
                lappend structure "$j:[llength $item]"
            } else {
                lappend structure "$j:$item"
            }
        }
        P "HOLEDET_DETAILS_${i}_STRUCT" [join $structure { | }]
    }
}
TRY "HOLEDET_END" {hm_holedetectionend}

# ---------------------------------------------------------------- cleanup
foreach name {AUDIT_SOLID ^faces} {
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
