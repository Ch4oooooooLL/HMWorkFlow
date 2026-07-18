# HyperMesh 2019 batch smoke test for solver-backed contact surfaces.
#
# Run with:
#   hmbatch.exe -tcl hm2019_contact_surface_smoke.tcl

set root [file dirname [file dirname [file dirname [file dirname [file normalize [info script]]]]]]
set outputDir [file join $root runtime tasks contact_setup cli_smoke]
file mkdir $outputDir
set reportPath [file join $outputDir hm2019_contact_surface_smoke.txt]
set deckPath [file join $outputDir hm2019_contact_surface_smoke.fem]

proc writeReport {path status details} {
    set channel [open $path w]
    puts $channel "status=$status"
    puts $channel $details
    close $channel
}

proc createNode {x y z} {
    *createnode $x $y $z 0 0 0
    return [hm_latestentityid nodes]
}

proc createQuad {nodeIds} {
    eval *createlist nodes 1 $nodeIds
    *createelement 104 1 1 1
    return [hm_latestentityid elems]
}

proc runContactSurfaceSmoke {root deckPath} {
    if {[file exists $deckPath]} {
        file delete -force $deckPath
    }
    set executableDir [hm_info -appinfo EXECUTABLEDIR]
    set templatePath [file normalize [file join $executableDir .. .. .. templates feoutput optistruct optistruct]]
    if {![file isfile $templatePath]} {
        error "OptiStruct output template not found: $templatePath"
    }
    *templatefileset $templatePath

    source [file join $root modules contact_setup.tcl]

    *collectorcreateonly components CONTACT_SMOKE_SHELL "" 11
    *currentcollector component CONTACT_SMOKE_SHELL

    set a1 [createNode 0.0 0.0 0.0]
    set a2 [createNode 10.0 0.0 0.0]
    set a3 [createNode 10.0 10.0 0.0]
    set a4 [createNode 0.0 10.0 0.0]
    set b1 [createNode 0.0 0.0 1.0]
    set b2 [createNode 0.0 10.0 1.0]
    set b3 [createNode 10.0 10.0 1.0]
    set b4 [createNode 10.0 0.0 1.0]
    set elemA [createQuad [list $a1 $a2 $a3 $a4]]
    set elemB [createQuad [list $b1 $b2 $b3 $b4]]

    set mainId [::ContactSetup::createContactSurf CLI_MAIN [list $elemA] 13 $elemA 0]
    set secondaryId [::ContactSetup::createContactSurf CLI_SECONDARY [list $elemB] 14 $elemB 0]

    set mainCard [hm_getvalue contactsurfs id=$mainId dataname=cardimage]
    set secondaryCard [hm_getvalue contactsurfs id=$secondaryId dataname=cardimage]
    set mainElems [hm_getvalue contactsurfs id=$mainId dataname=elements]
    set secondaryElems [hm_getvalue contactsurfs id=$secondaryId dataname=elements]
    if {![string equal -nocase $mainCard SURF] || ![string equal -nocase $secondaryCard SURF]} {
        error "Expected SURF card images, got main=$mainCard secondary=$secondaryCard"
    }
    if {[lsearch -exact $mainElems $elemA] < 0 || [lsearch -exact $secondaryElems $elemB] < 0} {
        error "Contact surfaces do not reference the expected shell elements"
    }

    set ::ContactSetup::ui(try_group) 1
    set ::ContactSetup::ui(contact_type) STICK
    set groupId [::ContactSetup::createGroup CLI_CONTACT $mainId $secondaryId]

    *feoutputwithdata $templatePath $deckPath 0 0 1 1 0
    if {![file isfile $deckPath] || [file size $deckPath] == 0} {
        error "OptiStruct export was not created: $deckPath"
    }

    set channel [open $deckPath r]
    set deck [read $channel]
    close $channel
    if {![regexp -line {^[ \t]*SURF[ \t,]} $deck]} {
        error "Exported OptiStruct deck contains no SURF card"
    }
    if {![regexp -line {^[ \t]*CONTACT[ \t,]} $deck]} {
        error "Exported OptiStruct deck contains no CONTACT card"
    }
    if {![regexp -line {^[ \t]*CONTACT[ \t]+[0-9]+[ \t]+STICK([ \t]|$)} $deck]} {
        error "Exported OptiStruct CONTACT card does not preserve requested type STICK"
    }

    return "main_surface_id=$mainId secondary_surface_id=$secondaryId group_id=$groupId\nmain_element=$elemA secondary_element=$elemB\ndeck=$deckPath"
}

set code [catch {runContactSurfaceSmoke $root $deckPath} details options]
if {$code != 0} {
    writeReport $reportPath FAIL $details
    return -options $options $details
}
writeReport $reportPath PASS $details
