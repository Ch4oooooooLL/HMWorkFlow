# Isolation probe: audit_contact_setup exported 22 GRID + 1 CHEXA in hmbatch
# from a hand-built model, while every auto_hole_rbe2 probe exported 0
# entities.  This probe reproduces the contact_setup recipe and varies one
# factor per variant to isolate the trigger.
#
#   V1: contact_setup EXACT (template first, quads 104 + hexa20 208)
#   V2: same fixture, but template set AFTER building
#   V3: hexa8 config 205 instead of 208 (template first)
#   V4: V3 + module mark sequence (elems 1 then nodes 1 by comp id) + mode 1
#   V5: V3 + module export command (feoutput_select 1 0 0)
#   V6: V3 + batch_mesher recipe (mode 2 + allsuppressoutput + unsuppress)
#
# Run headless with the same hmbatch invocations as the other audit probes.
# Result: runtime/audit_auto_hole_rbe2_feisolate_<version>.log

set root [file dirname [file dirname [file normalize [info script]]]]
set outputDir [file join $root runtime]
file mkdir $outputDir
set version [hm_info -appinfo VERSION]
set reportPath [file join $outputDir "audit_auto_hole_rbe2_feisolate_${version}.log"]
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
proc ::Audit::hex {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 208 1 1 1
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
    catch {*clearmark elems 2}
    catch {*clearmark comps 2}
    catch {*clearmark nodes 2}
}
proc ::Audit::buildFixture {hexProc} {
    *collectorcreateonly components AUDIT_SHELL "" 11
    *currentcollector component AUDIT_SHELL
    set elemA [::Audit::quad [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
        [::Audit::node 10 10 0] [::Audit::node 0 10 0]]]
    set elemB [::Audit::quad [list [::Audit::node 0 0 1] [::Audit::node 10 0 1] \
        [::Audit::node 10 10 1] [::Audit::node 0 10 1]]]
    *collectorcreateonly components AUDIT_SOLID "" 12
    *currentcollector component AUDIT_SOLID
    set hexE [$hexProc [list [::Audit::node 0 0 0] [::Audit::node 10 0 0] \
        [::Audit::node 10 10 0] [::Audit::node 0 10 0] \
        [::Audit::node 0 0 10] [::Audit::node 10 0 10] \
        [::Audit::node 10 10 10] [::Audit::node 0 10 10]]]
    set shellCompId [hm_getvalue comps name=AUDIT_SHELL dataname=id]
    set solidCompId [hm_getvalue comps name=AUDIT_SOLID dataname=id]
    P "ELEM_A" $elemA
    P "ELEM_B" $elemB
    P "ELEM_HEX" $hexE
    P "COMP_SHELL" $shellCompId
    P "COMP_SOLID" $solidCompId
}

set executableDir [hm_info -appinfo EXECUTABLEDIR]
set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
P "TEMPLATE_PATH_EXISTS" [expr {[file isfile $templatePath] ? "yes" : "no"}]
set base [file join $outputDir "audit_fei_${version}"]

# ---------------------------------------------------------------- V1: contact_setup EXACT
catch {*templatefileset $templatePath}
::Audit::buildFixture ::Audit::hex
set pathV1 "${base}_V1_template_first_208.fem"
if {[file exists $pathV1]} { file delete -force $pathV1 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathV1] 0 0 1 1 0} e1]} {
    P "V1_EXPORT" "ERROR: $e1"
} else {
    P "V1_EXPORT" "ok"
}
exportCounts "V1" $pathV1
::Audit::cleanup

# ---------------------------------------------------------------- V2: fixture first, template after
::Audit::buildFixture ::Audit::hex
catch {*templatefileset $templatePath}
set pathV2 "${base}_V2_template_after_208.fem"
if {[file exists $pathV2]} { file delete -force $pathV2 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathV2] 0 0 1 1 0} e2]} {
    P "V2_EXPORT" "ERROR: $e2"
} else {
    P "V2_EXPORT" "ok"
}
exportCounts "V2" $pathV2
::Audit::cleanup

# ---------------------------------------------------------------- V3: hexa8 205, template first
catch {*templatefileset $templatePath}
::Audit::buildFixture ::Audit::hex8
set pathV3 "${base}_V3_205_template_first.fem"
if {[file exists $pathV3]} { file delete -force $pathV3 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathV3] 0 0 1 1 0} e3]} {
    P "V3_EXPORT" "ERROR: $e3"
} else {
    P "V3_EXPORT" "ok"
}
exportCounts "V3" $pathV3
set solidCompId [hm_getvalue comps name=AUDIT_SOLID dataname=id]

# ---------------------------------------------------------------- V4: V3 + module mark sequence, mode 1
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 "by comp id" $solidCompId
*createmark nodes 1 "by comp id" $solidCompId
set pathV4 "${base}_V4_marks_mode1.fem"
if {[file exists $pathV4]} { file delete -force $pathV4 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathV4] 0 0 1 1 0} e4]} {
    P "V4_EXPORT" "ERROR: $e4"
} else {
    P "V4_EXPORT" "ok"
}
exportCounts "V4" $pathV4
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# ---------------------------------------------------------------- V5: module export command (feoutput_select 1 0 0)
catch {*clearmark elems 1}
catch {*clearmark nodes 1}
*createmark elems 1 "by comp id" $solidCompId
*createmark nodes 1 "by comp id" $solidCompId
set pathV5 "${base}_V5_feoutput_select.fem"
if {[file exists $pathV5]} { file delete -force $pathV5 }
catch {hm_answernext yes}
if {[catch {*feoutput_select $templatePath $pathV5 1 0 0} e5]} {
    P "V5_EXPORT" "ERROR: $e5"
} else {
    P "V5_EXPORT" "ok"
}
exportCounts "V5" $pathV5
catch {*clearmark elems 1}
catch {*clearmark nodes 1}

# ---------------------------------------------------------------- V6: batch_mesher recipe
catch {*clearmark elems 1}
catch {*clearmark comps 1}
*createmark elems 1 "by comp id" $solidCompId
catch {*allsuppressoutput 1}
*createmark comps 1 "by name only" AUDIT_SOLID
catch {*marksuppressoutput comps 1 0}
set pathV6 "${base}_V6_bmesher.fem"
if {[file exists $pathV6]} { file delete -force $pathV6 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathV6] 0 0 2 1 0} e6]} {
    P "V6_EXPORT" "ERROR: $e6"
} else {
    P "V6_EXPORT" "ok"
}
exportCounts "V6" $pathV6
catch {*marksuppressoutput comps 1 1}
catch {*allsuppressoutput 0}
catch {*clearmark elems 1}
catch {*clearmark comps 1}

# ---------------------------------------------------------------- V8: source module, fixture only, export
::Audit::cleanup
source [file join $root modules contact_setup.tcl]
::Audit::buildFixture ::Audit::hex8
set pathV8 "${base}_V8_module_sourced.fem"
if {[file exists $pathV8]} { file delete -force $pathV8 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathV8] 0 0 1 1 0} e8]} {
    P "V8_EXPORT" "ERROR: $e8"
} else {
    P "V8_EXPORT" "ok"
}
exportCounts "V8" $pathV8

# ---------------------------------------------------------------- V9: V8 + module contactsurfs + group
set shellCompId [hm_getvalue comps name=AUDIT_SHELL dataname=id]
catch {*clearmark elems 2}
*createmark elems 2 "by comp id" $shellCompId
set shellElems [hm_getmark elems 2]
catch {*clearmark elems 2}
set mainId [::ContactSetup::createContactSurf CLI_MAIN [lrange $shellElems 0 0] 13 [lindex $shellElems 0] 0]
set secondaryId [::ContactSetup::createContactSurf CLI_SECONDARY [lrange $shellElems 1 1] 14 [lindex $shellElems 1] 0]
set ::ContactSetup::ui(try_group) 1
set ::ContactSetup::ui(contact_type) STICK
set groupId [::ContactSetup::createGroup CLI_CONTACT $mainId $secondaryId]
P "V9_IDS" "$mainId $secondaryId $groupId"
set pathV9 "${base}_V9_contactsurfs.fem"
if {[file exists $pathV9]} { file delete -force $pathV9 }
catch {hm_answernext yes}
if {[catch {*feoutputwithdata [file nativename $templatePath] [file nativename $pathV9] 0 0 1 1 0} e9]} {
    P "V9_EXPORT" "ERROR: $e9"
} else {
    P "V9_EXPORT" "ok"
}
exportCounts "V9" $pathV9

# ---------------------------------------------------------------- cleanup
::Audit::cleanup

P "STATUS" "DONE"
close $channel
exit 0
