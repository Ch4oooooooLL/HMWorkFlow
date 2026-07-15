proc ::AutoHoleRBE2::runCore {} {
    set run [::AutoHoleRBE2::runPythonRecognition]
    set result [::AutoHoleRBE2::executePythonCandidates [dict get $run payload]]
    ::HybridCore::closeLog
    return $result
}
