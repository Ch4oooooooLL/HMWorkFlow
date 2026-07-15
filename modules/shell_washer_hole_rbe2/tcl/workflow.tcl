proc ::RB2W::processComponent {compId {compIndex 1} {compTotal 1}} {
    set base [expr {100.0*($compIndex-1)/double($compTotal)}]
    set span [expr {100.0/double($compTotal)}]
    set analysisStart [expr {$base+0.05*$span}]
    set analysisEnd [expr {$base+0.62*$span}]
    set run [::RB2W::runPythonRecognition $compId $analysisStart $analysisEnd]
    set result [::RB2W::executePythonCandidates \
        $compId [dict get $run payload] $analysisEnd [expr {$base+0.95*$span}]]
    ::RB2W::overallStatus [expr {$base+$span}] $compIndex $compTotal \
        [::RB2W::getComponentName $compId] 1 1 [lindex $result 2] \
        [lindex $result 0] [lindex $result 1] 1
    ::HybridCore::closeLog
    return $result
}
