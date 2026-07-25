proc ::RB2W::processComponents {compIds} {
    set compTotal [llength $compIds]
    if {$compTotal == 0} { return [list 0 0 0 0] }
    set analysisStart 5.0
    set analysisEnd 62.0
    set run [::RB2W::runPythonRecognition $compIds $analysisStart $analysisEnd]
    set result [::RB2W::executePythonCandidates \
        $compIds [dict get $run payload] $analysisEnd 95.0]
    ::RB2W::overallStatus 100.0 $compTotal $compTotal \
        "$compTotal components" 1 1 [lindex $result 2] \
        [lindex $result 0] [lindex $result 1] 1
    ::HybridCore::closeLog
    return $result
}
