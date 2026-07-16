proc ::AutoHoleRBE2::runCore {} {
    variable stat
    catch {array unset stat}
    set stat(sourceElems) 0
    set stat(freeFaces) 0
    set stat(validFaces) 0
    set stat(segments) 0
    set stat(created) 0
    set stat(skippedExisting) 0
    set stat(failed) 0
    set run [::AutoHoleRBE2::runPythonRecognition]
    set payload [dict get $run payload]
    set summary [dict get $payload summary]
    set stat(validFaces) [dict get $summary exterior_face_count]
    set stat(segments) [dict get $summary segment_count]
    set result [::AutoHoleRBE2::executePythonCandidates $payload]
    set stat(failed) [dict get $result failed]
    ::HybridCore::closeLog
    return $result
}
