proc ::WeldIntegrityCheck::txt {zh en} { return [::HWFlow::txt $zh $en] }
proc ::WeldIntegrityCheck::ctxt {zh en} { return [::HWFlow::ctxt $zh $en] }

proc ::WeldIntegrityCheck::log {level message} {
    variable logChannel
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] $level $message"
    catch {puts $line}
    if {$logChannel ne ""} { catch {puts $logChannel $line; flush $logChannel} }
    catch {::HybridCore::log $level "weld_integrity_check $message"}
}

proc ::WeldIntegrityCheck::openLog {} {
    variable ROOT_DIR; variable logChannel; variable logPath
    catch {close $logChannel}; set logChannel ""
    set logPath [file join $ROOT_DIR logs weld_integrity_check.log]
    file mkdir [file dirname $logPath]
    set logChannel [open $logPath a]
    fconfigure $logChannel -encoding utf-8 -translation lf
    ::WeldIntegrityCheck::log INFO "module started version=$::WeldIntegrityCheck::VERSION"
}

proc ::WeldIntegrityCheck::closeLog {} {
    variable logChannel
    catch {close $logChannel}; set logChannel ""
}

proc ::WeldIntegrityCheck::captureDisplay {} {
    variable originalVisibleCompIds; variable displayCaptured
    set originalVisibleCompIds [::WeldIntegrityCheck::displayedComponents]
    set displayCaptured 1
    ::WeldIntegrityCheck::log INFO "display captured visible_components=[llength $originalVisibleCompIds]"
}

proc ::WeldIntegrityCheck::loadConfig {} {
    if {[llength [info commands ::HWFlow::applyStateToArray]] > 0} {
        ::HWFlow::applyStateToArray weld_integrity_check ::WeldIntegrityCheck::cfg
    }
}

proc ::WeldIntegrityCheck::saveConfig {} {
    if {[llength [info commands ::HWFlow::saveArrayState]] > 0} {
        ::HWFlow::saveArrayState weld_integrity_check ::WeldIntegrityCheck::cfg
    }
}

proc ::WeldIntegrityCheck::runAction {} {
    ::WeldIntegrityCheck::openLog
    ::WeldIntegrityCheck::loadConfig
    ::WeldIntegrityCheck::captureDisplay
    set configResult [::WeldIntegrityCheck::showConfig 0]
    if {$configResult == 2} {
        ::WeldIntegrityCheck::showReview
        return
    }
    if {!$configResult} {
        ::WeldIntegrityCheck::closeLog
        return
    }
    if {[catch {::WeldIntegrityCheck::runDetection} err opts]} {
        catch {::HWFlow::progressClose}
        ::WeldIntegrityCheck::log ERROR "detection failed error=$err"
        set detail ""
        if {[dict exists $opts -errorinfo]} { set detail [dict get $opts -errorinfo] }
        tk_messageBox -icon error -title [::WeldIntegrityCheck::txt "网格焊缝完整性检查" "Weld Integrity Check"] \
            -message [::WeldIntegrityCheck::txt "检测失败：\n$err\n\n请查看日志：\n$::WeldIntegrityCheck::logPath" "Detection failed:\n$err\n\nSee log:\n$::WeldIntegrityCheck::logPath"]
        ::WeldIntegrityCheck::log ERROR $detail
        ::WeldIntegrityCheck::restoreDisplay
        ::WeldIntegrityCheck::closeLog
    }
}

proc ::WeldIntegrityCheck::runSettings {} {
    ::WeldIntegrityCheck::loadConfig
    ::WeldIntegrityCheck::showConfig 1
}

proc ::WeldIntegrityCheck::runDetection {} {
    variable ui; variable taskDir; variable taskId; variable resultData; variable pairRows; variable pairStates; variable currentPairId
    set selected {}
    foreach compId $ui(selectedCompIds) {
        if {[lsearch -exact $ui(excludedCompIds) $compId] < 0} { lappend selected $compId }
    }
    set selected [lsort -integer -unique $selected]
    if {[llength $selected] < 2} { error [::WeldIntegrityCheck::txt "排除后至少需要两个 Component。" "At least two components are required after exclusions."] }
    set workspace [::HybridCore::createTaskWorkspace weld_integrity_check]
    set taskDir [dict get $workspace task_dir]; set taskId [dict get $workspace run_id]
    foreach child {input output state} { file mkdir [file join $taskDir $child] }
    ::HWFlow::progressOpen [::WeldIntegrityCheck::ctxt "网格焊缝完整性检查" "Weld Integrity Check"] [::WeldIntegrityCheck::ctxt "正在读取组件信息" "Reading components"] 0
    ::HWFlow::progressUpdate 8 [::WeldIntegrityCheck::ctxt "正在读取组件信息" "Reading components"]
    set exported [::WeldIntegrityCheck::exportInput $selected]
    ::HWFlow::progressUpdate 48 [::WeldIntegrityCheck::ctxt "正在启动 Python 检测" "Starting Python detection"]
    set inputDir [file join $taskDir input]
    set outputPath [file join $taskDir output result.json]
    set tclPath [file join $taskDir output result.tcl]
    set pythonLog [file join $taskDir output python_log.txt]
    set entry [file join $::WeldIntegrityCheck::MODULE_DIR python main.py]
    set arguments [list --input $inputDir --output $outputPath --tcl-output $tclPath --log $pythonLog]
    ::WeldIntegrityCheck::log INFO "python command entry=$entry task=$taskDir"
    if {[catch {::HybridCore::runPythonEntry $entry $arguments $taskDir} processResult processOpts]} {
        set stderrPath [file join $taskDir python_stderr.log]
        set exitCode unknown
        if {[dict exists $processOpts -errorcode]} {
            set errorCode [dict get $processOpts -errorcode]
            if {[lindex $errorCode 0] eq "CHILDSTATUS" && [llength $errorCode] >= 3} { set exitCode [lindex $errorCode 2] }
            if {[lrange $errorCode 0 2] eq {HYBRID WORKER TASK} && [llength $errorCode] >= 4} { set exitCode [lindex $errorCode 3] }
        }
        error [::WeldIntegrityCheck::txt "Python 返回失败（返回码：$exitCode）：$processResult；日志：$pythonLog；stderr：$stderrPath" "Python failed (exit code: $exitCode): $processResult; log: $pythonLog; stderr: $stderrPath"]
    }
    ::HWFlow::progressUpdate 88 [::WeldIntegrityCheck::ctxt "正在加载结果" "Loading result"]
    if {![file isfile $outputPath] || ![file isfile $tclPath]} {
        error [::WeldIntegrityCheck::txt "检测程序未生成有效结果文件，请查看 Python 日志：$pythonLog" "No valid result was generated. See Python log: $pythonLog"]
    }
    set resultData [::HybridCore::loadDataSidecar $tclPath ::WeldIntegrityCheck::pythonResult "# WELD_INTEGRITY_RESULT_V1"]
    if {![dict exists $resultData success] || ![dict get $resultData success]} {
        set failureMessage "Invalid Python result"
        if {[dict exists $resultData message]} { set failureMessage [dict get $resultData message] }
        error $failureMessage
    }
    set pairRows [dict get $resultData pairs]
    array unset pairStates
    foreach pair $pairRows { set pairStates([dict get $pair pair_id]) pending }
    set currentPairId [expr {[llength $pairRows] ? [dict get [lindex $pairRows 0] pair_id] : ""}]
    ::WeldIntegrityCheck::saveReviewState
    ::HWFlow::progressFinish [::WeldIntegrityCheck::ctxt "检测完成" "Detection complete"] 100
    ::WeldIntegrityCheck::log INFO "detection complete selected=[llength $selected] excluded=[llength $ui(excludedCompIds)] pairs=[llength $pairRows] input=$inputDir"
    if {[llength $pairRows] == 0} {
        tk_messageBox -icon info -title [::WeldIntegrityCheck::txt "网格焊缝完整性检查" "Weld Integrity Check"] \
            -message [::WeldIntegrityCheck::txt "检测完成，未发现满足当前参数的候选 Component Pair。" "Detection completed; no candidate component pairs met the settings."]
        ::WeldIntegrityCheck::closeLog
        return
    }
    ::WeldIntegrityCheck::showReview
}

proc ::WeldIntegrityCheck::OpenWeldCreator {pairData} {
    if {![namespace exists ::MeshSeamWeld]} {
        set modulePath [file join [file dirname $::WeldIntegrityCheck::MODULE_DIR] mesh_seam_weld.tcl]
        if {[file isfile $modulePath]} { ::HWFlow::sourceUtf8 $modulePath }
    }
    if {[llength [info commands ::MeshSeamWeld::openAutoCandidate]] == 0} { error [::WeldIntegrityCheck::txt "无法加载自动壳焊缝创建器。" "Could not load the automatic shell seam creator."] }
    ::MeshSeamWeld::openAutoCandidate $pairData
}
