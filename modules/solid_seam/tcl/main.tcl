proc ::SolidSeam::runDetection {} {
    variable ui; variable candidateRows; variable mode; variable detectedMode; variable requiresReview; variable runtimeDir
    if {[catch {
        ::SolidSeam::validateSettings
        ::SolidSeam::saveState
        set ui(status) [::SolidSeam::txt "正在选择组件..." "Selecting components..."]; update idletasks
        set componentIds [::SolidSeam::selectComponents]
        if {[llength $componentIds] == 0} { error "__SOLID_SEAM_CANCEL__" }
        set primaryIds [lsort -integer -unique [::SolidSeam::selectedComponentsForDetection]]
        set ui(status) [::SolidSeam::txt "正在自动识别焊缝位置与类型..." "Auto-detecting seam locations and types..."]; update idletasks
        ::SolidSeam::autoDetectAndCreate $primaryIds
        set ui(status) [::SolidSeam::txt "创建批次完成：$::SolidSeam::lastResultSummary" "Creation batch complete: $::SolidSeam::lastResultSummary"]
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
