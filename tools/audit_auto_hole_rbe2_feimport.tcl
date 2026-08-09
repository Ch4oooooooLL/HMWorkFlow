# Root-cause probe for the empty FE export seen in hmbatch fresh sessions:
# hypothesis = freshly built hmbatch models have NO solver id pool, so
# feoutput serializes nothing (it writes solver ids).  Test: import a small
# OptiStruct deck via *readfile (batch_mesher precedent), then re-run the
# module's exact export variants and count GRID/CHEXA cards.  Also decides
# whether *feoutput_select reads entity marks or the display list.
#
# Run headless with the same hmbatch invocations as the other audit probes.
# Result: runtime/audit_auto_hole_rbe2_feimport_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_feimport_${version}.log"]
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
proc exportCounts {label path} {
    P "${label}_BYTES" [expr {[file isfile $path] ? [file size $path] : -1}]
    P "${label}_GRID" [countInFile $path {^GRID}]
    P "${label}_CHEXA" [countInFile $path {^CHEXA}]
}

P "VERSION" $version

# ---------------------------------------------------------------- fixture FEM text
set femSource [file join $outputDir "audit_feimport_source.fem"]
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
puts $fd "PSOLID,1,1"
puts $fd "MAT1,1,210000.,0.3,7.9E-9"
puts $fd "ENDDATA"
close $fd
P "SOURCE_BYTES" [file size $femSource]

# ---------------------------------------------------------------- pools before import
TRY "POOLS_BEFORE" {hm_getidpools nodes name}

set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
TRY "TEMPLATE_SET" {*templatefileset $templatePath}
P "TEMPLATE_NOW" [string trim [hm_info templatetype]]

# ---------------------------------------------------------------- import
# *readfile rejects .fem decks in hmbatch ("not a HyperMesh database");
# feinputwithdata2 with explicit optistruct selector is the proven path
# (adhesive probe, batch_mesher background_merge_worker.tcl).
catch {hm_answernext yes}
TRY "FEINPUT" {*feinputwithdata2 "#optistruct/optistruct" [file nativename $femSource] 0 0 0 0 0 1 10 1 0}
catch {*createmark comps 1 all}
set allComps [hm_getmark comps 1]
catch {*createmark nodes 1 all}
set allNodes [hm_getmark nodes 1]
catch {*createmark elems 1 all}
set allElems [hm_getmark elems 1]
catch {*clearmark comps 1}
catch {*clearmark nodes 1}
catch {*clearmark elems 1}
P "MODEL_COMPS" [llength $allComps]
P "MODEL_NODES" [llength $allNodes]
P "MODEL_ELEMS" [llength $allElems]
TRY "POOLS_AFTER" {hm_getidpools nodes name}
set poolAfter {}
catch {set poolAfter [hm_getidpools nodes name]}
P "POOLS_AFTER_VALUE" [join $poolAfter { }]
set nodeSolver 0
if {[llength $poolAfter] > 0} {
    TRY "INTERNALID_1" {hm_getinternalid [lindex $poolAfter 0] 1 -bypoolname}
    catch {set nodeSolver [hm_getinternalid [lindex $poolAfter 0] 1 -bypoolname]}
    P "NODE1_SOLVERID" $nodeSolver
}
set compA [hm_getvalue comps name=AUDIT_IMPORT_A dataname=id]
set compB [hm_getvalue comps name=AUDIT_IMPORT_B dataname=id]
P "COMP_A" $compA
P "COMP_B" $compB

set base [file join $outputDir "audit_feimport_${version}"]

# ---------------------------------------------------------------- A: no marks, whole model, feoutputwithdata 1 1 0
set pathA "${base}_A_nomark.fem"
catch {hm_answernext yes}
TRY "A_EXPORT" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathA] 0 0 1 1 0}
exportCounts "A_NOMARK" $pathA

# ---------------------------------------------------------------- B: module-exact mark clobber (elems 1 then nodes 1), feoutput_select 1 0 0
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 "by component id" $compA
*createmark nodes 1 "by component id" $compA
set pathB "${base}_B_clobber.fem"
catch {hm_answernext yes}
TRY "B_EXPORT" {*feoutput_select $templatePath $pathB 1 0 0}
exportCounts "B_CLOBBER" $pathB
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# ---------------------------------------------------------------- C: batch_mesher recipe (mergeincludefiles + allsuppress + unsuppress + withdata mode 2)
TRY "MERGEINCLUDE" {*feoutputmergeincludefiles 1}
catch {*allsuppressoutput 1}
catch {*clearmark comps 1}
*createmark comps 1 "by name only" AUDIT_IMPORT_A
catch {*marksuppressoutput comps 1 0}
set pathC "${base}_C_suppress_mode2.fem"
catch {hm_answernext yes}
TRY "C_EXPORT" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathC] 0 0 2 1 0}
exportCounts "C_SUPPRESS_MODE2" $pathC
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark comps 1}

# ---------------------------------------------------------------- D: elems mark 1 + nodes mark 2, feoutput_select 1 1 0
catch {*clearmark elems 1}
catch {*clearmark nodes 2}
*createmark elems 1 "by component id" $compA
*createmark nodes 2 "by component id" $compA
set pathD "${base}_D_elems1_nodes2.fem"
catch {hm_answernext yes}
TRY "D_EXPORT" {*feoutput_select $templatePath $pathD 1 1 0}
exportCounts "D_ELEMS1_NODES2" $pathD
catch {*clearmark elems 1}
catch {*clearmark nodes 2}

# ---------------------------------------------------------------- E: elems mark 1 = comp B only, feoutput_select 1 0 0
catch {*clearmark elems 1}
*createmark elems 1 "by component id" $compB
set pathE "${base}_E_markB.fem"
catch {hm_answernext yes}
TRY "E_EXPORT" {*feoutput_select $templatePath $pathE 1 0 0}
exportCounts "E_MARKB" $pathE
catch {*clearmark elems 1}

# ---------------------------------------------------------------- F: batch_mesher EXACT recipe on imported model
# (elems mark 1 + allsuppressoutput + unsuppress comps + feoutputwithdata 0 0 2 1 0)
catch {*clearmark elems 1}
catch {*clearmark comps 1}
*createmark elems 1 all
catch {*allsuppressoutput 1}
*createmark comps 1 "by name only" AUDIT_IMPORT_A
catch {*marksuppressoutput comps 1 0}
set pathF "${base}_F_bmesher_recipe.fem"
catch {hm_answernext yes}
TRY "F_EXPORT" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathF] 0 0 2 1 0}
exportCounts "F_BMESHER_RECIPE" $pathF
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark elems 1}
catch {*clearmark comps 1}

# ---------------------------------------------------------------- G: solver id checks on imported model
TRY "GETSOLVERID_IMPORTED" {hm_getsolverid nodes 1 -byid}
TRY "GETSOLVERID_IMPORTED_ELEM" {hm_getsolverid elems 1 -byid}
TRY "POOLS_COMP" {hm_getidpools comps name}
TRY "POOLS_ELEM" {hm_getidpools elems name}
TRY "POOLS_MAT" {hm_getidpools mats name}
set poolComp {}
catch {set poolComp [hm_getidpools comps name]}
if {[llength $poolComp] > 0} {
    TRY "INTERNALID_IMPORTED" {hm_getinternalid [lindex $poolComp 0] 1 -bypoolname}
}

# ---------------------------------------------------------------- cleanup
foreach name {AUDIT_IMPORT_A AUDIT_IMPORT_B} {
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
