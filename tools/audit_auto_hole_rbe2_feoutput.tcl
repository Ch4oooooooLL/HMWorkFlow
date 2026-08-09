# Matrix probe for HM FE-export semantics in hmbatch:
# which combination of marks / output suppression / display makes
# *feoutput_select / *feoutputwithdata actually serialize entities?
#
# Fixture: two small hexa8 blocks in two components (AUDIT_A, AUDIT_B).
# Run headless with the same hmbatch invocations as the first audit probe.
# Result: runtime/audit_auto_hole_rbe2_feoutput_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_feoutput_${version}.log"]
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
    P "${label}_CHEXA" [countInFile $path {CHEXA}]
    P "${label}_CQUAD4" [countInFile $path {CQUAD4}]
    P "${label}_CTRIA3" [countInFile $path {CTRIA3}]
}

P "VERSION" $version

namespace eval ::Audit {}
proc ::Audit::hexa8 {n1 n2 n3 n4 n5 n6 n7 n8} {
    catch {*clearmark nodes 1}
    eval *createlist nodes 1 [list $n1 $n2 $n3 $n4 $n5 $n6 $n7 $n8]
    *createelement 205 1 1 1
    catch {*clearmark nodes 1}
}

# two single-hexa components
foreach comp {AUDIT_A AUDIT_B} {
    catch {*createmark comps 2}
    *collectorcreateonly comps $comp "" 3
    *currentcollector comps $comp
    set base [expr {$comp eq "AUDIT_A" ? 0 : 50}]
    *createnode $base 0 0 0 0 0 0
    *createnode [expr {$base+10}] 0 0 0 0 0 0
    *createnode [expr {$base+10}] 10 0 0 0 0 0
    *createnode $base 10 0 0 0 0 0
    *createnode $base 0 10 0 0 0 0
    *createnode [expr {$base+10}] 0 10 0 0 0 0
    *createnode [expr {$base+10}] 10 10 0 0 0 0
    *createnode $base 10 10 0 0 0 0
    *createmark nodes 1 all
    set n [hm_getmark nodes 1]
    ::Audit::hexa8 [lindex $n end-7] [lindex $n end-6] [lindex $n end-5] [lindex $n end-4] \
        [lindex $n end-3] [lindex $n end-2] [lindex $n end-1] [lindex $n end]
    catch {*clearmark nodes 1}
}
set compA [hm_getvalue comps name=AUDIT_A dataname=id]
set compB [hm_getvalue comps name=AUDIT_B dataname=id]
P "COMP_A" $compA
P "COMP_B" $compB

set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
TRY "TEMPLATE_SET" {*templatefileset $templatePath}
P "TEMPLATE_NOW" [string trim [hm_info templatetype]]
set base [file join $outputDir "audit_feo_${version}"]

# G: display comp A via displaycollector, then export (feoutputwithdata, no marks)
TRY "DISPLAY_A" {*displaycollector comps on AUDIT_A 1 1}
TRY "REDRAW" {hm_redraw}
set pathG "${base}_G_displayed.fem"
catch {hm_answernext yes}
TRY "G_EXPORT" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathG] 0 0 1 1 0}
exportCounts "G_DISPLAYED" $pathG

# H: allsuppressoutput 1 + unsuppress comp A + export
catch {*allsuppressoutput 1}
catch {*clearmark comps 1}
*createmark comps 1 "by name only" AUDIT_A
catch {*marksuppressoutput comps 1 0}
set pathH "${base}_H_suppress.fem"
catch {hm_answernext yes}
TRY "H_EXPORT" {*feoutputwithdata [file nativename $templatePath] [file nativename $pathH] 0 0 1 1 0}
exportCounts "H_SUPPRESS" $pathH
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark comps 1}

# I: elems mark 1 = comp A only, export select 1 0 0 (no display, no suppress)
catch {*clearmark elems 1}
catch {*clearmark elems 2}
*createmark elems 2 "by comp id" $compA
set compAElems [hm_getmark elems 2]
P "COMP_A_ELEMS" $compAElems
catch {*clearmark elems 2}
eval *createmark elems 1 [lrange $compAElems 0 0]
set pathI "${base}_I_markA.fem"
catch {hm_answernext yes}
TRY "I_EXPORT" {*feoutput_select $templatePath $pathI 1 0 0}
exportCounts "I_MARKA" $pathI
catch {*clearmark elems 1}
catch {*clearmark elems 2}

# J: display A + elems mark 1 = comp A + export select 1 0 0
TRY "DISPLAY_A2" {*displaycollector comps on AUDIT_A 1 1}
catch {*clearmark elems 1}
catch {*clearmark elems 2}
*createmark elems 2 "by comp id" $compA
set compAElems [hm_getmark elems 2]
P "COMP_A_ELEMS" $compAElems
catch {*clearmark elems 2}
eval *createmark elems 1 [lrange $compAElems 0 0]
set pathJ "${base}_J_display_markA.fem"
catch {hm_answernext yes}
TRY "J_EXPORT" {*feoutput_select $templatePath $pathJ 1 0 0}
exportCounts "J_DISPLAY_MARKA" $pathJ
catch {*clearmark elems 1}
catch {*clearmark elems 2}

# K: display A + allsuppressoutput 1 + unsuppress A + export select 1 0 0
TRY "DISPLAY_A3" {*displaycollector comps on AUDIT_A 1 1}
catch {*allsuppressoutput 1}
catch {*clearmark comps 1}
*createmark comps 1 "by name only" AUDIT_A
catch {*marksuppressoutput comps 1 0}
set pathK "${base}_K_display_suppress.fem"
catch {hm_answernext yes}
TRY "K_EXPORT" {*feoutput_select $templatePath $pathK 1 0 0}
exportCounts "K_DISPLAY_SUPPRESS" $pathK
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark comps 1}

# L: elems mark 1 = comp A; module-exact mark overwrite with nodes mark 1; export 1 0 0
catch {*clearmark elems 1}
catch {*clearmark elems 2}
*createmark elems 2 "by comp id" $compA
set compAElems [hm_getmark elems 2]
P "COMP_A_ELEMS" $compAElems
catch {*clearmark elems 2}
eval *createmark elems 1 [lrange $compAElems 0 0]
catch {*clearmark nodes 2}
*createmark nodes 2 "by comp id" $compA
set compANodes [hm_getmark nodes 2]
catch {*clearmark nodes 1}
eval *createmark nodes 1 $compANodes
set pathL "${base}_L_clobber.fem"
catch {hm_answernext yes}
TRY "L_EXPORT" {*feoutput_select $templatePath $pathL 1 0 0}
exportCounts "L_CLOBBER" $pathL
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# M: elems mark 1 = comp A + nodes mark 2 = comp A nodes, export 1 1 0
catch {*clearmark elems 1}
catch {*clearmark elems 2}
*createmark elems 2 "by comp id" $compA
set compAElems [hm_getmark elems 2]
P "COMP_A_ELEMS" $compAElems
catch {*clearmark elems 2}
eval *createmark elems 1 [lrange $compAElems 0 0]
catch {*clearmark nodes 2}
*createmark nodes 2 "by comp id" $compA
P "COMP_A_NODES" [hm_getmark nodes 2]
set pathM "${base}_M_elems1_nodes2.fem"
catch {hm_answernext yes}
TRY "M_EXPORT" {*feoutput_select $templatePath $pathM 1 1 0}
exportCounts "M_ELEMS1_NODES2" $pathM
catch {*clearmark elems 1}
catch {*clearmark nodes 2}

# ---------------------------------------------------------------- cleanup
foreach name {AUDIT_A AUDIT_B} {
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
