# Isolation probe round 2: audit_contact_setup smoke test exports GRID+SURF
# cards in hmbatch 2019 from a hand-built model, but every auto_hole_rbe2
# probe exports 0 entities.  Round 1 showed template timing (V2), element
# config 205 vs 208 (V3), module source (V8) and contactsurfs+group (V9) are
# NOT the trigger.  Round 2 runs the smoke-exact sequence FIRST in the fresh
# session (V10, positive control), then tests findfaces/movemark (V11/V12)
# and a quads-only variant (V13).
#
# Run headless with the same hmbatch invocations as the other audit probes.
# Result: runtime/audit_auto_hole_rbe2_feisolate2_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_feisolate2_${version}.log"]
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
}
proc doExport {label path} {
    if {[file exists $path]} { file delete -force $path }
    if {[catch {*feoutputwithdata [file nativename $::templatePath] [file nativename $path] 0 0 1 1 0} e]} {
        P "${label}_EXPORT" "ERROR: $e"
    } else {
        P "${label}_EXPORT" "ok"
    }
    exportCounts $label $path
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
proc ::Audit::hex8 {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 205 1 1 1
    return [hm_latestentityid elems]
}
proc ::Audit::cleanup {} {
    catch {*createmark elems 2 all}
    catch {*deletemark elems 2}
    catch {*createmark comps 2 all}
    catch {*deletemark comps 2}
    catch {*createmark contactsurfs 2 all}
    catch {*deletemark contactsurfs 2}
    catch {*clearmark elems 2}
    catch {*clearmark comps 2}
    catch {*clearmark nodes 2}
}
proc ::Audit::quadsOnlyFixture {} {
    *collectorcreateonly components AUDIT_SHELL "" 11
    *currentcollector component AUDIT_SHELL
    set elemA [::Audit::quad [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
        [::Audit::node 10 10 0] [::Audit::node 0 10 0]]]
    set elemB [::Audit::quad [list [::Audit::node 0 0 1] [::Audit::node 10 0 1] \
        [::Audit::node 10 10 1] [::Audit::node 0 10 1]]]
    P "ELEM_A" $elemA
    P "ELEM_B" $elemB
    return [list $elemA $elemB]
}
proc ::Audit::fullFixture {} {
    ::Audit::quadsOnlyFixture
    *collectorcreateonly components AUDIT_SOLID "" 12
    *currentcollector component AUDIT_SOLID
    set hexE [::Audit::hex8 [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
        [::Audit::node 10 10 0] [::Audit::node 0 10 0] \
        [::Audit::node 0 0 10] [::Audit::node 10 0 10] \
        [::Audit::node 10 10 10] [::Audit::node 0 10 10]]]
    P "ELEM_HEX" $hexE
}

set executableDir [hm_info -appinfo EXECUTABLEDIR]
set ::templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_PATH_EXISTS" [expr {[file isfile $::templatePath] ? "yes" : "no"}]
catch {*templatefileset $::templatePath}
set base [file join $outputDir "audit_fei2_${version}"]

# ---------------------------------------------------------------- V10: smoke-exact, fresh session, no hm_answernext
source [file join $root modules contact_setup.tcl]
lassign [::Audit::quadsOnlyFixture] elemA elemB
set mainId [::ContactSetup::createContactSurf CLI_MAIN [list $elemA] 13 $elemA 0]
set secId [::ContactSetup::createContactSurf CLI_SECONDARY [list $elemB] 14 $elemB 0]
set ::ContactSetup::ui(try_group) 1
set ::ContactSetup::ui(contact_type) STICK
set groupId [::ContactSetup::createGroup CLI_CONTACT $mainId $secId]
P "V10_IDS" "$mainId $secId $groupId"
doExport V10 [file join $outputDir "audit_fei2_${version}_V10_smoke_exact.fem"]

# ---------------------------------------------------------------- V11: V10 fixture + findfaces on shell comp
set shellCompId [hm_getvalue comps name=AUDIT_SHELL dataname=id]
catch {*clearmark comps 1}
eval *createmark comps 1 [list $shellCompId]
catch {*findfaces components 1}
set facesId ""
catch {set facesId [hm_entityinfo id comps ^faces -byname]}
P "V11_FACES_COMP" $facesId
doExport V11 [file join $outputDir "audit_fei2_${version}_V11_findfaces.fem"]
::Audit::cleanup

# ---------------------------------------------------------------- V12: quads + hexa8 + findfaces + movemark
::Audit::fullFixture
set solidCompId [hm_getvalue comps name=AUDIT_SOLID dataname=id]
catch {*clearmark comps 1}
eval *createmark comps 1 [list $solidCompId]
catch {*findfaces components 1}
catch {*clearmark elems 2}
catch {*createmark elems 2 "by comp id" [hm_getvalue comps name=^faces dataname=id]}
catch {*collectorcreateonly components AUDIT_FACES_TMP "" 35}
catch {*movemark elems 2 AUDIT_FACES_TMP}
doExport V12 [file join $outputDir "audit_fei2_${version}_V12_findfaces_movemark.fem"]
::Audit::cleanup

# ---------------------------------------------------------------- V13: hexa8 only (no quads), no contactsurfs
*collectorcreateonly components AUDIT_SOLID "" 12
*currentcollector component AUDIT_SOLID
set hexE [::Audit::hex8 [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
    [::Audit::node 10 10 0] [::Audit::node 0 10 0] \
    [::Audit::node 0 0 10] [::Audit::node 10 0 10] \
    [::Audit::node 10 10 10] [::Audit::node 0 10 10]]]
P "V13_HEX" $hexE
doExport V13 [file join $outputDir "audit_fei2_${version}_V13_hexa8_only.fem"]
::Audit::cleanup

P "STATUS" "DONE"
close $channel
exit 0
