# HyperWorks 2022 read-only capability probe for hmbatch.exe.
#
# Run from a dedicated working directory:
#   hmbatch.exe -tcl C:/path/to/hm2022_capability_probe.tcl
#
# The result is written to hm2022_capability_<pid>.txt in the working directory.

set reportPath [file join [pwd] "hm2022_capability_[pid].txt"]

proc probeValue {label script} {
    if {[catch {uplevel 1 $script} value options]} {
        return "$label=ERROR:$value"
    }
    return "$label=$value"
}

set lines [list]
lappend lines "status=STARTED"
lappend lines "pid=[pid]"
lappend lines "working_directory=[pwd]"
lappend lines "tcl_patchlevel=[info patchlevel]"
lappend lines "executable=[info nameofexecutable]"
lappend lines [probeValue hm_version {string trim [hm_info -appinfo VERSION]}]

foreach command {
    *appendmark
    *batchmesh_mc
    *createmark
    *createstringarray
    *hm_batchmesh
    *hm_batchmesh2
    *readbatchparamsfile
    *readqualitycriteria
    hm_getmark
    hm_jobs_canSubmit
    hm_jobs_getJobStatus
    hm_jobs_setCurrentServer
    hm_jobs_submitBatchmeshJob
} {
    lappend lines "command.$command=[expr {[llength [info commands $command]] > 0 ? 1 : 0}]"
}

set attachedCode [catch {
    catch {*clearmark surfs 1}
    *createmark surfs 1
    *appendmark surfs 1 "by attached"
    catch {*clearmark surfs 1}
} attachedError attachedOptions]
lappend lines "blank_mark_by_attached=[expr {$attachedCode ? "FAIL" : "PASS"}]"
if {$attachedCode} {
    lappend lines "blank_mark_by_attached_error=$attachedError"
}

lappend lines "status=PASS"
set channel [open $reportPath w]
fconfigure $channel -encoding utf-8 -translation lf
puts $channel [join $lines "\n"]
close $channel
