# Does *findfaces change the export behavior of subsequent feoutput_select?
# Same session, same marks: export comp A BEFORE findfaces (Y1), AFTER
# findfaces (Y2), then the ^faces comp (Y3, nodes clobber), (Y4, elems mark
# only), and batch_mesher recipe on ^faces (Y5).
#
# Run headless with the same hmbatch invocations as the other audit probes.
# Result: runtime/audit_auto_hole_rbe2_fefaces_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_fefaces_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
proc countInFile {path keyword} {
    if {![file isfile $path]} { return -1 }
    set fd [open $path r]
    set content [read $fd]
    close $fd
    return [regexp -all "\n${keyword}" $content]
}
proc exportCounts {label path} {
    P "${label}_BYTES" [expr {[file isfile $path] ? [file size $path] : -1}]
    P "${label}_GRID" [countInFile $path "GRID"]
    P "${label}_CHEXA" [countInFile $path "CHEXA"]
    P "${label}_CQUAD4" [countInFile $path "CQUAD4"]
    P "${label}_CTRIA3" [countInFile $path "CTRIA3"]
}
proc moduleExact {label path compId} {
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
    *createmark elems 1 "by component id" $compId
    *createmark nodes 1 "by component id" $compId
    P "${label}_MARK1_NODES" [llength [hm_getmark nodes 1]]
    if {[file exists $path]} { file delete -force $path }
    catch {hm_answernext yes}
    if {[catch {*feoutput_select $::templatePath $path 1 0 0} e]} {
        P "${label}_EXPORT" "ERROR: $e"
    } else {
        P "${label}_EXPORT" "ok"
    }
    exportCounts $label $path
    catch {*clearmark elems 1}
    catch {*clearmark nodes 1}
}

P "VERSION" $version

namespace eval ::Audit {}
proc ::Audit::node {x y z} {
    catch {*createnode $x $y $z 0 0 0}
    catch {*createmark nodes 1 -1}
    return [lindex [hm_getmark nodes 1] end]
}
proc ::Audit::quad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    return [hm_latestentityid elems]
}

# ---------------------------------------------------------------- fixture FEM text
set femSource [file join $outputDir "audit_fefaces_source.fem"]
set fd [open $femSource w]
puts $fd "BEGIN BULK"
puts $fd "\$HMNAME COMP 1 \"AUDIT_IMPORT_A\""
puts $fd "\$HWCOLOR COMP 1 3"
puts $fd "\$HMNAME COMP 2 \"AUDIT_IMPORT_B\""
puts $fd "\$HWCOLOR COMP 2 4"
for {set i 1} {$i <= 8} {incr i} {
    set base [expr {($i-1) % 4}]
    set x [expr {[expr {$i > 4}] ? 10 : 0}]
    set y [expr {[expr {$base == 1 || $base == 2}] ? 10 : 0}]
    set z [expr {[expr {$base == 2 || $base == 3}] ? 10 : 0}]
    puts $fd "GRID,$i,,$x,$y,$z"
}
puts $fd "CHEXA          1       1       1       2       3       4       5       6"
puts $fd "+             7       8"
for {set i 1} {$i <= 8} {incr i} {
    set j [expr {$i + 10}]
    set base [expr {($i-1) % 4}]
    set x [expr {[expr {$i > 4}] ? 30 : 20}]
    set y [expr {[expr {$base == 1 || $base == 2}] ? 10 : 0}]
    set z [expr {[expr {$base == 2 || $base == 3}] ? 10 : 0}]
    puts $fd "GRID,$j,,$x,$y,$z"
}
puts $fd "CHEXA          2       2      11      12      13      14      15      16"
puts $fd "+            17      18"
puts $fd "ENDDATA"
close $fd

set executableDir [hm_info -appinfo EXECUTABLEDIR]
set ::templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
catch {*templatefileset $::templatePath}
catch {hm_answernext yes}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" [file nativename $femSource] 0 0 0 0 0 1 10 1 0} e]} {
    P "FEINPUT" "ERROR: $e"
    P "STATUS" "ABORT"
    close $channel
    exit 0
}
P "FEINPUT" "ok"
set compA [hm_getvalue comps name=AUDIT_IMPORT_A dataname=id]
set compB [hm_getvalue comps name=AUDIT_IMPORT_B dataname=id]
P "COMP_A" $compA
P "COMP_B" $compB

set base [file join $outputDir "audit_fefaces_${version}"]

# ---------------------------------------------------------------- Y1: module-exact on comp A, BEFORE findfaces
moduleExact Y1 [file join $outputDir "audit_fefaces_${version}_Y1_before_findfaces.fem"] $compA

# ---------------------------------------------------------------- findfaces on comp A
catch {*clearmark comps 1}
eval *createmark comps 1 [list $compA]
if {[catch {*findfaces components 1} e]} {
    P "FINDFACES" "ERROR: $e"
} else {
    P "FINDFACES" "ok"
}
set faceCompId ""
catch {set faceCompId [hm_entityinfo id comps ^faces -byname]}
P "FACES_COMP" $faceCompId
catch {*clearmark elems 2}
catch {*createmark elems 2 "by component id" $faceCompId}
set faceElems [hm_getmark elems 2]
P "FACES_COUNT" [llength $faceElems]
P "FACE_TYPENAME" [hm_getvalue elems id=[lindex $faceElems 0] dataname=typename]

# ---------------------------------------------------------------- Y2: module-exact on comp A, AFTER findfaces
moduleExact Y2 [file join $outputDir "audit_fefaces_${version}_Y2_after_findfaces.fem"] $compA

# ---------------------------------------------------------------- Y3: module-exact on ^faces
moduleExact Y3 [file join $outputDir "audit_fefaces_${version}_Y3_faces.fem"] $faceCompId

# ---------------------------------------------------------------- Y7: rename ^faces to a regular name, then module-exact
catch {*createmark comps 2 "by name only" ^faces}
set faceIds [hm_getmark comps 2]
catch {*clearmark comps 2}
if {[llength $faceIds] > 0} {
    set faceId [lindex $faceIds 0]
    if {[catch {*setvalue comps id=$faceId name=AUDIT_FACES_RENAMED} e]} {
        P "Y7_RENAME" "ERROR: $e"
    } else {
        P "Y7_RENAME" "ok"
    }
    P "Y7_RENAMED_ID" $faceId
    moduleExact Y7 [file join $outputDir "audit_fefaces_${version}_Y7_renamed.fem"] $faceId
}

# ---------------------------------------------------------------- Y4: elems mark 1 only (no node clobber)
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 "by component id" $faceCompId
set pathY4 [file join $outputDir "audit_fefaces_${version}_Y4_elems_only.fem"]
if {[file exists $pathY4]} { file delete -force $pathY4 }
catch {hm_answernext yes}
if {[catch {*feoutput_select $::templatePath $pathY4 1 0 0} e]} {
    P "Y4_EXPORT" "ERROR: $e"
} else {
    P "Y4_EXPORT" "ok"
}
exportCounts "Y4" $pathY4
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# ---------------------------------------------------------------- Y5: batch_mesher recipe on ^faces (name-based mark diag)
catch {*clearmark comps 1}
if {[catch {*createmark comps 1 "by name only" ^faces} e]} {
    P "Y5_MARK_NAME" "ERROR: $e"
} else {
    P "Y5_MARK_NAME_LEN" [hm_marklength comps 1]
}
catch {*clearmark comps 1}
catch {*clearmark comps 2}
*createmark comps 2 "by id only" $faceCompId
P "Y5_MARK_ID_LEN" [hm_marklength comps 2]
catch {*allsuppressoutput 1}
catch {*clearmark comps 1}
*createmark comps 1 "by id only" $faceCompId
catch {*marksuppressoutput comps 1 0}
set pathY5 [file join $outputDir "audit_fefaces_${version}_Y5_bmesher.fem"]
if {[file exists $pathY5]} { file delete -force $pathY5 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $::templatePath] [file nativename $pathY5] 0 0 2 1 0} e]} {
    P "Y5_EXPORT" "ERROR: $e"
} else {
    P "Y5_EXPORT" "ok"
}
exportCounts "Y5" $pathY5
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark comps 1}
catch {*clearmark comps 2}

# ---------------------------------------------------------------- Y6: movemark faces into a REGULAR comp, then module-exact
catch {*clearmark elems 2}
*createmark elems 2 "by component id" $faceCompId
set faceCountBefore [hm_marklength elems 2]
P "Y6_FACES_BEFORE" $faceCountBefore
catch {*collectorcreateonly components AUDIT_FACES_TMP "" 35}
catch {*movemark elems 2 AUDIT_FACES_TMP}
set tmpCompId [hm_getvalue comps name=AUDIT_FACES_TMP dataname=id]
moduleExact Y6 [file join $outputDir "audit_fefaces_${version}_Y6_moved.fem"] $tmpCompId
catch {*clearmark elems 2}

# ---------------------------------------------------------------- Y8: manually created caret-prefixed comp
catch {*collectorcreateonly components ^MINE "" 8}
*currentcollector component ^MINE
set quadE [::Audit::quad [list [::Audit::node 50 0 0] [::Audit::node 60 0 0] \
    [::Audit::node 60 10 0] [::Audit::node 50 10 0]]]
P "Y8_QUAD" $quadE
set mineId [hm_getvalue comps name=^MINE dataname=id]
moduleExact Y8 [file join $outputDir "audit_fefaces_${version}_Y8_caret_manual.fem"] $mineId

# ---------------------------------------------------------------- cleanup
foreach name {AUDIT_IMPORT_A AUDIT_IMPORT_B ^faces AUDIT_FACES_TMP AUDIT_FACES_RENAMED ^MINE} {
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
