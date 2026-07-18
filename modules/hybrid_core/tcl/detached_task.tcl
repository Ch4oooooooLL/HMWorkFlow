proc ::HybridCore::detachedStatusValue {path key fallback} {
    if {![file isfile $path]} {return $fallback}
    set text [::HybridCore::readTextFile $path]
    set escaped [regsub -all {([][(){}.*+?^$\\|])} $key {\\\1}]
    set stringPattern [format {"%s"\s*:\s*"([^"]*)"} $escaped]
    set numberPattern [format {"%s"\s*:\s*(-?[0-9]+)} $escaped]
    if {[regexp $stringPattern $text -> value]} {return $value}
    if {[regexp $numberPattern $text -> value]} {return $value}
    return $fallback
}

proc ::HybridCore::terminateProcessTree {pid} {
    if {$pid eq "" || ![string is integer -strict $pid]} {return 0}
    if {$::tcl_platform(platform) eq "windows"} {
        return [expr {![catch {exec taskkill /PID $pid /T /F}]}]
    }
    return [expr {![catch {exec kill -TERM $pid}]}]
}

proc ::HybridCore::detachedWaitTick {variableName} {
    upvar #0 $variableName tick
    incr tick
}

proc ::HybridCore::runDetachedPythonStage {entry arguments taskDir stage taskToken {progressCommand ""} {timeoutMs 1800000}} {
    if {![file isfile $entry]} {error "Python entry not found: $entry"}
    if {$taskToken eq ""} {error "Detached task token is required"}
    set python [::HybridCore::resolvePython]
    set safeStage [string map [list "-" "_"] $stage]
    set statusPath [file join $taskDir "python_${safeStage}_status.json"]
    set stdoutPath [file join $taskDir "python_${safeStage}_stdout.log"]
    set stderrPath [file join $taskDir "python_${safeStage}_stderr.log"]
    foreach path [list $statusPath $stdoutPath $stderrPath] {
        if {[file exists $path]} {file delete -force $path}
    }
    set command [concat $python [list $entry] $arguments [list --status-file $statusPath --task-token $taskToken]]
    if {[catch {set pid [exec {*}$command > $stdoutPath 2> $stderrPath &]} launchError]} {
        error "Could not launch detached Python stage $stage: $launchError"
    }
    ::HybridCore::writeTextFile [file join $taskDir "python_${safeStage}.meta"] \
        "stage $stage\npid $pid\ntask_token $taskToken\nstarted_epoch [clock seconds]\n"
    set tickVariable ::HybridCore::detachedTick_[pid]_[clock clicks -milliseconds]
    set $tickVariable 0
    set started [clock milliseconds]
    set cancelStarted 0
    while {![file isfile $statusPath]} {
        if {[file exists [file join $taskDir cancel.flag]]} {
            if {$cancelStarted == 0} {set cancelStarted [clock milliseconds]}
            if {[clock milliseconds] - $cancelStarted > 3000} {
                ::HybridCore::terminateProcessTree $pid
                unset $tickVariable
                error "Detached Python stage $stage was cancelled and its process tree was terminated"
            }
        }
        if {[clock milliseconds] - $started > $timeoutMs} {
            ::HybridCore::writeTextFile [file join $taskDir cancel.flag] "timeout\n"
            ::HybridCore::terminateProcessTree $pid
            unset $tickVariable
            error "Detached Python stage $stage timed out; process tree $pid was terminated"
        }
        if {$progressCommand ne ""} {catch {uplevel #0 [concat $progressCommand [list $stage]]}}
        after 100 [list ::HybridCore::detachedWaitTick $tickVariable]
        vwait $tickVariable
    }
    unset $tickVariable
    set returnedToken [::HybridCore::detachedStatusValue $statusPath task_token ""]
    if {$returnedToken ne $taskToken} {
        error "Detached Python stage $stage returned a stale or missing task token"
    }
    set exitCode [::HybridCore::detachedStatusValue $statusPath exit_code -1]
    if {$exitCode != 0} {
        set detail ""
        if {[file isfile $stderrPath]} {set detail [string trim [::HybridCore::readTextFile $stderrPath]]}
        error "Detached Python stage $stage failed (exit $exitCode): $detail"
    }
    return [dict create stage $stage pid $pid task_token $taskToken status $statusPath stdout $stdoutPath stderr $stderrPath]
}
