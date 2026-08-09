# Decisive test: module-exact export on an IMPORTED model with template
# loaded BEFORE *findfaces (the module's real production shape).
#
#   X1: module-exact (elems 1 + nodes 1 clobber + feoutput_select 1 0 0)
#   X2: batch_mesher recipe on ^faces (mode 2 + suppress others)
#   X3: elems-mark-only variant (elems 1 faces + nodes 2 faces, select 1 1 0)
#
# Run headless with the same hmbatch invocations as the other audit probes.
# Result: runtime/audit_auto_hole_rbe2_feexact_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_feexact_${version}.log"]
set channel [open $reportPath w]

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}
# Tcl regexp ^ anchors at string start only (no implicit multiline): count
# line-anchored cards via an explicit leading newline.
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

P "VERSION" $version

# ---------------------------------------------------------------- fixture FEM text (2 hexa comps)
set femSource [file join $outputDir "audit_feexact_source.fem"]
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
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
catch {*templatefileset $templatePath}
catch {hm_answernext yes}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" [file nativename $femSource] 0 0 0 0 0 1 10 1 0} e]} {
    P "FEINPUT" "ERROR: $e"
    P "STATUS" "ABORT"
    close $channel
    exit 0
}
P "FEINPUT" "ok"
set compA [hm_getvalue comps name=AUDIT_IMPORT_A dataname=id]
P "COMP_A" $compA

# ---------------------------------------------------------------- findfaces with template loaded
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
P "FACE_CONFIG" [hm_getvalue elems id=[lindex $faceElems 0] dataname=config]

set base [file join $outputDir "audit_feexact_${version}"]

# ---------------------------------------------------------------- X1: module-exact export
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 "by component id" $faceCompId
*createmark nodes 1 "by component id" $faceCompId
set nodeCount [llength [hm_getmark nodes 1]]
P "X1_NODE_COUNT" $nodeCount
set pathX1 "${base}_X1_module_exact.fem"
if {[file exists $pathX1]} { file delete -force $pathX1 }
catch {hm_answernext yes}
if {[catch {*feoutput_select $templatePath $pathX1 1 0 0} e]} {
    P "X1_EXPORT" "ERROR: $e"
} else {
    P "X1_EXPORT" "ok"
}
exportCounts "X1" $pathX1
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# ---------------------------------------------------------------- X2: batch_mesher recipe on ^faces
catch {*clearmark elems 1}
catch {*clearmark comps 1}
catch {*allsuppressoutput 1}
*createmark comps 1 "by name only" ^faces
catch {*marksuppressoutput comps 1 0}
set pathX2 "${base}_X2_bmesher_recipe.fem"
if {[file exists $pathX2]} { file delete -force $pathX2 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathX2] 0 0 2 1 0} e]} {
    P "X2_EXPORT" "ERROR: $e"
} else {
    P "X2_EXPORT" "ok"
}
exportCounts "X2" $pathX2
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark comps 1}

# ---------------------------------------------------------------- X3: elems 1 + nodes 2, feoutput_select 1 1 0
catch {*clearmark elems 1}
catch {*clearmark nodes 2}
*createmark elems 1 "by component id" $faceCompId
*createmark nodes 2 "by component id" $faceCompId
set pathX3 "${base}_X3_elems1_nodes2.fem"
if {[file exists $pathX3]} { file delete -force $pathX3 }
catch {hm_answernext yes}
if {[catch {*feoutput_select $templatePath $pathX3 1 1 0} e]} {
    P "X3_EXPORT" "ERROR: $e"
} else {
    P "X3_EXPORT" "ok"
}
exportCounts "X3" $pathX3
catch {*clearmark elems 1}
catch {*clearmark nodes 2}

# ---------------------------------------------------------------- cleanup
foreach name {AUDIT_IMPORT_A AUDIT_IMPORT_B ^faces} {
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
