proc ::SolidSeam::runDetection {} {
    variable ui; variable candidateRows; variable mode; variable runtimeDir
    if {[catch {
        ::SolidSeam::validateSettings
        ::SolidSeam::saveState
        set ui(status) [::SolidSeam::txt "正在选择组件..." "Selecting components..."]; update idletasks
        set componentIds [::SolidSeam::selectComponents]
        if {[llength $componentIds] == 0} { error "__SOLID_SEAM_CANCEL__" }
        set ui(status) [::SolidSeam::txt "正在分类组件..." "Classifying components..."]; update idletasks
        set classification [::SolidSeam::classifySelection $componentIds]
        ::SolidSeam::newRun
        set ui(status) [::SolidSeam::txt "正在导出网格拓扑..." "Exporting mesh topology..."]; update idletasks
        set meshPath [::SolidSeam::exportMeshData $classification]
        set requestPath [::SolidSeam::writeRequest]
        set ui(status) [::SolidSeam::txt "Python 正在识别候选焊缝..." "Python is detecting seam candidates..."]; update idletasks
        ::SolidSeam::runPythonDetection $requestPath $meshPath
        if {$ui(auto_accept_high)} { ::SolidSeam::acceptHighConfidence }
        set ui(status) [::SolidSeam::txt "识别完成：模式 $mode；候选 [llength $candidateRows] 条。运行目录：$runtimeDir" "Detection complete: mode $mode; [llength $candidateRows] candidates. Run directory: $runtimeDir"]
        ::SolidSeam::showCandidateWindow
    } err opts]} {
        if {$err eq "__SOLID_SEAM_CANCEL__"} {
            set ui(status) [::SolidSeam::txt "用户取消选择。" "Selection cancelled."]
            return 0
        }
        set ui(status) [::SolidSeam::txt "执行失败：$err" "Execution failed: $err"]
        ::SolidSeam::log ERROR $err
        ::SolidSeam::message error $ui(status)
        # The failure has already been presented to the user. Do not rethrow
        # into the Tk shortcut callback, which would display the same error a
        # second time together with an internal stack trace.
        return 0
    }
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
