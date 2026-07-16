proc ::HybridCore::runProcess {command taskDir} {
    set stdoutPath [::HybridCore::taskFile $taskDir python_stdout.log]
    set stderrPath [::HybridCore::taskFile $taskDir python_stderr.log]
    foreach path [list $stdoutPath $stderrPath] {
        if {[file exists $path]} { file delete -force $path }
    }
    ::HybridCore::log INFO "process start mode=one-shot command=$command"
    set started [clock clicks -milliseconds]
    set code [catch {exec {*}$command > $stdoutPath 2> $stderrPath} result opts]
    set elapsed [expr {([clock clicks -milliseconds] - $started) / 1000.0}]
    if {$code} {
        set detail ""
        if {[file isfile $stderrPath]} { catch {set detail [::HybridCore::readTextFile $stderrPath]} }
        ::HybridCore::log ERROR "process failed elapsed=$elapsed error=$result"
        error "Python process failed: $result\n$detail\nLog: $stderrPath"
    }
    ::HybridCore::log INFO "process complete mode=one-shot elapsed=$elapsed"
    return [dict create stdout $stdoutPath stderr $stderrPath elapsed_seconds $elapsed mode one-shot]
}

proc ::HybridCore::workerAlive {} {
    variable workerChannel
    if {$workerChannel eq ""} { return 0 }
    if {[catch {eof $workerChannel} ended] || $ended} { return 0 }
    return 1
}

proc ::HybridCore::stopPersistentWorker {} {
    variable workerChannel; variable workerPid; variable workerPython
    if {$workerChannel ne ""} {
        catch {fconfigure $workerChannel -blocking 1}
        catch {puts $workerChannel {"command":"shutdown"}; flush $workerChannel}
        catch {close $workerChannel}
    }
    set workerChannel ""; set workerPid ""; set workerPython ""
}

proc ::HybridCore::workerStatus {} {
    variable instanceId; variable workerPid; variable workerPython; variable workerStartupError
    return [dict create \
        instance_id $instanceId \
        owner_pid [pid] \
        worker_pid $workerPid \
        executable $workerPython \
        alive [::HybridCore::workerAlive] \
        startup_error $workerStartupError]
}

proc ::HybridCore::startPersistentWorker {} {
    variable workerChannel; variable workerPid; variable workerPython; variable MODULE_DIR
    if {[::HybridCore::workerAlive]} { return $workerChannel }
    ::HybridCore::stopPersistentWorker
    set python [::HybridCore::resolvePython]
    set worker [file join $MODULE_DIR python persistent_worker.py]
    if {![file isfile $worker]} { error "Persistent Python worker not found: $worker" }
    set command [concat $python [list -u $worker --owner-pid [pid] --instance-id $::HybridCore::instanceId]]
    if {[catch {set channel [open [concat | $command] r+]} err]} { error "Cannot start persistent Python worker: $err" }
    fconfigure $channel -blocking 0 -buffering line -encoding utf-8 -translation lf
    set workerChannel $channel; set workerPid [pid $channel]; set workerPython [lindex $python 0]
    ::HybridCore::log INFO "persistent worker started pid=$workerPid executable=$workerPython"
    return $workerChannel
}

proc ::HybridCore::workerFileFingerprint {path} {
    variable workerFileFingerprints
    set normalized [file normalize $path]
    if {[info exists workerFileFingerprints] && [dict exists $workerFileFingerprints $normalized]} {
        return [dict get $workerFileFingerprints $normalized]
    }
    set channel [open $normalized r]
    fconfigure $channel -encoding binary -translation binary
    set code [catch {read $channel} data opts]
    catch {close $channel}
    if {$code} { return -options $opts $data }
    return [::HybridCore::workerContentFingerprint $data]
}

proc ::HybridCore::workerInputFingerprints {arguments} {
    set rows {}
    for {set index 0} {$index < [llength $arguments] - 1} {incr index} {
        if {[lindex $arguments $index] ne "--mesh"} { continue }
        set path [file normalize [lindex $arguments [incr index]]]
        if {![file isfile $path]} { continue }
        lappend rows "[::HybridCore::jsonString $path]: [::HybridCore::jsonString [::HybridCore::workerFileFingerprint $path]]"
    }
    return "{[join $rows ,]}"
}

proc ::HybridCore::workerRequestJson {requestId entry arguments taskDir} {
    set encoded {}
    foreach value $arguments { lappend encoded [::HybridCore::jsonString $value] }
    set fingerprints [::HybridCore::workerInputFingerprints $arguments]
    return "{\"request_id\": [::HybridCore::jsonString $requestId], \"entry\": [::HybridCore::jsonString $entry], \"arguments\": \[[join $encoded ,]\], \"task_dir\": [::HybridCore::jsonString $taskDir], \"input_fingerprints\": $fingerprints}"
}

proc ::HybridCore::workerReadable {channel requestId} {
    variable workerWaitDone; variable workerWaitResponse; variable workerWaitError
    while {[gets $channel line]>=0} {
        if {[string match "HYBRID\t$requestId\t*" $line]} {
            set workerWaitResponse $line
            set workerWaitDone 1
            return
        }
    }
    if {[eof $channel]} {
        set workerWaitError "Persistent Python worker exited unexpectedly"
        set workerWaitDone 1
    }
}

proc ::HybridCore::workerProgressTick {started} {
    variable workerWaitDone; variable workerProgressAfter
    if {$workerWaitDone} { return }
    ::HybridCore::pulseProgress [expr {([clock milliseconds]-$started)/1000.0}]
    set workerProgressAfter [after 150 [list ::HybridCore::workerProgressTick $started]]
}

proc ::HybridCore::workerTimeout {} {
    variable workerWaitDone; variable workerWaitError
    set workerWaitError "Persistent Python worker timed out"
    set workerWaitDone 1
}

proc ::HybridCore::runPersistentProcess {entry arguments taskDir} {
    variable workerSequence; variable workerRequestTimeoutMs; variable workerChannel
    variable workerWaitDone; variable workerWaitResponse; variable workerWaitError; variable workerProgressAfter
    variable workerCacheHits; variable workerCacheMisses; variable workerCacheEntries
    set channel [::HybridCore::startPersistentWorker]
    incr workerSequence
    set requestId "[pid]-$workerSequence-[clock milliseconds]"
    set request [::HybridCore::workerRequestJson $requestId $entry $arguments $taskDir]
    set stdoutPath [::HybridCore::taskFile $taskDir python_stdout.log]
    set stderrPath [::HybridCore::taskFile $taskDir python_stderr.log]
    ::HybridCore::log INFO "process start mode=persistent request_id=$requestId worker_pid=[pid $channel] entry=$entry"
    set started [clock milliseconds]
    if {[catch {puts $channel $request; flush $channel} sendErr]} {
        ::HybridCore::stopPersistentWorker
        error "Persistent Python worker send failed: $sendErr"
    }
    set workerWaitDone 0; set workerWaitResponse ""; set workerWaitError ""
    fileevent $channel readable [list ::HybridCore::workerReadable $channel $requestId]
    set timeoutAfter [after $workerRequestTimeoutMs ::HybridCore::workerTimeout]
    set workerProgressAfter [after 150 [list ::HybridCore::workerProgressTick $started]]
    vwait ::HybridCore::workerWaitDone
    fileevent $channel readable {}
    after cancel $timeoutAfter
    if {$workerProgressAfter ne ""} { after cancel $workerProgressAfter; set workerProgressAfter "" }
    if {$workerWaitError ne ""} {
        set waitError $workerWaitError
        ::HybridCore::stopPersistentWorker
        error "$waitError. Log: $stderrPath"
    }
    set response $workerWaitResponse
    set fields [split $response "\t"]
    set state [lindex $fields 2]; set exitCode [lindex $fields 3]; set elapsed [lindex $fields 4]
    if {[llength $fields] >= 8} {
        set workerCacheHits [lindex $fields 5]
        set workerCacheMisses [lindex $fields 6]
        set workerCacheEntries [lindex $fields 7]
    }
    if {$state ne "OK" || $exitCode != 0} {
        set detail ""
        if {[file isfile $stderrPath]} { catch {set detail [::HybridCore::readTextFile $stderrPath]} }
        ::HybridCore::log ERROR "process failed mode=persistent request_id=$requestId exit_code=$exitCode"
        return -code error -errorcode [list HYBRID WORKER TASK $exitCode] \
            "Python worker task failed (exit $exitCode).\n$detail\nLog: $stderrPath"
    }
    ::HybridCore::completeProgressRange
    ::HybridCore::log INFO "process complete mode=persistent request_id=$requestId elapsed=$elapsed cache_hits=$workerCacheHits cache_misses=$workerCacheMisses cache_entries=$workerCacheEntries"
    return [dict create stdout $stdoutPath stderr $stderrPath elapsed_seconds $elapsed mode persistent worker_pid [pid $channel] cache_hits $workerCacheHits cache_misses $workerCacheMisses cache_entries $workerCacheEntries]
}

proc ::HybridCore::runPythonEntry {entry arguments taskDir} {
    variable persistentWorkerEnabled
    if {![file isfile $entry]} { error "Python entry not found: $entry" }
    if {$persistentWorkerEnabled} {
        set code [catch {set result [::HybridCore::runPersistentProcess $entry $arguments $taskDir]} err opts]
        if {!$code} { return $result }
        if {[dict exists $opts -errorcode] &&
            [lrange [dict get $opts -errorcode] 0 2] eq {HYBRID WORKER TASK}} {
            return -options $opts $err
        }
        ::HybridCore::log WARN "persistent worker unavailable; falling back to one-shot process: $err"
        ::HybridCore::stopPersistentWorker
    }
    set python [::HybridCore::resolvePython]
    set command [concat $python [list $entry] $arguments]
    return [::HybridCore::runProcess $command $taskDir]
}
