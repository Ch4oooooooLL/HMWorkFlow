proc ::AutoHoleRBE2::runCore {} {
    variable cfg; variable stat
    catch {array unset stat}
    set stat(sourceElems) 0
    set stat(freeFaces) 0
    set stat(validFaces) 0
    set stat(segments) 0
    set stat(created) 0
    set stat(skippedExisting) 0
    set stat(failed) 0
    set stat(candidates) 0
    set stat(adaptiveCandidates) 0
    set stat(rejectReasons) ""
    set stat(taskDir) ""
    set run [::AutoHoleRBE2::runPythonRecognition]
    set stat(taskDir) [dict get $run task_dir]
    set payload [dict get $run payload]
    set summary [dict get $payload summary]
    set stat(validFaces) [dict get $summary exterior_face_count]
    set stat(segments) [dict get $summary segment_count]
    set stat(candidates) [dict get $summary candidate_count]
    if {[dict exists $summary adaptive_candidate_count]} {
        set stat(adaptiveCandidates) [dict get $summary adaptive_candidate_count]
    }
    if {[dict exists $summary reject_reason_counts]} {
        set stat(rejectReasons) [dict get $summary reject_reason_counts]
    }
    ::AutoHoleRBE2::log INFO "Detection summary: candidates=$stat(candidates), adaptive=$stat(adaptiveCandidates), rejected={[set stat(rejectReasons)]}, task=$stat(taskDir)"
    if {$stat(candidates) == 0} {
        ::AutoHoleRBE2::warning [::HWFlow::txt \
            "未识别到可创建孔。拒绝原因：$stat(rejectReasons)；诊断目录：$stat(taskDir)" \
            "No creatable holes were recognized. Rejection reasons: $stat(rejectReasons); diagnostics: $stat(taskDir)"]
    }
    set result [::AutoHoleRBE2::executePythonCandidates $payload]
    ::AutoHoleRBE2::deleteComponentByName $cfg(faceCompName)
    ::AutoHoleRBE2::clearMarks
    set stat(failed) [dict get $result failed]
    ::HybridCore::closeLog
    return $result
}
