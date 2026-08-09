# Audit probe: why does *feinputwithdata2 return error "0" in hmbatch?
# The module (delta_import.tcl:33/110) calls:
#   *feinputwithdata2 "#optistruct/optistruct" path 0 0 0 0 0 1 2 1 0
# which errors with message "0" (no detail).  Test several delta file
# variants and argument layouts to find what works in batch mode.
#
#   hmbatch.exe -nocommand -nouserprofiledialog -tcl tools/audit_mesh_seam_weld_feinput.tcl
#   Results: runtime/audit_mesh_seam_weld_feinput_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_mesh_seam_weld_feinput_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line

proc P {key value} {
    variable channel
    puts $channel "${key}=${value}"
}

P "status" "STARTED"
P "version" $version

namespace eval ::MSWE {}
proc ::MSWE::comp {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    return [hm_getvalue comps name=$name dataname=id]
}
proc ::MSWE::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 all
    return [lindex [hm_getmark nodes 1] end]
}
proc ::MSWE::nodeCount {} {
    catch {*createmark nodes 1 all}
    set s {}
    catch {set s [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    return [llength $s]
}
proc ::MSWE::elemCount {} {
    catch {*createmark elems 1 all}
    set s {}
    catch {set s [hm_getmark elems 1]}
    catch {*clearmark elems 1}
    return [llength $s]
}

set compA [::MSWE::comp MSWE_A 11]
foreach p {{0 0 0} {10 0 0} {10 10 0} {0 10 0}} {
    ::MSWE::node {*}$p
}
P "FIXTURE_NODES" [::MSWE::nodeCount]
P "FIXTURE_ELEMS" [::MSWE::elemCount]

# --- Delta FEM variants ------------------------------------------------
# V1: free-format GRID + CQUAD4 with MID=0 (as before)
# V2: fixed-format Nastran GRID + CQUAD4 with MID=1 and a MAT1 card
# V3: free-format but MID=1 + MAT1
set variants {}
lappend variants [list V1 {
BEGIN BULK
GRID 9101 0.0 0.0 0.0
GRID 9102 10.0 0.0 0.0
GRID 9103 10.0 10.0 0.0
GRID 9104 0.0 10.0 0.0
CQUAD4 9201 0 9101 9102 9103 9104
ENDDATA
}]
lappend variants [list V2 {
BEGIN BULK
GRID 9101 0. 0. 0.
GRID 9102 10. 0. 0.
GRID 9103 10. 10. 0.
GRID 9104 0. 10. 0.
MAT1 1 210000. 80000. 0.3
CQUAD4 9201 1 9101 9102 9103 9104
ENDDATA
}]
lappend variants [list V3 {
BEGIN BULK
GRID 9101 0.0 0.0 0.0
GRID 9102 10.0 0.0 0.0
GRID 9103 10.0 10.0 0.0
GRID 9104 0.0 10.0 0.0
MAT1 1 210000. 80000. 0.3
CQUAD4 9201 1 9101 9102 9103 9104
ENDDATA
}]
lappend variants [list V4 {
BEGIN BULK
GRID* 9101 0 0.0 0.0 0.0
GRID* 9102 0 10.0 0.0 0.0
GRID* 9103 0 10.0 10.0 0.0
GRID* 9104 0 0.0 10.0 0.0
MAT1 1 210000. 80000. 0.3
CQUAD4 9201 1 9101 9102 9103 9104
ENDDATA
}]

set saOk 0
catch {*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "}
set saOk 1
P "CREATESTRINGARRAY" $saOk

foreach item $variants {
    set tag [lindex $item 0]
    set body [lindex $item 1]
    set deltaPath [file join $outputDir "audit_mesh_seam_weld_delta_${version}_${tag}.fem"]
    set chan [open $deltaPath w]
    puts $chan $body
    close $chan
    P "${tag}_FILE" $deltaPath
    set before [::MSWE::nodeCount]
    set beforeE [::MSWE::elemCount]
    if {[catch {*feinputwithdata2 "#optistruct/optistruct" $deltaPath 0 0 0 0 0 1 2 1 0} feErr opts]} {
        P "${tag}_ERROR" $feErr
        set ei [dict get $opts -errorinfo]
        P "${tag}_ERRORINFO" [string range $ei 0 300]
        P "${tag}_ERRCODE" [dict get $opts -errorcode]
    } else {
        P "${tag}_OK" 1
        P "${tag}_NODES_DELTA" [expr {[::MSWE::nodeCount] - $before}]
        P "${tag}_ELEMS_DELTA" [expr {[::MSWE::elemCount] - $beforeE}]
        catch {*createmark nodes 1 "by id" 9101}
        P "${tag}_N9101_PRESENT" [expr {[llength [hm_getmark nodes 1]] > 0}]
        catch {*clearmark nodes 1}
        catch {*createmark elems 1 "by id" 9201}
        P "${tag}_E9201_PRESENT" [expr {[llength [hm_getmark elems 1]] > 0}]
        catch {*clearmark elems 1}
    }
}

# --- Argument-layout variants on the V2 file (best candidate) -----------
set deltaPath [file join $outputDir "audit_mesh_seam_weld_delta_${version}_V2.fem"]
set argVariants {
    {"A11" {0 0 0 0 0 1 2 1 0}}
    {"A12" {0 0 0 0 0 1 2 1 0 0}}
    {"A13" {0 0 0 0 0 0 2 1 0}}
    {"A10" {0 0 0 0 0 1 2 1}}
}
foreach item $argVariants {
    set tag [lindex $item 0]
    set extra [lindex $item 1]
    set before [::MSWE::nodeCount]
    set cmd [list *feinputwithdata2 "#optistruct/optistruct" $deltaPath]
    foreach a $extra { lappend cmd $a }
    if {[catch {uplevel #0 $cmd} feErr]} {
        P "ARG${tag}_ERROR" $feErr
    } else {
        P "ARG${tag}_OK" 1
        P "ARG${tag}_NODES_DELTA" [expr {[::MSWE::nodeCount] - $before}]
    }
}

# --- Same file via plain *feinput (no options) --------------------------
set before [::MSWE::nodeCount]
if {[catch {*feinput "#optistruct/optistruct" $deltaPath} feErr]} {
    P "PLAIN_FEINPUT_ERROR" $feErr
} else {
    P "PLAIN_FEINPUT_OK" 1
    P "PLAIN_FEINPUT_NODES_DELTA" [expr {[::MSWE::nodeCount] - $before}]
}

P "status" "DONE"
close $channel
exit 0
