proc ::SolidSeam::pythonCandidates {} {
    variable ROOT_DIR
    return [list \
        [list [file normalize [file join $ROOT_DIR runtime python windows-x64 python.exe]]] \
        [list python3] [list python]]
}

proc ::SolidSeam::resolvePython {} {
    foreach candidate [::SolidSeam::pythonCandidates] {
        set executable [lindex $candidate 0]
        if {[file pathtype $executable] eq "absolute" && ![file isfile $executable]} { continue }
        if {![catch {exec {*}$candidate -c {import json,sys; assert sys.version_info >= (3, 8)}}]} { return $candidate }
    }
    error [::SolidSeam::txt "未找到可用 Python 3.8+ 运行时。" "No usable Python 3.8+ runtime was found."]
}

proc ::SolidSeam::runPythonDetection {requestPath meshPaths} {
    variable MODULE_DIR; variable runtimeDir; variable candidateRows
    set entry [file join $MODULE_DIR python main.py]
    if {![file isfile $entry]} { error "Python entry not found: $entry" }
    set output [file join $runtimeDir candidates.json]
    set tclOutput [file join $runtimeDir candidates.tcl]
    set stdout [file join $runtimeDir python_stdout.log]
    set stderr [file join $runtimeDir python_stderr.log]
    set meshArgs {}
    foreach meshPath $meshPaths { lappend meshArgs --mesh $meshPath }
    set command [concat [::SolidSeam::resolvePython] [list $entry --request $requestPath] $meshArgs [list --output $output --tcl-output $tclOutput --log [file join $runtimeDir operation.log]]]
    ::SolidSeam::log INFO "python launch"
    if {[catch {exec {*}$command > $stdout 2> $stderr} err opts]} {
        set detail [::HWFlow::readTextFile $stderr]
        error [::SolidSeam::txt "焊缝识别程序失败：$err\n$detail" "Seam detection failed: $err\n$detail"]
    }
    if {![file isfile $output] || ![file isfile $tclOutput]} { error [::SolidSeam::txt "Python 未生成有效候选结果。" "Python did not create valid candidate outputs."] }
    set candidateRows {}
    if {[catch {source $tclOutput} err]} { error [::SolidSeam::txt "候选结果无法读取：$err" "Candidate sidecar cannot be read: $err"] }
    ::SolidSeam::log INFO "python complete candidates=[llength $candidateRows]"
    return $candidateRows
}
