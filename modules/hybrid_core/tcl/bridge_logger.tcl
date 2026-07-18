proc ::HybridCore::openLog {path} {
    variable logChannel
    variable logPath
    ::HybridCore::closeLog
    file mkdir [file dirname $path]
    set logChannel [open $path a]
    fconfigure $logChannel -encoding utf-8 -translation lf -buffering line
    set logPath $path
    return $path
}

proc ::HybridCore::closeLog {} {
    variable logChannel
    if {$logChannel ne ""} { catch {close $logChannel} }
    set logChannel ""
}

proc ::HybridCore::log {level message} {
    variable logChannel
    set line "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] [string toupper $level] $message"
    # HyperMesh hmbatch does not expose Tcl's stdout channel. Console output
    # is therefore best-effort; the UTF-8 operation log remains authoritative.
    catch {puts $line}
    if {$logChannel ne ""} {
        catch {puts $logChannel $line; flush $logChannel}
    }
    return $line
}

proc ::HybridCore::readMetadataValue {path key {default "unknown"}} {
    if {![file isfile $path]} { return $default }
    if {[catch {set text [::HybridCore::readTextFile $path]}]} { return $default }
    set pattern [format {"%s"\s*:\s*"([^"]*)"} $key]
    if {[regexp $pattern $text -> value] && $value ne ""} { return $value }
    return $default
}

proc ::HybridCore::packageMetadata {} {
    variable ROOT_DIR
    set version "unknown"
    set versionPath [file join $ROOT_DIR VERSION]
    if {[file isfile $versionPath] && ![catch {set version [string trim [::HybridCore::readTextFile $versionPath]]}]} {
        if {$version eq ""} { set version "unknown" }
    }
    set releaseManifest [file join $ROOT_DIR release_manifest.json]
    set runtimeManifest [file join $ROOT_DIR runtime python RUNTIME_MANIFEST.json]
    return [dict create \
        package_version $version \
        build_time_utc [::HybridCore::readMetadataValue $releaseManifest build_time_utc] \
        source_commit [::HybridCore::readMetadataValue $releaseManifest source_commit] \
        runtime_version [::HybridCore::readMetadataValue $runtimeManifest version]]
}

proc ::HybridCore::diagnosticSummary {} {
    variable USER_CONFIG_ROOT
    variable CACHE_ROOT
    variable RUNTIME_ROOT
    variable TASK_ROOT
    set result [::HybridCore::packageMetadata]
    set hmVersion "unavailable"
    catch {set hmVersion [hm_info -appinfo VERSION]}
    dict set result hm_version $hmVersion
    dict set result expected_solver_profile OptiStruct
    dict set result user_config_root $USER_CONFIG_ROOT
    dict set result cache_root $CACHE_ROOT
    dict set result runtime_root $RUNTIME_ROOT
    dict set result task_root $TASK_ROOT
    if {[llength [info commands ::HWFlow::engineeringPreflight]] > 0} {
        catch {dict set result preflight_status [dict get [::HWFlow::engineeringPreflight] status]}
    }
    if {[llength [info commands ::HybridCore::workerStatus]] > 0} {
        set status [::HybridCore::workerStatus]
        dict set result worker_alive [dict get $status alive]
        dict set result worker_pid [dict get $status pid]
        dict set result worker_python [dict get $status executable]
    }
    return $result
}
