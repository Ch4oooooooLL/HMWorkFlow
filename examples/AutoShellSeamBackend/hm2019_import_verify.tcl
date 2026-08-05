# Import one generated offline result into HyperMesh 2019 hmbatch and verify
# that the solver reader creates nodes, elements, components and SEAM output.
#
# Required environment variables:
#   HMWF_OFFLINE_RESULT_FEM
#   HMWF_OFFLINE_VERIFY_REPORT

proc writeOfflineVerifyReport {path lines} {
    file mkdir [file dirname $path]
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel [join $lines "\n"]
    close $channel
}

set lines [list "status=STARTED" "pid=[pid]"]
set code [catch {
    foreach variable {HMWF_OFFLINE_RESULT_FEM HMWF_OFFLINE_VERIFY_REPORT} {
        if {![info exists ::env($variable)] || [string trim $::env($variable)] eq ""} {
            error "$variable is not set"
        }
    }
    set femPath [file normalize $::env(HMWF_OFFLINE_RESULT_FEM)]
    set reportPath [file normalize $::env(HMWF_OFFLINE_VERIFY_REPORT)]
    if {![file isfile $femPath] || [file size $femPath] == 0} { error "generated FEM is missing or empty: $femPath" }

    set template [file normalize [file join [file dirname [info nameofexecutable]] .. .. .. templates feoutput optistruct optistruct]]
    if {![file isfile $template]} { error "OptiStruct template is missing: $template" }
    catch {hm_answernext yes}
    *deletemodel
    *templatefileset [file nativename $template]
    *feinputwithdata2 "#optistruct/optistruct" [file nativename $femPath] 0 0 0 0 0 1 0 1 0

    *createmark nodes 1 all
    set nodeIds [hm_getmark nodes 1]
    *createmark elems 1 all
    set elementIds [hm_getmark elems 1]
    *createmark comps 1 all
    set componentIds [hm_getmark comps 1]
    if {[llength $nodeIds] == 0 || [llength $elementIds] == 0 || [llength $componentIds] == 0} {
        error "imported result is missing nodes, elements or components"
    }
    set seamComponents {}
    foreach componentId $componentIds {
        set name ""
        catch {set name [hm_getvalue comps id=$componentId dataname=name]}
        if {[string match -nocase "SEAM_*" $name]} { lappend seamComponents "$componentId:$name" }
    }
    if {[llength $seamComponents] == 0} { error "imported result contains no SEAM component" }

    lappend lines "hm_version=[string trim [hm_info -appinfo VERSION]]"
    lappend lines "fem_path=$femPath"
    lappend lines "fem_bytes=[file size $femPath]"
    lappend lines "nodes=[llength $nodeIds]"
    lappend lines "elements=[llength $elementIds]"
    lappend lines "components=[llength $componentIds]"
    lappend lines "seam_components=[join $seamComponents ,]"
    lappend lines "status=PASS"
    writeOfflineVerifyReport $reportPath $lines
} errorMessage errorOptions]

if {$code} {
    if {![info exists reportPath]} {
        set reportPath [file join [pwd] "hm2019_offline_backend_verify.txt"]
    }
    lappend lines "status=FAIL"
    lappend lines "error=$errorMessage"
    if {[dict exists $errorOptions -errorinfo]} {
        lappend lines "error_info=[string map {\n { | }} [dict get $errorOptions -errorinfo]]"
    }
    writeOfflineVerifyReport $reportPath $lines
    return -options $errorOptions $errorMessage
}
