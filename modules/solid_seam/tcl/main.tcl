proc ::SolidSeam::runDetection {} {
    variable ui; variable candidateRows; variable mode; variable detectedMode; variable requiresReview; variable runtimeDir
    if {[catch {
        ::SolidSeam::validateSettings
        ::SolidSeam::saveState
        set ui(status) [::SolidSeam::txt "正在选择组件..." "Selecting components..."]; update idletasks
        set componentIds [::SolidSeam::selectComponents]
        if {[llength $componentIds] == 0} { error "__SOLID_SEAM_CANCEL__" }
        ::SolidSeam::newRun
        set ui(status) [::SolidSeam::txt "正在导出所选 Components 为 FEM..." "Exporting selected components to FEM..."]; update idletasks
        set meshPath [::SolidSeam::exportSelectedFem]
        set requestPath [::SolidSeam::writeRequest]
        set ui(status) [::SolidSeam::txt "Python 正在识别候选焊缝..." "Python is detecting seam candidates..."]; update idletasks
        ::SolidSeam::runPythonDetection $requestPath $meshPath
        set mode $detectedMode
        set ui(status) [::SolidSeam::txt "识别完成：模式 $mode；候选 [llength $candidateRows] 条。运行目录：$runtimeDir" "Detection complete: mode $mode; [llength $candidateRows] candidates. Run directory: $runtimeDir"]
        if {$requiresReview} {
            if {$ui(auto_accept_high)} { ::SolidSeam::acceptHighConfidence }
            ::SolidSeam::showCandidateWindow
        } else {
            if {[llength $candidateRows] == 0} { error [::SolidSeam::txt "未识别到可创建的焊缝位置。" "No weld location was detected."] }
            ::SolidSeam::acceptAllCandidates
            ::SolidSeam::createAcceptedCandidates
        }
    } err opts]} {
        if {$err eq "__SOLID_SEAM_CANCEL__"} {
            set ui(status) [::SolidSeam::txt "用户取消选择。" "Selection cancelled."]
            return 0
        }
        set ui(status) [::SolidSeam::txt "执行失败：$err" "Execution failed: $err"]
        ::SolidSeam::log ERROR $err
        if {$runtimeDir ne ""} {catch {::HybridCore::finalizeTaskWorkspace $runtimeDir FAILED}}
        ::SolidSeam::message error $ui(status)
        # The failure has already been presented to the user. Do not rethrow
        # into the Tk shortcut callback, which would display the same error a
        # second time together with an internal stack trace.
        return 0
    }
    if {$runtimeDir ne ""} {catch {::HybridCore::finalizeTaskWorkspace $runtimeDir SUCCESS}}
    return 1
}

proc ::SolidSeam::runAction {} {
    # The normal module/shortcut action is intentionally one-step: load the
    # saved settings and enter the native component selector immediately.
    # The separate settings action continues to open the parameter panel.
    ::SolidSeam::loadState
    return [::SolidSeam::runDetection]
}
proc ::SolidSeam::run {} { ::SolidSeam::runAction }
