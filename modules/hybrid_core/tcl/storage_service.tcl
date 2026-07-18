namespace eval ::HybridCore {
    variable USER_CONFIG_ROOT ""
    variable CACHE_ROOT ""
    variable RUNTIME_ROOT ""
}

proc ::HybridCore::storageEnvRoot {name fallback} {
    if {[info exists ::env($name)] && [string trim $::env($name)] ne ""} {
        return [file normalize $::env($name)]
    }
    return [file normalize $fallback]
}

proc ::HybridCore::initializeStorage {} {
    variable ROOT_DIR
    variable USER_CONFIG_ROOT
    variable CACHE_ROOT
    variable RUNTIME_ROOT
    variable TASK_ROOT
    variable instanceId
    variable instanceLogDir

    set roaming [::HybridCore::storageEnvRoot APPDATA [file join $ROOT_DIR runtime user]]
    set local [::HybridCore::storageEnvRoot LOCALAPPDATA [file join $ROOT_DIR runtime local]]
    set USER_CONFIG_ROOT [file join $roaming HMWorkFlow]
    set CACHE_ROOT [file join $local HMWorkFlow cache]
    set configuredScratch ""
    if {[llength [info commands ::HWFlow::configScalar]] > 0} {
        set configuredScratch [string trim [::HWFlow::configScalar storage scratch_dir ""]]
    }
    if {$configuredScratch ne ""} {
        set RUNTIME_ROOT [file normalize $configuredScratch]
    } else {
        set RUNTIME_ROOT [file join $local HMWorkFlow runtime]
    }
    set TASK_ROOT [file join $RUNTIME_ROOT tasks]
    set instanceLogDir [file join $RUNTIME_ROOT instances $instanceId]
    foreach path [list $USER_CONFIG_ROOT $CACHE_ROOT $TASK_ROOT $instanceLogDir] {
        file mkdir $path
        if {![file writable $path]} {error "HMWorkFlow storage is not writable: $path"}
    }
    return [dict create config $USER_CONFIG_ROOT cache $CACHE_ROOT runtime $RUNTIME_ROOT tasks $TASK_ROOT]
}

proc ::HybridCore::newTaskToken {} {
    return "[pid]-[clock clicks -milliseconds]-[format %08x [expr {int(rand()*0x7fffffff)}]]"
}

proc ::HybridCore::writeTaskMetadata {taskDir status token} {
    set path [file join $taskDir task.meta]
    set text "schema_version 1\nstatus $status\ntask_token $token\nupdated_epoch [clock seconds]\n"
    ::HybridCore::writeTextFile $path $text
}

proc ::HybridCore::taskToken {taskDir} {
    set path [file join $taskDir task.meta]
    if {![file isfile $path]} {return ""}
    set text [::HybridCore::readTextFile $path]
    if {[regexp -line {^task_token\s+(.+)$} $text -> token]} {return [string trim $token]}
    return ""
}

proc ::HybridCore::finalizeTaskWorkspace {taskDir status} {
    set token [::HybridCore::taskToken $taskDir]
    if {$token eq ""} {set token [::HybridCore::newTaskToken]}
    ::HybridCore::writeTaskMetadata $taskDir [string toupper $status] $token
    return $taskDir
}

proc ::HybridCore::pinTaskWorkspace {taskDir {pinned 1}} {
    set marker [file join $taskDir .pinned]
    if {$pinned} {
        ::HybridCore::writeTextFile $marker "pinned\n"
    } elseif {[file exists $marker]} {
        file delete -force $marker
    }
}

proc ::HybridCore::pathWithin {child parent} {
    set child [file normalize $child]
    set parent [file normalize $parent]
    return [expr {$child ne $parent && [string first "${parent}[file separator]" "${child}[file separator]"] == 0}]
}

proc ::HybridCore::directorySize {path} {
    set total 0
    foreach filePath [glob -nocomplain -types f [file join $path *]] {
        catch {incr total [file size $filePath]}
    }
    foreach directory [glob -nocomplain -types d [file join $path *]] {
        incr total [::HybridCore::directorySize $directory]
    }
    return $total
}

proc ::HybridCore::cleanupTaskWorkspaces {} {
    variable TASK_ROOT
    if {![file isdirectory $TASK_ROOT]} {return 0}
    set successDays 7
    set failureDays 30
    set keepLatest 10
    set maxDiskGb 20
    if {[llength [info commands ::HWFlow::configScalar]] > 0} {
        set successDays [::HWFlow::configScalar storage success_retention_days 7]
        set failureDays [::HWFlow::configScalar storage failure_retention_days 30]
        set keepLatest [::HWFlow::configScalar storage success_keep_latest 10]
        set maxDiskGb [::HWFlow::configScalar storage max_disk_gb 20]
    }
    set now [clock seconds]
    set removed 0
    array set preserve {}
    foreach moduleDir [glob -nocomplain -types d [file join $TASK_ROOT *]] {
        set successes {}
        foreach taskDir [glob -nocomplain -types d [file join $moduleDir *]] {
            set meta [file join $taskDir task.meta]
            if {[file isfile $meta] && [regexp -line {^status\s+SUCCESS$} [::HybridCore::readTextFile $meta]]} {
                lappend successes [list [file mtime $taskDir] $taskDir]
            }
        }
        set successes [lsort -integer -decreasing -index 0 $successes]
        foreach pair [lrange $successes 0 [expr {$keepLatest - 1}]] {set preserve([lindex $pair 1]) 1}
    }
    foreach moduleDir [glob -nocomplain -types d [file join $TASK_ROOT *]] {
        foreach taskDir [glob -nocomplain -types d [file join $moduleDir *]] {
            if {[file exists [file join $taskDir .pinned]]} {continue}
            if {[info exists preserve($taskDir)]} {continue}
            set status UNKNOWN
            set meta [file join $taskDir task.meta]
            if {[file isfile $meta] && [regexp -line {^status\s+(.+)$} [::HybridCore::readTextFile $meta] -> value]} {
                set status [string toupper [string trim $value]]
            }
            if {$status in {RUNNING READY}} {continue}
            set days [expr {$status in {FAILED ERROR CANCELLED} ? $failureDays : $successDays}]
            if {$now - [file mtime $taskDir] <= $days * 86400} {continue}
            if {![::HybridCore::pathWithin $taskDir $TASK_ROOT]} {continue}
            file delete -force $taskDir
            incr removed
        }
    }
    if {[string is double -strict $maxDiskGb] && $maxDiskGb > 0} {
        set limit [expr {wide($maxDiskGb * 1024 * 1024 * 1024)}]
        set total [::HybridCore::directorySize $TASK_ROOT]
        set candidates {}
        foreach moduleDir [glob -nocomplain -types d [file join $TASK_ROOT *]] {
            foreach taskDir [glob -nocomplain -types d [file join $moduleDir *]] {
                if {[file exists [file join $taskDir .pinned]] || [info exists preserve($taskDir)]} {continue}
                set meta [file join $taskDir task.meta]
                set status UNKNOWN
                if {[file isfile $meta] && [regexp -line {^status\s+(.+)$} [::HybridCore::readTextFile $meta] -> value]} {set status [string toupper [string trim $value]]}
                if {$status in {RUNNING READY}} {continue}
                lappend candidates [list [file mtime $taskDir] $taskDir [::HybridCore::directorySize $taskDir]]
            }
        }
        foreach record [lsort -integer -index 0 $candidates] {
            if {$total <= $limit} {break}
            set taskDir [lindex $record 1]
            if {![::HybridCore::pathWithin $taskDir $TASK_ROOT]} {continue}
            file delete -force $taskDir
            incr total -[lindex $record 2]
            incr removed
        }
    }
    return $removed
}
