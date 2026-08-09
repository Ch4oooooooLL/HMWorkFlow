set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_feinput_roundtrip_${version}.log"]
set channel [open $reportPath w]
fconfigure $channel -buffering line
proc P {key value} { variable channel; puts $channel "${key}=${value}" }
P "status" "STARTED"
P "version" $version
namespace eval ::FRT {}
proc ::FRT::comp {name color} {
    *collectorcreateonly components $name "" $color
    *currentcollector component $name
    return [hm_getvalue comps name=$name dataname=id]
}
proc ::FRT::node {x y z} {
    *createnode $x $y $z 0 0 0
    *createmark nodes 1 all
    return [lindex [hm_getmark nodes 1] end]
}
proc ::FRT::quad {n1 n2 n3 n4} {
    eval *createlist nodes 1 $n1 $n2 $n3 $n4
    *createelement 104 1 1 1
    *createmark elems 1 all
    return [lindex [hm_getmark elems 1] end]
}
proc ::FRT::nodeCount {} {
    catch {*createmark nodes 1 all}
    set s {}
    catch {set s [hm_getmark nodes 1]}
    catch {*clearmark nodes 1}
    return [llength $s]
}
proc ::FRT::elemCount {} {
    catch {*createmark elems 1 all}
    set s {}
    catch {set s [hm_getmark elems 1]}
    catch {*clearmark elems 1}
    return [llength $s]
}

set compA [::FRT::comp FRT_A 11]
set n1 [::FRT::node 0 0 0]
set n2 [::FRT::node 10 0 0]
set n3 [::FRT::node 10 10 0]
set n4 [::FRT::node 0 10 0]
set e1 [::FRT::quad $n1 $n2 $n3 $n4]
P "FIXTURE_NODES" [::FRT::nodeCount]
P "FIXTURE_ELEMS" [::FRT::elemCount]

# Step 1: module-exact export (exporter.tcl uses *feoutput_select)
set templatePath [file normalize [file join \
    [hm_info -appinfo EXECUTABLEDIR] .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_ISFILE" [file isfile $templatePath]
set outFem [file join $outputDir "audit_feinput_roundtrip_export_${version}.fem"]
catch {file delete -force $outFem}
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 all
set allElemIds [hm_getmark elems 1]
eval *createmark nodes 1 [list "by elems"] $allElemIds
if {[catch {*feoutput_select $templatePath $outFem 1 0 0} feErr]} {
    P "EXPORT_ERROR" $feErr
} else {
    P "EXPORT_OK" 1
    P "EXPORT_SIZE" [file size $outFem]
}

# Step 2: module-exact import (delta_import.tcl uses *feinputwithdata2)
set before [::FRT::nodeCount]
set beforeE [::FRT::elemCount]
catch {hm_answernext yes}
catch {*createstringarray 2 "ASSIGNPROP_BYHMCOMMENTS " "ASSIGNPROP_ONELEMS "}
if {[catch {*feinputwithdata2 "#optistruct/optistruct" $outFem 0 0 0 0 0 1 2 1 0} feErr]} {
    P "IMPORT_ERROR" $feErr
} else {
    P "IMPORT_OK" 1
    P "IMPORT_NODES_DELTA" [expr {[::FRT::nodeCount] - $before}]
    P "IMPORT_ELEMS_DELTA" [expr {[::FRT::elemCount] - $beforeE}]
    catch {*createmark nodes 1 "by id" $n1}
    P "IMPORT_OLD_NODE_STILL_PRESENT" [expr {[llength [hm_getmark nodes 1]] > 0}]
    catch {*clearmark nodes 1}
    catch {*createmark elems 1 all}
    set ids [hm_getmark elems 1]
    P "IMPORT_ALL_ELEM_IDS" [join $ids { }]
    catch {*clearmark elems 1}
}
P "status" "DONE"
close $channel
exit 0
