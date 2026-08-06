proc ::HybridCore::setProgressRange {start end message {detail ""}} {
    variable progressRangeStart; variable progressRangeEnd; variable progressMessage; variable progressDetail; variable progressLastUpdateMs
    set progressRangeStart [expr {double($start)}]; set progressRangeEnd [expr {double($end)}]
    set progressMessage $message; set progressDetail $detail; set progressLastUpdateMs 0
    ::HybridCore::progressUpdate $progressRangeStart $message $detail 1
}

proc ::HybridCore::progressUpdate {percent message detail {force 0}} {
    variable progressLastUpdateMs
    set now [clock milliseconds]
    if {!$force && ($now-$progressLastUpdateMs)<150} { return }
    set progressLastUpdateMs $now
    if {[llength [info commands ::HWFlow::progressUpdate]]>0} { catch {::HWFlow::progressUpdate $percent $message $detail $force} }
    if {$force} { catch {update idletasks} }
}

proc ::HybridCore::pulseProgress {elapsedSeconds {runtimeDetail ""}} {
    variable progressRangeStart; variable progressRangeEnd; variable progressMessage; variable progressDetail
    set fraction [expr {min(0.90, 1.0-exp(-double($elapsedSeconds)/3.0))}]
    set percent [expr {$progressRangeStart+($progressRangeEnd-$progressRangeStart)*$fraction}]
    set detail [expr {$runtimeDetail ne "" ? $runtimeDetail : $progressDetail}]
    if {$detail eq ""} {
        set detail [format "Python analysis running (%.1f s)" $elapsedSeconds]
    } else {
        append detail [format " | elapsed %.1f s" $elapsedSeconds]
    }
    ::HybridCore::progressUpdate $percent $progressMessage $detail 0
}

proc ::HybridCore::completeProgressRange {} {
    variable progressRangeEnd; variable progressMessage; variable progressDetail
    ::HybridCore::progressUpdate $progressRangeEnd $progressMessage $progressDetail 1
}
